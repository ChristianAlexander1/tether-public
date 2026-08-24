import Foundation

// MARK: - Piece sinks

/// Receives expansion output piece by piece. Whether splitting, globbing and
/// `$@` field splicing happen is a property of the concrete sink.
protocol PieceSink {
    /// Text that may not be field-split and may not glob (quoted or from a
    /// quoted expansion).
    mutating func quoted(_ text: String)
    /// Literal, unquoted source text: eligible for field splitting; wildcard
    /// characters stay active (`canGlob`).
    mutating func unquoted(_ text: String, canGlob: Bool)
    /// `"$@"`: each positional parameter becomes its own field.
    mutating func quotedDollarAt(_ params: [String])
    /// Unquoted `$@`.
    mutating func unquotedDollarAt(_ params: [String])
}

extension PieceSink {
    mutating func quotedDollarAt(_ params: [String]) {
        quoted(params.joined(separator: " "))
    }
    mutating func unquotedDollarAt(_ params: [String]) {
        unquoted(params.joined(separator: " "), canGlob: false)
    }
}

/// Builds the field list for command arguments: IFS splitting for unquoted
/// text, no splitting for quoted text, per-field glob flags.
struct FieldsBuilder: PieceSink {
    let ifs: Set<Character>

    struct Field {
        var text = ""
        var keep = false      // survives even when empty (quoted content seen)
        var glob = false      // contains an active wildcard character
    }

    private(set) var fields: [Field] = [Field()]

    mutating func quoted(_ text: String) {
        fields[fields.count - 1].text += text
        fields[fields.count - 1].keep = true
    }

    mutating func unquoted(_ text: String, canGlob: Bool) {
        let arr = Array(text)
        var i = 0
        while i < arr.count {
            var j = i
            while j < arr.count && !ifs.contains(arr[j]) { j += 1 }
            if j > i {
                let portion = String(arr[i..<j])
                fields[fields.count - 1].text += portion
                fields[fields.count - 1].keep = true
                if canGlob, portion.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" }) {
                    fields[fields.count - 1].glob = true
                }
            }
            var k = j
            while k < arr.count && ifs.contains(arr[k]) { k += 1 }
            if k > j {
                fields.append(Field())
            }
            i = k
        }
    }

    mutating func quotedDollarAt(_ params: [String]) {
        guard let first = params.first else { return }  // "$@" with no params → nothing
        quoted(first)
        for p in params.dropFirst() {
            fields.append(Field(text: p, keep: true))
        }
    }

    mutating func unquotedDollarAt(_ params: [String]) {
        for (index, p) in params.enumerated() {
            if index > 0 { fields.append(Field()) }
            unquoted(p, canGlob: false)
        }
    }

    func result() -> [Field] {
        fields.filter { $0.keep || !$0.text.isEmpty }
    }
}

/// Concatenates everything into one string (assignment RHS, redirect target,
/// `case` subject, here-string, ...).
struct ScalarBuilder: PieceSink {
    private(set) var text = ""
    mutating func quoted(_ t: String) { text += t }
    mutating func unquoted(_ t: String, canGlob: Bool) { text += t }
}

/// Builds a glob pattern (for `case` items and `${var#pat}` trimming).
/// Unquoted expansion output keeps wildcard characters active; quoted text
/// is literal.
struct PatternBuilder: PieceSink {
    private(set) var tokens: [TetherPatToken] = []
    mutating func quoted(_ text: String) {
        tokens.append(contentsOf: TetherGlob.literals(text))
    }
    mutating func unquoted(_ text: String, canGlob: Bool) {
        tokens.append(contentsOf: TetherGlob.tokens(fromUnquoted: text))
    }
    mutating func quotedDollarAt(_ params: [String]) {
        unquoted(params.joined(separator: " "), canGlob: true)
    }
    mutating func unquotedDollarAt(_ params: [String]) {
        unquoted(params.joined(separator: " "), canGlob: true)
    }
}

// MARK: - Expansion engine

extension TetherShell {

