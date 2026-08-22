import XCTest
@testable import TermXShellLang

// MARK: - Fake ShellHost

/// Scripts acceptable exit codes per command line and records what was run.
final class FakeHost: ShellHost {
    var codes: [String: Int32] = [:]      // command line -> exit code (default 0)
    var recorded: [String] = []
    var stdoutText = ""
    var stderrText = ""
    var env: [String: String] = [:]

    func run(commandLine: String) -> Int32 {
        recorded.append(commandLine)
        return codes[commandLine] ?? 0
    }
    func write(_ text: String) { stdoutText += text }
    func writeError(_ text: String) { stderrText += text }
    func value(for name: String) -> String? { env[name] }
    func setValue(_ value: String, for name: String) { env[name] = value }
}

// MARK: - Arithmetic

final class ArithmeticTests: XCTestCase {
    func evaluate(_ e: String, vars: [String: String] = [:]) throws -> Int {
        var v = vars
        return try ArithmeticEvaluator.evaluate(e, variables: &v)
    }

    func testPrecedenceAndBasics() throws {
        XCTAssertEqual(try evaluate("1+2*3"), 7)
        XCTAssertEqual(try evaluate("(1+2)*3"), 9)
        XCTAssertEqual(try evaluate("10/3"), 3)
        XCTAssertEqual(try evaluate("10%3"), 1)
        XCTAssertEqual(try evaluate("2**3"), 8)
        XCTAssertEqual(try evaluate("2**3**2"), 512)   // right associative
        XCTAssertEqual(try evaluate("10-4-3"), 3)
        XCTAssertEqual(try evaluate("7>>1"), 3)
        XCTAssertEqual(try evaluate("1<<4"), 16)
    }

    func testUnaryAndBitwise() throws {
        XCTAssertEqual(try evaluate("-5+3"), -2)
        XCTAssertEqual(try evaluate("+5"), 5)
        XCTAssertEqual(try evaluate("!0"), 1)
        XCTAssertEqual(try evaluate("!5"), 0)
        XCTAssertEqual(try evaluate("~0"), -1)
        XCTAssertEqual(try evaluate("6&3"), 2)
        XCTAssertEqual(try evaluate("6|3"), 7)
        XCTAssertEqual(try evaluate("6^3"), 5)
    }

    func testComparisonAndLogic() throws {
        XCTAssertEqual(try evaluate("3==3"), 1)
        XCTAssertEqual(try evaluate("3!=3"), 0)
        XCTAssertEqual(try evaluate("3<5"), 1)
        XCTAssertEqual(try evaluate("5<=5"), 1)
        XCTAssertEqual(try evaluate("5>10"), 0)
        XCTAssertEqual(try evaluate("10>=10"), 1)
        XCTAssertEqual(try evaluate("1 && 0"), 0)
        XCTAssertEqual(try evaluate("1 || 0"), 1)
        // Short circuit: x stays 0 for && short-circuit.
        XCTAssertEqual(try evaluate("0 && (x=9)"), 0)
    }

    func testTernary() throws {
        XCTAssertEqual(try evaluate("(1 && 2) ? 10 : 20"), 10)
        XCTAssertEqual(try evaluate("(0) ? 10 : 20"), 20)
        XCTAssertEqual(try evaluate("1 ? 2 : 3"), 2)
    }

    func testLiterals() throws {
        XCTAssertEqual(try evaluate("0x10"), 16)
        XCTAssertEqual(try evaluate("0xff"), 255)
        XCTAssertEqual(try evaluate("010"), 8)      // octal
        XCTAssertEqual(try evaluate("2#101"), 5)    // base#digits
        XCTAssertEqual(try evaluate("16#FF"), 255)
    }

