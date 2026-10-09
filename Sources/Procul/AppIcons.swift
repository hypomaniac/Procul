import AppKit
import Observation

/// Icons for pinned apps. Each one is fetched once from Apple's public App
/// Store lookup and kept on disk. Apps with no listing (Apple's own, mostly)
/// get a lettered tile instead, and that answer is remembered too.
@MainActor
@Observable
final class AppIcons {
    private(set) var images: [String: NSImage] = [:]

    @ObservationIgnored private var settled: Set<String> = []
    @ObservationIgnored private let fetches: Bool
    @ObservationIgnored private var folder: URL {
        AppInfo.supportDirectory.appendingPathComponent("icons", isDirectory: true)
    }

    /// Layout snapshots pass false, so they touch neither the disk nor the network.
    init(fetches: Bool = true) {
        self.fetches = fetches
    }

    func load(_ ids: [String]) {
        guard fetches else { return }
        for id in ids where !settled.contains(id) {
            settled.insert(id)
            Task { await load(id) }
        }
    }

    private func load(_ id: String) async {
        let fm = FileManager.default
        let file = folder.appendingPathComponent("\(id).png")
        let none = folder.appendingPathComponent("\(id).none")
        if let image = NSImage(contentsOf: file) {
            images[id] = image
            return
        }
        if fm.fileExists(atPath: none.path) { return }

        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            guard let data = try await Self.fetch(id) else {
                fm.createFile(atPath: none.path, contents: nil)
                return
            }
            try data.write(to: file)
            images[id] = NSImage(data: data)
        } catch {
            // Offline or similar. Try again next launch.
            settled.remove(id)
        }
    }

    /// Returns nil when the App Store has no artwork for the app.
    private static func fetch(_ id: String) async throws -> Data? {
        for entity in ["", "&entity=tvSoftware"] {
            guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let lookup = URL(string: "https://itunes.apple.com/lookup?bundleId=\(escaped)\(entity)&limit=1") else { continue }
            let (body, _) = try await URLSession.shared.data(from: lookup)
            guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let result = (json["results"] as? [[String: Any]])?.first,
                  let artwork = result["artworkUrl512"] as? String ?? result["artworkUrl100"] as? String,
                  let url = URL(string: artwork.replacingOccurrences(of: "512x512bb.jpg", with: "128x128bb.png")) else { continue }
            let (image, response) = try await URLSession.shared.data(from: url)
            if (response as? HTTPURLResponse)?.statusCode == 200, NSImage(data: image) != nil {
                return image
            }
        }
        return nil
    }
}
