import AppKit
import Carbon.HIToolbox
import Observation

/// A global keyboard shortcut. Modifiers use the Carbon masks, since that
/// is what the hot key API takes.
struct Shortcut: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static let standard = Shortcut(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(controlKey | optionKey),
        display: "⌃⌥R"
    )

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Builds a shortcut from a key press. Returns nil for a press that
    /// would swallow ordinary typing: a plain key with no Control, Option
    /// or Command, unless it is a function key.
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        let function = Self.functionKeys[Int(keyCode)]
        guard function != nil || !flags.intersection([.control, .option, .command]).isEmpty else { return nil }

        var modifiers = 0
        var display = ""
        if flags.contains(.control) { modifiers |= controlKey; display += "⌃" }
        if flags.contains(.option) { modifiers |= optionKey; display += "⌥" }
        if flags.contains(.shift) { modifiers |= shiftKey; display += "⇧" }
        if flags.contains(.command) { modifiers |= cmdKey; display += "⌘" }

        if let function {
            display += function
        } else if Int(keyCode) == kVK_Space {
            display += "Space"
        } else if let key = characters?.uppercased(), !key.isEmpty, key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 0xF700 }) {
            display += key
        } else {
            return nil
        }

        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        self.display = display
    }

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }
}

/// Where preferences are kept. The app uses UserDefaults. Tests and layout
/// snapshots use a dictionary, so they leave nothing on disk.
protocol SettingsStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: SettingsStore {}

final class MemorySettings: SettingsStore {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// Everything this Mac remembers between launches, apart from the pairing.
@MainActor
@Observable
final class Preferences {
    static let maxFavorites = 6

    @ObservationIgnored private let defaults: SettingsStore

    var selectedDevice: String? {
        didSet { defaults.set(selectedDevice, forKey: "selectedDevice") }
    }
    var pinned: Bool {
        didSet { defaults.set(pinned, forKey: "pinned") }
    }
    /// App identifiers, in the order they were chosen.
    var favorites: [String] {
        didSet { defaults.set(favorites, forKey: "favorites") }
    }
    var notifyOnText: Bool {
        didSet { defaults.set(notifyOnText, forKey: "notifyOnText") }
    }
    var checksForUpdates: Bool {
        didSet { defaults.set(checksForUpdates, forKey: "checksForUpdates") }
    }
    var shortcut: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut") }
    }
    /// Devices where the Now Playing prompt was answered with Later.
    private var setupLater: [String] {
        didSet { defaults.set(setupLater, forKey: "setupLater") }
    }

    init(defaults: SettingsStore = UserDefaults.standard) {
        self.defaults = defaults
        selectedDevice = defaults.object(forKey: "selectedDevice") as? String
        pinned = defaults.object(forKey: "pinned") as? Bool ?? false
        favorites = defaults.object(forKey: "favorites") as? [String] ?? []
        notifyOnText = defaults.object(forKey: "notifyOnText") as? Bool ?? false
        checksForUpdates = defaults.object(forKey: "checksForUpdates") as? Bool ?? true
        setupLater = defaults.object(forKey: "setupLater") as? [String] ?? []
        if let data = defaults.object(forKey: "shortcut") as? Data,
           let saved = try? JSONDecoder().decode(Shortcut.self, from: data) {
            shortcut = saved
        } else {
            shortcut = .standard
        }
    }

    func isFavorite(_ id: String) -> Bool {
        favorites.contains(id)
    }

    /// Adds or removes a favorite. Returns false when the row is full.
    @discardableResult
    func toggleFavorite(_ id: String) -> Bool {
        if let index = favorites.firstIndex(of: id) {
            favorites.remove(at: index)
            return true
        }
        guard favorites.count < Self.maxFavorites else { return false }
        favorites.append(id)
        return true
    }

    func setupPromptDismissed(for device: String) -> Bool {
        setupLater.contains(device)
    }

    func dismissSetupPrompt(for device: String) {
        if !setupLater.contains(device) { setupLater.append(device) }
    }

    func forget(device: String) {
        setupLater.removeAll { $0 == device }
    }
}
