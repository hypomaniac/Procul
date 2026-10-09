import AppKit
import Observation
import os

struct Device: Identifiable, Equatable {
    let id: String
    var name: String
    var model: String
    var os: String
    var paired: Bool
    var nowPlayingPaired: Bool

    init?(_ event: HelperChannel.Event) {
        guard let id = event["id"] as? String, let name = event["name"] as? String else { return nil }
        self.id = id
        self.name = name
        model = event["model"] as? String ?? ""
        os = event["os"] as? String ?? ""
        paired = event["paired"] as? Bool ?? false
        nowPlayingPaired = event["nowPlayingPaired"] as? Bool ?? false
    }

    init(id: String, name: String, model: String = "", os: String = "", paired: Bool = true, nowPlayingPaired: Bool = false) {
        self.id = id
        self.name = name
        self.model = model
        self.os = os
        self.paired = paired
        self.nowPlayingPaired = nowPlayingPaired
    }
}

struct TVApp: Identifiable, Equatable {
    let id: String
    let name: String
}

struct NowPlaying: Equatable {
    var state: String
    var title: String?
    var artist: String?
    var app: String?

    var isPlaying: Bool { state == "playing" }
    var headline: String? { title ?? app }
    var detail: String? { title == nil ? nil : (artist ?? app) }
}

/// A PIN prompt for one of the two pairings. The remote itself needs
/// `companion`. Now Playing needs `airplay` as well.
struct Pairing: Equatable {
    static let remote = "companion"
    static let nowPlaying = "airplay"

    var deviceID: String
    var kind: String
    var awaitingPIN = false
}

enum RemoteKey: String {
    case up, down, left, right, select, menu, home
    case playPause = "play_pause"
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"
    case skipForward = "skip_forward"
    case skipBackward = "skip_backward"
    case controlCenter = "control_center"
}

enum PressAction: String {
    case single, double, hold
}

@MainActor
@Observable
final class RemoteModel {
    enum Status: Equatable {
        case starting
        case searching
        case connecting
        case connected
        case needsPairing
        case offline(String)
        case failed(String)
    }

    var status: Status = .starting {
        didSet {
            guard status != oldValue else { return }
            log.info("status \(String(describing: self.status), privacy: .public)")
        }
    }
    var devices: [Device] = []
    var pairing: Pairing?
    var power = "unknown"
    var keyboardFocused = false
    var keyboardText = ""
    var nowPlaying: NowPlaying?
    var apps: [TVApp] = []
    var notice: String?

    let prefs: Preferences

    var selectedID: String? { prefs.selectedDevice }
    var device: Device? { devices.first { $0.id == selectedID } }

    /// Pinned apps that are still installed, in the order they were chosen.
    var favoriteApps: [TVApp] {
        prefs.favorites.compactMap { id in apps.first { $0.id == id } }
    }

    /// True when the remote works but the second pairing was never done
    /// and nobody has said Later.
    var needsNowPlayingSetup: Bool {
        guard status == .connected, pairing == nil, let device else { return false }
        return !device.nowPlayingPaired && !prefs.setupPromptDismissed(for: device.id)
    }

    /// Called when the Apple TV puts up a text field, or takes it away.
    @ObservationIgnored var onTextWanted: ((Bool) -> Void)?

    @ObservationIgnored private let helper: HelperChannel
    @ObservationIgnored private let log = Logger(subsystem: AppInfo.bundleID, category: "remote")
    @ObservationIgnored private var tvText = ""
    @ObservationIgnored private var reconnects = 0
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var noticeToken = 0

    init(helper: HelperChannel = HelperProcess(), prefs: Preferences) {
        self.helper = helper
        self.prefs = prefs
    }

    // Lifecycle

