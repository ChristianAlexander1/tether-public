import Foundation

/// Parses token streams into the AST defined in `AST.swift`. Follows the
/// POSIX shell grammar with mksh extensions (`;&`, `;;&`, `function`,
/// `(( ... ))`, `for (( ... ))`, `<<<`).
public enum TetherShellParser {

    public static func parse(_ source: String) throws -> TetherProgram {
        var lexer = Lexer(source)
        let tokens = try lexer.tokenize()
        var parser = Parser(tokens: tokens)
        let items = try parser.parseList(stopWords: [], stopKinds: [.eof])
        guard parser.at(.eof) else {
            throw TetherShellParseError("unexpected `\(parser.peekDescription)'",
                                  line: parser.peek.line)
        }
        return TetherProgram(items: items)
    }
}

private struct Parser {
    let tokens: [Token]
    var pos = 0

    // MARK: - Cursor utilities

    var peek: Token { tokens[min(pos, tokens.count - 1)] }
    func peekAt(_ n: Int) -> Token { tokens[min(pos + n, tokens.count - 1)] }
    var peekDescription: String {
        switch peek.kind {
        case .eof: return "end of file"
        case .newline: return "newline"
        default: return peek.text.isEmpty ? "token" : peek.text
        }
    }

    mutating func advance() -> Token {
        let t = tokens[pos]
        if pos < tokens.count - 1 { pos += 1 }
        return t
    }

    func at(_ kind: TokenKind) -> Bool { kindEquals(peek.kind, kind) }

    func atWord(_ text: String) -> Bool {
        if case .word = peek.kind { return peek.text == text }
        return false
    }

    func kindEquals(_ a: TokenKind, _ b: TokenKind) -> Bool {
        switch (a, b) {
        case (.word, .word), (.ioNumber, .ioNumber), (.newline, .newline), (.eof, .eof),
             (.andIf, .andIf), (.orIf, .orIf), (.amp, .amp), (.semi, .semi),
             (.dsemi, .dsemi), (.semiAnd, .semiAnd), (.dsemiAnd, .dsemiAnd),
             (.pipe, .pipe), (.lparen, .lparen), (.rparen, .rparen),
             (.lbrace, .lbrace), (.rbrace, .rbrace), (.less, .less), (.great, .great),
             (.dless, .dless), (.dlessDash, .dlessDash), (.tripleLess, .tripleLess),
             (.dgreat, .dgreat), (.lessAnd, .lessAnd), (.greatAnd, .greatAnd),
             (.clobber, .clobber), (.lessGreat, .lessGreat):
            return true
        default: return false
        }
    }

    private func error(_ message: String, line: Int? = nil) -> TetherShellParseError {
        TetherShellParseError(message, line: line ?? peek.line)
    }

    mutating func skipNewlines() {
        while at(.newline) { _ = advance() }
    }

    /// Adjacent character ranges: `((` / `))` with no gap between the parens.
    func adjacent(_ a: Token, _ b: Token) -> Bool { a.end == b.start }

    // MARK: - Lists

    mutating func parseList(stopWords: Set<String>, stopKinds: Set<TokenKind>) throws -> [TetherListItem] {
        var items: [TetherListItem] = []
        skipNewlines()
        while !atStop(stopWords, stopKinds) {
            let mark = pos
            let andOr = try parseAndOr()
            if pos == mark {
                throw error("unexpected `\(peekDescription)'")
            }
            var async = false
            if at(.amp) {
                _ = advance()
                async = true
            } else {
                while at(.semi) { _ = advance() }
            }
            skipNewlines()
            items.append(TetherListItem(andOr: andOr, async: async))
        }
        return items
    }

    func atStop(_ stopWords: Set<String>, _ stopKinds: Set<TokenKind>) -> Bool {
        for kind in stopKinds where kindEquals(peek.kind, kind) { return true }
        if case .word = peek.kind, stopWords.contains(peek.text) { return true }
        return false
    }

    // MARK: - And/or & pipelines

    mutating func parseAndOr() throws -> TetherAndOr {
        let first = try parsePipeline()
        var rest: [TetherAndOrTail] = []
        while at(.andIf) || at(.orIf) {
            let op: TetherAndOrOp = at(.andIf) ? .and : .or
            _ = advance()
            skipNewlines()
            rest.append(TetherAndOrTail(op: op, pipeline: try parsePipeline()))
        }
        return TetherAndOr(first: first, rest: rest)
    }