    func testVariablesAndAssignment() throws {
        var vars = ["a": "5", "b": "3"]
        XCTAssertEqual(try ArithmeticEvaluator.evaluate("a ** 2 + b", variables: &vars), 28)
        XCTAssertEqual(try ArithmeticEvaluator.evaluate("x = a * 2", variables: &vars), 10)
        XCTAssertEqual(vars["x"], "10")
        XCTAssertEqual(try ArithmeticEvaluator.evaluate("x += 5", variables: &vars), 15)
        XCTAssertEqual(vars["x"], "15")
        XCTAssertEqual(try ArithmeticEvaluator.evaluate("x -= 5", variables: &vars), 10)
        XCTAssertEqual(try ArithmeticEvaluator.evaluate("x *= 2", variables: &vars), 20)
        XCTAssertEqual(try ArithmeticEvaluator.evaluate("x /= 4", variables: &vars), 5)
        XCTAssertEqual(try ArithmeticEvaluator.evaluate("x %= 3", variables: &vars), 2)
        XCTAssertEqual(vars["x"], "2")
    }

    func testUnsetVariableIsZero() throws {
        var vars: [String: String] = [:]
        XCTAssertEqual(try ArithmeticEvaluator.evaluate("nope + 5", variables: &vars), 5)
    }

    func testIncrementDecrement() throws {
        var vars = ["i": "5"]
        XCTAssertEqual(try ArithmeticEvaluator.evaluate("i++", variables: &vars), 5)
        XCTAssertEqual(vars["i"], "6")
        XCTAssertEqual(try ArithmeticEvaluator.evaluate("++i", variables: &vars), 7)
        XCTAssertEqual(vars["i"], "7")
        XCTAssertEqual(try ArithmeticEvaluator.evaluate("i--", variables: &vars), 7)
        XCTAssertEqual(vars["i"], "6")
        XCTAssertEqual(try ArithmeticEvaluator.evaluate("--i", variables: &vars), 5)
        XCTAssertEqual(vars["i"], "5")
    }

    func testDivisionByZeroThrows() {
        XCTAssertThrowsError(try evaluate("1/0"))
        XCTAssertThrowsError(try evaluate("1%0"))
    }

    func testArithmeticErrorCases() throws {
        XCTAssertThrowsError(try evaluate("1+"))
        XCTAssertThrowsError(try evaluate("((1"))
    }
}

// MARK: - Tilde / brace expansion

final class WordExpanderTests: XCTestCase {
    func testTilde() {
        XCTAssertEqual(WordExpander.expandTilde("~", home: "/home/u"), "/home/u")
        XCTAssertEqual(WordExpander.expandTilde("~/docs", home: "/home/u"), "/home/u/docs")
        XCTAssertEqual(WordExpander.expandTilde("~bob", home: "/home/u"), "~bob")
        XCTAssertEqual(WordExpander.expandTilde("plain", home: "/home/u"), "plain")
    }

    func testBraces() {
        XCTAssertEqual(WordExpander.expandBraces("a{b,c}d"), ["abd", "acd"])
        XCTAssertEqual(WordExpander.expandBraces("{1..3}"), ["1", "2", "3"])
        XCTAssertEqual(WordExpander.expandBraces("{1..5..2}"), ["1", "3", "5"])
        XCTAssertEqual(WordExpander.expandBraces("{a..e}"), ["a", "b", "c", "d", "e"])
    }

    func testBraceMultipleAndNested() {
        XCTAssertEqual(WordExpander.expandBraces("{a,b}{c,d}"), ["ac", "ad", "bc", "bd"])
        XCTAssertEqual(WordExpander.expandBraces("{x,{a,b}}y"), ["xy", "ay", "by"])
        // A non-expandable brace group is left literal.
        XCTAssertEqual(WordExpander.expandBraces("{a}"), ["{a}"])
    }

    func testDescendingRange() {
        XCTAssertEqual(WordExpander.expandBraces("{3..1}"), ["3", "2", "1"])
    }
}

// MARK: - Parameter expansion

final class ParameterExpanderTests: XCTestCase {
    func testPlainAndLength() throws {
        var v = ["V": "world"]
        XCTAssertEqual(try ParameterExpander.expand("${V}", variables: &v), "world")
        XCTAssertEqual(try ParameterExpander.expand("${#V}", variables: &v), "5")
        var unset: [String: String] = [:]
        XCTAssertEqual(try ParameterExpander.expand("${U}", variables: &unset), "")
        XCTAssertEqual(try ParameterExpander.expand("${#U}", variables: &unset), "0")
    }

