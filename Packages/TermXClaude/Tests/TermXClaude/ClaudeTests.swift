import XCTest
@testable import TermXClaude

private final class TestNode: ClaudeNodeRunner {
    var calls: [[String]] = []
    var nextExitCode: Int32 = 0
    var interrupted = false

    func run(argv: [String], cwd: String, env: [String: String], stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) async -> Int32 {
        calls.append(argv)
        return nextExitCode
    }

    func interrupt(forceNodeSignal: Bool) { interrupted = true }

    var resizes: [(cols: Int, rows: Int)] = []
    func resize(cols: Int, rows: Int) { resizes.append((cols, rows)) }
}

private final class TestLinux: ClaudeLinuxRunner {
    var rootfsPath: String
    var bootstrapped = false
    var runs: [[String]] = []
    var nextExitCode: Int32 = 0
    var interrupted = false
    var failBootstrap = false

    init(rootfsPath: String) { self.rootfsPath = rootfsPath }

    func ensureBootstrap(progress: @escaping (String) -> Void) async throws {
        if failBootstrap { throw ClaudeError.bootstrapFailed("test") }
        progress("boot\n")
        bootstrapped = true
    }

    func run(argv: [String], cwd: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) async -> Int32 {
        runs.append(argv)
        return nextExitCode
    }

    func interrupt() { interrupted = true }
}

private func seedEmbeddedInstall(home: String, includeDependencies: Bool = true) throws {
    let fm = FileManager.default
    let root = ClaudeRuntimeProbe.installRoot(home: home)
    try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    try "payload".write(
        toFile: ClaudeRuntimeProbe.extractedJSPath(home: home),
        atomically: true, encoding: .utf8
    )
    try "launcher".write(
        toFile: ClaudeRuntimeProbe.launcherPath(home: home),
        atomically: true, encoding: .utf8
    )
    guard includeDependencies else { return }
    for package in ["ws", "js-yaml"] {
        let packageRoot = (root as NSString)
            .appendingPathComponent("node_modules/\(package)")
        try fm.createDirectory(atPath: packageRoot, withIntermediateDirectories: true)
        try "{}".write(
            toFile: (packageRoot as NSString).appendingPathComponent("package.json"),
            atomically: true, encoding: .utf8
        )
    }
}

final class ClaudeTests: XCTestCase {
    func testStartsUnauthenticated() {
        let defaults = UserDefaults(suiteName: "TermXClaudeTests.unauth")!
        defaults.removePersistentDomain(forName: "TermXClaudeTests.unauth")
        XCTAssertEqual(ClaudeCodeService(node: TestNode(), defaults: defaults).state, .notInstalled)
    }

    func testLaunchEnvironmentEnablesBrowserOpenOnLinuxExtract() {
        ClaudeCodeService.platformOpenerName = "open"
        let env = ClaudeCodeService.launchEnvironment(base: [:])
        XCTAssertEqual(env["DISPLAY"], ":0")
        XCTAssertEqual(env["BROWSER"], "open")
        XCTAssertEqual(env["WAYLAND_DISPLAY"], "tether")
        XCTAssertEqual(env["TETHER_INTERACTIVE"], "1")
    }

