import XCTest
@testable import TermXCore

final class SubstitutionTests: XCTestCase {
    private var dir: String = ""

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "termx_sub_" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt"] {
            FileManager.default.createFile(atPath: dir + "/" + name, contents: Data("x\n".utf8))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func run(_ line: String) -> String {
        var captured = ""
        let session = ShellSession(cwd: dir, environment: ["HOME": dir, "PATH": "/bin"]) { captured += $0 }
        _ = session.eval(line)
        return captured
    }

    func testSubstitutionOfSimpleCommand() {
        XCTAssertTrue(run("echo v=$(echo hi)").contains("v=hi"))
    }

    func testSubstitutionOfPipeline() {
        let out = run("echo count=$(ls | wc -l)")
        XCTAssertTrue(out.contains("count=3"), "got: \(out)")
    }

    func testPipelineWithoutSubstitutionStillWrites() {
        let out = run("ls | wc -l")
        XCTAssertTrue(out.contains("3"), "got: \(out)")
    }
}

/// Regression: builtins must actually emit their output.
final class PrintfTests: XCTestCase {
    private func run(_ line: String) -> String {
        var captured = ""
        let dir = NSTemporaryDirectory()
        let session = ShellSession(cwd: dir, environment: ["HOME": dir, "PATH": "/bin"]) { captured += $0 }
        _ = session.eval(line)
        return captured
    }

    func testPrintfWritesPlainText() {
        XCTAssertEqual(run("printf hello"), "hello")
    }

    func testPrintfExpandsEscapes() {
        XCTAssertEqual(run(#"printf "one\ntwo\n""#), "one\ntwo\n")
    }

    func testPrintfFormatsArguments() {
        XCTAssertEqual(run(#"printf "%s-%d\n" abc 42"#), "abc-42\n")
    }
}
