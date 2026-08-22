import Foundation

/// Evaluates Bash/POSIX arithmetic expressions used inside ``$(( ... ))`` and by
/// `let`/`(( ))` style constructs. The language is evaluated directly to an Int;
/// it never executes commands and only reads/writes the `variables` dictionary
/// it is given.
///
/// Supported operators, lowest to highest precedence:
///   assignment   = += -= *= /= %=
///   ternary      ?:
///   logical or   ||
///   logical and  &&
///   bitwise or   |
///   bitwise xor  ^
///   bitwise and  &
///   equality     == !=
///   relational   < <= > >=
///   shift        << >>
///   additive     + -
///   multiplicative * / %
///   power        ** (right-associative)
///   unary        + - ! ~   and prefix ++ --
///   postfix      ++ --
///
/// Literals may be decimal, hexadecimal (0x…), octal (0…), or binary (base#digits).
/// Bare variable names are resolved through `variables`; an unset or non-numeric
/// variable reads as 0. Writing to a variable stores its decimal string.
public enum ArithmeticEvaluator {

    // MARK: - Public API

    public static func evaluate(_ expression: String,
                                variables: inout [String: String]) throws -> Int {
        var lexer = ArithLexer(expression)
        let ast: ArithNode
        do {
            var parser = ArithParser(lexer: &lexer)
            ast = try parser.parse()
        } catch let e as ShellLangError {
            throw e
        } catch {
            throw ShellLangError.arithmetic("\(error)")
        }
        var ctx = ArithContext(variables: variables)
        let result = try ast.eval(&ctx)
        variables = ctx.variables
        return result
    }

    // MARK: - AST

    indirect enum ArithNode {
        case literal(Int)
        case variable(String)
        case unary(String, ArithNode)
        case binary(String, ArithNode, ArithNode)
        case ternary(ArithNode, ArithNode, ArithNode)
        case assign(String, String, ArithNode)   // (op, name, rhs)
        case preIncDec(String, String)           // (op, name) op = "++"/"--"
        case postIncDec(String, String)

        func eval(_ ctx: inout ArithContext) throws -> Int {
            switch self {
            case .literal(let n):
                return n
            case .variable(let name):
                return ctx.value(of: name)
            case .unary(let op, let operand):
                let v = try operand.eval(&ctx)
                switch op {
                case "+": return v
                case "-": return -v
                case "!": return v == 0 ? 1 : 0
                case "~": return ~v
                default: throw ShellLangError.arithmetic("unknown unary operator \(op)")
                }
            case .binary(let op, let lhs, let rhs):
                return try evalBinary(op, lhs, rhs, &ctx)
            case .ternary(let cond, let t, let f):
                return (try cond.eval(&ctx)) != 0 ? (try t.eval(&ctx)) : (try f.eval(&ctx))
            case .assign(let op, let name, let rhs):
                let r = try rhs.eval(&ctx)
                let newVal: Int
                switch op {
                case "=": newVal = r
                case "+=": newVal = ctx.value(of: name) &+ r
                case "-=": newVal = ctx.value(of: name) &- r
                case "*=": newVal = ctx.value(of: name) &* r
                case "/=":
                    guard r != 0 else { throw ShellLangError.arithmetic("division by zero") }
                    newVal = ctx.value(of: name) / r
                case "%=":
                    guard r != 0 else { throw ShellLangError.arithmetic("division by zero") }
                    newVal = ctx.value(of: name) % r
                default: throw ShellLangError.arithmetic("unknown assignment operator \(op)")
                }
                ctx.set(newVal, for: name)
                return newVal
            case .preIncDec(let op, let name):
                let old = ctx.value(of: name)
                let new = op == "++" ? old &+ 1 : old &- 1
                ctx.set(new, for: name)
                return new
            case .postIncDec(let op, let name):
                let old = ctx.value(of: name)
                let new = op == "++" ? old &+ 1 : old &- 1
                ctx.set(new, for: name)
                return old
            }
        }

        private func evalBinary(_ op: String, _ l: ArithNode, _ r: ArithNode,
                                _ ctx: inout ArithContext) throws -> Int {
            // Short-circuit logical operators.
            if op == "&&" {
                let v = try l.eval(&ctx)
                if v == 0 { return 0 }
                return (try r.eval(&ctx)) != 0 ? 1 : 0
            }
            if op == "||" {
                let v = try l.eval(&ctx)
                if v != 0 { return 1 }
                return (try r.eval(&ctx)) != 0 ? 1 : 0
            }
            let a = try l.eval(&ctx)
            let b = try r.eval(&ctx)
            switch op {
            case "==": return a == b ? 1 : 0
            case "!=": return a != b ? 1 : 0
            case "<":  return a <  b ? 1 : 0
            case "<=": return a <= b ? 1 : 0
            case ">":  return a >  b ? 1 : 0
            case ">=": return a >= b ? 1 : 0
            case "&":  return a & b
            case "|":  return a | b
            case "^":  return a ^ b
            case "<<": return a << b
            case ">>": return a >> b
            case "+":  return a &+ b
            case "-":  return a &- b
            case "*":  return a &* b
            case "/":
                guard b != 0 else { throw ShellLangError.arithmetic("division by zero") }
                return a / b
            case "%":
                guard b != 0 else { throw ShellLangError.arithmetic("division by zero") }
                return a % b
            case "**": return pow(a, b)
            default: throw ShellLangError.arithmetic("unknown binary operator \(op)")
            }
        }

        private func pow(_ base: Int, _ exp: Int) -> Int {
            if exp < 0 {
                // Negative exponents yield 0 for integer arithmetic (|base| > 1)
                // or 1/0 for 0/1. Approximate with 0 for |base|>1, else 1.
                if base == 1 { return 1 }
                if base == -1 { return exp == Int.min ? 1 : (abs(exp) % 2 == 0 ? 1 : -1) }
                return 0
            }
            var result = 1
            var b = base
            var e = exp
            while e > 0 {
                if e & 1 == 1 { result = result &* b }
                b = b &* b
                e >>= 1
            }
            return result
        }
    }

