import XCTest
@testable import TetherShellLang

final class LexerTests: XCTestCase {

    private func lex(_ source: String) throws -> [Token] {
        var lexer = Lexer(source)
        return try lexer.tokenize()
    }

    private func kinds(_ tokens: [Token]) -> [String] {
        tokens.map { token in
            switch token.kind {
            case .word: return "w(\(token.text))"
            case .ioNumber: return "io(\(token.text))"
            case .newline: return "nl"
            case .eof: return "eof"
            case .andIf: return "&&"
            case .orIf: return "||"
            case .amp: return "&"
            case .semi: return ";"
            case .dsemi: return ";;"
            case .semiAnd: return ";&"
            case .dsemiAnd: return ";;&"
            case .pipe: return "|"
            case .lparen: return "("
            case .rparen: return ")"
            case .lbrace: return "{"
            case .rbrace: return "}"
            case .less: return "<"
            case .great: return ">"
            case .dless: return "<<"
            case .dlessDash: return "<<-"
            case .tripleLess: return "<<<"
            case .dgreat: return ">>"
            case .lessAnd: return "<&"
            case .greatAnd: return ">&"
            case .clobber: return ">|"
            case .lessGreat: return "<>"
            }
        }
    }

    func testOperators() throws {
        let k = kinds(try lex("true && echo hi | cat || false ; done"))
        XCTAssertEqual(k, ["w(true)", "&&", "w(echo)", "w(hi)", "|", "w(cat)",
                           "||", "w(false)", ";", "w(done)", "eof"])
    }

    func testCommentsAndLineContinuation() throws {
        // Raw words keep the continuation verbatim; expansion removes \<newline>.
        let k = kinds(try lex("echo a # a comment\necho b\\\nc\n"))
        XCTAssertEqual(k, ["w(echo)", "w(a)", "nl", "w(echo)", "w(b\\\nc)", "nl", "eof"])
    }

    func testWordsKeepQuotesRaw() throws {
        let k = kinds(try lex("echo \"a $b\" 'raw' \\$x"))
        XCTAssertEqual(k, [#"w(echo)"#, #"w("a $b")"#, #"w('raw')"#, #"w(\$x)"#, "eof"])
    }

    func testSubstitutionNesting() throws {
        let k = kinds(try lex(#"echo $(cat "$(echo hi)") $((1 + (2 * 3)))"#))
        XCTAssertEqual(k, ["w(echo)", #"w($(cat "$(echo hi)"))"#, #"w($((1 + (2 * 3))))"#, "eof"])
    }

    func testHereDocBodyAndExpansionFlag() throws {
        let tokens = try lex("cat <<EOF\nhi $x\nEOF\necho done")
        guard let delimiter = tokens.first(where: { $0.text == "EOF" }) else {
            return XCTFail("no delimiter token")
        }
        XCTAssertEqual(delimiter.hereDoc?.body, "hi $x\n")
        XCTAssertEqual(delimiter.hereDoc?.expand, true)
    }

    func testQuotedHereDocDisablesExpansion() throws {
        let tokens = try lex("cat <<'END'\n$x\nEND")
        let delimiter = tokens.first(where: { $0.text == "'END'" })
        XCTAssertEqual(delimiter?.hereDoc?.delimiter, "END")
        XCTAssertEqual(delimiter?.hereDoc?.expand, false)
    }

    func testHereDocDashStripsTabs() throws {
        let tokens = try lex("cat <<-E\n\t\tone\n\ttwo\nE")
        let delimiter = tokens.first(where: { $0.text == "E" })
        XCTAssertEqual(delimiter?.hereDoc?.stripTabs, true)
        XCTAssertEqual(delimiter?.hereDoc?.body, "one\ntwo\n")
    }

    func testIoNumber() throws {
        let k = kinds(try lex("echo hi 2>err > out 1>&2"))
        XCTAssertEqual(k, ["w(echo)", "w(hi)", "io(2)", ">", "w(err)", ">", "w(out)",
                           "io(1)", ">&", "w(2)", "eof"])
    }

    func testUnterminatedQuoteThrows() {
        XCTAssertThrowsError(try lex("echo 'oops")) { error in
            XCTAssert(error is TetherShellParseError)
        }
    }

    func testMissingHereDocDelimiterThrows() {
        XCTAssertThrowsError(try lex("cat <<")) { error in
            XCTAssert(error is TetherShellParseError)
        }
    }
}
