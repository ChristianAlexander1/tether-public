import Foundation

/// Errors from arithmetic expansion `$(( ... ))` / `(( ... ))`.
enum ArithError: Error, CustomStringConvertible {
    case divisionByZero
    case notLValue
    case badNumber(String)
    case syntax(String)

    var description: String {
        switch self {
        case .divisionByZero: return "division by zero"
        case .notLValue: return "expression not assignable"
        case .badNumber(let s): return "bad number `\(s)'"
        case .syntax(let s): return "arithmetic syntax error: \(s)"
        }
    }
}

private indirect enum Node {
    case number(Int)
    case variable(String)
    case unary(String, Node)                       // + - ! ~
    case binary(String, Node, Node)
    case ternary(Node, Node, Node)
    case assign(String, String, Node)              // name, op (=, +=, ...), rhs
    case change(String, Int, Bool)                 // name, delta, returnsOld
}

/// Recursive-descent arithmetic evaluator following C/POSIX precedence.
/// Variables are read/written through the provided closures so `$((x += 1))`
/// updates the real shell environment.
enum Arithmetic {

    typealias Get = (String) -> Int
    typealias Put = (String, Int) -> Void

    static func evaluate(_ source: String, get: @escaping Get, set: @escaping Put) throws -> Int {
        let toks = try tokenize(source)
        var parser = ArithParser(toks: toks)
        let node = try parser.parseComma()
        guard parser.atEnd else { throw ArithError.syntax("trailing input") }
        return try eval(node, get, set)
    }

    // MARK: - Tokenizer

    enum Tok: Equatable {
        case num(Int)
        case ident(String)
        case op(String)     // also ( ) ? : ,
    }

    private static let multiOps = [
        "<<=", ">>=", "**=",
        "++", "--", "<=", ">=", "==", "!=", "&&", "||", "<<", ">>", "**",
        "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=",
    ]
    private static let singleOps = Set("+-*/%<>!~&|^=?:(),")