    // MARK: - Context

    struct ArithContext {
        var variables: [String: String]

        init(variables: [String: String]) {
            self.variables = variables
        }

        func value(of name: String) -> Int {
            guard let raw = variables[name] else { return 0 }
            return ArithLexer.parseInt(raw) ?? 0
        }

        mutating func set(_ value: Int, for name: String) {
            variables[name] = String(value)
        }
    }

    // MARK: - Lexer

    struct Token: Equatable {
        enum Kind: Equatable {
            case number(Int)
            case name(String)
            case op(String)
            case lparen
            case rparen
        }
        let kind: Kind
    }

    struct ArithLexer {
        private let chars: [Character]
        private var i = 0

        init(_ s: String) {
            self.chars = Array(s)
        }

        mutating func next() -> Token {
            skipSpace()
            guard i < chars.count else { return Token(kind: .op("")) } // EOF marker
            let c = chars[i]

            if c == "(" {
                i += 1
                return Token(kind: .lparen)
            }
            if c == ")" {
                i += 1
                return Token(kind: .rparen)
            }
            if c.isNumber {
                return readNumber()
            }
            if isNameStart(c) {
                return readName()
            }
            // Multi-char operators.
            for (op, len) in [("**", 2), ("<<", 2), (">>", 2), ("==", 2), ("!=", 2),
                              ("<=", 2), (">=", 2), ("&&", 2), ("||", 2),
                              ("+=", 2), ("-=", 2), ("*=", 2), ("/=", 2), ("%=", 2),
                              ("++", 2), ("--", 2)] {
                if i + len <= chars.count && String(chars[i..<i + len]) == op {
                    i += len
                    return Token(kind: .op(op))
                }
            }
            i += 1
            return Token(kind: .op(String(c)))
        }

        private mutating func skipSpace() {
            while i < chars.count && chars[i].isWhitespace { i += 1 }
        }

        private func isNameStart(_ c: Character) -> Bool {
            return c.isLetter || c == "_"
        }

        private mutating func readName() -> Token {
            var name = ""
            while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                name.append(chars[i]); i += 1
            }
            return Token(kind: .name(name))
        }

        private mutating func readNumber() -> Token {
            var num = ""
            while i < chars.count && (chars[i].isNumber || chars[i] == "_") {
                num.append(chars[i]); i += 1
            }
            // `0x`/`0o`/`0b` hex/octal/binary prefix (e.g. 0x10, 0o17, 0b101).
            if !num.isEmpty, i < chars.count, isRadixPrefix(chars[i]) {
                num.append(chars[i]); i += 1
                while i < chars.count && isBaseDigit(chars[i]) {
                    num.append(chars[i]); i += 1
                }
            } else if !num.isEmpty, i < chars.count, chars[i] == "#" {
                // Base-prefixed literal: `base#digits` (e.g. 2#101, 16#FF).
                num.append("#")
                i += 1
                while i < chars.count && isBaseDigit(chars[i]) {
                    num.append(chars[i]); i += 1
                }
            }
            if let v = ArithLexer.parseInt(num) {
                return Token(kind: .number(v))
            }
            // Not a valid number; return as a (degenerate) name to trigger a
            // syntax error upstream, but keep the text for a useful message.
            return Token(kind: .name(num))
        }