    mutating func parsePipeline() throws -> TetherPipeline {
        var pipeline = TetherPipeline()
        if atWord("!") {
            _ = advance()
            pipeline.negated = true
        }
        pipeline.commands.append(try parseCommand())
        while at(.pipe) {
            _ = advance()
            skipNewlines()
            pipeline.commands.append(try parseCommand())
        }
        return pipeline
    }

    // MARK: - Commands

    mutating func parseCommand() throws -> TetherCommand {
        // POSIX function definition: name ( )
        if case .word = peek.kind, ScanUtil.isValidName(peek.text),
           case .lparen = peekAt(1).kind {
            var look = 2
            while case .newline = peekAt(look).kind { look += 1 }
            if case .rparen = peekAt(look).kind {
                return try parseFunctionDef()
            }
        }
        // mksh: `function name { ... }`
        if atWord("function") {
            return try parseKshFunctionDef()
        }

        switch peek.kind {
        case .lbrace:
            _ = advance()
            let body = try parseList(stopWords: [], stopKinds: [.rbrace])
            guard at(.rbrace) else { throw error("expected `}'") }
            _ = advance()
            return .braceGroup(body: body, redirects: try parseRedirects())
        case .lparen:
            if case .lparen = peekAt(1).kind, adjacent(peek, peekAt(1)) {
                return try parseArithmeticCommand()
            }
            _ = advance()
            let body = try parseList(stopWords: [], stopKinds: [.rparen])
            guard at(.rparen) else { throw error("expected `)'") }
            _ = advance()
            return .subshell(body: body, redirects: try parseRedirects())
        case .word:
            switch peek.text {
            case "if": return try parseIf()
            case "while", "until": return try parseLoop()
            case "for": return try parseFor()
            case "case": return try parseCase()
            default: break
            }
            return .simple(try parseSimpleCommand())
        default:
            return .simple(try parseSimpleCommand())
        }
    }

    /// A compound command is required as a function body.
    mutating func parseCompoundCommand() throws -> TetherCommand {
        let cmd = try parseCommand()
        switch cmd {
        case .simple(let s) where s.words.isEmpty && s.assignments.isEmpty && s.redirects.isEmpty:
            throw error("expected compound command as function body")
        case .simple:
            throw error("expected compound command as function body")
        default:
            return cmd
        }
    }

    mutating func parseFunctionDef() throws -> TetherCommand {
        let nameTok = advance()               // name
        _ = advance()                         // (
        skipNewlines()
        guard at(.rparen) else { throw error("expected `)' after function name", line: nameTok.line) }
        _ = advance()
        skipNewlines()
        let body = try parseCompoundCommand()
        return .functionDef(TetherFunctionDef(name: nameTok.text, body: body))
    }

    mutating func parseKshFunctionDef() throws -> TetherCommand {
        _ = advance()                          // `function`
        skipNewlines()
        guard case .word = peek.kind, ScanUtil.isValidName(peek.text) else {
            throw error("expected function name")
        }
        let name = advance().text
        if case .lparen = peek.kind {          // optional ()
            _ = advance()
            skipNewlines()
            guard at(.rparen) else { throw error("expected `)' after function name") }
            _ = advance()
        }
        skipNewlines()
        let body = try parseCompoundCommand()
        return .functionDef(TetherFunctionDef(name: name, body: body))
    }

    // MARK: - Compound commands

    mutating func parseIf() throws -> TetherCommand {
        _ = advance() // if
        let condition = try parseList(stopWords: ["then"], stopKinds: [])
        guard atWord("then") else { throw error("expected `then'") }
        _ = advance()
        let thenBody = try parseList(stopWords: ["elif", "else", "fi"], stopKinds: [])
        var clause = TetherIfClause(condition: condition, thenBody: thenBody)
        while atWord("elif") {
            _ = advance()
            let cond = try parseList(stopWords: ["then"], stopKinds: [])
            guard atWord("then") else { throw error("expected `then'") }
            _ = advance()
            let body = try parseList(stopWords: ["elif", "else", "fi"], stopKinds: [])
            clause.elifs.append(TetherElifClause(condition: cond, body: body))
        }
        if atWord("else") {
            _ = advance()
            clause.elseBody = try parseList(stopWords: ["fi"], stopKinds: [])
        }
        guard atWord("fi") else { throw error("expected `fi'") }
        _ = advance()
        return .ifClause(clause, redirects: try parseRedirects())
    }