    func start() {
        helper.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        helper.onExit = { [weak self] status in
            MainActor.assumeIsolated { self?.helperExited(status) }
        }
        launchHelper()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshConnection() }
        }
    }

    func stop() {
        helper.stop()
    }

    private func launchHelper() {
        status = .starting
        do {
            try helper.start()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func helperExited(_ code: Int32) {
        guard restarts < 3 else {
            status = .failed("The helper keeps stopping. See the log in ~/Library/Logs/\(AppInfo.name).")
            return
        }
        restarts += 1
        status = .starting
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.launchHelper() }
    }

    func restartHelper() {
        restarts = 0
        launchHelper()
    }

    /// The panel was opened. Make sure there is a live connection behind it.
    func panelOpened() {
        reconnects = 0
        if isOffline, pairing == nil { connect() }
    }

    /// A sleeping Mac leaves a dead socket behind. Start over after waking.
    private func refreshConnection() {
        guard status == .connected || isOffline, selectedID != nil, pairing == nil else { return }
        connect()
    }

    // Commands

    func search() {
        status = .searching
        helper.send(["cmd": "scan"])
    }

    func select(_ device: Device) {
        pairing = nil
        prefs.selectedDevice = device.id
        connect()
    }

    func connect() {
        guard let selectedID else {
            search()
            return
        }
        status = .connecting
        nowPlaying = nil
        keyboardFocused = false
        helper.send(["cmd": "connect", "id": selectedID])
    }

    func press(_ key: RemoteKey, _ action: PressAction = .single) {
        guard status == .connected || (isOffline && selectedID != nil) else { return }
        helper.send(["cmd": "key", "key": key.rawValue, "action": action.rawValue])
    }

    /// A click on the power button. It only ever turns the TV on.
    func powerTapped() {
        guard status == .connected else { return }
        if power == "on" {
            show("Hold the power button to turn the TV off.")
        } else {
            helper.send(["cmd": "power", "on": true])
        }
    }

    func powerHeld() {
        guard status == .connected else { return }
        helper.send(["cmd": "power", "on": false])
    }

    /// Mirror the text field to the TV. Text the TV just reported is not sent back.
    func sendText(_ text: String) {
        guard keyboardFocused, text != tvText else { return }
        tvText = text
        helper.send(["cmd": "text", "text": text])
    }

    func launch(_ app: TVApp) {
        guard status == .connected else { return }
        helper.send(["cmd": "launch", "id": app.id])
    }

    func toggleFavorite(_ app: TVApp) {
        if !prefs.toggleFavorite(app.id) {
            show("The row holds \(Preferences.maxFavorites). Remove one first.")
        }
    }

    func beginPairing(kind: String = Pairing.remote) {
        guard let selectedID else { return }
        pairing = Pairing(deviceID: selectedID, kind: kind)
        helper.send(["cmd": "pair_begin", "id": selectedID, "protocol": kind])
    }

    func submitPIN(_ pin: String) {
        guard pairing?.awaitingPIN == true else { return }
        pairing?.awaitingPIN = false
        helper.send(["cmd": "pair_pin", "pin": pin])
    }

    /// Cancel on the first code, Skip on the second.
    func cancelPairing() {
        guard let pairing else { return }
        self.pairing = nil
        helper.send(["cmd": "pair_cancel"])
        if pairing.kind == Pairing.nowPlaying {
            prefs.dismissSetupPrompt(for: pairing.deviceID)
            connect()
        }
    }

    func dismissSetupPrompt() {
        guard let selectedID else { return }
        prefs.dismissSetupPrompt(for: selectedID)
    }

    func forgetDevice() {
        guard let selectedID else { return }
        helper.send(["cmd": "forget", "id": selectedID])
    }

    /// True when the remote itself is on screen, so keys mean TV buttons.
    var acceptsKeys: Bool {
        switch status {
        case .connected, .connecting: true
        case .offline: selectedID != nil
        case .starting, .searching, .needsPairing, .failed: false
        }
    }

    private var isOffline: Bool {
        if case .offline = status { return true }
        return false
    }

    // Events

    func handle(_ event: HelperChannel.Event) {
        switch event["event"] as? String {
        case "ready":
            restarts = 0
            search()

        case "devices":
            let found = (event["devices"] as? [HelperChannel.Event] ?? []).compactMap(Device.init)
            devices = found
            if selectedID == nil, found.count == 1 {
                prefs.selectedDevice = found[0].id
            }
            if device != nil {
                connect()
            } else if found.isEmpty {
                status = .offline("No Apple TV found on this network.")
            } else {
                status = .offline("Choose an Apple TV.")
            }

        case "needs_pairing":
            update(event)
            status = .needsPairing

        case "pin_requested":
            pairing?.awaitingPIN = true

        case "paired":
            let kind = event["protocol"] as? String ?? pairing?.kind
            pairing = nil
            if kind == Pairing.remote {
                // Setup is two codes. Go straight on to the second.
                beginPairing(kind: Pairing.nowPlaying)
            } else {
                connect()
            }

        case "pair_failed":
            let kind = pairing?.kind
            pairing = nil
            show(event["message"] as? String)
            if kind == Pairing.nowPlaying {
                connect()
            } else {
                status = .needsPairing
            }

        case "connected":
            update(event)
            reconnects = 0
            status = .connected
            power = event["power"] as? String ?? "unknown"
            setKeyboard(focused: event["keyboardFocused"] as? Bool ?? false, text: "")
            helper.send(["cmd": "apps"])

        case "disconnected":
            guard pairing == nil else { break }
            let reason = event["reason"] as? String ?? ""
            log.info("disconnected \(reason, privacy: .public)")
            status = .offline(reason.isEmpty ? "Not connected." : reason)
            nowPlaying = nil
            setKeyboard(focused: false, text: "")
            // One quiet retry covers a TV that dropped the link while idle.
            if !reason.isEmpty, reconnects < 1 {
                reconnects += 1
                connect()
            }

        case "power":
            power = event["state"] as? String ?? "unknown"

        case "keyboard":
            setKeyboard(focused: event["focused"] as? Bool ?? false, text: event["text"] as? String ?? "")

        case "playing":
            let state = event["state"] as? String ?? "idle"
            let playing = NowPlaying(
                state: state,
                title: event["title"] as? String,
                artist: event["artist"] as? String,
                app: event["app"] as? String
            )
            nowPlaying = (state == "idle" && playing.headline == nil) ? nil : playing

        case "apps":
            apps = (event["apps"] as? [HelperChannel.Event] ?? []).compactMap { app in
                guard let id = app["id"] as? String else { return nil }
                return TVApp(id: id, name: app["name"] as? String ?? id)
            }

        case "forgotten":
            if let id = event["id"] as? String { prefs.forget(device: id) }
            prefs.selectedDevice = nil
            apps = []
            search()

        case "error":
            log.error("helper error \(String(describing: event["cmd"] ?? ""), privacy: .public): \(event["message"] as? String ?? "", privacy: .public)")
            if let kind = pairing?.kind, event["cmd"] as? String == "pair_begin" {
                pairing = nil
                if kind == Pairing.nowPlaying { connect() }
            }
            show(event["message"] as? String)

        default:
            break
        }
    }

    private func setKeyboard(focused: Bool, text: String) {
        let changed = focused != keyboardFocused
        keyboardFocused = focused
        tvText = text
        keyboardText = text
        if changed { onTextWanted?(focused) }
    }

    private func update(_ event: HelperChannel.Event) {
        guard let device = Device(event) else { return }
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
    }

    /// Show a short message at the bottom of the remote for a few seconds.
    func show(_ message: String?) {
        notice = message
        noticeToken += 1
        let token = noticeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.noticeToken == token else { return }
            self.notice = nil
        }
    }
}
