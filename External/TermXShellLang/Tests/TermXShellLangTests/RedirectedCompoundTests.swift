import XCTest
@testable import TermXShellLang

/// A FakeHost that also records redirect scopes handed to `withRedirects`.
private final class RedirectRecordingHost: ShellHost {
    var recorded: [String] = []
    var redirectSpecs: [String] = []

    func run(commandLine: String) -> Int32 { recorded.append(commandLine); return 0 }
    func write(_ text: String) {}
    func writeError(_ text: String) {}
    func value(for name: String) -> String? { nil }
    func setValue(_ value: String, for name: String) {}
    func withRedirects(_ spec: String, body: () -> Int32) -> Int32 {
        redirectSpecs.append(spec)
        return body()
    }
}

final class RedirectedCompoundTests: XCTestCase {

    func testWhileTrailingRedirectParses() throws {
        let node = try ScriptParser.parse("while true; do echo x; done > out.txt")
        guard case .redirected(let inner, let redirects)? = node else {
            return XCTFail("expected .redirected, got \(String(describing: node))")
        }
        XCTAssertEqual(redirects, [">", "out.txt"])
        if case .whileLoop = inner {} else { XCTFail("expected while loop inside") }
    }

    func testIfTrailingRedirectWithStderrDup() throws {
        let node = try ScriptParser.parse("if true; then echo y; fi >> log.txt 2>&1")
        guard case .redirected(_, let redirects)? = node else {
            return XCTFail("expected .redirected")
        }
        XCTAssertEqual(redirects, [">>", "log.txt", "2>&1"])
    }

    func testNoRedirectLeavesNodeUnwrapped() throws {
        let node = try ScriptParser.parse("while true; do echo x; done")
        if case .redirected = node { XCTFail("must not wrap without redirects") }
    }

    func testEvaluatorHandsSpecToHost() throws {
        let host = RedirectRecordingHost()
        let evaluator = ScriptEvaluator(host: host)
        var vars: [String: String] = [:]
        let node = try XCTUnwrap(try ScriptParser.parse("if true; then echo y; fi > f.txt"))
        _ = try evaluator.evaluate(node, variables: &vars)
        XCTAssertEqual(host.redirectSpecs, ["> f.txt"])
        XCTAssertTrue(host.recorded.contains("echo y"))
    }

    func testRedirectWordClassification() {
        XCTAssertTrue(Parser.isRedirectWord(">"))
        XCTAssertTrue(Parser.isRedirectWord(">>"))
        XCTAssertTrue(Parser.isRedirectWord("2>"))
        XCTAssertTrue(Parser.isRedirectWord("2>&1"))
        XCTAssertTrue(Parser.isRedirectWord("&>"))
        XCTAssertTrue(Parser.isRedirectWord(">file"))
        XCTAssertFalse(Parser.isRedirectWord("echo"))
        XCTAssertFalse(Parser.isRedirectWord("2"))

        XCTAssertTrue(Parser.redirectTargetIsNextWord(">"))
        XCTAssertTrue(Parser.redirectTargetIsNextWord("2>>"))
        XCTAssertFalse(Parser.redirectTargetIsNextWord(">file"))
        XCTAssertFalse(Parser.redirectTargetIsNextWord("2>&1"))
    }
}
