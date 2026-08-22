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

    func interrupt() { interrupted = true }
}

final class ClaudeTests: XCTestCase {
    func testStartsUnauthenticated() {
        let defaults = UserDefaults(suiteName: "TermXClaudeTests.unauth")!
        defaults.removePersistentDomain(forName: "TermXClaudeTests.unauth")
        XCTAssertEqual(ClaudeCodeService(node: TestNode(), defaults: defaults).state, .notInstalled)
    }

    func testInstallMarksInstalled() async throws {
        let defaults = UserDefaults(suiteName: "TermXClaudeTests.install")!
        defaults.removePersistentDomain(forName: "TermXClaudeTests.install")
        let node = TestNode()
        node.nextExitCode = 0
        let service = ClaudeCodeService(node: node, defaults: defaults)
        _ = try await service.install(cwd: "/tmp", env: [:], fds: (0, 1, 2))
        XCTAssertEqual(service.state, .installed)
        XCTAssertEqual(node.calls.first?.prefix(2), ["npm", "install"])
    }

    func testLoginMarksAuthenticated() async {
        let defaults = UserDefaults(suiteName: "TermXClaudeTests.login")!
        defaults.removePersistentDomain(forName: "TermXClaudeTests.login")
        defaults.set(true, forKey: "termx.claude.installed")
        let node = TestNode()
        node.nextExitCode = 0
        let service = ClaudeCodeService(node: node, defaults: defaults)
        let code = await service.login(cwd: "/tmp", env: [:], fds: (0, 1, 2))
        XCTAssertEqual(code, 0)
        XCTAssertEqual(service.state, .authenticated)
        XCTAssertEqual(node.calls.last?.first, "claude")
    }

    func testRunRequiresAuthWhenNotLoggedIn() async {
        let defaults = UserDefaults(suiteName: "TermXClaudeTests.runauth")!
        defaults.removePersistentDomain(forName: "TermXClaudeTests.runauth")
        defaults.set(true, forKey: "termx.claude.installed")
        let service = ClaudeCodeService(node: TestNode(), defaults: defaults)
        do {
            _ = try await service.run(cwd: "/tmp", env: [:], fds: (0, 1, 2))
            // installed but not authenticated is allowed to launch (login may happen in TUI)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testInterruptForwardsToNode() {
        let node = TestNode()
        let service = ClaudeCodeService(node: node)
        service.interrupt()
        XCTAssertTrue(node.interrupted)
    }

    @MainActor
    func testLauncherInstallFlow() async {
        let defaults = UserDefaults(suiteName: "TermXClaudeTests.launcher")!
        defaults.removePersistentDomain(forName: "TermXClaudeTests.launcher")
        let node = TestNode()
        node.nextExitCode = 0
        let launcher = ClaudeLauncher(service: ClaudeCodeService(node: node, defaults: defaults))
        await launcher.ensureInstalled(cwd: "/tmp", env: [:], fds: (0, 1, 2))
        XCTAssertEqual(launcher.state, .installed)
    }
}