    /// Full word expansion for command words/param lists: brace-free POSIX
    /// pipeline of param/cmdsub/arith → field split → pathname glob.
    @discardableResult
    func expandFields(_ word: TetherWord, ctx: ExecContext, glob: Bool = true) throws -> [String] {
        var raw = Array(word.raw)
        var builder = FieldsBuilder(ifs: Set(ifs))
        var start = 0
        // Tilde expansion at word start (`~` and `~/...` only).
        if !raw.isEmpty, raw[0] == "~", raw.count == 1 || raw[1] == "/",
           let home = lookup("HOME") {
            builder.quoted(home)
            start = 1
            raw = Array(raw[start...])
        }
        try walk(raw, 0, raw.count, inDQ: false, sink: &builder, ctx: ctx)
        var out: [String] = []
        for field in builder.result() {
            if glob, field.glob {
                let matches = pathnameMatches(field.text)
                out.append(contentsOf: matches.isEmpty ? [field.text] : matches)
            } else {
                out.append(field.text)
            }
        }
        return out
    }

    /// Expansion without field splitting or globbing (assignment contexts).
    func expandScalar(_ word: TetherWord, ctx: ExecContext) throws -> String {
        var builder = ScalarBuilder()
        try walk(Array(word.raw), 0, word.raw.count, inDQ: false, sink: &builder, ctx: ctx)
        return builder.text
    }

    /// Builds pattern tokens for `case` and parameter trimming.
    func expandPattern(_ word: TetherWord, ctx: ExecContext) throws -> [TetherPatToken] {
        var builder = PatternBuilder()
        try walk(Array(word.raw), 0, word.raw.count, inDQ: false, sink: &builder, ctx: ctx)
        return builder.tokens
    }