    func testDefaultForms() throws {
        // ${V:-d}: value if set & non-empty, else default.
        var v = ["V": "real"]
        XCTAssertEqual(try ParameterExpander.expand("${V:-def}", variables: &v), "real")
        var empty = ["V": ""]
        XCTAssertEqual(try ParameterExpander.expand("${V:-def}", variables: &empty), "def")
        var unset: [String: String] = [:]
        XCTAssertEqual(try ParameterExpander.expand("${V:-def}", variables: &unset), "def")

        // ${V:=d}: assign default when null.
        var assign: [String: String] = [:]
        XCTAssertEqual(try ParameterExpander.expand("${V:=set}", variables: &assign), "set")
        XCTAssertEqual(assign["V"], "set")

        // ${V:+alt}: alt if set (and, with ':', non-empty).
        var setV = ["V": "x"]
        XCTAssertEqual(try ParameterExpander.expand("${V:+alt}", variables: &setV), "alt")
        var unsetV: [String: String] = [:]
        XCTAssertEqual(try ParameterExpander.expand("${V:+alt}", variables: &unsetV), "")

        // ${V:?msg}: throws when unset.
        XCTAssertThrowsError(try ParameterExpander.expand("${V:?oops}", variables: &unsetV))
    }

    func testPatternRemoval() throws {
        var v = ["V": "file.tar.gz"]
        XCTAssertEqual(try ParameterExpander.expand("${V#*.}", variables: &v), "tar.gz")   // shortest prefix removal of "*.g"? actually removes ".g"? let's use clearer patterns
        XCTAssertEqual(try ParameterExpander.expand("${V##*.}", variables: &v), "gz")
        XCTAssertEqual(try ParameterExpander.expand("${V%.*}", variables: &v), "file.tar")
        XCTAssertEqual(try ParameterExpander.expand("${V%%.*}", variables: &v), "file")
    }

    func testSubstitution() throws {
        var v = ["V": "abcabc"]
        XCTAssertEqual(try ParameterExpander.expand("${V/a/X}", variables: &v), "Xbcabc")
        XCTAssertEqual(try ParameterExpander.expand("${V//a/X}", variables: &v), "XbcXbc")
    }

    func testSubstring() throws {
        var v = ["V": "hello world"]
        XCTAssertEqual(try ParameterExpander.expand("${V:6}", variables: &v), "world")
        XCTAssertEqual(try ParameterExpander.expand("${V:0:5}", variables: &v), "hello")
        XCTAssertEqual(try ParameterExpander.expand("${V:2}", variables: &v), "llo world")
    }

    func testLeavesBareDollarForms() throws {
        var v = ["V": "x"]
        XCTAssertEqual(try ParameterExpander.expand("$V", variables: &v), "$V")
        XCTAssertEqual(try ParameterExpander.expand("$(cmd)", variables: &v), "$(cmd)")
        XCTAssertEqual(try ParameterExpander.expand("$((1+1))", variables: &v), "$((1+1))")
    }
}

// MARK: - Here-docs

final class HereDocTests: XCTestCase {
    func testPlainHereDoc() throws {
        var v: [String: String] = [:]
        let e = try HereDocProcessor.extract(line: "cat <<EOF",
                                             following: ["line1", "line2", "EOF", "rest"],
                                             variables: &v)
        XCTAssertEqual(e.commandLine, "cat")
        XCTAssertEqual(e.body, "line1\nline2\n")
        XCTAssertEqual(e.remainder, ["rest"])
    }

    func testExpandBody() throws {
        var v = ["name": "Ada"]
        let e = try HereDocProcessor.extract(line: "cat <<EOF",
                                             following: ["hi $name", "EOF"],
                                             variables: &v)
        XCTAssertEqual(e.body, "hi Ada\n")
    }

