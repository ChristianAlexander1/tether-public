import Foundation

/// The constructs this layer parses. Anything that is not one of these is a
/// `.command(String)` handed verbatim to `ShellHost.run(commandLine:)`.
public indirect enum ShellNode {
    case command(String)
    case sequence([ShellNode])
    case ifStatement(conditions: [(ShellNode, ShellNode)], elseBranch: ShellNode?)
    case whileLoop(condition: ShellNode, body: ShellNode, isUntil: Bool)
    case caseStatement(subject: String, cases: [(patterns: [String], body: ShellNode)])
    case functionDefinition(name: String, body: ShellNode)
    case breakLoop(levels: Int)
    case continueLoop(levels: Int)
    case returnFromFunction(code: Int32?)
    /// A compound command with trailing redirections (`done > f`, `fi 2>err`).
    /// `redirects` keeps the raw words; the host applies them around the node.
    case redirected(node: ShellNode, redirects: [String])
}

// Tuple payloads prevent synthesised conformance, so equality is written out.
extension ShellNode: Equatable {
    public static func == (lhs: ShellNode, rhs: ShellNode) -> Bool {
        switch (lhs, rhs) {
        case let (.command(a), .command(b)):
            return a == b
        case let (.sequence(a), .sequence(b)):
            return a == b
        case let (.ifStatement(ac, ae), .ifStatement(bc, be)):
            return ac.count == bc.count
                && zip(ac, bc).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
                && ae == be
        case let (.whileLoop(ac, ab, au), .whileLoop(bc, bb, bu)):
            return ac == bc && ab == bb && au == bu
        case let (.caseStatement(asub, acases), .caseStatement(bsub, bcases)):
            return asub == bsub
                && acases.count == bcases.count
                && zip(acases, bcases).allSatisfy { $0.patterns == $1.patterns && $0.body == $1.body }
        case let (.functionDefinition(an, ab), .functionDefinition(bn, bb)):
            return an == bn && ab == bb
        case let (.breakLoop(a), .breakLoop(b)):
            return a == b
        case let (.continueLoop(a), .continueLoop(b)):
            return a == b
        case let (.returnFromFunction(a), .returnFromFunction(b)):
            return a == b
        case let (.redirected(an, ar), .redirected(bn, br)):
            return an == bn && ar == br
        default:
            return false
        }
    }
}

public enum ScriptParser {

    /// Parses a script. Returns nil when `source` contains none of the constructs
    /// we model (so the caller can fall back to its existing single-line path).
    /// Throws on genuinely malformed input (e.g. `if` with no `fi`).
    public static func parse(_ source: String) throws -> ShellNode? {
        let tokens = Lexer(source).tokenize()
        guard containsConstruct(tokens) else { return nil }

        var p = Parser(tokens: tokens)
        let nodes = try p.parseList(terminators: [])
        if !p.atEnd {
            throw ShellLangError.syntax("unexpected token '\(p.peekDesc())' after parser finished")
        }
        return collapse(nodes)
    }

    private static func collapse(_ nodes: [ShellNode]) -> ShellNode? {
        if nodes.count == 1 { return nodes[0] }
        return .sequence(nodes)
    }

    private static func containsConstruct(_ tokens: [Token]) -> Bool {
        for t in tokens {
            if case .word(let w) = t {
                if compoundWords.contains(w) || controlWords.contains(w) { return true }
            }
            if case .lbrace = t { return true }
        }
        // Function definition detected structurally: name ( ) {.
        // Guard the subtraction: a one-token line (`ls`) would otherwise form 0..<(-1).
        guard tokens.count >= 3 else { return false }
        for i in 0..<(tokens.count - 2) {
            if case .word = tokens[i], case .lparen = tokens[i + 1],
               case .rparen = tokens[i + 2] {
                return true
            }
        }
        return false
    }

