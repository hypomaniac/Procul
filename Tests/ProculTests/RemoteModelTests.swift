import AppKit
import Carbon.HIToolbox
import Testing
@testable import Procul

/// Stands in for the pyatv helper. Records what the model sends and lets a
/// test play events back.
final class FakeHelper: HelperChannel {
    var onEvent: ((Event) -> Void)?
    var onExit: ((Int32) -> Void)?
    private(set) var sent: [[String: Any]] = []
    private(set) var started = 0

    func start() throws { started += 1 }
    func send(_ command: [String: Any]) { sent.append(command) }
    func stop() {}

    /// The commands sent so far, as their names, then forgets them.
    func drain() -> [String] {
        defer { sent = [] }
        return sent.compactMap { $0["cmd"] as? String }
    }

    var last: [String: Any] { sent.last ?? [:] }
}

@MainActor
struct Rig {
    let helper = FakeHelper()
    let prefs = Preferences(defaults: MemorySettings())
    let model: RemoteModel

    static let tv = "AA:BB:CC:DD:EE:FF"

    init() {
        model = RemoteModel(helper: helper, prefs: prefs)
    }

    func device(paired: Bool = true, nowPlaying: Bool = true) -> [String: Any] {
        ["id": Self.tv, "name": "Den", "model": "Apple TV 4K", "os": "tvOS 26", "paired": paired, "nowPlayingPaired": nowPlaying]
    }

    func send(_ event: String, _ fields: [String: Any] = [:]) {
        var fields = fields
        fields["event"] = event
        model.handle(fields)
    }

    /// Runs the model up to a live connection.
    func connect(nowPlaying: Bool = true, power: String = "on") {
        send("ready")
        send("devices", ["devices": [device(nowPlaying: nowPlaying)]])
        var connected = device(nowPlaying: nowPlaying)
        connected["power"] = power
        connected["keyboardFocused"] = false
        send("connected", connected)
        _ = helper.drain()
    }
}

@MainActor
@Suite("Finding and connecting")
struct ConnectingTests {
    @Test func readySearchesAndTheOnlyTVIsChosen() {
        let rig = Rig()
        rig.send("ready")
        #expect(rig.model.status == .searching)
        #expect(rig.helper.drain() == ["scan"])

        rig.send("devices", ["devices": [rig.device()]])
        #expect(rig.prefs.selectedDevice == Rig.tv)
        #expect(rig.model.status == .connecting)
        #expect(rig.helper.last["cmd"] as? String == "connect")
        #expect(rig.helper.last["id"] as? String == Rig.tv)
    }

    @Test func nothingFoundSaysSo() {
        let rig = Rig()
        rig.send("ready")
        rig.send("devices", ["devices": [] as [Any]])
        #expect(rig.model.status == .offline("No Apple TV found on this network."))
        #expect(rig.model.acceptsKeys == false)
    }

    @Test func severalTVsWaitForAChoice() {
        let rig = Rig()
        rig.send("ready")
        var second = rig.device()
        second["id"] = "11:22:33:44:55:66"
        rig.send("devices", ["devices": [rig.device(), second]])
        #expect(rig.prefs.selectedDevice == nil)
        #expect(rig.model.status == .offline("Choose an Apple TV."))
    }

    @Test func connectedAsksForTheAppList() {
        let rig = Rig()
        rig.send("ready")
        rig.send("devices", ["devices": [rig.device()]])
        _ = rig.helper.drain()
        var connected = rig.device()
        connected["power"] = "off"
        rig.send("connected", connected)
        #expect(rig.model.status == .connected)
        #expect(rig.model.power == "off")
        #expect(rig.helper.drain() == ["apps"])
    }

    @Test func aDroppedLinkIsRetriedOnce() {
        let rig = Rig()
        rig.connect()
        rig.send("disconnected", ["reason": "Connection lost"])
        #expect(rig.model.status == .connecting)
        #expect(rig.helper.drain() == ["connect"])

        rig.send("disconnected", ["reason": "Connection lost"])
        #expect(rig.model.status == .offline("Connection lost"))
        #expect(rig.helper.drain().isEmpty)
    }

    @Test func openingThePanelReconnects() {
        let rig = Rig()
        rig.connect()
        rig.send("disconnected", ["reason": ""])
        #expect(rig.model.status == .offline("Not connected."))
        rig.model.panelOpened()
        #expect(rig.helper.drain() == ["connect"])
    }
}

