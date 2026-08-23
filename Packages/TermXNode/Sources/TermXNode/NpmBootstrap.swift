import Foundation
import TermXCore

/// Makes `npm` real. nodejs-mobile ships only the Node engine, so the npm CLI
/// is fetched once from the registry into `$HOME/node/lib/node_modules/npm`
/// (the same install-on-first-use pattern as the Alpine rootfs) and every
/// `npm`/`npx` invocation is rewritten to `node <npm-cli.js> …`.
enum NpmBootstrap {
    /// npm 10.9.x is the current 10.x line; works with embedded Node 24.
    /// (Still a real registry tarball — not a stub.)
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
    static func install(home: String, progress: (String) -> Void) throws {
        let fm = FileManager.default
        let root = npmRoot(home: home)
        if isInstalled(home: home) { return }

        progress("Installing npm \(pinnedVersion) (one-time setup)…\n")
        let url = URL(string: "https://registry.npmjs.org/npm/-/npm-\(pinnedVersion).tgz")!

        let sem = DispatchSemaphore(value: 0)
        var payload: Data?
        var failure: String?
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error {
                failure = error.localizedDescription
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                failure = "HTTP \(http.statusCode)"
            } else {
                payload = data
            }
            sem.signal()
        }.resume()
        sem.wait()

        guard let payload else { throw BootstrapError.download(failure ?? "no data") }

        let staging = URL(fileURLWithPath: home + "/.npm-bootstrap-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let archive = staging.appendingPathComponent("npm.tgz")
        try payload.write(to: archive)
        try TarGzExtractor.extract(archive: archive, into: staging)

        // Registry tarballs unpack under "package/".
        let unpacked = staging.appendingPathComponent("package")
        guard fm.fileExists(atPath: unpacked.appendingPathComponent("bin/npm-cli.js").path) else {
            throw BootstrapError.layout("npm-cli.js missing after extraction")
        }
        try fm.createDirectory(atPath: (root as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try? fm.removeItem(atPath: root)
        try fm.moveItem(atPath: unpacked.path, toPath: root)
        try fm.createDirectory(atPath: home + "/node/bin", withIntermediateDirectories: true)
        progress("npm \(pinnedVersion) installed.\n")
    }
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
