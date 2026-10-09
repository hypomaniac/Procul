import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        #if DEBUG
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.count > flag + 1 {
            MainActor.assumeIsolated { Snapshot.write(to: CommandLine.arguments[flag + 1]) }
            return
        }
        #endif
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences()
    private lazy var model = RemoteModel(prefs: prefs)
    private let icons = AppIcons()
    private let notifier = Notifier()
    private let hotKey = HotKey()
    private var panel: PanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app has no windows most of the time. It should stay running anyway.
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar remote")

        panel = PanelController(model: model, prefs: prefs, icons: icons, notifier: notifier, hotKey: hotKey)

        notifier.start()
        notifier.onOpen = { [weak self] in
            self?.panel.show(focusText: true)
        }
        model.onTextWanted = { [weak self] wanted in
            guard let self else { return }
            if wanted, self.prefs.notifyOnText, !self.panel.hasKeyboard {
                self.notifier.textWanted(on: self.model.device?.name ?? "The Apple TV")
            } else if !wanted {
                self.notifier.clear()
            }
        }

        model.start()

        #if DEBUG
        listenForDebugCommands()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    #if DEBUG
    /// Lets a script drive a debug build, since nothing else can press its
    /// buttons: `toggle`, `hotkey`, `pin`, `mode:favorites`, `snapshot:<path>`
    /// and `state:<path>`, posted as the object of a distributed notification.
    private func listenForDebugCommands() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("\(AppInfo.bundleID).debug"), object: nil, queue: .main
        ) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.run(debug: command) }
        }
    }

    private func run(debug command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "toggle":
            if panel.isVisible { panel.hide() } else { panel.show() }
        case "hotkey":
            panel.hotKeyPressed()
        case "pin":
            panel.togglePin()
        case "mode":
            panel.state.mode = ["favorites": .favorites, "shortcut": .shortcut][argument] ?? .remote
        case "favorite":
            prefs.toggleFavorite(argument)
        case "snapshot":
            panel.writeSnapshot(to: argument)
        case "state":
            let frame = panel.frame
            let state: [String: Any] = [
                "visible": panel.isVisible,
                "keyboard": panel.hasKeyboard,
                "pinned": panel.state.pinned,
                "frame": [frame.minX, frame.minY, frame.width, frame.height],
                "status": String(describing: model.status),
                "power": model.power,
                "apps": model.apps.count,
                "favorites": model.favoriteApps.map(\.name),
                "nowPlayingPaired": model.device?.nowPlayingPaired ?? false,
                "playing": model.nowPlaying?.headline ?? "",
                "shortcut": prefs.shortcut.display,
            ]
            let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: URL(fileURLWithPath: argument))
        default:
            break
        }
    }
    #endif
}