        private func isRadixPrefix(_ c: Character) -> Bool {
            return c == "x" || c == "X" || c == "o" || c == "O" || c == "b" || c == "B"
        }

        private func isBaseDigit(_ c: Character) -> Bool {
            return c.isNumber || c.isLetter
        }

        // Parse an integer literal honoring 0x/0o/0b and base#digits and octal.
        static func parseInt(_ raw: String) -> Int? {
            let s = raw.replacingOccurrences(of: "_", with: "")
            if s.isEmpty { return nil }

            // base#digits form.
            if let hash = s.firstIndex(of: "#") {
                let basePart = s[..<hash]
                let digits = s[s.index(after: hash)...]
                guard let base = Int(basePart), base >= 2, base <= 36 else { return nil }
                return parseInBase(digits, base: base)
            }
            if s.hasPrefix("0x") || s.hasPrefix("0X") {
                return parseInBase(s.dropFirst(2), base: 16)
            }
            if s.hasPrefix("0b") || s.hasPrefix("0B") {
                return parseInBase(s.dropFirst(2), base: 2)
            }
            if s.hasPrefix("0o") || s.hasPrefix("0O") {
                return parseInBase(s.dropFirst(2), base: 8)
            }
            if s.hasPrefix("0") && s.count > 1 {
                // Leading zero => octal, unless it's just "0" (already handled).
                if let v = parseInBase(Substring(s), base: 8) { return v }
                // Some shells reject invalid octal; treat as error.
                return nil
            }
            return Int(s)
        }

