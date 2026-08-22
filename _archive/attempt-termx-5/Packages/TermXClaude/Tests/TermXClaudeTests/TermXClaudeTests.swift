import XCTest
@testable import TermXClaude

final class FakeNode: NodeService {
    var calls = 0
    func run(argv: [String], cwd: String, env: [String : String], stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) async -> Int32 { calls += 1; return 0 }
    func interrupt() {}
}

@MainActor
final class TermXClaudeTests: XCTestCase {
    func testLauncherInstallsThenRuns() async {
        let fake = FakeNode(); let launcher = ClaudeLauncher(node: fake)
        let code = await launcher.run(cwd: NSTemporaryDirectory(), env: [:])
        XCTAssertEqual(code, 0); XCTAssertEqual(fake.calls, 2); XCTAssertEqual(launcher.state, .ready)
    }
}
