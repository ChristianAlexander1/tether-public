import Foundation
import TermXCore

/// How Claude Code is executed inside TermX.
///
/// Anthropic ships Claude as a **Bun standalone ELF** (~300 MB). That binary:
/// - dies with SIGILL under Blink (x86 interpreter) — same class as bun itself
/// - cannot run on iOS Node natively (wrong OS/ABI)
///
/// The durable, widely used approach (QNX Claude port, Termux community ports):
/// **extract the embedded JS app from the Bun binary and run it on Node**.
/// TermX already has NodeMobile — so we download any current linux Bun package
/// solely as a JS payload source, extract once, then launch via `launcher.js`.
///
/// Linux/Blink remains the door for Alpine `apk`, git, compilers, and other
/// ELF tools — not for Bun-based Claude.
public enum ClaudeRuntimeLane: Equatable, Sendable {
    /// Extracted JS + bun-shim under embedded Node.
    case embeddedNode
    /// Legacy pure-JS `cli.js` install (e.g. @2.1.110) still on disk.
    case legacyJS
}

public enum ClaudeRuntimeProbe {
    /// Prefer an already-installed runnable entry.
    public static func detect(
        home: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> ClaudeRuntimeLane? {
        if fileExists(launcherPath(home: home)), fileExists(extractedJSPath(home: home)) {
            return .embeddedNode
        }
        if jsEntryPath(home: home, fileExists: fileExists) != nil {
            return .legacyJS
        }
        return nil
    }

    public static func installRoot(home: String) -> String {
        (home as NSString).appendingPathComponent("claude")
    }

    public static func launcherPath(home: String) -> String {
        (installRoot(home: home) as NSString).appendingPathComponent("launcher.js")
    }

    public static func extractedJSPath(home: String) -> String {
        (installRoot(home: home) as NSString).appendingPathComponent("claude-code.js")
    }

    /// QNX-required Node deps next to the launcher (`ws`, `js-yaml`).
    public static func nodeModulesReady(
        home: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        let root = installRoot(home: home) as NSString
        let ws = root.appendingPathComponent("node_modules/ws/package.json")
        let yaml = root.appendingPathComponent("node_modules/js-yaml/package.json")
        return fileExists(ws) && fileExists(yaml)
    }

    public static func shimPath(home: String) -> String {
        (installRoot(home: home) as NSString).appendingPathComponent("bun-shim.js")
    }

    /// Path to a legacy JS entry the embedded engine can run without the shim.
    public static func jsEntryPath(
        home: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        let bin = home + "/node/bin/claude"
        guard fileExists(bin) else { return nil }
        let resolved = URL(fileURLWithPath: bin).resolvingSymlinksInPath().path
        if resolved.hasSuffix(".js") || resolved.hasSuffix(".cjs") || resolved.hasSuffix(".mjs") {
            return fileExists(resolved) ? resolved : nil
        }
        let pkgRoot = URL(fileURLWithPath: resolved)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cliJS = pkgRoot.appendingPathComponent("cli.js").path
        if fileExists(cliJS) { return cliJS }
        return nil
    }
}

/// Downloads a current Anthropic Bun binary, extracts the JS app, installs the Node launcher.
public enum ClaudeNodeInstaller {
    public static let packageScope = "@anthropic-ai"
    public static let wrapperName = "claude-code"
    /// Any linux Bun package works — we only need the embedded JS, not to execute the ELF.
    /// Prefer musl x64 (smaller download than some channels; always published).
    public static let payloadPackageName = "claude-code-linux-x64-musl"

    public enum InstallError: Error, CustomStringConvertible {
        case registry(String)
        case download(String)
        case extract(String)
        case noJSBundle
        case resourcesMissing

        public var description: String {
            switch self {
            case .registry(let why): return "claude: registry: \(why)"
            case .download(let why): return "claude: download failed: \(why)"
            case .extract(let why): return "claude: extract failed: \(why)"
            case .noJSBundle: return "claude: Bun binary had no extractable JS app"
            case .resourcesMissing: return "claude: launcher/shim resources missing from app bundle"
            }
        }
    }

    public static func resolveLatestVersion(
        session: URLSession = .shared
    ) async throws -> String {
        let url = URL(string: "https://registry.npmjs.org/\(packageScope)%2F\(wrapperName)/latest")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw InstallError.registry("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String, !version.isEmpty else {
            throw InstallError.registry("missing version field")
        }
        return version
    }

    public static func linuxTarballURL(version: String) -> URL {
        URL(string:
            "https://registry.npmjs.org/\(packageScope)/\(payloadPackageName)/-/"
            + "\(payloadPackageName)-\(version).tgz"
        )!
    }