        private static func parseInBase(_ s: Substring, base: Int) -> Int? {
            var result = 0
            for ch in s {
                let v: Int
                if let d = ch.wholeNumberValue, d < base {
                    v = d
                } else if let ascii = ch.asciiValue {
                    if ch.isLowercase, ascii >= Character("a").asciiValue! {
                        v = Int(ascii - Character("a").asciiValue!) + 10
                    } else if ch.isUppercase, ascii >= Character("A").asciiValue! {
                        v = Int(ascii - Character("A").asciiValue!) + 10
                    } else {
                        return nil
                    }
                    if v >= base { return nil }
                } else {
                    return nil
                }
                result = result * base + v
            }
            return result
        }
    }

    // MARK: - Parser (recursive descent, AST building)

    struct ArithParser {
        private var lexer: ArithLexer
        private var lookahead: Token
        private var haveLookahead = false

        init(lexer: inout ArithLexer) {
            self.lexer = lexer
            lookahead = Token(kind: .op(""))
        }

        private mutating func peek() -> Token {
            if !haveLookahead {
                lookahead = lexer.next()
                haveLookahead = true
            }
            return lookahead
        }

        private mutating func advance() -> Token {
            let t = peek()
            haveLookahead = false
            return t
        }

        private mutating func expect(_ op: String) throws {
            let t = advance()
            // Parentheses have their own token kinds; everything else is `.op`.
            switch t.kind {
            case .rparen where op == ")": return
            case .lparen where op == "(": return
            case .op(let o) where o == op: return
            default: throw ShellLangError.arithmetic("expected '\(op)'")
            }
        }

        mutating func parse() throws -> ArithNode {
            let node = try parseAssign()
            let t = peek()
            if case .op(let o) = t.kind, o != "" {
                throw ShellLangError.arithmetic("unexpected '\(o)'")
            }
            return node
        }

        // assignment: right-associative, lowest precedence.
        private mutating func parseAssign() throws -> ArithNode {
            let left = try parseTernary()
            if case .op(let op) = peek().kind, isAssignOp(op) {
                _ = advance()
                let rhs = try parseAssign()
                if case .variable(let name) = left {
                    return .assign(op, name, rhs)
                }
                throw ShellLangError.arithmetic("assignment requires a variable on the left")
            }
            return left
        }

        private func isAssignOp(_ op: String) -> Bool {
            return op == "=" || op == "+=" || op == "-=" || op == "*=" || op == "/=" || op == "%="
        }

        private mutating func parseTernary() throws -> ArithNode {
            let cond = try parseOr()
            if case .op("?") = peek().kind {
                _ = advance()
                let t = try parseAssign()
                _ = try expect(":")
                let f = try parseAssign()
                return .ternary(cond, t, f)
            }
            return cond
        }

        private mutating func parseOr() throws -> ArithNode {
            var node = try parseAnd()
            while case .op("||") = peek().kind {
                _ = advance()
                let rhs = try parseAnd()
                node = .binary("||", node, rhs)
            }
            return node
        }

        private mutating func parseAnd() throws -> ArithNode {
            var node = try parseBitOr()
            while case .op("&&") = peek().kind {
                _ = advance()
                let rhs = try parseBitOr()
                node = .binary("&&", node, rhs)
            }
            return node
        }

        private mutating func parseBitOr() throws -> ArithNode {
            var node = try parseBitXor()
            while case .op("|") = peek().kind {
                _ = advance()
                let rhs = try parseBitXor()
                node = .binary("|", node, rhs)
            }
            return node
        }

        private mutating func parseBitXor() throws -> ArithNode {
            var node = try parseBitAnd()
            while case .op("^") = peek().kind {
                _ = advance()
                let rhs = try parseBitAnd()
                node = .binary("^", node, rhs)
            }
            return node
        }

        private mutating func parseBitAnd() throws -> ArithNode {
            var node = try parseEquality()
            while case .op("&") = peek().kind {
                _ = advance()
                let rhs = try parseEquality()
                node = .binary("&", node, rhs)
            }
            return node
        }

        private mutating func parseEquality() throws -> ArithNode {
            var node = try parseRelational()
            while case .op(let o) = peek().kind, o == "==" || o == "!=" {
                _ = advance()
                let rhs = try parseRelational()
                node = .binary(o, node, rhs)
            }
            return node
        }

        private mutating func parseRelational() throws -> ArithNode {
            var node = try parseShift()
            while case .op(let o) = peek().kind, isRelational(o) {
                _ = advance()
                let rhs = try parseShift()
                node = .binary(o, node, rhs)
            }
            return node
        }

        private func isRelational(_ op: String) -> Bool {
            return op == "<" || op == "<=" || op == ">" || op == ">="
        }

        private mutating func parseShift() throws -> ArithNode {
            var node = try parseAdditive()
            while case .op(let o) = peek().kind, o == "<<" || o == ">>" {
                _ = advance()
                let rhs = try parseAdditive()
                node = .binary(o, node, rhs)
            }
            return node
        }

        private mutating func parseAdditive() throws -> ArithNode {
            var node = try parseMultiplicative()
            while case .op(let o) = peek().kind, o == "+" || o == "-" {
                _ = advance()
                let rhs = try parseMultiplicative()
                node = .binary(o, node, rhs)
            }
            return node
        }

        private mutating func parseMultiplicative() throws -> ArithNode {
            var node = try parsePower()
            while case .op(let o) = peek().kind, o == "*" || o == "/" || o == "%" {
                _ = advance()
                let rhs = try parsePower()
                node = .binary(o, node, rhs)
            }
            return node
        }

        // Right-associative power.
        private mutating func parsePower() throws -> ArithNode {
            let left = try parseUnary()
            if case .op("**") = peek().kind {
                _ = advance()
                let right = try parsePower()
                return .binary("**", left, right)
            }
            return left
        }

        private mutating func parseUnary() throws -> ArithNode {
            if case .op(let o) = peek().kind,
               o == "+" || o == "-" || o == "!" || o == "~" {
                _ = advance()
                let operand = try parseUnary()
                return .unary(o, operand)
            }
            if case .op(let o) = peek().kind, o == "++" || o == "--" {
                _ = advance()
                let operand = try parseUnary()
                if case .variable(let name) = operand {
                    return .preIncDec(o, name)
                }
                throw ShellLangError.arithmetic("\(o) requires a variable operand")
            }
            return try parsePostfix()
        }

        private mutating func parsePostfix() throws -> ArithNode {
            var node = try parsePrimary()
            while case .op(let o) = peek().kind, o == "++" || o == "--" {
                _ = advance()
                if case .variable(let name) = node {
                    node = .postIncDec(o, name)
                } else {
                    throw ShellLangError.arithmetic("\(o) requires a variable operand")
                }
            }
            return node
        }

        private mutating func parsePrimary() throws -> ArithNode {
            let t = advance()
            switch t.kind {
            case .number(let n):
                return .literal(n)
            case .name(let name):
                return .variable(name)
            case .lparen:
                let inner = try parseAssign()
                _ = try expect(")")
                return inner
            default:
                throw ShellLangError.arithmetic("unexpected token")
            }
        }
    }
}