    // NOTE: `for` is intentionally NOT a modelled construct. The app already
    // handles `for` loops, so a script that is purely a `for` loop should return
    // nil from parse() (letting the app process it whole) rather than being
    // reconstructed here. We only flag constructs this layer owns.
    static let compoundWords: Set<String> = ["if", "while", "until", "case", "function"]
    static let controlWords: Set<String> = ["break", "continue", "return"]
}

// MARK: - Tokens

enum Token: Equatable {
    case word(String)
    case lparen
    case rparen
    case lbrace
    case rbrace
    case semi
    case dsemi
    case newline
}

// MARK: - Lexer

struct Lexer {
    private let chars: [Character]

    init(_ source: String) {
        self.chars = Array(source)
    }

    func tokenize() -> [Token] {
        var tokens: [Token] = []
        var buf = ""
        var i = 0
        let n = chars.count

        func flushWord() {
            if !buf.isEmpty {
                tokens.append(.word(buf))
                buf = ""
            }
        }

        func consumeQuoted(_ quote: Character) {
            buf.append(quote)
            i += 1
            while i < n && chars[i] != quote {
                buf.append(chars[i])
                i += 1
            }
            if i < n { buf.append(chars[i]); i += 1 }
        }

        // Consume a `$(...)`, `$((...))`, `${...}` (possibly nested) into buf.
        func consumeDollarExpansion() {
            buf.append("$")
            let opener = chars[i + 1]
            buf.append(opener)
            let close: Character = opener == "(" ? ")" : "}"
            var depth = 1
            i += 2
            while i < n {
                let d = chars[i]
                if d == "\\" {
                    buf.append(d)
                    if i + 1 < n { buf.append(chars[i + 1]); i += 2 } else { i += 1 }
                    continue
                }
                if d == "'" { consumeQuoted("'"); continue }
                if d == "\"" { consumeQuoted("\""); continue }
                if d == "$", i + 1 < n, chars[i + 1] == "(" || chars[i + 1] == "{" {
                    consumeDollarExpansion()
                    continue
                }
                buf.append(d)
                if d == opener { depth += 1 }
                if d == close {
                    depth -= 1
                    if depth == 0 { i += 1; return }
                }
                i += 1
            }
        }

        while i < n {
            let c = chars[i]

            if c == "'" || c == "\"" {
                consumeQuoted(c)
                continue
            }
            if c == "\\" {
                buf.append(c)
                if i + 1 < n { buf.append(chars[i + 1]); i += 2 } else { i += 1 }
                continue
            }
            if c == "$", i + 1 < n, chars[i + 1] == "(" || chars[i + 1] == "{" {
                consumeDollarExpansion()
                continue
            }
            // A `#` that starts a word begins a comment running to end of line.
            // Mid-word (`abc#def`, `${#V}`) it is an ordinary character.
            if c == "#", buf.isEmpty {
                while i < n && chars[i] != "\n" { i += 1 }
                continue
            }

            switch c {
            case " ", "\t":
                flushWord()
                i += 1
            case "\n", "\r":
                flushWord()
                tokens.append(.newline)
                i += 1
            case ";":
                flushWord()
                if i + 1 < n && chars[i + 1] == ";" {
                    tokens.append(.dsemi)
                    i += 2
                } else {
                    tokens.append(.semi)
                    i += 1
                }
            case "{":
                flushWord()
                tokens.append(.lbrace)
                i += 1
            case "}":
                flushWord()
                tokens.append(.rbrace)
                i += 1
            case "(":
                flushWord()
                tokens.append(.lparen)
                i += 1
            case ")":
                flushWord()
                tokens.append(.rparen)
                i += 1
            default:
                buf.append(c)
                i += 1
            }
        }
        flushWord()
        return tokens
    }
}

// MARK: - Parser

struct Parser {
    let tokens: [Token]
    var idx = 0

    init(tokens: [Token]) {
        self.tokens = tokens
    }

    var atEnd: Bool { idx >= tokens.count }