    private static func tokenize(_ source: String) throws -> [Tok] {
        let chars = Array(source)
        var toks: [Tok] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" { i += 1; continue }
            if ScanUtil.isDigit(c) {
                if chars[i] == "0", i + 1 < chars.count,
                   chars[i + 1] == "x" || chars[i + 1] == "X" {
                    var k = i + 2
                    while k < chars.count && chars[k].isHexDigit { k += 1 }
                    let hex = String(chars[(i + 2)..<k])
                    guard let value = Int(hex, radix: 16) else {
                        throw ArithError.badNumber("0x" + hex)
                    }
                    toks.append(.num(value)); i = k; continue
                }
                var j = i
                while j < chars.count && ScanUtil.isDigit(chars[j]) { j += 1 }
                let digits = String(chars[i..<j])
                if j < chars.count && chars[j] == "#" {
                    // base#number (mksh/ksh): 16#ff, 2#1010 ...
                    guard let base = Int(digits), base >= 2, base <= 36 else {
                        throw ArithError.badNumber(digits + "#")
                    }
                    var k = j + 1
                    while k < chars.count
                            && (chars[k].isLetter || ScanUtil.isDigit(chars[k])
                                || chars[k] == "_") { k += 1 }
                    let body = String(chars[(j + 1)..<k]).replacingOccurrences(of: "_", with: "")
                    guard let value = Arithmetic.parseBase(body, base: base) else {
                        throw ArithError.badNumber(digits + "#" + body)
                    }
                    toks.append(.num(value)); i = k; continue
                }
                if digits.count > 1, digits.hasPrefix("0") {
                    guard let value = Int(digits, radix: 8) else {
                        throw ArithError.badNumber(digits)
                    }
                    toks.append(.num(value)); i = j; continue
                }
                guard let value = Int(digits) else {
                    throw ArithError.badNumber(digits)
                }
                toks.append(.num(value)); i = j; continue
            }
            if ScanUtil.isNameStart(c) {
                var j = i
                while j < chars.count && ScanUtil.isNameChar(chars[j]) { j += 1 }
                toks.append(.ident(String(chars[i..<j]))); i = j; continue
            }
            var matched = false
            for op in multiOps where chars.count - i >= op.count {
                if String(chars[i..<(i + op.count)]) == op {
                    toks.append(.op(op)); i += op.count; matched = true; break
                }
            }
            if matched { continue }
            if singleOps.contains(c) {
                toks.append(.op(String(c))); i += 1; continue
            }
            throw ArithError.syntax("unexpected character `\(c)'")
        }
        return toks
    }

    private static func parseBase(_ digits: String, base: Int) -> Int? {
        var value = 0
        for c in digits {
            guard let ascii = c.asciiValue else { return nil }
            let d: Int
            switch c {
            case "0"..."9": d = Int(ascii - Character("0").asciiValue!)
            case "a"..."z": d = Int(ascii - Character("a").asciiValue!) + 10
            case "A"..."Z": d = Int(ascii - Character("A").asciiValue!) + 10
            default: return nil
            }
            if d >= base { return nil }
            value = value &* base &+ d
        }
        return digits.isEmpty ? nil : value
    }

    // MARK: - Parser

    private struct ArithParser {
        let toks: [Tok]
        var pos = 0

        var atEnd: Bool { pos >= toks.count }
        var peek: Tok? { pos < toks.count ? toks[pos] : nil }

        func peekOp(_ s: String) -> Bool {
            guard case .op(let o)? = peek else { return false }
            return o == s
        }

        @discardableResult
        mutating func takeOp(_ s: String) -> Bool {
            if peekOp(s) { pos += 1; return true }
            return false
        }

        static let assignOps = ["=", "+=", "-=", "*=", "/=", "%=",
                                "<<=", ">>=", "**=", "&=", "|=", "^="]

        mutating func parseComma() throws -> Node {
            var left = try parseAssign()
            while takeOp(",") {
                left = .binary(",", left, try parseAssign())
            }
            return left
        }

        mutating func parseAssign() throws -> Node {
            let left = try parseTernary()
            for op in ArithParser.assignOps where peekOp(op) {
                pos += 1
                guard case .variable(let name) = left else { throw ArithError.notLValue }
                return .assign(name, op, try parseAssign())
            }
            return left
        }

        mutating func parseTernary() throws -> Node {
            let cond = try parseBinary(minPrec: 1)
            guard takeOp("?") else { return cond }
            let then = try parseComma()
            guard takeOp(":") else { throw ArithError.syntax("expected `:' in conditional") }
            let els = try parseTernary()
            return .ternary(cond, then, els)
        }

        static let precedence: [String: Int] = [
            "||": 1, "&&": 2, "|": 3, "^": 4, "&": 5,
            "==": 6, "!=": 6,
            "<": 7, "<=": 7, ">": 7, ">=": 7,
            "<<": 8, ">>": 8,
            "+": 9, "-": 9,
            "*": 10, "/": 10, "%": 10,
            "**": 11,
        ]

        mutating func parseBinary(minPrec: Int) throws -> Node {
            var left = try parseUnary()
            while true {
                guard case .op(let o)? = peek,
                      let prec = ArithParser.precedence[o], prec >= minPrec else { break }
                pos += 1
                // `**` is right-associative (ksh/mksh).
                let right = try parseBinary(minPrec: o == "**" ? prec : prec + 1)
                left = .binary(o, left, right)
            }
            return left
        }

        mutating func parseUnary() throws -> Node {
            if takeOp("-") { return .unary("-", try parseUnary()) }
            if takeOp("+") { return .unary("+", try parseUnary()) }
            if takeOp("!") { return .unary("!", try parseUnary()) }
            if takeOp("~") { return .unary("~", try parseUnary()) }
            if takeOp("++") || takeOp("--") {
                let delta = toks[pos - 1] == .op("++") ? 1 : -1
                guard case .ident(let name)? = peek else { throw ArithError.notLValue }
                pos += 1
                return .change(name, delta, false)
            }
            return try parsePostfix()
        }

        mutating func parsePostfix() throws -> Node {
            var node = try parsePrimary()
            while true {
                if takeOp("++") || takeOp("--") {
                    let delta = toks[pos - 1] == .op("++") ? 1 : -1
                    guard case .variable(let name) = node else { throw ArithError.notLValue }
                    node = .change(name, delta, true)
                } else {
                    return node
                }
            }
        }

        mutating func parsePrimary() throws -> Node {
            guard let tok = peek else { throw ArithError.syntax("unexpected end") }
            switch tok {
            case .num(let v):
                pos += 1
                return .number(v)
            case .ident(let name):
                pos += 1
                return .variable(name)
            case .op("("):
                pos += 1
                let node = try parseComma()
                guard takeOp(")") else { throw ArithError.syntax("expected `)'") }
                return node
            default:
                throw ArithError.syntax("unexpected token")
            }
        }
    }

    // MARK: - Evaluator

    /// Integer exponentiation (wrapping). Negative exponents give 0 like
    /// integer 1/x^n would (any nonzero base), matching mksh's behavior.
    static func intPow(_ base: Int, _ exp: Int) -> Int {
        if exp < 0 {
            return base == 1 ? 1 : (base == -1 ? ((exp & 1) == 0 ? 1 : -1) : 0)
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

    private static func eval(_ node: Node, _ get: Get, _ set: Put) throws -> Int {
        switch node {
        case .number(let v):
            return v
        case .variable(let name):
            return get(name)
        case .change(let name, let delta, let returnsOld):
            let current = get(name)
            set(name, current &+ delta)
            return returnsOld ? current : current &+ delta
        case .assign(let name, let op, let rhs):
            let r = try eval(rhs, get, set)
            let value: Int
            switch op {
            case "=": value = r
            case "+=": value = get(name) &+ r
            case "-=": value = get(name) &- r
            case "*=": value = get(name) &* r
            case "/=":
                if r == 0 { throw ArithError.divisionByZero }
                value = get(name) / r
            case "%=":
                if r == 0 { throw ArithError.divisionByZero }
                value = get(name) % r
            case "<<=": value = get(name) << (r & 63)
            case ">>=": value = get(name) >> (r & 63)
            case "**=": value = Arithmetic.intPow(get(name), r)
            case "&=": value = get(name) & r
            case "|=": value = get(name) | r
            case "^=": value = get(name) ^ r
            default: throw ArithError.syntax("bad assignment op")
            }
            set(name, value)
            return value
        case .unary(let op, let operand):
            let v = try eval(operand, get, set)
            switch op {
            case "-": return 0 &- v
            case "+": return v
            case "!": return v == 0 ? 1 : 0
            case "~": return ~v
            default: throw ArithError.syntax("bad unary op")
            }
        case .ternary(let cond, let then, let els):
            let c = try eval(cond, get, set)
            return c != 0 ? try eval(then, get, set) : try eval(els, get, set)
        case .binary(let op, let left, let right):
            switch op {
            case ",": _ = try eval(left, get, set); return try eval(right, get, set)
            case "&&":
                if try eval(left, get, set) == 0 { return 0 }
                return try eval(right, get, set) != 0 ? 1 : 0
            case "||":
                if try eval(left, get, set) != 0 { return 1 }
                return try eval(right, get, set) != 0 ? 1 : 0
            default: break
            }
            let l = try eval(left, get, set)
            let r = try eval(right, get, set)
            switch op {
            case "+": return l &+ r
            case "-": return l &- r
            case "*": return l &* r
            case "/":
                if r == 0 { throw ArithError.divisionByZero }
                return l / r
            case "%":
                if r == 0 { throw ArithError.divisionByZero }
                return l % r
            case "<<": return l << (r & 63)
            case ">>": return l >> (r & 63)
            case "<": return l < r ? 1 : 0
            case "<=": return l <= r ? 1 : 0
            case ">": return l > r ? 1 : 0
            case ">=": return l >= r ? 1 : 0
            case "==": return l == r ? 1 : 0
            case "!=": return l != r ? 1 : 0
            case "**": return Arithmetic.intPow(l, r)
            case "&": return l & r
            case "|": return l | r
            case "^": return l ^ r
            default: throw ArithError.syntax("bad binary op `\(op)'")
            }
        }
    }
}