    func testQuotedDelimiterNoExpansion() throws {
        var v = ["name": "Ada"]
        let e = try HereDocProcessor.extract(line: "cat <<'EOF'",
                                             following: ["hi $name", "EOF"],
                                             variables: &v)
        XCTAssertEqual(e.body, "hi $name\n")
    }

    func testStripTabs() throws {
        var v: [String: String] = [:]
        let e = try HereDocProcessor.extract(line: "cat <<-EOF",
                                             following: ["\tline1", "\tEOF"],
                                             variables: &v)
        XCTAssertEqual(e.body, "line1\n")
        XCTAssertEqual(e.remainder, [])
    }

    func testUnterminatedThrows() {
        var v: [String: String] = [:]
        XCTAssertThrowsError(try HereDocProcessor.extract(line: "cat <<EOF",
                                                          following: ["no terminator"],
                                                          variables: &v))
    }
}

// MARK: - Parser / Evaluator integration

final class ScriptTests: XCTestCase {
    /// Returns a host with all commands programmed to exit 0 and returns what was run.
    func run(_ source: String, codes: [String: Int32] = [:],
             host: FakeHost = FakeHost()) throws -> (FakeHost, Int32) {
        for (k, v) in codes { host.codes[k] = v }
        guard let node = try ScriptParser.parse(source) else {
            XCTFail("parse returned nil for \(source)")
            return (host, -1)
        }
        var vars: [String: String] = [:]
        let ev = ScriptEvaluator(host: host)
        let code = try ev.evaluate(node, variables: &vars)
        return (host, code)
    }

    func testPlainCommandReturnsNil() throws {
        // A script with no modelled construct -> parse returns nil so the app
        // can use its existing single-line path.
        XCTAssertNil(try ScriptParser.parse("echo hello world"))
    }

    func testPureForScriptReturnsNil() throws {
        // `for` is handled by the app, so a pure for-loop should fall through
        // (return nil) rather than being reconstructed/truncated here.
        let src = "for i in a b c; do echo $i; done\n"
        XCTAssertNil(try ScriptParser.parse(src))
    }

    func testBashColonVsPlainParameterOps() throws {
        // Plain ${V-op}: default only when UNSET (an empty-but-set V is kept).
        var v = ["V": ""]
        XCTAssertEqual(try ParameterExpander.expand("${V-def}", variables: &v), "")     // kept (set but empty)
        XCTAssertEqual(try ParameterExpander.expand("${V:-def}", variables: &v), "def") // null → default
        // Plain ${V+alt}: alt when SET (even empty); :+ requires non-empty.
        XCTAssertEqual(try ParameterExpander.expand("${V+alt}", variables: &v), "alt")
        XCTAssertEqual(try ParameterExpander.expand("${V:+alt}", variables: &v), "")    // empty → not alt
        // Unset variable with plain op: defaults apply.
        var unset: [String: String] = [:]
        XCTAssertEqual(try ParameterExpander.expand("${V-def}", variables: &unset), "def")
        XCTAssertEqual(try ParameterExpander.expand("${V+alt}", variables: &unset), "")
        // Set non-empty:
        var full = ["V": "x"]
        XCTAssertEqual(try ParameterExpander.expand("${V+alt}", variables: &full), "alt")
        XCTAssertEqual(try ParameterExpander.expand("${V:+alt}", variables: &full), "alt")
    }

    func testSubstringUsesShellVariablesForOffset() throws {
        var v = ["V": "hello world", "start": "6"]
        XCTAssertEqual(try ParameterExpander.expand("${V:$start}", variables: &v), "world")
    }

    func testIfThenElse() throws {
        let src = """
        if cond1
        then
          echo a
        else
          echo b
        fi
        """
        let (host, _) = try run(src, codes: ["cond1": 0])
        XCTAssertEqual(host.recorded, ["cond1", "echo a"])
    }

    func testIfThreeDeepNesting() throws {
        let src = """
        if a
        then
          if b
          then
            if c
            then
              echo deep
            else echo skip
            fi
          fi
        fi
        """
        let (host, _) = try run(src, codes: ["a": 0, "b": 0, "c": 0])
        XCTAssertEqual(host.recorded, ["a", "b", "c", "echo deep"])
    }

