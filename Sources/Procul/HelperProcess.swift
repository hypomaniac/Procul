import Foundation

enum AppInfo {
    static let name = "Procul"
    static let bundleID = "io.github.hypomaniac.Procul"

    /// Settings, pairing credentials and cached icons.
    static let supportDirectory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent(name, isDirectory: true)
        // Builds before the rename kept the pairing under the old name.
        let old = base.appendingPathComponent("Apple TV Remote", isDirectory: true)
        if !fm.fileExists(atPath: folder.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: folder)
        }
        return folder
    }()

    static let logURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/\(name)/helper.log")
    }()
}

/// The line the model talks down. The real one runs the pyatv helper.
/// Tests put a scripted one in its place.
protocol HelperChannel: AnyObject {
    typealias Event = [String: Any]

    /// Called on the main queue for every event the helper writes.
    var onEvent: ((Event) -> Void)? { get set }
    /// Called on the main queue when the helper exits.
    var onExit: ((Int32) -> Void)? { get set }

    func start() throws
    func send(_ command: [String: Any])
    func stop()
}

/// Runs the pyatv helper and exchanges JSON lines with it.
final class HelperProcess: HelperChannel {
    var onEvent: ((Event) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()

    /// The frozen helper inside the app bundle, or the repo's venv when
    /// PROCUL_DEV_ROOT points at a checkout.
    private static func launchCommand() -> (URL, [String])? {
        let fm = FileManager.default
        if let root = ProcessInfo.processInfo.environment["PROCUL_DEV_ROOT"] {
            let python = URL(fileURLWithPath: root).appendingPathComponent(".venv/bin/python")
            let script = URL(fileURLWithPath: root).appendingPathComponent("helper/atv_helper.py")
            if fm.isExecutableFile(atPath: python.path) {
                return (python, [script.path])
            }
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("helper/atv_helper/atv_helper"),
           fm.isExecutableFile(atPath: bundled.path) {
            return (bundled, [])
        }
        return nil
    }

    func start() throws {
        guard let (executable, arguments) = Self.launchCommand() else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "The helper is missing from the app. Install the app again."
            ])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: AppInfo.supportDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: AppInfo.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: AppInfo.logURL.path, contents: nil)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments + [AppInfo.supportDirectory.appendingPathComponent("credentials.json").path]

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = try FileHandle(forWritingTo: AppInfo.logURL)

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async {
                guard let self, self.process === process else { return }
                self.process = nil
                self.input = nil
                self.onExit?(status)
            }
        }

        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
    }

    func send(_ command: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: command) else { return }
        data.append(0x0A)
        // The helper may have just died. Its exit is reported through onExit.
        try? input.write(contentsOf: data)
    }

    func stop() {
        let process = self.process
        self.process = nil
        // Closing stdin lets the helper disconnect cleanly and exit.
        try? input?.close()
        input = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process?.isRunning == true { process?.terminate() }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let event = try? JSONSerialization.jsonObject(with: line) as? Event else { continue }
            onEvent?(event)
        }
    }
}