@MainActor
@Suite("Pairing")
struct PairingTests {
    @Test func setupIsTwoCodesInARow() {
        let rig = Rig()
        rig.send("ready")
        rig.send("devices", ["devices": [rig.device(paired: false, nowPlaying: false)]])
        rig.send("needs_pairing", rig.device(paired: false, nowPlaying: false))
        #expect(rig.model.status == .needsPairing)
        _ = rig.helper.drain()

        rig.model.beginPairing()
        #expect(rig.helper.last["protocol"] as? String == "companion")
        #expect(rig.model.pairing?.awaitingPIN == false)

        rig.send("pin_requested", ["protocol": "companion"])
        #expect(rig.model.pairing?.awaitingPIN == true)

        rig.model.submitPIN("1234")
        #expect(rig.helper.last["pin"] as? String == "1234")

        rig.send("paired", ["protocol": "companion"])
        #expect(rig.model.pairing?.kind == Pairing.nowPlaying)
        #expect(rig.helper.last["cmd"] as? String == "pair_begin")
        #expect(rig.helper.last["protocol"] as? String == "airplay")

        rig.send("pin_requested", ["protocol": "airplay"])
        rig.model.submitPIN("5678")
        rig.send("paired", ["protocol": "airplay"])
        #expect(rig.model.pairing == nil)
        #expect(rig.helper.last["cmd"] as? String == "connect")
    }

    @Test func aWrongFirstCodeGoesBackToThePairScreen() {
        let rig = Rig()
        rig.send("ready")
        rig.send("devices", ["devices": [rig.device(paired: false, nowPlaying: false)]])
        rig.send("needs_pairing", rig.device(paired: false, nowPlaying: false))
        rig.model.beginPairing()
        rig.send("pin_requested")
        rig.model.submitPIN("0000")
        rig.send("pair_failed", ["protocol": "companion", "message": "That code did not work. Try again."])
        #expect(rig.model.pairing == nil)
        #expect(rig.model.status == .needsPairing)
        #expect(rig.model.notice == "That code did not work. Try again.")
    }

    @Test func skippingTheSecondCodeStillConnectsAndStopsAsking() {
        let rig = Rig()
        rig.connect(nowPlaying: false)
        #expect(rig.model.needsNowPlayingSetup)

        rig.model.beginPairing(kind: Pairing.nowPlaying)
        rig.send("pin_requested")
        _ = rig.helper.drain()
        rig.model.cancelPairing()
        #expect(rig.helper.drain() == ["pair_cancel", "connect"])

        var connected = rig.device(nowPlaying: false)
        connected["power"] = "on"
        rig.send("connected", connected)
        #expect(rig.model.needsNowPlayingSetup == false)
    }

    @Test func laterHidesThePromptForThatTV() {
        let rig = Rig()
        rig.connect(nowPlaying: false)
        rig.model.dismissSetupPrompt()
        #expect(rig.model.needsNowPlayingSetup == false)
        #expect(rig.prefs.setupPromptDismissed(for: Rig.tv))
    }

    @Test func aFullyPairedTVNeverPrompts() {
        let rig = Rig()
        rig.connect(nowPlaying: true)
        #expect(rig.model.needsNowPlayingSetup == false)
    }

    @Test func forgettingStartsOver() {
        let rig = Rig()
        rig.connect(nowPlaying: false)
        rig.model.dismissSetupPrompt()
        rig.model.forgetDevice()
        rig.send("forgotten", ["id": Rig.tv])
        #expect(rig.prefs.selectedDevice == nil)
        #expect(rig.prefs.setupPromptDismissed(for: Rig.tv) == false)
        #expect(rig.model.status == .searching)
    }
}

@MainActor
@Suite("Buttons")
struct ButtonTests {
    @Test func keysCarryTheirAction() {
        let rig = Rig()
        rig.connect()
        rig.model.press(.select, .hold)
        #expect(rig.helper.last["key"] as? String == "select")
        #expect(rig.helper.last["action"] as? String == "hold")
        rig.model.press(.controlCenter)
        #expect(rig.helper.last["key"] as? String == "control_center")
    }

    @Test func keysAreDroppedBeforeThereIsATV() {
        let rig = Rig()
        rig.send("ready")
        rig.send("devices", ["devices": [] as [Any]])
        _ = rig.helper.drain()
        rig.model.press(.up)
        #expect(rig.helper.drain().isEmpty)
    }

    @Test func aClickOnPowerOnlyTurnsOn() {
        let rig = Rig()
        rig.connect(power: "on")
        rig.model.powerTapped()
        #expect(rig.helper.drain().isEmpty)
        #expect(rig.model.notice != nil)

        rig.send("power", ["state": "off"])
        rig.model.powerTapped()
        #expect(rig.helper.last["cmd"] as? String == "power")
        #expect(rig.helper.last["on"] as? Bool == true)
    }

    @Test func holdingPowerTurnsOff() {
        let rig = Rig()
        rig.connect(power: "on")
        rig.model.powerHeld()
        #expect(rig.helper.last["on"] as? Bool == false)
    }
}

