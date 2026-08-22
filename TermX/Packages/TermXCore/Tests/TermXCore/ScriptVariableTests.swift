import XCTest
@testable import TermXCore

/// Regression: a variable assigned in a script must be visible to later expansions
/// in the same script (loop counters were expanding from a stale copy).
final class ScriptVariableTests: XCTestCase {
    private func run(_ line: String) -> String {
        var out = ""
        let dir = NSTemporaryDirectory()
        let s = ShellSession(cwd: dir, environment: ["HOME": dir, "PATH": "/bin"]) { out += $0 }
        _ = s.eval(line)
        return out
    }

    func testWhileLoopWithCounter() {
        XCTAssertEqual(run("i=0; while [ $i -lt 3 ]; do echo n$i; i=$((i+1)); done"),
                       "n0\nn1\nn2\n")
    }

    func testUntilLoopWithCounter() {
        XCTAssertEqual(run("k=0; until [ $k -eq 2 ]; do echo u$k; k=$((k+1)); done"),
                       "u0\nu1\n")
    }
}
