import XCTest
@testable import TermXCore

/// Regression: redirections trailing a compound command (`done > f`, `fi > f`)
/// were silently dropped — the file was never created and the output went to
/// the terminal.
final class CompoundRedirectTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "compound-redirect-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func run(_ line: String) -> String {
        var out = ""
        let s = ShellSession(cwd: dir, environment: ["HOME": dir, "PATH": "/bin"]) { out += $0 }
        _ = s.eval(line)
        return out
    }

    private func contents(_ name: String) -> String? {
        try? String(contentsOfFile: dir + "/" + name, encoding: .utf8)
    }

    func testWhileLoopRedirect() {
        let out = run("i=0; while [ $i -lt 3 ]; do echo n$i; i=$((i+1)); done > loop.txt")
        XCTAssertEqual(contents("loop.txt"), "n0\nn1\nn2\n")
        XCTAssertEqual(out, "", "loop output must go to the file, not the terminal")
    }

    func testWhileLoopAppendRedirect() {
        _ = run("echo first > app.txt; i=0; while [ $i -lt 2 ]; do echo a$i; i=$((i+1)); done >> app.txt")
        XCTAssertEqual(contents("app.txt"), "first\na0\na1\n")
    }

    func testForLoopRedirect() {
        let out = run("for x in a b c; do echo f$x; done > forloop.txt")
        XCTAssertEqual(contents("forloop.txt"), "fa\nfb\nfc\n")
        XCTAssertEqual(out, "")
    }

    func testIfRedirect() {
        let out = run("if true; then echo yes; fi > if.txt")
        XCTAssertEqual(contents("if.txt"), "yes\n")
        XCTAssertEqual(out, "")
    }

    func testRedirectTargetWithVariable() {
        _ = run("f=var.txt; i=0; while [ $i -lt 1 ]; do echo v; i=$((i+1)); done > $f")
        XCTAssertEqual(contents("var.txt"), "v\n")
    }

    func testUnredirectedLoopStillPrints() {
        XCTAssertEqual(run("i=0; while [ $i -lt 2 ]; do echo p$i; i=$((i+1)); done"),
                       "p0\np1\n")
    }
}
