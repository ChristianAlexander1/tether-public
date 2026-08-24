import Foundation

enum TokenKind {
    case word, ioNumber, newline, eof
    case andIf, orIf                 // &&  ||
    case amp, semi                   // &   ;
    case dsemi, semiAnd, dsemiAnd    // ;;  ;&  ;;&
    case pipe
    case lparen, rparen
    case lbrace, rbrace
    case less, great, dless, dlessDash, tripleLess, dgreat
    case lessAnd, greatAnd, clobber, lessGreat
}

struct Token {
    var kind: TokenKind
    /// Raw text for `.word` tokens (quotes preserved) or digits for `.ioNumber`.
    var text: String = ""
    /// Character offsets into the source; used for token adjacency (`((` / `))`).
    var start: Int = 0
    var end: Int = 0
    var line: Int
    /// Set on the delimiter word of a here-doc redirection.
    var hereDoc: TetherHereDoc?
}

/// Tokenizes shell source. Words are kept raw (quotes intact) so expansion
/// can happen at evaluation time; here-doc bodies are collected inline once
/// the terminating newline is reached, exactly like a real shell.
struct Lexer {
    let chars: [Character]
    let source: String
    var pos = 0
    var line = 1
    var tokens: [Token] = []

    /// Pending here-docs to read at the next newline, in order of appearance.
    var pendingHereDocs: [(stripTabs: Bool, delimiter: String, expand: Bool, tokenIndex: Int)] = []
    var expectHereDocDelimiter = false
    var hereDocStripTabs = false

    init(_ source: String) {
        self.source = source
        self.chars = Array(source)
    }

    // MARK: - Entry point

    mutating func tokenize() throws -> [Token] {
        while true {
            skipBlanksAndContinuation()
            if pos >= chars.count {
                if expectHereDocDelimiter {
                    throw error("missing here-doc delimiter")
                }
                // Trailing newline missing at EOF: here-doc bodies still
                // terminate here (or error when the delimiter never comes).
                try readPendingHereDocs()
                emit(.eof, "", pos, pos)
                return tokens
            }
            let c = chars[pos]

            if c == "#" { // comment, only at token start
                while pos < chars.count && chars[pos] != "\n" { pos += 1 }
                continue
            }
            if c == "\n" {
                emit(.newline, "", pos, pos + 1)
                pos += 1
                line += 1
                if expectHereDocDelimiter {
                    throw error("missing here-doc delimiter")
                }
                try readPendingHereDocs()
                continue
            }
            if isOperatorStart(c) {
                try scanOperator()
                continue
            }
            try scanWord()
        }
    }

    // MARK: - Helpers

    private func error(_ message: String) -> TetherShellParseError {
        TetherShellParseError(message, line: line)
    }

    private mutating func emit(_ kind: TokenKind, _ text: String, _ start: Int, _ end: Int,
                               hereDoc: TetherHereDoc? = nil) {
        tokens.append(Token(kind: kind, text: text, start: start, end: end,
                            line: line, hereDoc: hereDoc))
    }

    private mutating func skipBlanksAndContinuation() {
        while pos < chars.count {
            let c = chars[pos]
            if c == " " || c == "\t" {
                pos += 1
            } else if c == "\\", pos + 1 < chars.count, chars[pos + 1] == "\n" {
                pos += 2
                line += 1
            } else {
                break
            }
        }
    }

    private func isOperatorStart(_ c: Character) -> Bool {
        switch c {
        case "|", "&", ";", "(", ")", "<", ">", "{", "}":
            return true
        default:
            return false
        }
    }

    /// `{` and `}` are only reserved words when they stand alone; the caller
    /// has already established this is a token start, so check the follower.
    private mutating func braceIsOperator(_ c: Character) -> Bool {
        guard c == "{" || c == "}" else { return true }
        if c == "{" {
            // `{` must be followed by blank / metachar / newline / EOF.
            guard pos + 1 < chars.count else { return true }
            let n = chars[pos + 1]
            return n == " " || n == "\t" || n == "\n" || ScanUtil.isMetachar(n) || n == "#"
        }
        return true
    }

    private mutating func scanOperator() throws {
        let start = pos
        func matches(_ s: String) -> Bool {
            let arr = Array(s)
            guard pos + arr.count <= chars.count else { return false }
            return Array(chars[pos..<(pos + arr.count)]) == arr
        }
        func take(_ kind: TokenKind, _ n: Int, _ text: String) {
            emit(kind, text, start, start + n)
            pos += n
        }

        if expectHereDocDelimiter {
            throw error("missing here-doc delimiter word")
        }

        switch chars[pos] {
        case "&":
            if matches("&&") { take(.andIf, 2, "&&") } else { take(.amp, 1, "&") }
        case "|":
            if matches("||") { take(.orIf, 2, "||") } else { take(.pipe, 1, "|") }
        case ";":
            if matches(";;&") { take(.dsemiAnd, 3, ";;&") }
            else if matches(";;") { take(.dsemi, 2, ";;") }
            else if matches(";&") { take(.semiAnd, 2, ";&") }
            else { take(.semi, 1, ";") }
        case "(":
            take(.lparen, 1, "(")
        case ")":
            take(.rparen, 1, ")")
        case "{":
            if braceIsOperator("{") { take(.lbrace, 1, "{") } else { try scanWord() }
        case "}":
            take(.rbrace, 1, "}")
        case "<":
            if matches("<<<") { take(.tripleLess, 3, "<<<"); expectHereDocDelimiter = false }
            else if matches("<<-") { take(.dlessDash, 3, "<<-"); expectHereDocDelimiter = true; hereDocStripTabs = true }
            else if matches("<<") { take(.dless, 2, "<<"); expectHereDocDelimiter = true; hereDocStripTabs = false }
            else if matches("<&") { take(.lessAnd, 2, "<&") }
            else if matches("<>") { take(.lessGreat, 2, "<>") }
            else { take(.less, 1, "<") }
        case ">":
            if matches(">>") { take(.dgreat, 2, ">>") }
            else if matches(">&") { take(.greatAnd, 2, ">&") }
            else if matches(">|") { take(.clobber, 2, ">|") }
            else { take(.great, 1, ">") }
        default:
            break
        }
    }