    /// Here-doc body expansion (unquoted delimiter): params, arithmetic and
    /// command substitution only — no splitting, no globbing, backslash only
    /// protects `$`, `` ` ``, `\` and newline.
    func expandHereDocText(_ body: String, ctx: ExecContext) throws -> String {
        let chars = Array(body)
        var sink = ScalarBuilder()
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count,
               chars[i + 1] == "$" || chars[i + 1] == "`" || chars[i + 1] == "\\"
               || chars[i + 1] == "\n" {
                i += chars[i + 1] == "\n" ? 2 : 0
                if chars[i + 1] != "\n" {
                    sink.quoted(String(chars[i + 1]))
                    i += 2
                }
            } else if c == "`" {
                let end = try ScanUtil.skipBackquoted(chars, from: i)
                let subBody = String(chars[(i + 1)..<(end - 1)])
                sink.quoted(try commandSubstitute(subBody, ctx: ctx))
                i = end
            } else if c == "$" {
                try handleDollar(chars, &i, inDQ: true, sink: &sink, ctx: ctx)
            } else {
                var j = i
                while j < chars.count && chars[j] != "\\" && chars[j] != "`" && chars[j] != "$" {
                    j += 1
                }
                sink.quoted(String(chars[i..<j]))
                i = j
            }
        }
        return sink.text
    }

    // MARK: - The walker

    /// Scans raw text, performing escapes, quotes and `$`-expansions.
    func walk<S: PieceSink>(_ chars: [Character], _ start: Int, _ end: Int,
                            inDQ: Bool, sink: inout S, ctx: ExecContext) throws {
        var i = start
        while i < end {
            let c = chars[i]
            if !inDQ {
                switch c {
                case "\\":
                    if i + 1 >= end {
                        sink.quoted("\\")
                        i += 1
                    } else if chars[i + 1] == "\n" {
                        i += 2
                    } else {
                        sink.quoted(String(chars[i + 1]))
                        i += 2
                    }
                case "'":
                    var j = i + 1
                    while j < end && chars[j] != "'" { j += 1 }
                    sink.quoted(String(chars[(i + 1)..<min(j, end)]))
                    i = min(j + 1, end)
                case "\"":
                    let close = try ScanUtil.skipDoubleQuoted(chars, from: i)
                    if close - 1 == i + 1 {
                        sink.quoted("")   // "" — quoted emptiness keeps the field
                    }
                    try walk(chars, i + 1, min(close - 1, end), inDQ: true, sink: &sink, ctx: ctx)
                    i = min(close, end)
                case "`":
                    let close = try ScanUtil.skipBackquoted(chars, from: i)
                    let body = String(chars[(i + 1)..<(close - 1)])
                    let result = try commandSubstitute(unescapeBackquoted(body), ctx: ctx)
                    sink.unquoted(result, canGlob: false)
                    i = close
                case "$":
                    try handleDollar(chars, &i, inDQ: false, sink: &sink, ctx: ctx)
                default:
                    var j = i
                    while j < end && !["\\", "'", "\"", "`", "$"].contains(chars[j]) { j += 1 }
                    sink.unquoted(String(chars[i..<j]), canGlob: true)
                    i = j
                }
            } else {
                switch c {
                case "\\":
                    if i + 1 < end, ["$", "`", "\"", "\\"].contains(chars[i + 1]) {
                        sink.quoted(String(chars[i + 1]))
                        i += 2
                    } else if i + 1 < end, chars[i + 1] == "\n" {
                        i += 2
                    } else {
                        sink.quoted("\\")
                        i += 1
                    }
                case "`":
                    let close = try ScanUtil.skipBackquoted(chars, from: i)
                    let body = String(chars[(i + 1)..<(close - 1)])
                    let result = try commandSubstitute(unescapeBackquoted(body), ctx: ctx)
                    sink.quoted(result)
                    i = close
                case "$":
                    try handleDollar(chars, &i, inDQ: true, sink: &sink, ctx: ctx)
                default:
                    var j = i
                    while j < end && !["\\", "`", "$"].contains(chars[j]) { j += 1 }
                    sink.quoted(String(chars[i..<j]))
                    i = j
                }
            }
        }
    }

    /// In legacy backquotes, `\` before `$`, `` ` `` and `\` is an escape.
    func unescapeBackquoted(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count,
               ["$", "`", "\\"].contains(chars[i + 1]) {
                out.append(chars[i + 1])
                i += 2
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    // MARK: - $ handling

    func handleDollar<S: PieceSink>(_ chars: [Character], _ i: inout Int,
                                    inDQ: Bool, sink: inout S, ctx: ExecContext) throws {
        let end = chars.count
        func emit(_ text: String) {
            if inDQ { sink.quoted(text) } else { sink.unquoted(text, canGlob: false) }
        }
        guard i + 1 < end else {
            emit("$")
            i += 1
            return
        }
        let next = chars[i + 1]

        if ScanUtil.isNameStart(next) {
            var j = i + 1
            while j < end && ScanUtil.isNameChar(chars[j]) { j += 1 }
            let name = String(chars[(i + 1)..<j])
            emit(lookup(name) ?? "")
            i = j
            return
        }
        if ScanUtil.isDigit(next) {
            if next == "0" {
                emit(scriptName)
            } else {
                emit(positionalAt(Int(String(next))!) ?? "")
            }
            i += 2
            return
        }

        switch next {
        case "@":
            if inDQ {
                sink.quotedDollarAt(positional)
            } else {
                sink.unquotedDollarAt(positional)
            }
            i += 2
        case "*":
            emit(positional.joined(separator: ifsFirst))
            i += 2
        case "#":
            emit(String(positional.count))
            i += 2
        case "?":
            emit(String(lastStatus))
            i += 2
        case "$":
            emit(String(pid))
            i += 2
        case "0":
            emit(scriptName)
            i += 2
        case "-", "!":
            emit("")
            i += 2
        case "{":
            let close = try ScanUtil.skipBraceParam(chars, from: i + 1)
            let content = String(chars[(i + 2)..<(close - 1)])
            emit(try evalBraceParam(content, ctx: ctx))
            i = close
        case "(":
            if i + 2 < end, chars[i + 2] == "(" {
                // Possible arithmetic: `((expr))`.
                let innerClose = try ScanUtil.skipCommandSub(chars, from: i + 2)
                if innerClose < end, chars[innerClose] == ")" {
                    let expr = String(chars[(i + 3)..<(innerClose - 1)])
                    let value = try runArithmetic(expr, ctx: ctx)
                    emit(String(value))
                    i = innerClose + 1
                    return
                }
            }
            let close = try ScanUtil.skipCommandSub(chars, from: i + 1)
            let body = String(chars[(i + 2)..<(close - 1)])
            emit(try commandSubstitute(body, ctx: ctx))
            i = close
        default:
            emit("$")
            i += 1
        }
    }

    // MARK: - $( ) command substitution

    func commandSubstitute(_ body: String, ctx: ExecContext) throws -> String {
        let sub = makeSubshell()
        let program: TetherProgram
        do {
            program = try TetherShellParser.parse(body)
        } catch let error as TetherShellParseError {
            ctx.stderr("tethersh: \(error)\n")
            self.cmdSubHappened = true
            self.lastStatus = 2
            return ""
        }
        var captured = ""
        let subCtx = ExecContext(
            stdin: StdinBuffer(ctx.stdin.remaining()),
            stdout: { captured += $0 },
            stderr: ctx.stderr
        )
        let status = sub.execute(program, ctx: subCtx)
        self.lastStatus = status
        self.cmdSubHappened = true
        while captured.hasSuffix("\n") { captured.removeLast() }
        return captured
    }

    // MARK: - Arithmetic glue

    /// POSIX: the text of an arithmetic expansion/command is first expanded
    /// like it were double-quoted (params, command substitution), and the
    /// result is then evaluated as arithmetic. Plain names are resolved by
    /// the arithmetic evaluator itself against shell variables.
    func runArithmetic(_ expr: String, ctx: ExecContext) throws -> Int {
        var sink = ScalarBuilder()
        let chars = Array(expr)
        try walk(chars, 0, chars.count, inDQ: true, sink: &sink, ctx: ctx)
        do {
            return try Arithmetic.evaluate(sink.text, get: { name in
                Int(self.lookup(name) ?? "") ?? 0
            }, set: { name, value in
                self.setVar(name, String(value))
            })
        } catch let error as ArithError {
            throw ShellFlow.abort(1, message: "tethersh: arithmetic: \(error)\n")
        }
    }

    // MARK: - ${...} parameter expansion

    func evalBraceParam(_ content: String, ctx: ExecContext) throws -> String {
        var body = content

        // ${#var} length form.
        if body.hasPrefix("#"), body.count > 1 {
            let rest = String(body.dropFirst())
            if ScanUtil.isValidName(rest) {
                return String((lookup(rest) ?? "").count)
            }
            if rest.allSatisfy(ScanUtil.isDigit), let idx = Int(rest) {
                return String((positionalAt(idx) ?? "").count)
            }
        }
        if body == "#" || body == "#@" || body == "#*" {
            return String(positional.count)
        }

        // Parameter name (or special parameter).
        var name = ""
        if let first = body.first, ScanUtil.isNameStart(first) {
            var j = body.startIndex
            while j < body.endIndex, ScanUtil.isNameChar(body[j]) { j = body.index(after: j) }
            name = String(body[body.startIndex..<j])
            body = String(body[j...])
        } else if let first = body.first,
                  "@*#?$!-0123456789".contains(first) {
            name = String(first)
            body = String(body.dropFirst())
        }
        guard !name.isEmpty else {
            throw ShellFlow.abort(2, message: "tethersh: bad substitution: ${\(content)}\n")
        }

        // Unsupported array subscript:  ${name[...]} behaves like ${name}.
        if body.hasPrefix("[") {
            if let close = body.firstIndex(of: "]") {
                throw ShellFlow.abort(2, message:
                    "tethersh: arrays are not supported: ${\(content[..<content.index(after: close)])}...\n")
            }
        }

        guard !body.isEmpty else {
            return parameterValue(name) ?? ""
        }

        // Operator forms. Two-character operators first.
        let word: String
        let op: String
        if body.hasPrefix(":-") || body.hasPrefix(":=") || body.hasPrefix(":?")
           || body.hasPrefix(":+") {
            op = String(body.prefix(2))
            word = String(body.dropFirst(2))
        } else if body.hasPrefix("##") || body.hasPrefix("%%") {
            op = String(body.prefix(2))
            word = String(body.dropFirst(2))
        } else if let first = body.first, "-=?+#%".contains(first) {
            op = String(first)
            word = String(body.dropFirst())
        } else {
            throw ShellFlow.abort(2, message: "tethersh: bad substitution: ${\(content)}\n")
        }

        let usesColon = op.hasPrefix(":")
        let isSet = parameterIsSet(name)
        let value = parameterValue(name) ?? ""
        let missing = usesColon ? (!isSet || value.isEmpty) : !isSet

        switch op {
        case "-", ":-":
            return missing ? try expandScalar(TetherWord(word), ctx: ctx) : value
        case "=", ":=":
            guard missing else { return value }
            let newValue = try expandScalar(TetherWord(word), ctx: ctx)
            guard ScanUtil.isValidName(name) else {
                throw ShellFlow.abort(1, message: "tethersh: \(name): cannot assign\n")
            }
            setVar(name, newValue)
            return newValue
        case "?", ":?":
            guard missing else { return value }
            let message = try expandScalar(TetherWord(word), ctx: ctx)
            throw ShellFlow.abort(1, message: message.isEmpty
                ? "tethersh: \(name): parameter null or not set\n"
                : "tethersh: \(name): \(message)\n")
        case "+", ":+":
            return missing ? "" : try expandScalar(TetherWord(word), ctx: ctx)
        case "#", "##", "%", "%%":
            guard isSet else { return "" }
            let pattern = try expandPattern(TetherWord(word), ctx: ctx)
            switch op {
            case "#":  return trimPrefix(value, pattern: pattern, longest: false)
            case "##": return trimPrefix(value, pattern: pattern, longest: true)
            case "%":  return trimSuffix(value, pattern: pattern, longest: false)
            default:   return trimSuffix(value, pattern: pattern, longest: true)
            }
        default:
            throw ShellFlow.abort(2, message: "tethersh: bad substitution: ${\(content)}\n")
        }
    }

    func parameterValue(_ name: String) -> String? {
        switch name {
        case "@", "*": return positional.joined(separator: ifsFirst)
        case "#": return String(positional.count)
        case "?": return String(lastStatus)
        case "$": return String(pid)
        case "0": return scriptName
        case "-", "!": return ""
        default:
            if name.allSatisfy(ScanUtil.isDigit), let idx = Int(name) {
                return positionalAt(idx)
            }
            return lookup(name)
        }
    }

    func parameterIsSet(_ name: String) -> Bool {
        if name.allSatisfy(ScanUtil.isDigit), let idx = Int(name), idx > 0 {
            return pos1(idx) != nil
        }
        switch name {
        case "@", "*", "#", "?", "$", "0", "-", "!": return true
        default: return lookup(name) != nil
        }
    }

    private func pos1(_ idx: Int) -> String? {
        idx >= 1 && idx <= positional.count ? positional[idx - 1] : nil
    }

    func trimPrefix(_ value: String, pattern: [TetherPatToken], longest: Bool) -> String {
        let chars = Array(value)
        var result: String? = nil
        for end in 0...chars.count {
            if TetherGlob.match(pattern, String(chars[0..<end])) {
                result = String(chars[end...])
                if !longest { break }
            }
        }
        return result ?? value
    }

    func trimSuffix(_ value: String, pattern: [TetherPatToken], longest: Bool) -> String {
        let chars = Array(value)
        var result: String? = nil
        var start = chars.count
        while start >= 0 {
            if TetherGlob.match(pattern, String(chars[start...])) {
                result = String(chars[0..<start])
                if !longest { break }
            }
            start -= 1
        }
        return result ?? value
    }

    // MARK: - Pathname expansion

    /// Matches a glob field against the virtual file system (flat basenames
    /// only — the virtual FS has no subdirectories).
    func pathnameMatches(_ field: String) -> [String] {
        let tokens = TetherGlob.tokens(fromUnquoted: field)
        guard TetherGlob.hasWildcards(tokens) else { return [] }
        var names: [String] = []
        for key in fileSystem.keys {
            let name = key.hasPrefix("/") ? String(key.dropFirst()) : key
            guard !name.isEmpty, !name.contains("/") else { continue }
            if TetherGlob.match(tokens, name) {
                names.append(name)
            }
        }
        return names.sorted()
    }
}
