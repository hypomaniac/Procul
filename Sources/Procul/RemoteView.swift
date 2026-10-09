import ServiceManagement
import SwiftUI

struct RemoteView: View {
    @Bindable var model: RemoteModel
    let prefs: Preferences
    let panel: PanelState
    let icons: AppIcons
    let notifier: Notifier
    let updates: UpdateChecker

    var body: some View {
        VStack(spacing: 14) {
            HeaderView(model: model, prefs: prefs, panel: panel, notifier: notifier, updates: updates)
            content
            if let release = updates.available {
                HStack(spacing: 5) {
                    Text("Version \(release.version) is available.")
                    Button("Get It") { updates.openReleasePage() }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 252)
        // The panel takes its height from here. Without this, text that
        // wraps is measured as one line and the last line is cut off.
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        if let pairing = model.pairing {
            PairingView(model: model, pairing: pairing)
        } else if panel.mode == .shortcut {
            ShortcutRecorder(prefs: prefs, panel: panel)
        } else if panel.mode == .favorites, model.status == .connected {
            FavoritesEditor(model: model, prefs: prefs, panel: panel)
        } else {
            switch model.status {
            case .starting, .searching:
                MessageView(symbol: nil, text: "Looking for Apple TVs.")
            case .needsPairing:
                MessageView(
                    symbol: "appletv",
                    text: "Pair with \(model.device?.name ?? "your Apple TV") to use it from this Mac. Two codes will appear on the TV, one after the other.",
                    button: "Pair",
                    action: { model.beginPairing() }
                )
            case .failed(let message):
                MessageView(
                    symbol: "exclamationmark.triangle",
                    text: message,
                    button: "Try Again",
                    action: { model.restartHelper() }
                )
            case .offline(let message) where model.device == nil:
                DevicePicker(model: model, message: message)
            case .connecting, .connected, .offline:
                PadView(model: model, prefs: prefs, panel: panel, icons: icons)
            }
        }
    }
}

// Header

private struct HeaderView: View {
    @Bindable var model: RemoteModel
    let prefs: Preferences
    let panel: PanelState
    let notifier: Notifier
    let updates: UpdateChecker
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Menu {
                if let release = updates.available {
                    Button("Get Version \(release.version)…") { updates.openReleasePage() }
                    Divider()
                }
                ForEach(model.devices) { device in
                    Toggle(device.name, isOn: Binding(
                        get: { device.id == model.selectedID },
                        set: { _ in model.select(device) }
                    ))
                }
                if !model.devices.isEmpty { Divider() }
                Button("Search Again") { model.search() }
                if model.status == .connected {
                    if model.device?.nowPlayingPaired == false {
                        Button("Set Up Now Playing…") { model.beginPairing(kind: Pairing.nowPlaying) }
                    }
                    Button("Edit Favorites…") { panel.mode = .favorites }
                }
                Divider()
                Toggle("Notify When the TV Wants Text", isOn: Binding(
                    get: { prefs.notifyOnText },
                    set: { setNotifies($0) }
                ))
                Toggle("Open at Login", isOn: Binding(
                    get: { opensAtLogin },
                    set: { setOpensAtLogin($0) }
                ))
                Toggle("Check for Updates", isOn: Binding(
                    get: { prefs.checksForUpdates },
                    set: { updates.setEnabled($0) }
                ))
                Button("Change Shortcut (\(prefs.shortcut.display))…") { panel.mode = .shortcut }
                Divider()
                if model.device != nil {
                    Button("Forget This Apple TV") { model.forgetDevice() }
                }
                Button("Quit \(AppInfo.name)") { NSApp.terminate(nil) }
            } label: {
                Text(model.device?.name ?? AppInfo.name)
                    .font(.headline)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer(minLength: 0)

            KeyButton(
                shape: Circle(),
                help: panel.pinned ? "Unpin. The remote goes back under the menu bar." : "Pin. The remote stays open and floats.",
                tap: { panel.togglePin() }
            ) {
                Image(systemName: panel.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(panel.pinned ? .primary : .secondary)
            }
            .frame(width: 30, height: 30)

            KeyButton(
                shape: Circle(),
                help: "Power. Click to turn on. Hold to turn off.",
                held: .action { model.powerHeld() },
                tap: { model.powerTapped() }
            ) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.power == "off" ? .secondary : .primary)
            }
            .frame(width: 30, height: 30)
            .opacity(model.status == .connected ? 1 : 0)
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .connected: .green
        case .starting, .searching, .connecting: .yellow
        case .needsPairing, .offline: .secondary
        case .failed: .red
        }
    }

