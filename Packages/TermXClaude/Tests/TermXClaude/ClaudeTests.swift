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

final class ClaudeTests: XCTestCase {
    func testStartsUnauthenticated() {
        let defaults = UserDefaults(suiteName: "TermXClaudeTests.unauth")!
        defaults.removePersistentDomain(forName: "TermXClaudeTests.unauth")
        XCTAssertEqual(ClaudeCodeService(node: TestNode(), defaults: defaults).state, .notInstalled)
    }

    func testLegacyJSPackagePin() {
        XCTAssertTrue(ClaudeCodeService.legacyJSPackage.contains("@anthropic-ai/claude-code@2.1.110"))
    }

    func testLaunchEnvironmentEnablesBrowserOpenOnLinuxExtract() {
        let env = ClaudeCodeService.launchEnvironment(base: [:])
        XCTAssertEqual(env["DISPLAY"], ":0")
        XCTAssertEqual(env["BROWSER"], "open")
        XCTAssertEqual(env["WAYLAND_DISPLAY"], "tether")
        XCTAssertEqual(env["TETHER_INTERACTIVE"], "1")
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
        let node = TestNode()
        node.nextExitCode = 0
        let service = ClaudeCodeService(node: node, defaults: defaults)
        let code = await service.login(cwd: "/tmp", env: [:], fds: (-1, -1, -1))
        XCTAssertEqual(code, 0)
        XCTAssertEqual(service.state, .authenticated)
        XCTAssertEqual(node.calls.last?.first, "node")
    }

    func testRunWhenInstalled() async {
        let defaults = UserDefaults(suiteName: "TermXClaudeTests.runauth")!
        defaults.removePersistentDomain(forName: "TermXClaudeTests.runauth")
        defaults.set(true, forKey: "termx.claude.installed")
        defaults.set("node", forKey: "termx.claude.lane")
        let service = ClaudeCodeService(node: TestNode(), defaults: defaults)
        do {
            _ = try await service.run(cwd: "/tmp", env: [:], fds: (-1, -1, -1))
        } catch {
            XCTFail("unexpected error \(error)")
        }
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

    @MainActor
    func testLauncherInstallFlow() async {
        let defaults = UserDefaults(suiteName: "TermXClaudeTests.launcher")!
        defaults.removePersistentDomain(forName: "TermXClaudeTests.launcher")
        let node = TestNode()
        node.nextExitCode = 0
        let home = "/tmp/termx-claude-launcher-\(UUID().uuidString)"
        let launcher = ClaudeLauncher(service: ClaudeCodeService(node: node, defaults: defaults))
        await launcher.ensureInstalled(cwd: "/tmp", env: ["HOME": home], fds: (-1, -1, -1))
        XCTAssertEqual(launcher.state, .installed)
        try? FileManager.default.removeItem(atPath: home)
    }
}
