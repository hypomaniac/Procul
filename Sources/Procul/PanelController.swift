import AppKit
import Observation
import SwiftUI

/// What the views need to know about the panel they are drawn in.
@MainActor
@Observable
final class PanelState {
    enum Mode {
        case remote
        case favorites
        case shortcut
    }

    var mode: Mode = .remote
    var pinned = false
    /// True while the panel has the keyboard.
    var keyboardLive = true
    /// Bumped to pull focus into the text field.
    var textFocusRequests = 0

    @ObservationIgnored var togglePin: () -> Void = {}
}

/// A borderless panel that can take the keyboard without making Procul the
/// active app. The app you were using stays in front.
private final class RemotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the menu bar item and the panel. Unpinned, the panel hangs under the
/// menu bar and closes when you click elsewhere. Pinned, it floats above
/// other windows wherever it was dragged.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let state = PanelState()

    private let model: RemoteModel
    private let prefs: Preferences
    private let hotKey: HotKey
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: RemotePanel
    private var hosting: NSHostingController<AnyView>!
    private var keyMonitor: Any?
    private var closedByClickAway = Date.distantPast

    private static let pinnedOriginKey = "pinnedTopLeft"
    private static let cornerRadius: CGFloat = 14

    init(model: RemoteModel, prefs: Preferences, icons: AppIcons, notifier: Notifier, hotKey: HotKey) {
        self.model = model
        self.prefs = prefs
        self.hotKey = hotKey
        panel = RemotePanel(
            contentRect: NSRect(x: 0, y: 0, width: 252, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        state.pinned = prefs.pinned
        state.togglePin = { [weak self] in self?.togglePin() }

        let root = RemoteView(model: model, prefs: prefs, panel: state, icons: icons, notifier: notifier)
            .background(PanelBackground())
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { [weak self] size in
                self?.resize(to: size)
            })
        hosting = NSHostingController(rootView: AnyView(root))
        // The panel is sized by hand so that it grows downward from its top edge.
        hosting.sizingOptions = []

        panel.contentViewController = hosting
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        applyPinned()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "appletvremote.gen4.fill", accessibilityDescription: AppInfo.name)
            button.target = self
            button.action = #selector(statusItemClicked)
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }

        hotKey.onPress = { [weak self] in self?.hotKeyPressed() }
        if !hotKey.register(prefs.shortcut) {
            model.show("\(prefs.shortcut.display) is taken by another app. Choose another shortcut from the menu.")
        }

        // A remote that was left pinned comes back where it was.
        if prefs.pinned {
            DispatchQueue.main.async { [weak self] in self?.show(takingKeyboard: false) }
        }
    }

    // Showing and hiding

    var isVisible: Bool { panel.isVisible }
    var hasKeyboard: Bool { panel.isKeyWindow }
    var frame: NSRect { panel.frame }

    @objc private func statusItemClicked() {
        // The click that closed the panel by taking the keyboard away must not reopen it.
        if Date().timeIntervalSince(closedByClickAway) < 0.3 { return }
        if panel.isVisible { hide() } else { show() }
    }

    /// Unpinned: show or hide. Pinned: hand the keyboard to the remote, or
    /// back to whatever was in front.
    func hotKeyPressed() {
        if !panel.isVisible {
            show()
        } else if !state.pinned {
            hide()
        } else if panel.isKeyWindow {
            releaseKeyboard()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func show(takingKeyboard: Bool = true, focusText: Bool = false) {
        if !panel.isVisible {
            resize(to: hosting.sizeThatFits(in: CGSize(width: 252, height: 4000)))
            place()
        }
        if takingKeyboard {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        if focusText { state.textFocusRequests += 1 }
        model.panelOpened()
    }

    func hide() {
        state.mode = .remote
        panel.orderOut(nil)
    }

    /// Give the keyboard back to the app in front and stay on screen.
    private func releaseKeyboard() {
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    func togglePin() {
        prefs.pinned.toggle()
        state.pinned = prefs.pinned
        applyPinned()
        if state.pinned {
            if let origin = savedOrigin() { setTopLeft(origin) }
        } else {
            place()
        }
    }

    private func applyPinned() {
        panel.level = state.pinned ? .floating : .statusBar
        panel.isMovableByWindowBackground = state.pinned
    }

    // Geometry

    private func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, size != panel.frame.size else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func place() {
        if state.pinned, let origin = savedOrigin() {
            setTopLeft(origin)
            return
        }
        guard let button = statusItem.button, let anchor = button.window?.frame else { return }
        let size = panel.frame.size
        var topLeft = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - 4)
        if let screen = button.window?.screen?.visibleFrame {
            topLeft.x = min(max(topLeft.x, screen.minX + 8), screen.maxX - size.width - 8)
        }
        setTopLeft(topLeft)
    }

    private func setTopLeft(_ point: NSPoint) {
        panel.setFrameTopLeftPoint(point)
    }

    private func savedOrigin() -> NSPoint? {
        guard let text = UserDefaults.standard.string(forKey: Self.pinnedOriginKey) else { return nil }
        let point = NSPointFromString(text)
        // A display that has since been unplugged would strand the remote off screen.
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(point) }
        return onScreen ? point : nil
    }

    // Window delegate

    func windowDidBecomeKey(_ notification: Notification) {
        state.keyboardLive = true
    }

    func windowDidResignKey(_ notification: Notification) {
        state.keyboardLive = false
        if !state.pinned, panel.isVisible {
            closedByClickAway = Date()
            hide()
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard state.pinned, panel.isVisible else { return }
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: Self.pinnedOriginKey)
    }

    // Keyboard

    /// Keyboard control while the remote has the keyboard. Returns true when
    /// the key was used.
    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if state.mode == .shortcut {
            return record(event, modifiers)
        }

        if modifiers.contains(.command) {
            if event.charactersIgnoringModifiers == "q" {
                NSApp.terminate(nil)
                return true
            }
            return false
        }

        // A text field gets its keys. Esc hands the keyboard back to the remote.
        if panel.firstResponder is NSText {
            if event.keyCode == 53 {
                panel.makeFirstResponder(nil)
                return true
            }
            return false
        }

        guard state.mode == .remote, model.pairing == nil, model.acceptsKeys else { return false }
        let hold = modifiers.contains(.shift)

        switch event.keyCode {
        case 126: model.press(.up)
        case 125: model.press(.down)
        case 123: model.press(.left)
        case 124: model.press(.right)
        case 36, 76: model.press(.select, hold ? .hold : .single)
        case 53, 51: model.press(.menu)
        case 49: model.press(.playPause)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "h": model.press(hold ? .controlCenter : .home)
            case "=", "+": model.press(.volumeUp)
            case "-", "_": model.press(.volumeDown)
            case "[": model.press(.skipBackward)
            case "]": model.press(.skipForward)
            default: return false
            }
        }
        return true
    }

    /// The next key press becomes the global shortcut. Esc cancels.
    private func record(_ event: NSEvent, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        if event.keyCode == 53, modifiers.isDisjoint(with: [.command, .control, .option]) {
            state.mode = .remote
            return true
        }
        guard let shortcut = Shortcut(
            keyCode: event.keyCode,
            flags: modifiers,
            characters: event.charactersIgnoringModifiers
        ) else {
            NSSound.beep()
            return true
        }
        let previous = prefs.shortcut
        if hotKey.register(shortcut) {
            prefs.shortcut = shortcut
        } else {
            hotKey.register(previous)
            model.show("\(shortcut.display) is taken by another app.")
        }
        state.mode = .remote
        return true
    }

    #if DEBUG
    /// Draws the live panel to a PNG, for checking layout against a real TV.
    func writeSnapshot(to path: String) {
        guard let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        bitmap.draw(in: view.bounds)
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
    #endif
}

/// The frosted material behind the remote.
private struct PanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
