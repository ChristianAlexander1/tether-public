import XCTest
@testable import TetherShellLang

final class ParserTests: XCTestCase {

    private func firstCommand(_ source: String, file: StaticString = #filePath,
                              line: UInt = #line) throws -> TetherCommand {
        let program = try TetherShellParser.parse(source)
        guard let pipeline = program.items.first?.andOr.first,
              let command = pipeline.commands.first else {
            XCTFail("no command parsed", file: file, line: line)
            throw TetherShellParseError("empty", line: 0)
        }
        return command
    }

    func testIfClause() throws {
        let command = try firstCommand("if true; then echo a; elif false; then echo b; else echo c; fi")
        guard case .ifClause(let clause, _) = command else {
            return XCTFail("expected ifClause")
        }
        XCTAssertEqual(clause.elifs.count, 1)
        XCTAssertNotNil(clause.elseBody)
    }

    func testWhileAndUntil() throws {
        for keyword in ["while", "until"] {
            let command = try firstCommand("\(keyword) true; do echo x; done")
            guard case .loop(_, _, let until, _) = command else {
                return XCTFail("expected loop for \(keyword)")
            }
            XCTAssertEqual(until, keyword == "until")
        }
    }

    func testForForms() throws {
        let wordsForm = try firstCommand("for x in a b; do echo; done")
        guard case .forClause(let clause, _) = wordsForm,
              clause.arithmetic == nil, clause.words?.count == 2 else {
            return XCTFail("bad for-in parse")
        }

        let bare = try firstCommand("for x; do echo; done")
        guard case .forClause(let bareClause, _) = bare, bareClause.words == nil else {
            return XCTFail("bare for should iterate over $@")
        }

        let arith = try firstCommand("for ((i = 0; i < 3; i++)); do echo; done")
        guard case .forClause(let arithClause, _) = arith,
              let spec = arithClause.arithmetic else {
            return XCTFail("bad arithmetic for parse")
        }
        XCTAssertEqual(spec.start, "i=0")
        XCTAssertEqual(spec.condition, "i<3")
        XCTAssertEqual(spec.step, "i++")
    }

    func testCaseTerminators() throws {
        let command = try firstCommand("case $x in a) echo 1 ;& b|c) echo 2 ;;& *) echo 3 ;; esac")
        guard case .caseClause(let clause, _) = command else {
            return XCTFail("expected caseClause")
        }
        XCTAssertEqual(clause.items.count, 3)
        XCTAssertEqual(clause.items[0].terminator, .fallThru)
        XCTAssertEqual(clause.items[1].terminator, .retest)
        XCTAssertEqual(clause.items[2].terminator, .stop)
        XCTAssertEqual(clause.items[1].patterns.map(\.raw), ["b", "c"])
    }

    func testFunctionDefinitions() throws {
        let posixForm = try firstCommand("f() { echo hi; } > out")
        guard case .functionDef(let def) = posixForm, def.name == "f",
              case .braceGroup(_, let redirects) = def.body, redirects.count == 1 else {
            return XCTFail("bad posix function def")
        }

        let kshForm = try firstCommand("function g { echo hi; }")
        guard case .functionDef(let kdef) = kshForm, kdef.name == "g" else {
            return XCTFail("bad ksh function def")
        }
    }

    func testArithmeticCommand() throws {
        let command = try firstCommand("((x = i + 1))")
        guard case .arithmetic(let expr, _) = command else {
            return XCTFail("expected arithmetic command")
        }
        XCTAssertEqual(expr, "x=i+1")
    }

    func testPipelineNegation() throws {
        let program = try TetherShellParser.parse("! true | false")
        XCTAssertEqual(program.items.first?.andOr.first.negated, true)
        XCTAssertEqual(program.items.first?.andOr.first.commands.count, 2)
    }

    func testSubshellAndBraceGroup() throws {
        let sub = try firstCommand("( echo a; echo b ) > f")
        guard case .subshell(let body, let redirects) = sub else {
            return XCTFail("expected subshell")
        }
        XCTAssertEqual(body.count, 2)
        XCTAssertEqual(redirects.count, 1)

        let group = try firstCommand("{ echo a; }")
        guard case .braceGroup = group else {
            return XCTFail("expected brace group")
        }
    }

    func testRedirectsOnSimpleCommand() throws {
        let program = try TetherShellParser.parse("echo hi 2>&1 > f")
        guard case .simple(let simple)? = program.items.first?.andOr.first.commands.first else {
            return XCTFail("expected simple command")
        }
        XCTAssertEqual(simple.redirects.count, 2)
        XCTAssertEqual(simple.redirects[0].fd, 2)
        XCTAssertEqual(simple.redirects[1].op, .output)
    }

    func testAssignmentRecognition() throws {
        let program = try TetherShellParser.parse("x=1 y=2 echo z")
        guard case .simple(let simple)? = program.items.first?.andOr.first.commands.first else {
            return XCTFail("expected simple command")
        }
        XCTAssertEqual(simple.assignments.map(\.name), ["x", "y"])
        XCTAssertEqual(simple.words.map(\.raw), ["echo", "z"])
    }

    func testUnmatchedFiThrows() {
        XCTAssertThrowsError(try TetherShellParser.parse("if true; then echo x"))
    }
}