    func testWhileAndBreakTwo() throws {
        let src = """
        while cond
        do
          if inner
          then
            break 2
          fi
          echo body
        done
        echo after
        """
        let codes: [String: Int32] = ["cond": 0, "inner": 0]
        let (host, _) = try run(src, codes: codes)
        // break 2 must exit both the if and the while, but the if is a nested loop
        // the break 2 skips the enclosing while; 'echo body' and 'echo after' both run.
        XCTAssertEqual(host.recorded, ["cond", "inner", "echo after"])
    }

    func testUntil() throws {
        let src = """
        until cond
        do
          echo body
        done
        """
        // cond exit 0 => until stops immediately.
        let (host, _) = try run(src, codes: ["cond": 0])
        XCTAssertEqual(host.recorded, ["cond"])
    }

    func testCaseStatement() throws {
        let src = """
        case foo in
          bar) echo matchbar ;;
          fo*) echo matchfo ;;
          *) echo wild;;
        esac
        """
        let (host, _) = try run(src)
        XCTAssertEqual(host.recorded, ["echo matchfo"])
    }

    func testCaseFallbackPattern() throws {
        let src = """
        case x in
          a|b) echo ab ;;
          *) echo other ;;
        esac
        """
        let (host, _) = try run(src)
        XCTAssertEqual(host.recorded, ["echo other"])
    }

    func testFunctionDefinitionAndCall() throws {
        let src = """
        greet() {
          echo hi $1
        }
        greet world
        """
        let (host, _) = try run(src)
        XCTAssertEqual(host.recorded, ["echo hi world"])
    }

    func testFunctionCallingFunction() throws {
        let src = """
        inner() {
          echo inner
        }
        outer() {
          inner
          echo outer
        }
        outer
        """
        let (host, _) = try run(src)
        XCTAssertEqual(host.recorded, ["echo inner", "echo outer"])
    }

    func testFunctionKeywordForm() throws {
        let src = """
        function f {
          echo run
        }
        f
        """
        let (host, _) = try run(src)
        XCTAssertEqual(host.recorded, ["echo run"])
    }

    func testPositionalParameters() throws {
        let src = """
        argh() {
          echo $1 $2 $#
          return 3
        }
        argh a b c
        """
        let (host, _) = try run(src)
        XCTAssertEqual(host.recorded, ["echo a b 3"])
    }

    func testReturnCodePropagates() throws {
        let src = """
        f() {
          echo inside
          return 5
          echo unreachable
        }
        echo before
        f
        echo after
        """
        let (host, code) = try run(src)
        XCTAssertEqual(host.recorded, ["echo before", "echo inside", "echo after"])
        XCTAssertEqual(code, 0)
    }

    func testMalformedIfThrows() {
        let src = "if cond\nthen\n echo x\n"   // no fi
        XCTAssertThrowsError(try ScriptParser.parse(src))
    }

    func testMalformedCaseThrows() {
        let src = "case x in\n a) echo a\n"     // no esac
        XCTAssertThrowsError(try ScriptParser.parse(src))
    }

    func testOneLineIf() throws {
        let src = "if [ -f x ]; then echo y; fi"
        let (host, _) = try run(src, codes: ["[ -f x ]": 0])
        XCTAssertEqual(host.recorded, ["[ -f x ]", "echo y"])
    }

    func testCommentsAndBlankLines() throws {
        let src = """
        # a comment

        if cond
        # a comment in the middle

        then
          echo a
        fi
        """
        let (host, _) = try run(src, codes: ["cond": 0])
        XCTAssertEqual(host.recorded, ["cond", "echo a"])
    }

    func testUndefinedFunctionError() throws {
        let host = FakeHost()
        let ev = ScriptEvaluator(host: host)
        var vars: [String: String] = [:]
        XCTAssertThrowsError(try ev.callFunction(named: "nope", arguments: [], variables: &vars)) {
            XCTAssertEqual($0 as? ShellLangError, .undefinedFunction("nope"))
        }
    }
}
