import Foundation
import TermXCore

/// How Claude Code is executed inside TermX.
///
/// Anthropic ships Claude as a **Bun standalone ELF** (~300 MB). That binary:
/// - dies with SIGILL under Blink (x86 interpreter) — same class as bun itself
/// - cannot run on iOS Node natively (wrong OS/ABI)
///
/// Tether parses the official package's embedded application module graph and
/// runs that graph with its embedded Node runtime. The platform package remains
/// the source of truth: no Claude commands or release-specific behavior are
/// reimplemented by Tether.
///
/// Linux/Blink remains the door for Alpine `apk`, git, compilers, and other
/// ELF tools — not for Bun-based Claude.
public enum ClaudeRuntimeLane: Equatable, Sendable {
    /// Extracted JS + bun-shim under embedded Node.
    case embeddedNode
    /// A compatible older pure-JS `cli.js` installation already on disk.
    case legacyJS
}

public enum ClaudeRuntimeProbe {
    /// Prefer an already-installed runnable entry.
    public static func detect(
        home: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> ClaudeRuntimeLane? {
        if fileExists(launcherPath(home: home)),
           applicationEntryPath(home: home, fileExists: fileExists) != nil {
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

    public static func splitBundleRoot(home: String) -> String {
        (installRoot(home: home) as NSString).appendingPathComponent("bunfs")
    }

    public static func splitBundleEntryPath(home: String) -> String {
        (splitBundleRoot(home: home) as NSString)
            .appendingPathComponent("root/__tether_entry__.mjs")
    }

    public static func splitBundleCompletePath(home: String) -> String {
        (splitBundleRoot(home: home) as NSString).appendingPathComponent(".complete")
    }

    public static func applicationEntryPath(
        home: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        let split = splitBundleEntryPath(home: home)
        if fileExists(split), fileExists(splitBundleCompletePath(home: home)) {
            return split
        }
        let single = extractedJSPath(home: home)
        return fileExists(single) ? single : nil
    }

    public static func usesSplitBundle(
        home: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        fileExists(splitBundleEntryPath(home: home))
            && fileExists(splitBundleCompletePath(home: home))
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

/// Files and preferences owned by the optional Claude Code installation.
///
/// This deliberately excludes the user's workspace and `~/.claude` settings.
/// Removing the CLI should behave like uninstalling a global package: program
/// files go away, while user-created projects and configuration are preserved.
public enum ClaudeInstallation {
    private static let installedKey = "termx.claude.installed"
    private static let authenticatedKey = "termx.claude.authenticated"
    private static let laneKey = "termx.claude.lane"

    public static func installRoot(home: String) -> String {
        ClaudeRuntimeProbe.installRoot(home: home)
    }

    /// Remove both the current extracted-JS lane and the exact legacy npm
    /// package, without deleting unrelated global Node packages.
    public static func uninstall(
        home: String,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        let embeddedRoot = URL(fileURLWithPath: installRoot(home: home)).standardizedFileURL
        if fileManager.fileExists(atPath: embeddedRoot.path) {
            try fileManager.removeItem(at: embeddedRoot)
        }

        let nodeRoot = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
        let legacyPackage = nodeRoot
            .appendingPathComponent("lib/node_modules/@anthropic-ai/claude-code", isDirectory: true)
            .standardizedFileURL
        let legacyLauncher = nodeRoot
            .appendingPathComponent("bin/claude", isDirectory: false)
            .standardizedFileURL
        if fileManager.fileExists(atPath: legacyLauncher.path) {
            try fileManager.removeItem(at: legacyLauncher)
        }
        if fileManager.fileExists(atPath: legacyPackage.path) {
            try fileManager.removeItem(at: legacyPackage)
        }

        // Remove the now-empty package scope, but never its node_modules parent.
        let legacyScope = legacyPackage.deletingLastPathComponent()
        if let children = try? fileManager.contentsOfDirectory(atPath: legacyScope.path),
           children.isEmpty {
            try? fileManager.removeItem(at: legacyScope)
        }

        defaults.removeObject(forKey: installedKey)
        defaults.removeObject(forKey: authenticatedKey)
        defaults.removeObject(forKey: laneKey)
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
        if ClaudeRuntimeProbe.applicationEntryPath(home: home) != nil,
           fm.fileExists(atPath: destLauncher) {
            progress("claude: already installed (Node + extracted JS).\n")
            try ensureBundleLocation(home: home)
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
        progress("claude: preparing the official application module graph for embedded Node.\n")

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
        progress("claude: extracting JavaScript module graph from Bun standalone…\n")
        let root = ClaudeRuntimeProbe.installRoot(home: home)
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        do {
            let stagedBundle = fm.temporaryDirectory
                .appendingPathComponent("claude-bunfs-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: stagedBundle) }
            let finalBundle = URL(
                fileURLWithPath: ClaudeRuntimeProbe.splitBundleRoot(home: home),
                isDirectory: true
            )
            try ClaudeBunExtractor.extractApplication(
                fromBinaryAt: binary,
                into: stagedBundle,
                runtimeRoot: finalBundle.appendingPathComponent("root", isDirectory: true).path
            )
            if fm.fileExists(atPath: finalBundle.path) {
                try fm.removeItem(at: finalBundle)
            }
            try fm.moveItem(at: stagedBundle, to: finalBundle)
            try? fm.removeItem(atPath: destJS)
        } catch {
            // Older Bun releases used one contiguous CommonJS entry instead
            // of the serialized split-module graph.
            do {
                let js = try ClaudeBunExtractor.extractJavaScript(fromBinaryAt: binary)
                try js.write(
                    to: URL(fileURLWithPath: destJS), atomically: true, encoding: .utf8
                )
            } catch {
                throw InstallError.extract(String(describing: error))
            }
        }

        try ensureLauncherFiles(home: home)
        try ensurePackageManifest(home: home)
        progress("claude: ready — Node launcher at \(destLauncher)\n")
    }

    /// iOS can relocate an app's data container while preserving its files.
    /// The extracted ESM graph uses absolute import paths, so repair those
    /// paths before launch if the enclosing container moved.
    public static func ensureBundleLocation(home: String) throws {
        let fm = FileManager.default
        guard ClaudeRuntimeProbe.usesSplitBundle(home: home) else { return }
        let bundle = URL(
            fileURLWithPath: ClaudeRuntimeProbe.splitBundleRoot(home: home),
            isDirectory: true
        )
        let root = bundle.appendingPathComponent("root", isDirectory: true).path
        let location = bundle.appendingPathComponent(".root-path")
        let oldRoot = (try? String(contentsOf: location, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let oldRoot, !oldRoot.isEmpty, oldRoot != root else { return }

        guard let enumerator = fm.enumerator(
            at: bundle,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw InstallError.extract("could not enumerate installed module graph")
        }
        let oldBytes = Data((oldRoot + "/").utf8)
        let newBytes = Data((root + "/").utf8)
        for case let file as URL in enumerator {
            guard ["js", "mjs"].contains(file.pathExtension) else { continue }
            var data = try Data(contentsOf: file)
            guard data.range(of: oldBytes) != nil else { continue }
            data.replaceAll(oldBytes, with: newBytes)
            try data.write(to: file, options: .atomic)
        }
        try (root + "\n").write(to: location, atomically: true, encoding: .utf8)
    }

    /// package.json so `npm install ws js-yaml` resolves next to launcher.js (QNX port deps).
    public static func ensurePackageManifest(home: String) throws {
        let fm = FileManager.default
        let root = ClaudeRuntimeProbe.installRoot(home: home)
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        let pkg = (root as NSString).appendingPathComponent("package.json")
        if fm.fileExists(atPath: pkg) { return }
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
        // The Bun surface itself lives in `tether-bun-compat`; bun-shim.js
        // requires it from ./bun-compat, so the library ships beside it.
        if let compat = resourceDirectoryURL(named: "bun-compat") {
            let dest = (root as NSString).appendingPathComponent("bun-compat")
            try? fm.removeItem(atPath: dest)
            try fm.copyItem(at: compat, to: URL(fileURLWithPath: dest))
        } else {
            throw InstallError.resourcesMissing
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

    /// Locate a directory shipped in the SPM resource bundle.
    private static func resourceDirectoryURL(named name: String) -> URL? {
        let candidates = [
            Bundle.module.resourceURL?.appendingPathComponent(name),
            Bundle.module.bundleURL.appendingPathComponent(name),
            Bundle.module.bundleURL.appendingPathComponent("Resources/\(name)"),
        ].compactMap { $0 }
        return candidates.first { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
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
        case unsupportedExecutable
        case invalidModuleGraph(String)

        public var description: String {
            switch self {
            case .markerNotFound:
                return "Bun application entry was not found in the platform executable"
            case .emptyBundle:
                return "extracted JS bundle was empty"
            case .unsupportedExecutable:
                return "unsupported Bun executable format"
            case .invalidModuleGraph(let why):
                return "invalid Bun module graph: \(why)"
            }
        }
    }

    private static let bunFSRoot = "/$bunfs/root/"
    private static let graphTrailer = Data("\n---- Bun! ----\n".utf8)
    private static let moduleRecordSize = 52

    /// Extract Bun's serialized standalone module graph. New Claude releases
    /// use ESM code splitting, so the entry point is not a self-contained JS
    /// string: every module and asset must be materialized together.
    public static func extractApplication(
        fromBinaryAt path: String,
        into destination: URL,
        runtimeRoot: String
    ) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        let section = try elfBunSection(in: data)
        guard section.count >= 8 else {
            throw ExtractError.invalidModuleGraph("section is shorter than its length header")
        }
        let payloadLength = try integer64(data, at: section.lowerBound)
        guard payloadLength <= UInt64(Int.max) else {
            throw ExtractError.invalidModuleGraph("payload is too large")
        }
        let payloadStart = section.lowerBound + 8
        let payloadEnd = payloadStart + Int(payloadLength)
        guard payloadEnd <= section.upperBound,
              payloadLength >= UInt64(32 + graphTrailer.count),
              data[payloadEnd - graphTrailer.count..<payloadEnd] == graphTrailer else {
            throw ExtractError.invalidModuleGraph("missing or out-of-bounds trailer")
        }

        // Bun x64 Offsets layout: usize byteCount, StringPointer modules,
        // u32 entryPointID, StringPointer execArgv, u32 flags.
        let offsetsStart = payloadEnd - graphTrailer.count - 32
        let byteCount = try checkedInt(integer64(data, at: offsetsStart), "byte count")
        let modulesOffset = try checkedInt(integer32(data, at: offsetsStart + 8), "modules offset")
        let modulesLength = try checkedInt(integer32(data, at: offsetsStart + 12), "modules length")
        let entryPointID = try checkedInt(integer32(data, at: offsetsStart + 16), "entry point")
        guard byteCount <= offsetsStart - payloadStart,
              modulesLength > 0,
              modulesLength % moduleRecordSize == 0,
              modulesOffset <= byteCount,
              modulesLength <= byteCount - modulesOffset else {
            throw ExtractError.invalidModuleGraph("invalid offsets")
        }
        let moduleCount = modulesLength / moduleRecordSize
        guard entryPointID < moduleCount else {
            throw ExtractError.invalidModuleGraph("entry point is outside the module table")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let outputRoot = destination.appendingPathComponent("root", isDirectory: true)
        try fm.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let escapedRuntimeRoot = runtimeRoot
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var entryContents: Data?

        for index in 0..<moduleCount {
            let record = payloadStart + modulesOffset + index * moduleRecordSize
            let name = try graphSlice(data, payloadStart: payloadStart, byteCount: byteCount,
                                      pointerAt: record)
            let contents = try graphSlice(data, payloadStart: payloadStart, byteCount: byteCount,
                                          pointerAt: record + 8)
            guard let nameString = String(data: name, encoding: .utf8),
                  nameString.hasPrefix(bunFSRoot) else {
                throw ExtractError.invalidModuleGraph("unsafe or non-UTF8 module name")
            }
            let relative = String(nameString.dropFirst(bunFSRoot.count))
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !relative.contains("\\") else {
                throw ExtractError.invalidModuleGraph("unsafe module path \(relative)")
            }

            let moduleFormat = data[record + 50]
            var output = Data(contents)
            if moduleFormat == 1 || moduleFormat == 2 {
                var source = String(decoding: contents, as: UTF8.self)
                source = source.replacingOccurrences(
                    of: bunFSRoot,
                    with: escapedRuntimeRoot + "/"
                )
                output = Data(source.utf8)
            }

            let file = outputRoot.appendingPathComponent(relative, isDirectory: false)
            try fm.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try output.write(to: file, options: .atomic)
            if index == entryPointID { entryContents = output }
        }

        guard let entryContents, !entryContents.isEmpty else {
            throw ExtractError.emptyBundle
        }
        try entryContents.write(
            to: outputRoot.appendingPathComponent("__tether_entry__.mjs"), options: .atomic
        )
        try Data("{\"type\":\"module\"}\n".utf8).write(
            to: destination.appendingPathComponent("package.json"), options: .atomic
        )
        try Data((runtimeRoot + "\n").utf8).write(
            to: destination.appendingPathComponent(".root-path"), options: .atomic
        )
        // Written last: the probe never treats a partially extracted graph as runnable.
        try Data("1\n".utf8).write(
            to: destination.appendingPathComponent(".complete"), options: .atomic
        )
    }

    private static func elfBunSection(in data: Data) throws -> Range<Int> {
        guard data.count >= 64,
              data[0] == 0x7f, data[1] == 0x45, data[2] == 0x4c, data[3] == 0x46,
              data[4] == 2, data[5] == 1 else {
            throw ExtractError.unsupportedExecutable
        }
        let sectionTable = try checkedInt(integer64(data, at: 40), "section table")
        let entrySize = Int(try integer16(data, at: 58))
        let sectionCount = Int(try integer16(data, at: 60))
        let namesIndex = Int(try integer16(data, at: 62))
        guard entrySize >= 64, sectionCount > 0, namesIndex < sectionCount,
              sectionTable <= data.count,
              sectionCount <= (data.count - sectionTable) / entrySize else {
            throw ExtractError.invalidModuleGraph("invalid ELF section table")
        }

        let namesHeader = sectionTable + namesIndex * entrySize
        let namesOffset = try checkedInt(integer64(data, at: namesHeader + 24), "section names")
        let namesLength = try checkedInt(integer64(data, at: namesHeader + 32), "section names length")
        guard namesOffset <= data.count, namesLength <= data.count - namesOffset else {
            throw ExtractError.invalidModuleGraph("section name table is out of bounds")
        }
        let namesEnd = namesOffset + namesLength

        for index in 0..<sectionCount {
            let header = sectionTable + index * entrySize
            let nameOffset = try checkedInt(integer32(data, at: header), "section name")
            guard nameOffset < namesLength else { continue }
            let start = namesOffset + nameOffset
            var end = start
            while end < namesEnd, data[end] != 0 { end += 1 }
            guard end < namesEnd else { continue }
            if String(decoding: data[start..<end], as: UTF8.self) != ".bun" { continue }
            let offset = try checkedInt(integer64(data, at: header + 24), "Bun section")
            let length = try checkedInt(integer64(data, at: header + 32), "Bun section length")
            guard offset <= data.count, length <= data.count - offset else {
                throw ExtractError.invalidModuleGraph("Bun section is out of bounds")
            }
            return offset..<(offset + length)
        }
        throw ExtractError.markerNotFound
    }

    private static func graphSlice(
        _ data: Data, payloadStart: Int, byteCount: Int, pointerAt offset: Int
    ) throws -> Data {
        let relativeOffset = try checkedInt(integer32(data, at: offset), "string offset")
        let length = try checkedInt(integer32(data, at: offset + 4), "string length")
        guard relativeOffset <= byteCount, length <= byteCount - relativeOffset else {
            throw ExtractError.invalidModuleGraph("string pointer is out of bounds")
        }
        let start = payloadStart + relativeOffset
        return data.subdata(in: start..<(start + length))
    }

    private static func checkedInt<T: BinaryInteger>(_ value: T, _ field: String) throws -> Int {
        guard let result = Int(exactly: value) else {
            throw ExtractError.invalidModuleGraph("\(field) is too large")
        }
        return result
    }

    private static func integer16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= data.count - 2 else {
            throw ExtractError.invalidModuleGraph("truncated integer")
        }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func integer32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else {
            throw ExtractError.invalidModuleGraph("truncated integer")
        }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func integer64(_ data: Data, at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset <= data.count - 8 else {
            throw ExtractError.invalidModuleGraph("truncated integer")
        }
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(data[offset + index]) << UInt64(index * 8) }
        return value
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

private extension Data {
    mutating func replaceAll(_ needle: Data, with replacement: Data) {
        guard !needle.isEmpty else { return }
        var cursor = startIndex
        while cursor <= endIndex,
              let match = range(of: needle, in: cursor..<endIndex) {
            replaceSubrange(match, with: replacement)
            cursor = match.lowerBound + replacement.count
        }
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
