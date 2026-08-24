import XCTest
@testable import TetherShellLang

/// Behavior-level checks that complement the fixture suite.
final class EvaluatorTests: XCTestCase {

    private var host: MockShellHost!
    private var shell: TetherShell!

    override func setUp() {
        host = MockShellHost()
        shell = TetherShell(host: host)
    }

    private func run(_ source: String) throws -> (status: Int32, out: String) {
        let status = try shell.run(source)
        return (status, host.stdout)
    }

    func testHelloWorld() throws {
        let result = try run("echo hello, tether")
        XCTAssertEqual(result.out, "hello, tether\n")
        XCTAssertEqual(result.status, 0)
    }

    func testExternalCommandsGoToHost() throws {
        host.responses["tool --version"] = .init(stdout: "tool v1\n", code: 0)
        let result = try run("tool --version")
        XCTAssertEqual(result.out, "tool v1\n")
        XCTAssertEqual(host.ranCommands, ["tool --version"])
    }

    func testPipelineFeedsStdin() throws {
        let result = try run("printf 'a\\nb\\n' | cat | cat")
        XCTAssertEqual(result.out, "a\nb\n")
    }

    func testAndOrAndNegation() throws {
        let result = try run("false && echo no; true || echo no2; ! false && echo yes")
        XCTAssertEqual(result.out, "yes\n")
    }

    func testIfElifElseWithTests() throws {
        let result = try run("""
        x=7
        if [ $x -lt 5 ]; then echo small
        elif [ $x -lt 10 ]; then echo mid
        else echo big
        fi
        """)
        XCTAssertEqual(result.out, "mid\n")
    }

    func testWhileWithBreak() throws {
        let result = try run("""
        i=0
        while [ $i -lt 10 ]; do
            i=$((i + 1))
            if [ $i -eq 4 ]; then break; fi
            echo $i
        done
        """)
        XCTAssertEqual(result.out, "1\n2\n3\n")
    }

    func testFunctionScopeAndReturn() throws {
        let result = try run("""
        x=global
        f() {
            local x=local
            echo "in:$x"
            return 5
        }
        f
        echo "out:$x status=$?"
        """)
        XCTAssertEqual(result.out, "in:local\nout:global status=5\n")
    }

    func testSubshellIsolation() throws {
        let result = try run("x=1; (x=9; echo sub$x); echo main$x")
        XCTAssertEqual(result.out, "sub9\nmain1\n")
    }

    func testRedirectRoundTrip() throws {
        let result = try run("echo one > f; echo two >> f; cat < f")
        XCTAssertEqual(result.out, "one\ntwo\n")
        XCTAssertEqual(shell.virtualFile("f"), "one\ntwo\n")
    }

    func testRedirectOnCompound() throws {
        let result = try run("""
        i=0
        while [ $i -lt 3 ]; do echo n$i; i=$((i + 1)); done > out
        cat out
        """)
        XCTAssertEqual(result.out, "n0\nn1\nn2\n")
    }

    func testHereDocAndReadLoop() throws {
        let result = try run("""
        cat <<EOF > data
        alpha 1
        beta 2
        EOF
        while read name num; do
            echo "row:$name=$num"
        done < data
        """)
        XCTAssertEqual(result.out, "row:alpha=1\nrow:beta=2\n")
    }

    func testDotSourcePersistsDefinitions() throws {
        let result = try run("""
        printf 'X=42\\nhello() { echo "hi $1"; }\\n' > lib.sh
        . ./lib.sh
        echo "x=$X"
        hello tether
        """)
        XCTAssertEqual(result.out, "x=42\nhi tether\n")
    }

    func testExitStopsScript() throws {
        let result = try run("echo before; exit 7; echo after")
        XCTAssertEqual(result.out, "before\n")
        XCTAssertEqual(result.status, 7)
    }

    func testExportReachesHostEnv() throws {
        _ = try run("export GREETING=hello; echo $GREETING")
        XCTAssertEqual(host.env["GREETING"], "hello")
    }

    func testCaseStatement() throws {
        let result = try run("""
        for w in foo bar zed; do
            case $w in
                f*) echo "f:$w" ;;
                bar|baz) echo "b:$w" ;;
                *) echo "?:"$w ;;
            esac
        done
        """)
        XCTAssertEqual(result.out, "f:foo\nb:bar\n?:zed\n")
    }

    func testParseErrorSurfaces() {
        XCTAssertThrowsError(try shell.run("if true; then echo oops")) { error in
            XCTAssert(error is TetherShellParseError)
        }
    }

    func testExecutionLimitProtectsHost() throws {
        shell.maxCommandExecutions = 500
        let status = try shell.run("while true; do :; done")
        XCTAssertEqual(status, 2)   // aborted, did not hang
    }
}
