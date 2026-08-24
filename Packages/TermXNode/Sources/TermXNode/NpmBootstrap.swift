import Foundation
import TermXCore

/// Makes `npm` real. nodejs-mobile ships only the Node engine, so the npm CLI
/// is fetched once from the registry into `$HOME/node/lib/node_modules/npm`
/// and every `npm`/`npx` invocation is rewritten to `node <npm-cli.js> …`.
enum NpmBootstrap {
    /// npm 10.9.x works with embedded Node 24.
    static let pinnedVersion = "10.9.2"

    static func npmRoot(home: String) -> String {
        home + "/node/lib/node_modules/npm"
    }

    static func cliPath(home: String, tool: String) -> String {
        npmRoot(home: home) + "/bin/\(tool)-cli.js"
    }

    static func isInstalled(home: String) -> Bool {
        FileManager.default.fileExists(atPath: cliPath(home: home, tool: "npm"))
    }

    enum BootstrapError: Error, CustomStringConvertible {
        case download(String)
        case layout(String)

        var description: String {
            switch self {
            case .download(let why): return "npm bootstrap download failed: \(why)"
            case .layout(let why): return "npm bootstrap failed: \(why)"
            }
        }
    }

    /// Downloads and unpacks the npm CLI. Blocking; callers run on a job queue.
    static func install(home: String, progress: @escaping (String) -> Void) throws {
        let fm = FileManager.default
        let root = npmRoot(home: home)
        if isInstalled(home: home) { return }

        let url = URL(string: "https://registry.npmjs.org/npm/-/npm-\(pinnedVersion).tgz")!
        progress("Installing npm \(pinnedVersion) (one-time setup)…\n")
        progress("Downloading \(url.lastPathComponent)…\n")

        let started = Date()
        let archive = try download(from: url, progress: progress)
        defer { try? fm.removeItem(at: archive) }
        let downloadSecs = String(format: "%.1f", Date().timeIntervalSince(started))
        let bytes = (try? fm.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.intValue ?? 0
        progress("Downloaded \(byteString(bytes)) in \(downloadSecs)s. Extracting…\n")

        let extractStarted = Date()
        // Extract under tmp — Documents/iCloud coordination on thousands of
        // tiny files is a common cause of "2.5 MB took forever" on iOS.
        let staging = fm.temporaryDirectory
            .appendingPathComponent("npm-bootstrap-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let tick = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        tick.schedule(deadline: .now() + 1.0, repeating: 1.0)
        tick.setEventHandler {
            let secs = Int(Date().timeIntervalSince(extractStarted))
            progress("  … still extracting (\(secs)s)\n")
        }
        tick.resume()
        defer { tick.cancel() }

        // Skip docs/man — npm never needs them at runtime; cuts ~270 members.
        try TarGzExtractor.extract(archive: archive, into: staging) { name in
            if name.hasPrefix("package/man/") { return false }
            if name.hasPrefix("package/docs/") { return false }
            if name.contains("/docs/") { return false }
            return true
        }

        let unpacked = staging.appendingPathComponent("package")
        guard fm.fileExists(atPath: unpacked.appendingPathComponent("bin/npm-cli.js").path) else {
            throw BootstrapError.layout("npm-cli.js missing after extraction")
        }
        try fm.createDirectory(atPath: (root as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try? fm.removeItem(atPath: root)
        try fm.moveItem(atPath: unpacked.path, toPath: root)
        try fm.createDirectory(atPath: home + "/node/bin", withIntermediateDirectories: true)

        let extractSecs = String(format: "%.1f", Date().timeIntervalSince(extractStarted))
        let totalSecs = String(format: "%.1f", Date().timeIntervalSince(started))
        progress("npm \(pinnedVersion) installed (extract \(extractSecs)s, total \(totalSecs)s).\n")
    }

    // MARK: - Download

    /// Same pattern as AlpineBootstrap: `URLSession.download`, not an in-memory
    /// `dataTask`. Progress is reported so a slow link does not look hung.
    private static func download(from url: URL, progress: @escaping (String) -> Void) throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        // Prefer HTTP/1.1 — HTTP/2 stalls on some simulator/network paths
        // look like a hung 2.5 MB download with zero feedback.
        config.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        let session = URLSession(configuration: config)

        let box = DownloadBox()
        let sem = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        // Force HTTP/1.1 via legacy path: disable multiplexed QUIC/H2 when possible
        // by using a download task on ephemeral config (no connection reuse).
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.downloadTask(with: request) { fileURL, response, error in
            defer { sem.signal() }
            if let error {
                box.failure = error.localizedDescription
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                box.failure = "HTTP \(http.statusCode)"
                return
            }
            guard let fileURL else {
                box.failure = "no file"
                return
            }
            // Move out of URLSession's temp location before the callback returns.
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("npm-\(UUID().uuidString).tgz")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: fileURL, to: dest)
                box.fileURL = dest
            } catch {
                box.failure = error.localizedDescription
            }
        }

        // Tick even at 0 bytes so a DNS/TLS stall is visible, not a silent hang.
        let progressQueue = DispatchQueue(label: "app.tether.npm.download.progress")
        var lastReported: Int64 = -1
        var ticks = 0
        let ticker = DispatchSource.makeTimerSource(queue: progressQueue)
        ticker.schedule(deadline: .now() + 0.5, repeating: 0.5)
        ticker.setEventHandler {
            ticks += 1
            let got = task.countOfBytesReceived
            let total = task.countOfBytesExpectedToReceive
            if got == 0 {
                if ticks == 1 || ticks % 4 == 0 {
                    progress("  … connecting to registry.npmjs.org (\(ticks / 2)s)\n")
                }
                return
            }
            if got == lastReported { return }
            lastReported = got
            if total > 0 {
                let pct = Int((Double(got) / Double(total)) * 100.0)
                progress("  … \(byteString(Int(got))) / \(byteString(Int(total))) (\(pct)%)\n")
            } else {
                progress("  … \(byteString(Int(got))) downloaded\n")
            }
        }
        ticker.resume()
        task.resume()

        let rc = sem.wait(timeout: .now() + 120)
        ticker.cancel()
        session.finishTasksAndInvalidate()

        if rc == .timedOut {
            task.cancel()
            throw BootstrapError.download("timed out after 120s — check network")
        }
        if let failure = box.failure {
            throw BootstrapError.download(failure)
        }
        guard let fileURL = box.fileURL else {
            throw BootstrapError.download("no data")
        }
        return fileURL
    }

    private static func byteString(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024.0) }
        return String(format: "%.2f MB", Double(n) / (1024.0 * 1024.0))
    }
}