    private func setNotifies(_ enabled: Bool) {
        guard enabled else {
            prefs.notifyOnText = false
            return
        }
        notifier.requestPermission { granted in
            prefs.notifyOnText = granted
            if !granted {
                model.show("Allow notifications for \(AppInfo.name) in System Settings, then turn this on again.")
            }
        }
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            model.show("Open at Login could not be changed.")
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// The remote itself

private struct PadView: View {
    @Bindable var model: RemoteModel
    let prefs: Preferences
    let panel: PanelState
    let icons: AppIcons
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 14) {
            if model.needsNowPlayingSetup {
                SetupPrompt(model: model)
            }

            controls
                .opacity(model.status == .connected ? 1 : 0.45)

            if model.keyboardFocused {
                TextField("Type on Apple TV", text: $model.keyboardText)
                    .textFieldStyle(.roundedBorder)
                    .focused($typing)
                    .onSubmit { typing = false }
                    .onChange(of: model.keyboardText) { _, text in model.sendText(text) }
                    .onChange(of: panel.textFocusRequests) { typing = true }
                    .onAppear { typing = true }
            }

            footer
        }
        .animation(.default, value: model.keyboardFocused)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if let playing = model.nowPlaying, let headline = playing.headline {
                NowPlayingView(playing: playing, headline: headline)
            }

            DPad(model: model)
                .frame(width: 204, height: 204)

            HStack(alignment: .top, spacing: 28) {
                VStack(spacing: 12) {
                    round("Back. Hold for Home.", "chevron.backward", held: .action { model.press(.home) }) {
                        model.press(.menu)
                    }
                    round(playPauseHelp, playPauseSymbol) { model.press(.playPause) }
                    AppsButton(model: model, panel: panel)
                }
                VStack(spacing: 12) {
                    round("TV. Hold for Control Center.", "tv", held: .action { model.press(.controlCenter) }) {
                        model.press(.home)
                    }
                    VolumeRocker(model: model)
                }
            }

            HStack(spacing: 28) {
                small("Back 10 Seconds", "gobackward.10") { model.press(.skipBackward) }
                small("Forward 10 Seconds", "goforward.10") { model.press(.skipForward) }
            }

            if !model.favoriteApps.isEmpty {
                FavoritesRow(model: model, icons: icons)
            }
        }
        .task(id: prefs.favorites) { icons.load(prefs.favorites) }
    }

    /// With Now Playing set up the button shows what a press will do.
    private var playPauseSymbol: String {
        guard let playing = model.nowPlaying else { return "playpause.fill" }
        return playing.isPlaying ? "pause.fill" : "play.fill"
    }

    private var playPauseHelp: String {
        guard let playing = model.nowPlaying else { return "Play or Pause" }
        return playing.isPlaying ? "Pause" : "Play"
    }

    @ViewBuilder
    private var footer: some View {
        switch model.status {
        case .offline(let message):
            HStack(spacing: 6) {
                Text(message)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reconnect") { model.connect() }
                    .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .connecting:
            Text("Connecting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            Text(panel.keyboardLive
                ? "Arrow keys, Return, Esc\nand Space work too."
                : "Click the remote or press \(prefs.shortcut.display)\nto use the keyboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func round(
        _ help: String,
        _ symbol: String,
        held: KeyButton<Circle, Image>.Held = .nothing,
        tap: @escaping () -> Void
    ) -> some View {
        KeyButton(shape: Circle(), help: help, held: held, tap: tap) {
            Image(systemName: symbol)
        }
        .font(.system(size: 20, weight: .medium))
        .frame(width: 62, height: 62)
    }

    private func small(_ help: String, _ symbol: String, tap: @escaping () -> Void) -> some View {
        KeyButton(shape: Capsule(), help: help, tap: tap) {
            Image(systemName: symbol)
        }
        .font(.system(size: 14, weight: .medium))
        .frame(width: 62, height: 30)
    }
}

private struct DPad: View {
    let model: RemoteModel

    private static let inner: CGFloat = 0.46

    var body: some View {
        ZStack {
            direction("Up", "chevron.up", .up, angle: -90, x: 0, y: -1)
            direction("Right", "chevron.right", .right, angle: 0, x: 1, y: 0)
            direction("Down", "chevron.down", .down, angle: 90, x: 0, y: 1)
            direction("Left", "chevron.left", .left, angle: 180, x: -1, y: 0)

            KeyButton(
                shape: Circle(),
                help: "Select",
                held: .action { model.press(.select, .hold) },
                tap: { model.press(.select) }
            ) {
                // EmptyView would take the background and the hit area away with it.
                Color.clear
            }
            .frame(width: 204 * Self.inner - 8, height: 204 * Self.inner - 8)
        }
    }

    private func direction(
        _ help: String,
        _ symbol: String,
        _ key: RemoteKey,
        angle: Double,
        x: CGFloat,
        y: CGFloat
    ) -> some View {
        KeyButton(
            shape: Sector(angle: .degrees(angle), inner: Self.inner),
            help: help,
            held: .repeats,
            tap: { model.press(key) }
        ) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .offset(x: x * 74, y: y * 74)
        }
    }
}

private struct VolumeRocker: View {
    let model: RemoteModel

    var body: some View {
        VStack(spacing: 0) {
            half("Volume Up", "plus", .volumeUp)
            half("Volume Down", "minus", .volumeDown)
        }
        .font(.system(size: 20, weight: .medium))
        .frame(width: 62, height: 136)
        .clipShape(Capsule())
    }

    private func half(_ help: String, _ symbol: String, _ key: RemoteKey) -> some View {
        KeyButton(shape: Rectangle(), help: help, held: .repeats, tap: { model.press(key) }) {
            Image(systemName: symbol)
        }
    }
}

private struct AppsButton: View {
    let model: RemoteModel
    let panel: PanelState

    var body: some View {
        Menu {
            if model.apps.isEmpty {
                Text("No apps listed")
            }
            ForEach(model.apps) { app in
                Button(app.name) { model.launch(app) }
            }
            if !model.apps.isEmpty {
                Divider()
                Button("Edit Favorites…") { panel.mode = .favorites }
            }
        } label: {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 62, height: 62)
                .background(Circle().fill(Color.primary.opacity(0.09)))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: 62, height: 62)
        .help("Apps")
    }
}

