import AppKit
import Observation

/// A dotted version number, compared part by part as numbers.
enum Version {
    static func parts(_ text: String) -> [Int] {
        text.trimmingCharacters(in: .whitespaces)
            .drop { $0 == "v" || $0 == "V" }
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let new = parts(candidate)
        let old = parts(current)
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

struct Release: Equatable {
    let version: String
    let page: URL
}

/// Asks the project's public release list whether a newer version exists.
/// It only reports. Getting the update is left to the person, because an
/// unnotarized download has nothing to be verified against.
@MainActor
@Observable
final class UpdateChecker {
    static let releasesPage = "https://github.com/hypomaniac/Procul/releases"
    private static let latest = URL(string: "https://api.github.com/repos/hypomaniac/Procul/releases/latest")!
    private static let day: TimeInterval = 24 * 60 * 60

    private(set) var available: Release?

    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let current: String
    @ObservationIgnored private let fetch: () async throws -> Data
    @ObservationIgnored private var lastCheck = Date.distantPast
    @ObservationIgnored private var timer: Timer?

    init(
        prefs: Preferences,
        current: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        fetch: @escaping () async throws -> Data = UpdateChecker.download
    ) {
        self.prefs = prefs
        self.current = current
        self.fetch = fetch
    }

    /// Checks now, then again whenever a day has gone by. The hourly timer
    /// is what notices, since a sleeping Mac does not fire timers on time.
    func start() {
        Task { await check() }
        timer = .scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.lastCheck) >= Self.day else { return }
                await self.check()
            }
        }
    }

    /// The switch in the menu.
    func setEnabled(_ enabled: Bool) {
        prefs.checksForUpdates = enabled
        if enabled {
            Task { await check() }
        } else {
            available = nil
        }
    }

    func check() async {
        guard prefs.checksForUpdates else {
            available = nil
            return
        }
        lastCheck = Date()
        // No network, or no public release yet. Either way there is nothing to say.
        guard let data = try? await fetch(), let release = Self.parse(data) else { return }
        available = Version.isNewer(release.version, than: current) ? release : nil
    }

    func openReleasePage() {
        guard let available else { return }
        NSWorkspace.shared.open(available.page)
    }

    /// Reads GitHub's "latest release" answer. A page that is not this
    /// project's own release page is refused, so a strange answer cannot
    /// send the browser somewhere else.
    static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let link = json["html_url"] as? String,
              link.hasPrefix(releasesPage + "/"),
              let page = URL(string: link),
              json["draft"] as? Bool != true,
              json["prerelease"] as? Bool != true,
              !Version.parts(tag).isEmpty else { return nil }
        return Release(version: String(tag.drop { $0 == "v" || $0 == "V" }), page: page)
    }

    static func download() async throws -> Data {
        var request = URLRequest(url: latest)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