    func peek() -> Token? {
        idx < tokens.count ? tokens[idx] : nil
    }

    func peekDesc() -> String {
        guard let t = peek() else { return "end-of-input" }
        switch t {
        case .word(let w): return w
        case .newline: return "newline"
        case .semi: return ";"
        case .dsemi: return ";;"
        case .lparen: return "("
        case .rparen: return ")"
        case .lbrace: return "{"
        case .rbrace: return "}"
        }
    }

    mutating func advance() -> Token? {
        guard !atEnd else { return nil }
        defer { idx += 1 }
        return tokens[idx]
    }

    private func isBoundary(_ t: Token) -> Bool {
        switch t {
        case .semi, .dsemi, .newline, .rbrace, .rparen, .lbrace, .lparen:
            return true
        case .word:
            return false
        }
    }

    mutating func skipSeps() {
        while !atEnd {
            if case .newline = tokens[idx] { idx += 1; continue }
            if case .semi = tokens[idx] { idx += 1; continue }
            break
        }
    }

    /// Parse a statement list until a terminator word, a close brace/paren, or `;;`.
    mutating func parseList(terminators: Set<String>) throws -> [ShellNode] {
        var nodes: [ShellNode] = []
        while !atEnd {
            skipSeps()
            if atEnd { break }
            if let t = peek() {
                if case .word(let w) = t, terminators.contains(w) { break }
                if case .rbrace = t { break }
                if case .rparen = t { break }
                if case .dsemi = t { break }
            }
            nodes.append(try parseStatement())
        }
        return nodes
    }

    mutating func expectWord(_ w: String) throws {
        skipSeps()
        if case .word(let x)? = peek(), x == w {
            _ = advance()
            return
        }
        throw ShellLangError.syntax("expected '\(w)' but found '\(peekDesc())'")
    }

    mutating func parseStatement() throws -> ShellNode {
        skipSeps()
        guard let t = peek() else {
            throw ShellLangError.syntax("expected a statement")
        }
        if case .word(let w) = t {
            switch w {
            case "if": return attachTrailingRedirects(try parseIf())
            case "while": return attachTrailingRedirects(try parseLoop(isUntil: false))
            case "until": return attachTrailingRedirects(try parseLoop(isUntil: true))
            case "case": return attachTrailingRedirects(try parseCase())
            case "function": return try parseFunctionDecl()
            case "break": return try parseBreakContinue(isBreak: true)
            case "continue": return try parseBreakContinue(isBreak: false)
            case "return": return try parseReturn()
            default:
                return try parseCommandOrFunctionDefinition()
            }
        }
        if case .lbrace = t {
            _ = advance()
            let body = try parseList(terminators: [])
            guard case .rbrace? = peek() else {
                throw ShellLangError.syntax("missing '}'")
            }
            _ = advance()
            return attachTrailingRedirects(.sequence(body))
        }
        if case .lparen = t {
            _ = advance()
            let body = try parseList(terminators: [])
            guard case .rparen? = peek() else {
                throw ShellLangError.syntax("missing ')'")
            }
            _ = advance()
            return attachTrailingRedirects(.sequence(body))
        }
        throw ShellLangError.syntax("unexpected token '\(peekDesc())'")
    }

    /// Collects redirect words trailing a compound command (`done > f 2>&1`).
    /// The lexer keeps `>`/`<` inside plain words, so a redirect arrives either
    /// as a self-contained word (`>f`, `2>&1`) or as an operator word (`>`,
    /// `2>>`) whose target is the next word.
    private mutating func attachTrailingRedirects(_ node: ShellNode) -> ShellNode {
        var words: [String] = []
        while case .word(let w)? = peek(), Self.isRedirectWord(w) {
            words.append(w)
            _ = advance()
            if Self.redirectTargetIsNextWord(w), case .word(let target)? = peek() {
                words.append(target)
                _ = advance()
            }
        }
        return words.isEmpty ? node : .redirected(node: node, redirects: words)
    }