    mutating func parseLoop() throws -> TetherCommand {
        let until = peek.text == "until"
        _ = advance()
        let condition = try parseList(stopWords: ["do"], stopKinds: [])
        guard atWord("do") else { throw error("expected `do'") }
        _ = advance()
        let body = try parseList(stopWords: ["done"], stopKinds: [])
        guard atWord("done") else { throw error("expected `done'") }
        _ = advance()
        return .loop(condition: condition, body: body, until: until,
                     redirects: try parseRedirects())
    }

    mutating func parseFor() throws -> TetherCommand {
        _ = advance() // for
        skipNewlines()

        var clause = TetherForClause(varName: "")
        if case .lparen = peek.kind, case .lparen = peekAt(1).kind, adjacent(peek, peekAt(1)) {
            // mksh arithmetic for: for ((init; cond; step))
            let exprs = try collectArithmeticParens()
            guard exprs.count == 3 else {
                throw error("arithmetic for needs exactly three expressions")
            }
            clause.arithmetic = TetherArithFor(start: exprs[0], condition: exprs[1], step: exprs[2])
        } else {
            guard case .word = peek.kind, ScanUtil.isValidName(peek.text) else {
                throw error("bad for-loop variable name")
            }
            clause.varName = advance().text
            skipNewlines()
            if atWord("in") {
                _ = advance()
                var words: [TetherWord] = []
                while case .word = peek.kind {
                    words.append(TetherWord(advance().text))
                }
                clause.words = words.isEmpty ? [] : words
            }
        }
        // separators between the header and `do`
        while at(.semi) || at(.newline) { _ = advance() }
        guard atWord("do") else { throw error("expected `do'") }
        _ = advance()
        clause.body = try parseList(stopWords: ["done"], stopKinds: [])
        guard atWord("done") else { throw error("expected `done'") }
        _ = advance()
        return .forClause(clause, redirects: try parseRedirects())
    }

    mutating func parseCase() throws -> TetherCommand {
        _ = advance() // case
        skipNewlines()
        guard case .word = peek.kind else { throw error("expected word after `case'") }
        let subject = TetherWord(advance().text)
        skipNewlines()
        guard atWord("in") else { throw error("expected `in'") }
        _ = advance()
        while at(.semi) || at(.newline) { _ = advance() }

        var items: [TetherCaseItem] = []
        while !atWord("esac") {
            if at(.eof) { throw error("expected `esac'") }
            var patterns: [TetherWord] = []
            if at(.lparen) { _ = advance() }        // optional leading (
            while true {
                guard case .word = peek.kind else {
                    throw error("expected case pattern")
                }
                patterns.append(TetherWord(advance().text))
                if at(.pipe) {
                    _ = advance()
                    continue
                }
                break
            }
            guard at(.rparen) else { throw error("expected `)' in case item") }
            _ = advance()
            let body = try parseList(stopWords: ["esac"],
                                     stopKinds: [.dsemi, .semiAnd, .dsemiAnd])
            let terminator: TetherCaseTerminator
            if at(.dsemi) { terminator = .stop; _ = advance() }
            else if at(.semiAnd) { terminator = .fallThru; _ = advance() }
            else if at(.dsemiAnd) { terminator = .retest; _ = advance() }
            else { terminator = .stop }
            while at(.semi) || at(.newline) { _ = advance() }
            items.append(TetherCaseItem(patterns: patterns, body: body, terminator: terminator))
        }
        _ = advance() // esac
        return .caseClause(TetherCaseClause(subject: subject, items: items),
                           redirects: try parseRedirects())
    }

    // MARK: - Arithmetic commands (( ... ))

    mutating func parseArithmeticCommand() throws -> TetherCommand {
        let exprs = try collectArithmeticParens()
        guard exprs.count == 1 else {
            throw error("arithmetic command takes one expression")
        }
        let redirects = try parseRedirects()
        return .arithmetic(expression: exprs[0], redirects: redirects)
    }