    public static func installIntoHome(
        home: String,
        version: String? = nil,
        progress: @escaping (String) -> Void
    ) throws {
        let fm = FileManager.default
        let destJS = ClaudeRuntimeProbe.extractedJSPath(home: home)
        let destLauncher = ClaudeRuntimeProbe.launcherPath(home: home)
        if fm.fileExists(atPath: destJS), fm.fileExists(atPath: destLauncher),
           (try? Data(contentsOf: URL(fileURLWithPath: destJS)).count) ?? 0 > 1_000_000 {
            progress("claude: already installed (Node + extracted JS).\n")
            try ensureLauncherFiles(home: home)
            try ensurePackageManifest(home: home)
            return
        }

        let resolvedVersion: String
        if let version {
            resolvedVersion = version
        } else {
            progress("claude: looking up latest release…\n")
            resolvedVersion = try syncLatestVersion()
        }
        progress("claude: installing @anthropic-ai/\(wrapperName)@\(resolvedVersion)\n")
        progress("claude: extracting JS app from Bun binary → run on embedded Node (works for every current release).\n")

        let url = linuxTarballURL(version: resolvedVersion)
        progress("claude: downloading \(url.lastPathComponent)…\n")
        let archive = try download(from: url, progress: progress)
        defer { try? fm.removeItem(at: archive) }

        let staging = fm.temporaryDirectory.appendingPathComponent("claude-payload-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        progress("claude: extracting package…\n")
        do {
            try TarGzExtractor.extract(archive: archive, into: staging)
        } catch {
            throw InstallError.extract(String(describing: error))
        }

        guard let binary = findBunBinary(in: staging) else {
            throw InstallError.noJSBundle
        }
        progress("claude: extracting JavaScript app from Bun standalone…\n")
        let js: String
        do {
            js = try ClaudeBunExtractor.extractJavaScript(fromBinaryAt: binary)
        } catch {
            throw InstallError.extract(String(describing: error))
        }

        let root = ClaudeRuntimeProbe.installRoot(home: home)
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        let jsURL = URL(fileURLWithPath: destJS)
        try js.write(to: jsURL, atomically: true, encoding: .utf8)
        try ensureLauncherFiles(home: home)
        try ensurePackageManifest(home: home)
        progress("claude: ready — Node launcher at \(destLauncher)\n")
    }

    /// package.json so `npm install ws js-yaml` resolves next to launcher.js (QNX port deps).
    public static func ensurePackageManifest(home: String) throws {
        let root = ClaudeRuntimeProbe.installRoot(home: home)
        let pkg = (root as NSString).appendingPathComponent("package.json")
        if FileManager.default.fileExists(atPath: pkg) { return }
        let body = """
        {
          "name": "termx-claude",
          "private": true,
          "dependencies": {
            "ws": "^8.18.0",
            "js-yaml": "^4.1.0"
          }
        }
        """
        try body.write(toFile: pkg, atomically: true, encoding: .utf8)
    }

    /// Copy launcher.js + bun-shim.js from the SPM resource bundle into $HOME/claude/.
    public static func ensureLauncherFiles(home: String) throws {
        let fm = FileManager.default
        let root = ClaudeRuntimeProbe.installRoot(home: home)
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        for name in ["launcher", "bun-shim"] {
            guard let src = resourceURL(name: name, ext: "js") else {
                throw InstallError.resourcesMissing
            }
            let dest = (root as NSString).appendingPathComponent("\(name).js")
            try? fm.removeItem(atPath: dest)
            try fm.copyItem(at: src, to: URL(fileURLWithPath: dest))
        }
        // Remove the obsolete command-specific browser module installed by
        // earlier builds. The generic child-process opener now owns this path.
        let legacyOpenStub = (root as NSString).appendingPathComponent("termx-open-stub.js")
        try? fm.removeItem(atPath: legacyOpenStub)
        if let notice = resourceURL(name: "NOTICE-claude-bun-bridge", ext: "txt") {
            let dest = (root as NSString).appendingPathComponent("NOTICE-claude-bun-bridge.txt")
            try? fm.removeItem(atPath: dest)
            try? fm.copyItem(at: notice, to: URL(fileURLWithPath: dest))
        }
    }

    private static func resourceURL(name: String, ext: String) -> URL? {
        if let url = Bundle.module.url(forResource: name, withExtension: ext) {
            return url
        }
        let fileName = "\(name).\(ext)"
        let candidates = [
            Bundle.module.resourceURL?.appendingPathComponent(fileName),
            Bundle.module.bundleURL.appendingPathComponent(fileName),
            Bundle.module.bundleURL.appendingPathComponent("Resources/\(fileName)"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func syncLatestVersion() throws -> String {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<String, Error>!
        Task {
            do { result = .success(try await resolveLatestVersion()) }
            catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }

    private static func download(from url: URL, progress: @escaping (String) -> Void) throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        let session = URLSession(configuration: config)
        let box = DownloadBox()
        let sem = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
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
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("claude-\(UUID().uuidString).tgz")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: fileURL, to: dest)
                box.fileURL = dest
            } catch {
                box.failure = error.localizedDescription
            }
        }

        let progressQueue = DispatchQueue(label: "com.termx.claude.download.progress")
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
                    progress("  … connecting (\(ticks / 2)s)\n")
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

        let rc = sem.wait(timeout: .now() + 600)
        ticker.cancel()
        session.finishTasksAndInvalidate()
        if rc == .timedOut {
            task.cancel()
            throw InstallError.download("timed out after 600s")
        }
        if let failure = box.failure { throw InstallError.download(failure) }
        guard let fileURL = box.fileURL else { throw InstallError.download("no data") }
        return fileURL
    }

    private static func findBunBinary(in root: URL) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            guard name == "claude" || name == "claude.exe" else { continue }
            if isELF(at: fileURL.path) || isMachO(at: fileURL.path) {
                return fileURL.path
            }
            // Even if magic is odd, try extract if large enough
            if ((try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0) > 10_000_000 {
                return fileURL.path
            }
        }
        return nil
    }