    /// `>`, `>>`, `<`, `2>`, `&>`, `>file`, `2>&1`, … — after optional `&` and
    /// digits, the word must reach a `<` or `>`.
    static func isRedirectWord(_ w: String) -> Bool {
        var s = Substring(w)
        if s.hasPrefix("&") { s = s.dropFirst() }
        while let f = s.first, f.isNumber { s = s.dropFirst() }
        return s.first == ">" || s.first == "<"
    }

    /// True for a bare operator (`>`, `2>>`) whose filename is the next word;
    /// false when the word carries its own target (`>f`, `2>&1`).
    static func redirectTargetIsNextWord(_ w: String) -> Bool {
        var s = Substring(w)
        if s.hasPrefix("&") { s = s.dropFirst() }
        while let f = s.first, f.isNumber { s = s.dropFirst() }
        while let f = s.first, f == ">" || f == "<" { s = s.dropFirst() }
        return s.isEmpty
    }

    /// Reads a single command line (one already-expanded command, which may
    /// contain pipes/redirects/&&/||). Stops at a structural boundary or, when
    /// `stopWords` is non-nil, at one of those words too.
    private mutating func readCommand(stopWords: Set<String>? = nil) throws -> String {
        var parts: [String] = []
        while !atEnd {
            guard let t = peek() else { break }
            if isBoundary(t) { break }
            if case .word(let w) = t {
                if let stop = stopWords, stop.contains(w) { break }
                parts.append(w)
                _ = advance()
            } else {
                break
            }
        }
        if parts.isEmpty {
            throw ShellLangError.syntax("expected a command")
        }
        return parts.joined(separator: " ")
    }

    private mutating func parseCommandOrFunctionDefinition() throws -> ShellNode {
        // Function definition: name ( ) { ... }  (maybe with space).
        if case .word(let name)? = peek(), idx + 2 < tokens.count {
            if case .lparen = tokens[idx + 1], case .rparen = tokens[idx + 2] {
                _ = advance() // name
                _ = advance() // (
                _ = advance() // )
                return try parseFunctionBody(name: name)
            }
        }
        let cmd = try readCommand()
        return .command(cmd)
    }

    private mutating func parseFunctionBody(name: String) throws -> ShellNode {
        skipSeps()
        guard case .lbrace? = peek() else {
            throw ShellLangError.syntax("expected '{' after function name '\(name)' (check name is an identifier)")
        }
        _ = advance()
        let body = try parseList(terminators: [])
        guard case .rbrace? = peek() else {
            throw ShellLangError.syntax("missing '}' in function \(name)")
        }
        _ = advance()
        return .functionDefinition(name: name, body: .sequence(body))
    }

    private mutating func parseIf() throws -> ShellNode {
        _ = advance() // 'if'
        var conditions: [(ShellNode, ShellNode)] = []
        var elseBranch: ShellNode?

        let cond = try readCommand(stopWords: ["then"])
        try expectWord("then")
        let body = try parseList(terminators: ["elif", "else", "fi"])
        conditions.append((.command(cond), collapse(body)))

        // `break` inside a switch exits the switch, so the loop is driven by this flag.
        var closed = false
        while !closed {
            guard !atEnd, case .word(let kw)? = peek() else {
                throw ShellLangError.syntax("expected 'elif', 'else', or 'fi' in if")
            }
            switch kw {
            case "elif":
                _ = advance()
                let c = try readCommand(stopWords: ["then"])
                try expectWord("then")
                let b = try parseList(terminators: ["elif", "else", "fi"])
                conditions.append((.command(c), collapse(b)))
            case "else":
                _ = advance()
                let b = try parseList(terminators: ["fi"])
                elseBranch = collapse(b)
                try expectWord("fi")
                closed = true
            case "fi":
                _ = advance()
                closed = true
            default:
                throw ShellLangError.syntax("expected 'elif', 'else', or 'fi' in if")
            }
        }
        return .ifStatement(conditions: conditions, elseBranch: elseBranch)
    }