    func testLauncherRestartsExtractedPayloadForEveryPersistentNodeJob() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-launcher-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }

        try ClaudeNodeInstaller.ensureLauncherFiles(home: home)
        let launcher = try String(
            contentsOfFile: ClaudeRuntimeProbe.launcherPath(home: home),
            encoding: .utf8
        )

        XCTAssertTrue(launcher.contains("delete require.cache[resolvedClaudeCodePath]"))
        XCTAssertTrue(launcher.contains("Symbol.for('tether.claude.bunfs-interceptor')"))
        XCTAssertTrue(launcher.contains("CLAUDE_CODE_ESM"))
        XCTAssertTrue(launcher.contains("syncBuiltinESMExports"))
        XCTAssertTrue(launcher.contains("COPYFILE_FICLONE"))
        XCTAssertTrue(launcher.contains("cloneFreshGraph"))
    }

    func testExecuteUsesNodeLauncherWhenExtractedInstallPresent() async throws {
        let defaults = UserDefaults(suiteName: "TermXClaudeTests.exec")!
        defaults.removePersistentDomain(forName: "TermXClaudeTests.exec")
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-home-\(UUID().uuidString)").path
        let root = ClaudeRuntimeProbe.installRoot(home: home)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        // Seed a fake extracted install (large enough to pass the size check on reinstall).
        let js = String(repeating: "x", count: 1_100_000)
        try js.write(toFile: ClaudeRuntimeProbe.extractedJSPath(home: home), atomically: true, encoding: .utf8)
        try "console.log('launcher')".write(toFile: ClaudeRuntimeProbe.launcherPath(home: home), atomically: true, encoding: .utf8)
        try "// shim".write(toFile: ClaudeRuntimeProbe.shimPath(home: home), atomically: true, encoding: .utf8)
        // Seed QNX-required deps so install() does not call npm.
        let nm = (root as NSString).appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(atPath: (nm as NSString).appendingPathComponent("ws"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (nm as NSString).appendingPathComponent("js-yaml"), withIntermediateDirectories: true)
        try "{\"name\":\"ws\"}".write(toFile: (nm as NSString).appendingPathComponent("ws/package.json"), atomically: true, encoding: .utf8)
        try "{\"name\":\"js-yaml\"}".write(toFile: (nm as NSString).appendingPathComponent("js-yaml/package.json"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: home) }

        let node = TestNode()
        node.nextExitCode = 0
        let service = ClaudeCodeService(node: node, defaults: defaults)
        let code = try await service.install(cwd: "/tmp", env: ["HOME": home], fds: (-1, -1, -1))
        XCTAssertEqual(code, 0)
        XCTAssertTrue(node.calls.isEmpty, "must not npm-install when extract install + deps exist")

        let run = await service.execute(
            argv: ["claude", "--version"], cwd: "/tmp", env: ["HOME": home], fds: (-1, -1, -1)
        )
        XCTAssertEqual(run, 0)
        XCTAssertEqual(node.calls.last?.first, "node")
        XCTAssertTrue(node.calls.last?.contains { $0.hasSuffix("launcher.js") } == true)
        XCTAssertEqual(node.calls.last?.last, "--version")
    }

    func testLoginMarksAuthenticated() async {
        let defaults = UserDefaults(suiteName: "TermXClaudeTests.login")!
        defaults.removePersistentDomain(forName: "TermXClaudeTests.login")
        defaults.set(true, forKey: "termx.claude.installed")
        defaults.set("node", forKey: "termx.claude.lane")
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-login-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try! seedEmbeddedInstall(home: home)
        let node = TestNode()
        node.nextExitCode = 0
        let service = ClaudeCodeService(node: node, defaults: defaults)
        let code = await service.login(
            cwd: "/tmp", env: ["HOME": home], fds: (-1, -1, -1)
        )
        XCTAssertEqual(code, 0)
        XCTAssertEqual(service.state, .authenticated)
        XCTAssertEqual(node.calls.last?.first, "node")
        XCTAssertEqual(Array(node.calls.last?.suffix(2) ?? []), ["auth", "login"])
    }

    func testPromptNamedLoginDoesNotMarkAuthenticated() async throws {
        let suite = "TermXClaudeTests.prompt-login.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-prompt-login-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try seedEmbeddedInstall(home: home)

        let node = TestNode()
        node.nextExitCode = 0
        let service = ClaudeCodeService(node: node, defaults: defaults)
        let code = try await service.run(
            argv: ["claude", "login"], cwd: "/tmp",
            env: ["HOME": home], fds: (-1, -1, -1)
        )

        XCTAssertEqual(code, 0)
        XCTAssertEqual(service.state, .installed)
        XCTAssertEqual(node.calls.last?.last, "login")
    }

    func testRunRepairsPartiallyDeletedInstallDespiteStoredFlags() async throws {
        let defaults = UserDefaults(suiteName: "TermXClaudeTests.runauth")!
        defaults.removePersistentDomain(forName: "TermXClaudeTests.runauth")
        defaults.set(true, forKey: "termx.claude.installed")
        defaults.set("node", forKey: "termx.claude.lane")
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-repair-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try ClaudeNodeInstaller.ensureLauncherFiles(home: home)
        XCTAssertNil(ClaudeRuntimeProbe.detect(home: home))

        var installs = 0
        let node = TestNode()
        let service = ClaudeCodeService(
            node: node,
            defaults: defaults,
            runtimeInstaller: { repairHome, _ in
                installs += 1
                try seedEmbeddedInstall(home: repairHome)
            }
        )
        let code = try await service.run(
            argv: ["claude", "--version"], cwd: "/tmp",
            env: ["HOME": home], fds: (-1, -1, -1)
        )

        XCTAssertEqual(code, 0)
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(ClaudeRuntimeProbe.detect(home: home), .embeddedNode)
        XCTAssertTrue(node.calls.last?.contains("--version") == true)
    }

    func testPackageManifestRecreatesDeletedInstallDirectory() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-manifest-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }

        try ClaudeNodeInstaller.ensurePackageManifest(home: home)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (ClaudeRuntimeProbe.installRoot(home: home) as NSString)
                .appendingPathComponent("package.json")
        ))
    }

    func testRunDiscoversFilesystemInstallWhenPreferenceWasLost() async throws {
        let suite = "TermXClaudeTests.filesystem-source-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-filesystem-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }

        let root = ClaudeRuntimeProbe.installRoot(home: home)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try "payload".write(
            toFile: ClaudeRuntimeProbe.extractedJSPath(home: home),
            atomically: true, encoding: .utf8
        )
        try "launcher".write(
            toFile: ClaudeRuntimeProbe.launcherPath(home: home),
            atomically: true, encoding: .utf8
        )

        let node = TestNode()
        let service = ClaudeCodeService(node: node, defaults: defaults)
        let code = try await service.run(cwd: "/tmp", env: ["HOME": home], fds: (-1, -1, -1))

        XCTAssertEqual(code, 0)
        XCTAssertEqual(service.state, .installed)
        XCTAssertTrue(node.calls.last?.contains { $0.hasSuffix("launcher.js") } == true)
    }

    func testInterruptForwardsToNodeOnly() {
        let node = TestNode()
        let linux = TestLinux(rootfsPath: "/tmp")
        let service = ClaudeCodeService(node: node, linux: linux)
        service.interrupt(forceNodeSignal: false)
        XCTAssertTrue(node.interrupted)
        XCTAssertFalse(linux.interrupted)
    }

    func testProbePrefersExtractedNodeInstall() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString)").path
        let fm = FileManager.default
        defer { try? fm.removeItem(atPath: home) }
        let root = ClaudeRuntimeProbe.installRoot(home: home)
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        try "js".write(toFile: ClaudeRuntimeProbe.extractedJSPath(home: home), atomically: true, encoding: .utf8)
        try "launcher".write(toFile: ClaudeRuntimeProbe.launcherPath(home: home), atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeRuntimeProbe.detect(home: home), .embeddedNode)
    }

    func testProbeAcceptsOnlyCompletedSplitBundle() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("split-probe-\(UUID().uuidString)").path
        let fm = FileManager.default
        defer { try? fm.removeItem(atPath: home) }
        let entry = ClaudeRuntimeProbe.splitBundleEntryPath(home: home)
        try fm.createDirectory(
            at: URL(fileURLWithPath: entry).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "entry".write(toFile: entry, atomically: true, encoding: .utf8)
        try "launcher".write(
            toFile: ClaudeRuntimeProbe.launcherPath(home: home),
            atomically: true, encoding: .utf8
        )
        XCTAssertNil(ClaudeRuntimeProbe.detect(home: home))
        try "1".write(
            toFile: ClaudeRuntimeProbe.splitBundleCompletePath(home: home),
            atomically: true, encoding: .utf8
        )
        XCTAssertEqual(ClaudeRuntimeProbe.detect(home: home), .embeddedNode)
    }

    func testTarballURLTracksVersion() {
        let url = ClaudeNodeInstaller.linuxTarballURL(version: "2.1.241")
        XCTAssertTrue(url.absoluteString.contains("claude-code-linux-x64-musl-2.1.241.tgz"))
    }

    func testBunExtractorFindsUpdatedMarkers() throws {
        // Synthetic mini Bun layout matching Claude ≥2.1.241
        var blob = Data("PAD".utf8)
        blob.append(Data("/$bunfs/root/cli\0// @bun @bytecode @bun-cjs\n".utf8))
        blob.append(Data("(function(exports, require, module, __filename, __dirname) {const APP='claude-test-app';})".utf8))
        blob.append(Data("\n\0/$bunfs/root/image-processor.js\0".utf8))
        blob.append(Data("TAIL".utf8))
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-\(UUID().uuidString)").path
        FileManager.default.createFile(atPath: path, contents: blob)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let js = try ClaudeBunExtractor.extractJavaScript(fromBinaryAt: path)
        XCTAssertTrue(js.contains("claude-test-app"))
        XCTAssertFalse(js.hasPrefix("(function(exports"))
    }

    func testCurrentOfficialSplitBundleWhenFixtureProvided() throws {
        guard let binary = ProcessInfo.processInfo.environment["TETHER_CLAUDE_BINARY"] else {
            throw XCTSkip("set TETHER_CLAUDE_BINARY to an official Claude platform executable")
        }
        let fm = FileManager.default
        let destination = fm.temporaryDirectory
            .appendingPathComponent("claude-graph-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: destination) }
        let runtimeRoot = destination.appendingPathComponent("root", isDirectory: true).path

        try ClaudeBunExtractor.extractApplication(
            fromBinaryAt: binary, into: destination, runtimeRoot: runtimeRoot
        )

        let entry = destination.appendingPathComponent("root/__tether_entry__.mjs")
        let entryText = try String(contentsOf: entry, encoding: .utf8)
        XCTAssertGreaterThan(entryText.count, 1_000)
        XCTAssertTrue(entryText.contains(runtimeRoot + "/"))
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent(".complete").path))
        let files = fm.enumerator(at: destination, includingPropertiesForKeys: nil)?
            .allObjects.compactMap { $0 as? URL } ?? []
        XCTAssertGreaterThan(files.filter { $0.pathExtension == "js" }.count, 100)
    }

    func testUninstallRemovesOnlyClaudeArtifactsAndResetsState() throws {
        let fm = FileManager.default
        let homeURL = fm.temporaryDirectory
            .appendingPathComponent("tether-claude-uninstall-\(UUID().uuidString)", isDirectory: true)
        let home = homeURL.path
        defer { try? fm.removeItem(at: homeURL) }

        let embedded = URL(fileURLWithPath: ClaudeInstallation.installRoot(home: home), isDirectory: true)
        try fm.createDirectory(at: embedded, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: embedded.appendingPathComponent("claude-code.js"))

        let legacy = homeURL.appendingPathComponent(
            "node/lib/node_modules/@anthropic-ai/claude-code", isDirectory: true
        )
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("cli.js"))
        let bin = homeURL.appendingPathComponent("node/bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: bin.appendingPathComponent("claude"),
            withDestinationURL: legacy.appendingPathComponent("cli.js")
        )

        let unrelated = homeURL.appendingPathComponent(
            "node/lib/node_modules/example-package/index.js", isDirectory: false
        )
        try fm.createDirectory(at: unrelated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: unrelated)
        let settings = homeURL.appendingPathComponent(".claude/settings.json")
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: settings)

        let suite = "TermXClaudeTests.uninstall.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "termx.claude.installed")
        defaults.set(true, forKey: "termx.claude.authenticated")
        defaults.set("node", forKey: "termx.claude.lane")

        try ClaudeInstallation.uninstall(home: home, defaults: defaults)

        XCTAssertFalse(fm.fileExists(atPath: embedded.path))
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertFalse(fm.fileExists(atPath: bin.appendingPathComponent("claude").path))
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path))
        XCTAssertTrue(fm.fileExists(atPath: settings.path))
        XCTAssertFalse(defaults.bool(forKey: "termx.claude.installed"))
        XCTAssertFalse(defaults.bool(forKey: "termx.claude.authenticated"))
        XCTAssertNil(defaults.string(forKey: "termx.claude.lane"))
    }

    @MainActor
    func testLauncherInstallFlow() async {
        let defaults = UserDefaults(suiteName: "TermXClaudeTests.launcher")!
        defaults.removePersistentDomain(forName: "TermXClaudeTests.launcher")
        let node = TestNode()
        node.nextExitCode = 0
        let home = "/tmp/termx-claude-launcher-\(UUID().uuidString)"
        let launcher = ClaudeLauncher(service: ClaudeCodeService(
            node: node,
            defaults: defaults,
            runtimeInstaller: { installHome, _ in
                try seedEmbeddedInstall(home: installHome)
            }
        ))
        await launcher.ensureInstalled(cwd: "/tmp", env: ["HOME": home], fds: (-1, -1, -1))
        XCTAssertEqual(launcher.state, .installed)
        try? FileManager.default.removeItem(atPath: home)
    }
}
