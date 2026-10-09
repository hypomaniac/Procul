import Carbon.HIToolbox
import Foundation

/// One system-wide keyboard shortcut. The Carbon hot key API is the only
/// one that works from any app without asking for Accessibility access.
final class HotKey {
    var onPress: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return noErr }
                let me = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { me.onPress?() }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    deinit {
        unregister()
        if let handler { RemoveEventHandler(handler) }
    }

    /// Returns false when another app already owns the shortcut.
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        // "PRCL"
        let id = EventHotKeyID(signature: 0x5052_434C, id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotKey
        )
        return status == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}