    private mutating func parseLoop(isUntil: Bool) throws -> ShellNode {
        _ = advance() // 'while'/'until'
        let cond = try readCommand(stopWords: ["do"])
        try expectWord("do")
        let body = try parseList(terminators: ["done"])
        try expectWord("done")
        return .whileLoop(condition: .command(cond), body: .sequence(body), isUntil: isUntil)
    }

    private mutating func parseCase() throws -> ShellNode {
        _ = advance() // 'case'
        var subjectParts: [String] = []
        while !atEnd {
            if case .word(let w) = peek()!, w == "in" { break }
            if case .newline = peek()! { _ = advance(); continue }
            if case .word(let w) = peek()! { subjectParts.append(w); _ = advance(); continue }
            break
        }
        try expectWord("in")
        let subject = subjectParts.joined(separator: " ")
        var cases: [(patterns: [String], body: ShellNode)] = []

        while !atEnd {
            skipSeps()
            if atEnd { break }
            if case .word("esac")? = peek() { break }

            // Gather one or more patterns separated by '|' until a ')'.
            var patterns: [String] = []
            var seenParen = false
            var patternParts: [String] = []
            while !atEnd {
                let t = peek()!
                if case .word(let w) = t {
                    _ = advance()
                    // A pattern may carry the trailing ')' attached (e.g. "a*)")
                    // when the next character was reserved; but the lexer emits
                    // ')' as its own token, so we just accumulate here.
                    if w == "|" {
                        if !patternParts.isEmpty { patterns.append(patternParts.joined(separator: "")) }
                        patternParts = []
                        continue
                    }
                    patternParts.append(w)
                    continue
                }
                if case .rparen = t {
                    _ = advance()
                    seenParen = true
                    if !patternParts.isEmpty {
                        patterns.append(patternParts.joined(separator: ""))
                    }
                    break
                }
                if case .newline = t { _ = advance(); continue }
                break
            }
            guard seenParen else {
                throw ShellLangError.syntax("expected ')' in case pattern")
            }

            let body = try parseList(terminators: ["esac"])
            cases.append((patterns, collapse(body)))

            if case .dsemi? = peek() {
                _ = advance()
            }
        }

        try expectWord("esac")
        return .caseStatement(subject: subject, cases: cases)
    }

    private mutating func parseFunctionDecl() throws -> ShellNode {
        _ = advance() // 'function'
        skipSeps()
        guard case .word(let name)? = peek() else {
            throw ShellLangError.syntax("expected function name")
        }
        _ = advance()
        skipSeps()
        if case .lparen = peek()! {
            _ = advance()
            if case .rparen = peek()! { _ = advance() }
        }
        return try parseFunctionBody(name: name)
    }

    private mutating func parseBreakContinue(isBreak: Bool) throws -> ShellNode {
        _ = advance()
        skipSeps()
        var levels = 1
        if case .word(let s)? = peek() {
            let maybeNumber = s.split(separator: " ").first.map(String.init) ?? ""
            if let n = Int(maybeNumber), n > 0 {
                levels = n
                _ = advance()
            }
        }
        return isBreak ? .breakLoop(levels: levels) : .continueLoop(levels: levels)
    }

    private mutating func parseReturn() throws -> ShellNode {
        _ = advance()
        skipSeps()
        var code: Int32?
        if case .word(let s)? = peek() {
            let maybeNumber = s.split(separator: " ").first.map(String.init) ?? ""
            if let n = Int32(maybeNumber) {
                code = n
                _ = advance()
            }
        }
        return .returnFromFunction(code: code)
    }

    private func collapse(_ nodes: [ShellNode]) -> ShellNode {
        if nodes.count == 1 { return nodes[0] }
        return .sequence(nodes)
    }
}