    private static func isELF(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        return handle.readData(ofLength: 4) == Data([0x7F, 0x45, 0x4C, 0x46])
    }

    private static func isMachO(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: 4)
        return magic == Data([0xCF, 0xFA, 0xED, 0xFE]) || magic == Data([0xCE, 0xFA, 0xED, 0xFE])
    }

    private static func byteString(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024.0) }
        return String(format: "%.2f MB", Double(n) / (1024.0 * 1024.0))
    }
}

/// Pulls the Claude Code JS application out of a Bun standalone binary.
public enum ClaudeBunExtractor {
    public enum ExtractError: Error, CustomStringConvertible {
        case markerNotFound
        case emptyBundle

        public var description: String {
            switch self {
            case .markerNotFound:
                return "Bun entry marker not found (is this a Claude Code standalone?)"
            case .emptyBundle:
                return "extracted JS bundle was empty"
            }
        }
    }

    /// Bun ≥1.2 / Claude ≥2.1.241 layout:
    /// `/$bunfs/root/cli\0// @bun @bytecode @bun-cjs\n(function(exports,…`
    /// Older layout used `…/entrypoints/cli.js\0// @bun @bytecode…` directly.
    private static let entryMarkers: [Data] = [
        Data("/$bunfs/root/cli\0// @bun @bytecode @bun-cjs\n".utf8),
        Data("/$bunfs/root/src/entrypoints/cli.js\0// @bun @bytecode @bun-cjs\n".utf8),
    ]
    private static let nextSection = Data("\0/$bunfs/root/image-processor.js\0".utf8)
    private static let wrapPrefix = "(function(exports, require, module, __filename, __dirname) {"
    private static let wrapSuffix = "})"

    public static func extractJavaScript(fromBinaryAt path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        var jsStart: Int?
        for marker in entryMarkers {
            if let pos = data.range(of: marker)?.lowerBound {
                jsStart = pos + marker.count
                break
            }
        }
        guard let start = jsStart else { throw ExtractError.markerNotFound }

        var jsEnd = data.count
        if let next = data.range(of: nextSection, in: start..<data.count)?.lowerBound {
            jsEnd = next
        } else {
            jsEnd = min(data.count, start + 40 * 1024 * 1024)
        }

        var js = String(decoding: data[start..<jsEnd], as: UTF8.self)
        if let nul = js.firstIndex(of: "\0") {
            js = String(js[..<nul])
        }
        js = js.trimmingCharacters(in: .whitespacesAndNewlines)

        if js.hasPrefix(wrapPrefix) {
            js = String(js.dropFirst(wrapPrefix.count))
            if js.hasSuffix(wrapSuffix + "\n") {
                js = String(js.dropLast(wrapSuffix.count + 1))
            } else if js.hasSuffix(wrapSuffix) {
                js = String(js.dropLast(wrapSuffix.count))
            }
        }
        guard js.count > 10 else { throw ExtractError.emptyBundle }
        return js
    }
}

/// Kept for Alpine tooling docs / optional ELF experiments — not used for Claude launch.
public enum ClaudeLinuxInstaller {
    public static let linuxPackageName = "claude-code-linux-x64-musl"
}

private final class DownloadBox: @unchecked Sendable {
    var fileURL: URL?
    var failure: String?
}