@MainActor
@Suite("Text entry")
struct TextTests {
    @Test func textFromTheTVIsNotEchoedBack() {
        let rig = Rig()
        rig.connect()
        rig.send("keyboard", ["focused": true, "text": "sev"])
        #expect(rig.model.keyboardFocused)
        #expect(rig.model.keyboardText == "sev")

        rig.model.sendText("sev")
        #expect(rig.helper.drain().isEmpty)

        rig.model.sendText("seve")
        #expect(rig.helper.last["text"] as? String == "seve")
    }

    @Test func nothingIsSentOnceTheFieldHasGone() {
        let rig = Rig()
        rig.connect()
        rig.send("keyboard", ["focused": true, "text": ""])
        rig.send("keyboard", ["focused": false, "text": ""])
        rig.model.sendText("stray")
        #expect(rig.helper.drain().isEmpty)
    }

    @Test func theTextCallbackFiresOnChangeOnly() {
        let rig = Rig()
        rig.connect()
        var calls: [Bool] = []
        rig.model.onTextWanted = { calls.append($0) }
        rig.send("keyboard", ["focused": true, "text": ""])
        rig.send("keyboard", ["focused": true, "text": "a"])
        rig.send("keyboard", ["focused": false, "text": ""])
        #expect(calls == [true, false])
    }
}

@MainActor
@Suite("Favorites")
struct FavoriteTests {
    private func apps(_ count: Int) -> [[String: Any]] {
        (0..<count).map { ["id": "app.\($0)", "name": "App \($0)"] }
    }

    @Test func theRowKeepsTheOrderChosenAndStopsAtSix() {
        let rig = Rig()
        rig.connect()
        rig.send("apps", ["apps": apps(8)])
        for index in [5, 2, 7, 0, 1, 3] {
            rig.model.toggleFavorite(rig.model.apps[index])
        }
        #expect(rig.model.favoriteApps.map(\.id) == ["app.5", "app.2", "app.7", "app.0", "app.1", "app.3"])

        rig.model.toggleFavorite(rig.model.apps[4])
        #expect(rig.model.favoriteApps.count == 6)
        #expect(rig.model.notice != nil)

        rig.model.toggleFavorite(rig.model.apps[2])
        #expect(rig.model.favoriteApps.map(\.id) == ["app.5", "app.7", "app.0", "app.1", "app.3"])
    }

    @Test func anAppThatWasDeletedDropsOutOfTheRow() {
        let rig = Rig()
        rig.connect()
        rig.send("apps", ["apps": apps(3)])
        rig.model.toggleFavorite(rig.model.apps[1])
        rig.model.toggleFavorite(rig.model.apps[2])
        rig.send("apps", ["apps": Array(apps(3).dropLast())])
        #expect(rig.model.favoriteApps.map(\.id) == ["app.1"])
    }

    @Test func favoritesSurviveARelaunch() {
        let defaults = MemorySettings()
        let first = Preferences(defaults: defaults)
        first.toggleFavorite("a")
        first.toggleFavorite("b")
        first.pinned = true
        first.shortcut = Shortcut(keyCode: 49, modifiers: UInt32(cmdKey), display: "⌘Space")

        let second = Preferences(defaults: defaults)
        #expect(second.favorites == ["a", "b"])
        #expect(second.pinned)
        #expect(second.shortcut.display == "⌘Space")
    }
}

@Suite("Shortcuts")
struct ShortcutTests {
    @Test func theDefaultIsControlOptionR() {
        #expect(Shortcut.standard.keyCode == UInt32(kVK_ANSI_R))
        #expect(Shortcut.standard.modifiers == UInt32(controlKey | optionKey))
    }

    @Test func aRecordedShortcutNamesItsKeys() {
        let shortcut = Shortcut(keyCode: UInt16(kVK_ANSI_T), flags: [.control, .shift, .command], characters: "t")
        #expect(shortcut?.display == "⌃⇧⌘T")
        #expect(shortcut?.modifiers == UInt32(controlKey | shiftKey | cmdKey))
    }

    @Test func aPlainLetterIsRefused() {
        #expect(Shortcut(keyCode: UInt16(kVK_ANSI_T), flags: [], characters: "t") == nil)
        #expect(Shortcut(keyCode: UInt16(kVK_ANSI_T), flags: [.shift], characters: "T") == nil)
    }

    @Test func aFunctionKeyNeedsNoModifier() {
        #expect(Shortcut(keyCode: UInt16(kVK_F8), flags: [], characters: "\u{F70B}")?.display == "F8")
    }

    @Test func spaceIsSpelledOut() {
        #expect(Shortcut(keyCode: UInt16(kVK_Space), flags: [.option], characters: " ")?.display == "⌥Space")
    }
}
