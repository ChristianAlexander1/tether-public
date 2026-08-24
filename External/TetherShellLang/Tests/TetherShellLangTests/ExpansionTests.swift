import XCTest
@testable import TetherShellLang

final class ExpansionTests: XCTestCase {

    private var host: MockShellHost!
    private var shell: TetherShell!
    private var ctx: ExecContext!

    override func setUp() {
        host = MockShellHost()
        shell = TetherShell(host: host)
        ctx = ExecContext(stdin: StdinBuffer(), stdout: { _ in }, stderr: { _ in })
    }

    private func fields(_ raw: String) throws -> [String] {
        try shell.expandFields(TetherWord(raw), ctx: ctx)
    }

    private func scalar(_ raw: String) throws -> String {
        try shell.expandScalar(TetherWord(raw), ctx: ctx)
    }

    func testParameterDefaults() throws {
        shell.setVar("full", "value")
        shell.setVar("empty", "")

        XCTAssertEqual(try scalar("${missing:-fallback}"), "fallback")
        XCTAssertEqual(try scalar("${empty:-fallback}"), "fallback")
        XCTAssertEqual(try scalar("${empty-fallback}"), "")
        XCTAssertEqual(try scalar("${full:-fallback}"), "value")
        XCTAssertEqual(try scalar("${new:=created}"), "created")
        XCTAssertEqual(shell.lookup("new"), "created")
        XCTAssertEqual(try scalar("${full:+alt}"), "alt")
        XCTAssertEqual(try scalar("${missing:+alt}"), "")
    }

    func testLengthAndTrimming() throws {
        shell.setVar("path", "/usr/local/bin/tool")
        XCTAssertEqual(try scalar("${#path}"), "19")
        XCTAssertEqual(try scalar("${path##*/}"), "tool")
        XCTAssertEqual(try scalar("${path#*/}"), "usr/local/bin/tool")
        XCTAssertEqual(try scalar("${path%/tool}"), "/usr/local/bin")
        shell.setVar("f", "archive.tar.gz")
        XCTAssertEqual(try scalar("${f%.*}"), "archive.tar")
        XCTAssertEqual(try scalar("${f%%.*}"), "archive")
    }

    func testFieldSplittingAndQuoting() throws {
        shell.setVar("list", "one two  three")
        XCTAssertEqual(try fields("$list"), ["one", "two", "three"])
        XCTAssertEqual(try fields("\"$list\""), ["one two  three"])
        XCTAssertEqual(try fields("x''y"), ["xy"])
        XCTAssertEqual(try fields("\"\""), [""])
        XCTAssertEqual(try fields("$missing"), [])
    }

    func testDollarAtAndStar() throws {
        shell.arguments = ["a b", "c"]
        XCTAssertEqual(try fields("\"$@\""), ["a b", "c"])
        XCTAssertEqual(try fields("\"$*\""), ["a b c"])
        XCTAssertEqual(try scalar("$#"), "2")
        shell.arguments = []
        XCTAssertEqual(try fields("\"$@\""), [])
    }

    func testArithmeticExpansion() throws {
        shell.setVar("n", "4")
        XCTAssertEqual(try scalar("$((n * 2 + 1))"), "9")
        XCTAssertEqual(try scalar("$(( n > 3 ? 1 : 0 ))"), "1")
    }

    func testCommandSubstitution() throws {
        XCTAssertEqual(try scalar("$(echo hello)"), "hello")
        XCTAssertEqual(try scalar("$(echo a; echo b)"), "a\nb")
        XCTAssertEqual(try scalar("`echo nested`"), "nested")
        XCTAssertEqual(try scalar("\"$(echo \"$(echo deep)\")\""), "deep")
    }

    func testCommandSubstitutionIsIsolated() throws {
        shell.setVar("x", "outer")
        XCTAssertEqual(try scalar("$(x=inner; echo $x)"), "inner")
        XCTAssertEqual(shell.lookup("x"), "outer")
    }

    func testHereDocExpansion() throws {
        shell.setVar("who", "world")
        let body = try shell.expandHereDocText("hello $who \\$not $((1 + 1))\n", ctx: ctx)
        XCTAssertEqual(body, "hello world $not 2\n")
    }

    func testSpecialParameters() throws {
        shell.setVar("x", "1")
        _ = try shell.run("false")
        XCTAssertEqual(try scalar("$?"), "1")
        XCTAssertEqual(try scalar("$$"), "4242")
        XCTAssertEqual(try scalar("$0"), "tethersh")
    }

    func testPathnameExpansion() throws {
        shell.setVirtualFile("a.txt", contents: "")
        shell.setVirtualFile("b.txt", contents: "")
        shell.setVirtualFile("c.md", contents: "")
        XCTAssertEqual(try fields("*.txt"), ["a.txt", "b.txt"])
        XCTAssertEqual(try fields("\\*.txt"), ["*.txt"])    // escaped → literal
        XCTAssertEqual(try fields("*.zzz"), ["*.zzz"])      // no match → literal
    }

    func testParamErrorAborts() throws {
        XCTAssertThrowsError(try scalar("${nope:?must set}")) { error in
            guard case ShellFlow.abort(let code, let message) = error else {
                return XCTFail("expected abort")
            }
            XCTAssertEqual(code, 1)
            XCTAssertTrue(message?.contains("must set") ?? false)
        }
    }
}