    /// Collects the token text between an adjacent `((` and its matching
    /// `))`, splitting at top-level `;`. Operators already tokenized by the
    /// lexer (`<`, `>`, `&&`, `||`, ...) are mapped back to their text.
    mutating func collectArithmeticParens() throws -> [String] {
        _ = advance() // (
        _ = advance() // (
        var exprs: [String] = [""]
        var depth = 0
        while true {
            let t = peek
            switch t.kind {
            case .eof, .newline:
                throw error("unterminated arithmetic expression")
            case .lparen:
                depth += 1
                _ = advance()
                exprs[exprs.count - 1] += "("
            case .rparen:
                if depth == 0 {
                    if case .rparen = peekAt(1).kind, adjacent(t, peekAt(1)) {
                        _ = advance()
                        _ = advance()
                        return exprs
                    }
                    throw error("expected `))' to close arithmetic expression")
                }
                depth -= 1
                _ = advance()
                exprs[exprs.count - 1] += ")"
            case .semi where depth == 0:
                _ = advance()
                exprs.append("")
            case .dsemi, .semiAnd, .dsemiAnd:
                throw error("unexpected token in arithmetic expression")
            default:
                exprs[exprs.count - 1] += arithTokenText(t)
                _ = advance()
            }
        }
    }

    func arithTokenText(_ t: Token) -> String {
        switch t.kind {
        case .word, .ioNumber: return t.text
        case .andIf: return "&&"
        case .orIf: return "||"
        case .amp: return "&"
        case .pipe: return "|"
        case .less: return "<"
        case .great: return ">"
        case .dless: return "<<"
        case .dgreat: return ">>"
        case .lparen: return "("
        case .rparen: return ")"
        case .lbrace: return "{"
        case .rbrace: return "}"
        default: return t.text
        }
    }

    // MARK: - Simple commands

    mutating func parseSimpleCommand() throws -> TetherSimpleCommand {
        var command = TetherSimpleCommand()
        while true {
            if case .ioNumber = peek.kind, isRedirect(peekAt(1).kind) {
                command.redirects.append(try parseRedirect())
                continue
            }
            if isRedirect(peek.kind) {
                command.redirects.append(try parseRedirect())
                continue
            }
            if case .word = peek.kind {
                if command.words.isEmpty, let assignment = parseAssignment(peek.text) {
                    _ = advance()
                    command.assignments.append(assignment)
                    continue
                }
                command.words.append(TetherWord(advance().text))
                continue
            }
            break
        }
        return command
    }

    func parseAssignment(_ raw: String) -> TetherAssignment? {
        guard let eq = raw.firstIndex(of: "=") else { return nil }
        let name = String(raw[raw.startIndex..<eq])
        guard ScanUtil.isValidName(name) else { return nil }
        return TetherAssignment(name: name, value: TetherWord(String(raw[raw.index(after: eq)...])))
    }

    // MARK: - Redirects

    func isRedirect(_ kind: TokenKind) -> Bool {
        switch kind {
        case .less, .great, .dless, .dlessDash, .tripleLess, .dgreat,
             .lessAnd, .greatAnd, .clobber, .lessGreat:
            return true
        default:
            return false
        }
    }

    func redirectOp(_ kind: TokenKind) -> TetherRedirOp {
        switch kind {
        case .less: return .input
        case .great: return .output
        case .dgreat: return .append
        case .clobber: return .clobber
        case .lessGreat: return .readWrite
        case .lessAnd: return .inputDup
        case .greatAnd: return .outputDup
        case .dless: return .heredoc
        case .dlessDash: return .heredocTabs
        case .tripleLess: return .hereString
        default: return .output
        }
    }

    mutating func parseRedirects() throws -> [TetherRedirect] {
        var redirects: [TetherRedirect] = []
        while true {
            if case .ioNumber = peek.kind, isRedirect(peekAt(1).kind) {
                redirects.append(try parseRedirect())
                continue
            }
            if isRedirect(peek.kind) {
                redirects.append(try parseRedirect())
                continue
            }
            return redirects
        }
    }

    mutating func parseRedirect() throws -> TetherRedirect {
        var fd: Int? = nil
        if case .ioNumber = peek.kind {
            fd = Int(advance().text)
        }
        let opToken = advance()
        let op = redirectOp(opToken.kind)
        switch op {
        case .heredoc, .heredocTabs:
            guard case .word = peek.kind, let hd = peek.hereDoc else {
                throw error("missing here-doc delimiter", line: opToken.line)
            }
            _ = advance()
            return TetherRedirect(fd: fd, op: op, target: TetherWord(""), hereDoc: hd)
        default:
            guard case .word = peek.kind else {
                throw error("missing redirection target", line: opToken.line)
            }
            let target = TetherWord(advance().text)
            return TetherRedirect(fd: fd, op: op, target: target)
        }
    }
}