    /// Scans one word (quotes / substitutions preserved verbatim in the raw
    /// text) or an io-number, and handles here-doc delimiter bookkeeping.
    private mutating func scanWord() throws {
        let start = pos

        // io-number: digits immediately followed by < or >.
        if ScanUtil.isDigit(chars[pos]) {
            var j = pos
            while j < chars.count && ScanUtil.isDigit(chars[j]) { j += 1 }
            if j < chars.count && (chars[j] == "<" || chars[j] == ">") {
                let digits = String(chars[pos..<j])
                emit(.ioNumber, digits, start, j)
                pos = j
                return
            }
        }

        do {
            wordLoop: while pos < chars.count {
                let c = chars[pos]
                switch c {
                case "\\":
                    pos = min(pos + 2, chars.count)
                case "'":
                    pos = try ScanUtil.skipSingleQuoted(chars, from: pos)
                case "\"":
                    pos = try ScanUtil.skipDoubleQuoted(chars, from: pos)
                case "`":
                    pos = try ScanUtil.skipBackquoted(chars, from: pos)
                case "$" where pos + 1 < chars.count && chars[pos + 1] == "(":
                    pos = try ScanUtil.skipCommandSub(chars, from: pos + 1)
                case "$" where pos + 1 < chars.count && chars[pos + 1] == "{":
                    pos = try ScanUtil.skipBraceParam(chars, from: pos + 1)
                default:
                    // `{`/`}` mid-word are literal; they're handled as
                    // operator tokens only when standing alone at token start.
                    if ScanUtil.isMetachar(c) { break wordLoop }
                    pos += 1
                }
            }
        } catch let e as TetherShellParseError {
            throw TetherShellParseError(e.message, line: line)
        }

        if pos == start { // defensive; should not happen
            throw error("unexpected character '\(chars[pos])'")
        }

        let raw = String(chars[start..<pos])
        if expectHereDocDelimiter {
            let expand = !(raw.contains("\"") || raw.contains("'") || raw.contains("\\"))
            let delimiter = Lexer.stripQuotes(raw)
            let hd = TetherHereDoc(delimiter: delimiter, body: "", stripTabs: hereDocStripTabs,
                             expand: expand)
            pendingHereDocs.append((hereDocStripTabs, delimiter, expand, tokens.count))
            expectHereDocDelimiter = false
            emit(.word, raw, start, pos, hereDoc: hd)
        } else {
            emit(.word, raw, start, pos)
        }
    }

    /// Removes quotes and quote-backslashes from a here-doc delimiter word.
    static func stripQuotes(_ raw: String) -> String {
        let chars = Array(raw)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                out.append(chars[i + 1])
                i += 2
            } else if c == "'" {
                i += 1
                while i < chars.count && chars[i] != "'" { out.append(chars[i]); i += 1 }
                i += 1
            } else if c == "\"" {
                i += 1
                while i < chars.count && chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                    out.append(chars[i])
                    i += 1
                }
                i += 1
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    // MARK: - Here-doc bodies

    private mutating func readPendingHereDocs() throws {
        guard !pendingHereDocs.isEmpty else { return }
        for qi in pendingHereDocs.indices {
            let pending = pendingHereDocs[qi]
            var body = ""
            var found = false
            while pos < chars.count {
                var j = pos
                while j < chars.count && chars[j] != "\n" { j += 1 }
                let rawLine = Array(chars[pos..<j])
                let contentStart = pending.stripTabs
                    ? rawLine.drop(while: { $0 == "\t" }).startIndex
                    : rawLine.startIndex
                let content = String(rawLine[contentStart...])
                if content == pending.delimiter {
                    found = true
                    pos = j < chars.count ? j + 1 : j
                    line += 1
                    break
                }
                body += content + "\n"
                pos = j < chars.count ? j + 1 : j
                line += 1
            }
            if !found {
                throw TetherShellParseError("here-document delimited by end-of-file "
                                      + "(wanted `\(pending.delimiter)')", line: line)
            }
            tokens[pending.tokenIndex].hereDoc?.body = body
        }
        pendingHereDocs.removeAll()
    }
}
