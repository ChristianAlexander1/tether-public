import XCTest
@testable import TermXCommands

/// Integrator smoke tests: the priority-1 commands against real GNU/BSD behaviour.
final class SmokeTests: XCTestCase {
    private func run(_ argv: [String], stdin: String = "") -> CommandResult {
        guard let cmd = TermXCommandRegistry.command(named: argv[0]) else {
            return CommandResult(stderr: "no such command", exitCode: 127)
        }
        return cmd.run(CommandIO(argv: argv, stdin: stdin, cwd: NSTemporaryDirectory()))
    }

    func testSedSubstituteGlobal() {
        let r = run(["sed", "s/a/X/g"], stdin: "banana\n")
        XCTAssertEqual(r.stdout, "bXnXnX\n")
        XCTAssertEqual(r.exitCode, 0)
    }

    func testSedQuietWithPrint() {
        let r = run(["sed", "-n", "2p"], stdin: "one\ntwo\nthree\n")
        XCTAssertEqual(r.stdout, "two\n")
    }

    func testSedDelete() {
        let r = run(["sed", "/two/d"], stdin: "one\ntwo\nthree\n")
        XCTAssertEqual(r.stdout, "one\nthree\n")
    }

    func testAwkPrintField() {
        let r = run(["awk", "{print $2}"], stdin: "a b c\nd e f\n")
        XCTAssertEqual(r.stdout, "b\ne\n")
    }

    func testAwkNRAndNF() {
        let r = run(["awk", "{print NR, NF}"], stdin: "a b\nc d e\n")
        XCTAssertEqual(r.stdout, "1 2\n2 3\n")
    }

    func testAwkFieldSeparator() {
        let r = run(["awk", "-F,", "{print $1}"], stdin: "x,y\np,q\n")
        XCTAssertEqual(r.stdout, "x\np\n")
    }

    func testAwkPatternMatch() {
        let r = run(["awk", "/b/ {print $1}"], stdin: "a b\nc d\n")
        XCTAssertEqual(r.stdout, "a\n")
    }

    func testTacRevNl() {
        XCTAssertEqual(run(["tac"], stdin: "1\n2\n3\n").stdout, "3\n2\n1\n")
        XCTAssertEqual(run(["rev"], stdin: "abc\n").stdout, "cba\n")
    }

    func testUnknownFlagIsUsageError() {
        let r = run(["sed"], stdin: "x\n")
        XCTAssertNotEqual(r.exitCode, 0)
        XCTAssertFalse(r.stderr.isEmpty)
    }
}
