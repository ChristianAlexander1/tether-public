import XCTest
@testable import TetherShellLang

final class GlobTests: XCTestCase {

    private func matches(_ pattern: String, _ string: String) -> Bool {
        TetherGlob.match(TetherGlob.tokens(fromUnquoted: pattern), string)
    }

    func testStar() {
        XCTAssertTrue(matches("*.txt", "notes.txt"))
        XCTAssertFalse(matches("*.txt", "notes.md"))
        XCTAssertTrue(matches("*", "anything"))
        XCTAssertTrue(matches("a*c", "abc"))
        XCTAssertTrue(matches("a*c", "ac"))
        XCTAssertFalse(matches("a*c", "ab"))
    }

    func testQuestion() {
        XCTAssertTrue(matches("a?", "ab"))
        XCTAssertFalse(matches("a?", "abc"))
    }

    func testClasses() {
        XCTAssertTrue(matches("[abc]x", "bx"))
        XCTAssertFalse(matches("[abc]x", "dx"))
        XCTAssertTrue(matches("[a-z][0-9]", "f7"))
        XCTAssertFalse(matches("[a-z][0-9]", "F7"))
        XCTAssertTrue(matches("[!a]b", "cb"))
        XCTAssertFalse(matches("[!a]b", "ab"))
    }

    func testQuotedStarsAreLiteral() {
        let pattern = TetherGlob.literals("*.txt")
        XCTAssertTrue(TetherGlob.match(pattern, "*.txt"))
        XCTAssertFalse(TetherGlob.match(pattern, "a.txt"))
    }

    func testWildcardsDetection() {
        XCTAssertTrue(TetherGlob.hasWildcards(TetherGlob.tokens(fromUnquoted: "a*b")))
        XCTAssertFalse(TetherGlob.hasWildcards(TetherGlob.tokens(fromUnquoted: "plain")))
    }
}