private final class DownloadBox: @unchecked Sendable {
    var fileURL: URL?
    var failure: String?
}

/// Rewrites the argv the shell hands the Node service so every entry point is a
/// real script the engine can `runMain()`:
///   node …            → unchanged
///   npm/npx …         → node <npm-cli.js|npx-cli.js> …
///   claude (any bin)  → node <resolved $HOME/node/bin/claude> …
enum NodeCommandResolver {
    enum Resolution: Equatable {
        case run([String])           // final argv, argv[0] == "node"
        case needsNpm(tool: String)  // npm/npx requested but not installed yet
        case notFound(String)        // no such installed bin
    }

    static func resolve(argv: [String], home: String,
                        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Resolution {
        guard let first = argv.first else { return .run(argv) }
        let name = (first as NSString).lastPathComponent

        if name == "node" { return .run(["node"] + argv.dropFirst()) }

        if name == "npm" || name == "npx" {
            let cli = NpmBootstrap.cliPath(home: home, tool: name)
            guard fileExists(cli) else { return .needsNpm(tool: name) }
            return .run(["node", cli] + argv.dropFirst())
        }

        // A bin installed by `npm install -g` (a symlink in $HOME/node/bin).
        let bin = home + "/node/bin/\(name)"
        if fileExists(bin) {
            let resolved = URL(fileURLWithPath: bin).resolvingSymlinksInPath().path
            // Native-wrapper packages (Claude Code ≥2.1.120) point bin at
            // `bin/claude.exe`. Prefer a sibling JS entry so the embedded
            // engine can actually run the tool.
            if let jsEntry = Self.jsEntry(replacingNativeBin: resolved, fileExists: fileExists) {
                return .run(["node", jsEntry] + argv.dropFirst())
            }
            return .run(["node", resolved] + argv.dropFirst())
        }
        return .notFound(name)
    }

    /// If `resolved` looks like a native stub (*.exe / extensionless binary
    /// next to `cli.js` / `cli-wrapper.cjs`), return the JS entry instead.
    private static func jsEntry(replacingNativeBin resolved: String,
                                fileExists: (String) -> Bool) -> String? {
        let url = URL(fileURLWithPath: resolved)
        let dir = url.deletingLastPathComponent()
        let parent = dir.deletingLastPathComponent()
        let candidates = [
            dir.appendingPathComponent("cli.js").path,
            parent.appendingPathComponent("cli.js").path,
            dir.appendingPathComponent("cli-wrapper.cjs").path,
            parent.appendingPathComponent("cli-wrapper.cjs").path,
        ]
        let looksNative = resolved.hasSuffix(".exe")
            || !resolved.hasSuffix(".js") && !resolved.hasSuffix(".cjs") && !resolved.hasSuffix(".mjs")
        guard looksNative else { return nil }
        return candidates.first { fileExists($0) }
    }
}
