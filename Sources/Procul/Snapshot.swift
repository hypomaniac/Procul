#if DEBUG
import AppKit
import SwiftUI

/// Renders the remote in each of its states to PNG files, so the layout can
/// be checked without a paired Apple TV. Run with `--snapshot <directory>`.
@MainActor
enum Snapshot {
    private static let apps = [
        TVApp(id: "com.example.films", name: "Films"),
        TVApp(id: "com.example.music", name: "Music"),
        TVApp(id: "com.example.news", name: "News"),
        TVApp(id: "com.example.photos", name: "Photos"),
        TVApp(id: "com.example.settings", name: "Settings"),
        TVApp(id: "com.example.sport", name: "Sport"),
        TVApp(id: "com.example.video", name: "Video"),
    ]

    static func write(to directory: String) {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let full = Device(id: "tv", name: "Living Room", nowPlayingPaired: true)
        let remoteOnly = Device(id: "tv", name: "Living Room")
        let unpaired = Device(id: "tv", name: "Living Room", paired: false)

        render("connected", to: folder) { model, _, _ in
            model.devices = [full]
            model.status = .connected
            model.power = "on"
        }
        render("update-available", to: folder, newer: "9.0") { model, _, _ in
            model.devices = [full]
            model.status = .connected
            model.power = "on"
        }
        render("playing-typing-favorites", to: folder) { model, prefs, panel in
            model.devices = [full]
            model.status = .connected
            model.power = "on"
            model.apps = apps
            prefs.favorites = apps.prefix(6).map(\.id)
            model.nowPlaying = NowPlaying(state: "playing", title: "The Long Way Round", artist: "Episode 4", app: "Video")
            model.keyboardFocused = true
            model.keyboardText = "long way"
            panel.pinned = true
        }
        render("finish-setup", to: folder) { model, prefs, panel in
            model.devices = [remoteOnly]
            model.status = .connected
            model.power = "on"
            model.apps = apps
            prefs.favorites = apps.prefix(3).map(\.id)
            panel.pinned = true
            panel.keyboardLive = false
        }
        render("favorites-editor", to: folder) { model, prefs, panel in
            model.devices = [full]
            model.status = .connected
            model.apps = apps
            prefs.favorites = [apps[0].id, apps[6].id]
            panel.mode = .favorites
        }
        render("shortcut", to: folder) { model, _, panel in
            model.devices = [full]
            model.status = .connected
            panel.mode = .shortcut
        }
        render("offline", to: folder) { model, _, _ in
            model.devices = [full]
            model.status = .offline("Connection lost")
        }
        render("needs-pairing", to: folder) { model, _, _ in
            model.devices = [unpaired]
            model.status = .needsPairing
        }
        render("pin-second", to: folder) { model, _, _ in
            model.devices = [remoteOnly]
            model.status = .connected
            model.pairing = Pairing(deviceID: "tv", kind: Pairing.nowPlaying, awaitingPIN: true)
        }
        render("none-found", to: folder) { model, prefs, _ in
            prefs.selectedDevice = nil
            model.status = .offline("No Apple TV found on this network.")
        }
    }

    private static func render(
        _ name: String,
        to folder: URL,
        newer: String? = nil,
        configure: (RemoteModel, Preferences, PanelState) -> Void
    ) {
        let prefs = Preferences(defaults: MemorySettings())
        prefs.selectedDevice = "tv"
        let model = RemoteModel(prefs: prefs)
        let panel = PanelState()
        configure(model, prefs, panel)

        // A canned answer in place of the network, when the state calls for one.
        let answer = newer.map {
            Data(#"{"tag_name":"v\#($0)","html_url":"\#(UpdateChecker.releasesPage)/tag/v\#($0)"}"#.utf8)
        }
        let updates = UpdateChecker(prefs: prefs, current: "1.0") {
            guard let answer else { throw URLError(.notConnectedToInternet) }
            return answer
        }
        if answer != nil {
            Task { await updates.check() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = RemoteView(
                model: model, prefs: prefs, panel: panel,
                icons: AppIcons(fetches: false), notifier: Notifier(), updates: updates
            )
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)

            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))

            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let url = folder.appendingPathComponent("\(name)-\(suffix).png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
#endif