/// Up to six pinned apps, one click each.
private struct FavoritesRow: View {
    let model: RemoteModel
    let icons: AppIcons

    var body: some View {
        HStack(spacing: 8) {
            ForEach(model.favoriteApps) { app in
                Button {
                    model.launch(app)
                } label: {
                    AppTile(app: app, image: icons.images[app.id])
                }
                .buttonStyle(.plain)
                .help(app.name)
                .accessibilityLabel(app.name)
            }
        }
    }
}

private struct AppTile: View {
    let app: TVApp
    let image: NSImage?

    /// Stable across launches, which hashValue is not.
    private var hue: Double {
        Double(app.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                // No artwork. A letter on a colour picked by the app's name.
                ZStack {
                    Color(hue: hue, saturation: 0.45, brightness: 0.55)
                    Text(String(app.name.prefix(1)).uppercased())
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct NowPlayingView: View {
    let playing: NowPlaying
    let headline: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: playing.isPlaying ? "play.fill" : "pause.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let detail = playing.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
    }
}

/// Shown once on a Mac that has the remote paired but not Now Playing.
private struct SetupPrompt: View {
    let model: RemoteModel

    var body: some View {
        VStack(spacing: 8) {
            Text("Finish setup to see what is playing. The TV will show one more code.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Later") { model.dismissSetupPrompt() }
                Button("Finish Setup") { model.beginPairing(kind: Pairing.nowPlaying) }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
    }
}

// Everything that is not the remote

private struct MessageView: View {
    var symbol: String?
    var text: String
    var button: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let button, let action {
                Button(button, action: action)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

private struct DevicePicker: View {
    let model: RemoteModel
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "appletv")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.devices) { device in
                Button(device.name) { model.select(device) }
            }
            Button("Search Again") { model.search() }
            if model.devices.isEmpty {
                Text("If macOS asked whether \(AppInfo.name) may find devices on your local network, allow it. The switch is in System Settings under Privacy & Security, Local Network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

private struct PairingView: View {
    let model: RemoteModel
    let pairing: Pairing
    @State private var pin = ""
    @FocusState private var focused: Bool

    private var second: Bool { pairing.kind == Pairing.nowPlaying }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "appletv")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            if pairing.awaitingPIN {
                Text(second
                    ? "Enter the second code shown on \(name). This one adds what is playing."
                    : "Enter the code shown on \(name).")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Code", text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .frame(width: 110)
                    .focused($focused)
                    .onSubmit(submit)
                    .onAppear { focused = true }
                HStack {
                    Button(second ? "Skip" : "Cancel") { model.cancelPairing() }
                    Button("Pair", action: submit)
                        .disabled(pin.filter(\.isNumber).count < 4)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for the Apple TV.")
                    .font(.callout)
                Button(second ? "Skip" : "Cancel") { model.cancelPairing() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var name: String { model.device?.name ?? "your Apple TV" }

    private func submit() {
        let code = pin.filter(\.isNumber)
        guard code.count >= 4 else { return }
        model.submitPIN(code)
        pin = ""
    }
}

/// A checklist of every app on the TV. Ticked apps become the row of
/// one-click buttons on the remote.
private struct FavoritesEditor: View {
    let model: RemoteModel
    let prefs: Preferences
    let panel: PanelState

    var body: some View {
        VStack(spacing: 10) {
            Text("Favorites")
                .font(.headline)
            Text("Choose up to \(Preferences.maxFavorites). They appear on the remote in the order you tick them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.apps) { app in
                        row(app)
                    }
                }
            }
            .frame(height: 330)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 9))

            Button("Done") { panel.mode = .remote }
        }
    }

    private func row(_ app: TVApp) -> some View {
        let chosen = prefs.isFavorite(app.id)
        return Button {
            model.toggleFavorite(app)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen ? Color.accentColor : .secondary)
                Text(app.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// Waits for the next key press, which the panel controller turns into the
/// new global shortcut.
private struct ShortcutRecorder: View {
    let prefs: Preferences
    let panel: PanelState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Press the new shortcut. It opens the remote from any app.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Now: \(prefs.shortcut.display)")
                .font(.title3)
            Text("Include Control, Option or Command. Esc cancels.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Cancel") { panel.mode = .remote }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
