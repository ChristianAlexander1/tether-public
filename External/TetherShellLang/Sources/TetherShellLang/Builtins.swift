import Foundation

/// Builtin commands. Returns nil for names that aren't builtins, letting the
/// dispatcher fall through to the host.
extension TetherShell {

    /// Executes `name` as a builtin, or returns nil if it isn't one.
    func runBuiltin(name: String, args: [String], ctx: ExecContext) throws -> Int32? {
        switch name {
        case "true", ":":
            return 0
        case "false":
            return 1
        case "echo":
            return echoBuiltin(args, ctx: ctx)
        case "printf":
            return printfBuiltin(args, ctx: ctx)
        case "cat":
            return catBuiltin(args, ctx: ctx)
        case "read":
            return readBuiltin(args, ctx: ctx)
        case "test":
            return runTest(args, ctx: ctx)
        case "[":
            guard args.last == "]" else {
                ctx.stderr("tethersh: [: missing ]\n")
                return 2
            }
            return runTest(Array(args.dropLast()), ctx: ctx)
        case "exit":
            let code = args.first.flatMap { Int32($0) } ?? lastStatus
            throw ShellFlow.exitShell(code)
        case "return":
            let code = args.first.flatMap { Int32($0) } ?? lastStatus
            throw ShellFlow.returnFromFunction(code)
        case "break":
            throw ShellFlow.breakLoop(numericArg(args, default: 1))
        case "continue":
            throw ShellFlow.continueLoop(numericArg(args, default: 1))
        case "shift":
            let n = numericArg(args, default: 1)
            let top = positionalStack.last ?? []
            guard n >= 0, n <= top.count else {
                ctx.stderr("tethersh: shift: can't shift \(n) (have \(top.count))\n")
                return 1
            }
            positionalStack[positionalStack.count - 1] = Array(top.dropFirst(n))
            return 0
        case "set":
            return setBuiltin(args, ctx: ctx)
        case "export":
            return exportBuiltin(args, ctx: ctx)
        case "local":
            return localBuiltin(args, ctx: ctx)
        case "unset":
            return unsetBuiltin(args, ctx: ctx)
        case "eval":
            let joined = args.joined(separator: " ")
            do {
                return try runItems(parse(joined).items, ctx: ctx)
            } catch let error as TetherShellParseError {
                ctx.stderr("tethersh: \(error)\n")
                return 2
            }
        case ".", "source":
            return try dotBuiltin(args, ctx: ctx)
        case "command":
            var rest = args
            while let first = rest.first, first.hasPrefix("-"), first.count > 1 {
                rest.removeFirst()   // -v / -V merely report; ignored here
            }
            guard let cmd = rest.first else { return 0 }
            return try dispatchCommand(name: cmd, args: Array(rest.dropFirst()),
                                       ctx: ctx, bypassFunctions: true)
        case "exec":
            guard let cmd = args.first else { return 0 }
            return try dispatchCommand(name: cmd, args: Array(args.dropFirst()),
                                       ctx: ctx, bypassFunctions: false)
        case "pwd":
            ctx.stdout(cwd + "\n")
            return 0
        case "cd":
            let target = args.first ?? lookup("HOME") ?? "/"
            cwd = normalizePath(target)
            return 0
        default:
            return nil
        }
    }

    private func numericArg(_ args: [String], default value: Int) -> Int {
        args.first.flatMap { Int($0) } ?? value
    }

    // MARK: echo

    private func echoBuiltin(_ args: [String], ctx: ExecContext) -> Int32 {
        var newline = true
        var escapes = false
        var rest = args[...]
        flagLoop: while let first = rest.first, first.hasPrefix("-"), first.count > 1 {
            for ch in first.dropFirst() {
                switch ch {
                case "n": newline = false
                case "e": escapes = true
                case "E": escapes = false
                default: break flagLoop
                }
            }
            rest = rest.dropFirst()
        }
        var text = rest.joined(separator: " ")
        var stopped = false
        if escapes {
            (text, stopped) = interpretEscapes(text)
        }
        if newline && !stopped { text += "\n" }
        ctx.stdout(text)
        return 0
    }

    /// echo -e / printf format escapes. Returns (result, hitSlashC).
    func interpretEscapes(_ text: String) -> (String, Bool) {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            guard chars[i] == "\\", i + 1 < chars.count else {
                out.append(chars[i]); i += 1; continue
            }
            let e = chars[i + 1]
            switch e {
            case "n": out.append("\n"); i += 2
            case "t": out.append("\t"); i += 2
            case "r": out.append("\r"); i += 2
            case "b": out.append("\u{8}"); i += 2
            case "f": out.append("\u{c}"); i += 2
            case "v": out.append("\u{b}"); i += 2
            case "a": out.append("\u{7}"); i += 2
            case "\\": out.append("\\"); i += 2
            case "c": return (out, true)
            case "0":
                var j = i + 2
                var digits = ""
                while j < chars.count, digits.count < 3,
                      chars[j] >= "0", chars[j] <= "7" {
                    digits.append(chars[j]); j += 1
                }
                if let value = Int(digits, radix: 8), let scalar = Unicode.Scalar(value) {
                    out.append(Character(scalar))
                }
                i = j
            default:
                out.append(chars[i]); out.append(e); i += 2
            }
        }
        return (out, false)
    }

    // MARK: printf

    private func printfBuiltin(_ args: [String], ctx: ExecContext) -> Int32 {
        guard let format0 = args.first else {
            ctx.stderr("tethersh: printf: usage: printf format [argument ...]\n")
            return 1
        }
        let (format, _) = interpretEscapes(format0)
        let fmt = Array(format)
        var argIndex = 1
        var output = ""
        var firstCycle = true
        var conversionsPerCycle = 0

        while firstCycle || (conversionsPerCycle > 0 && argIndex < args.count) {
            firstCycle = false
            conversionsPerCycle = 0
            var i = 0
            while i < fmt.count {
                let c = fmt[i]
                if c != "%" {
                    output.append(c); i += 1; continue
                }
                i += 1
                guard i < fmt.count else { output.append("%"); break }
                if fmt[i] == "%" {
                    output.append("%"); i += 1; continue
                }
                var leftAlign = false, zeroPad = false
                while i < fmt.count, "-+ #0".contains(fmt[i]) {
                    if fmt[i] == "-" { leftAlign = true }
                    if fmt[i] == "0" { zeroPad = true }
                    i += 1
                }
                var widthStr = ""
                while i < fmt.count, ScanUtil.isDigit(fmt[i]) {
                    widthStr.append(fmt[i]); i += 1
                }
                var precisionStr: String? = nil
                if i < fmt.count, fmt[i] == "." {
                    i += 1
                    var p = ""
                    while i < fmt.count, ScanUtil.isDigit(fmt[i]) {
                        p.append(fmt[i]); i += 1
                    }
                    precisionStr = p
                }
                guard i < fmt.count else {
                    output.append("%"); break
                }
                let spec = fmt[i]
                i += 1

                func numericArgValue() -> Int {
                    let raw = argIndex < args.count ? args[argIndex] : "0"
                    if let v = Int(raw) { return v }
                    ctx.stderr("tethersh: printf: \(raw): illegal number\n")
                    return 0
                }

                let arg = argIndex < args.count ? args[argIndex] : ""
                var piece: String
                switch spec {
                case "d", "i", "u":
                    piece = String(numericArgValue())
                case "x":
                    piece = String(numericArgValue(), radix: 16)
                case "X":
                    piece = String(numericArgValue(), radix: 16, uppercase: true)
                case "o":
                    piece = String(numericArgValue(), radix: 8)
                case "c":
                    piece = String(arg.prefix(1))
                case "s":
                    piece = arg
                    if let p = precisionStr, let limit = Int(p), piece.count > limit {
                        piece = String(piece.prefix(limit))
                    }
                case "b":
                    let (expanded, _) = interpretEscapes(arg)
                    piece = expanded
                default:
                    output.append("%" + String(spec))
                    continue
                }
                conversionsPerCycle += 1
                argIndex += 1

                if let p = precisionStr, let limit = Int(p), limit > piece.count,
                   "diuxXo".contains(spec) {
                    piece = String(repeating: "0", count: limit - piece.count) + piece
                }
                if let width = Int(widthStr), width > piece.count {
                    let fill = String(repeating: zeroPad && !leftAlign ? "0" : " ",
                                      count: width - piece.count)
                    piece = leftAlign ? piece + fill : fill + piece
                }
                output.append(piece)
            }
        }
        ctx.stdout(output)
        return 0
    }

    // MARK: cat

    private func catBuiltin(_ args: [String], ctx: ExecContext) -> Int32 {
        if args.isEmpty {
            ctx.stdout(ctx.stdin.readRest())
            return 0
        }
        var status: Int32 = 0
        for path in args {
            if path == "-" {
                ctx.stdout(ctx.stdin.readRest())
            } else if let content = virtualFile(path) {
                ctx.stdout(content)
            } else {
                ctx.stderr("tethersh: cat: \(path): no such file\n")
                status = 1
            }
        }
        return status
    }

    // MARK: read

    private func readBuiltin(_ args: [String], ctx: ExecContext) -> Int32 {
        var raw = false
        var rest = args[...]
        while let first = rest.first {
            if first == "-r" { raw = true; rest = rest.dropFirst() }
            else if first.hasPrefix("-"), first.count > 1, first.allSatisfy({ $0 == "-" || $0 == "r" }) {
                raw = true; rest = rest.dropFirst()
            } else {
                break
            }
        }
        let names = Array(rest)
        guard let read = ctx.stdin.readLine() else { return 1 }
        var line = read.line
        if !raw {
            line = collapseBackslashes(line)
        }
        let status: Int32 = read.hitNewline ? 0 : 1
        if names.isEmpty {
            setVar("REPLY", line)
            return status
        }
        let ifsChars = Set(ifs)
        // Split with mksh semantics: trim IFS ends; the last variable keeps
        // the (internal) remainder.
        let chars = Array(line)
        var remaining = ArraySlice(chars)
        func skipIFS(_ s: inout ArraySlice<Character>) {
            while let f = s.first, ifsChars.contains(f) { s = s.dropFirst() }
        }
        func rtrim(_ s: ArraySlice<Character>) -> ArraySlice<Character> {
            var t = s
            while let l = t.last, ifsChars.contains(l) { t = t.dropLast() }
            return t
        }
        for (index, name) in names.enumerated() {
            guard ScanUtil.isValidName(name) else { continue }
            skipIFS(&remaining)
            if index == names.count - 1 {
                setVar(name, String(rtrim(remaining)))
            } else {
                var end = remaining.startIndex
                while end < remaining.endIndex, !ifsChars.contains(remaining[end]) {
                    end = remaining.index(after: end)
                }
                setVar(name, String(remaining[remaining.startIndex..<end]))
                remaining = remaining[end...]
            }
        }
        return status
    }

    private func collapseBackslashes(_ line: String) -> String {
        let chars = Array(line)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                out.append(chars[i + 1]); i += 2
            } else {
                out.append(chars[i]); i += 1
            }
        }
        return out
    }

    // MARK: set / export / local / unset

    private func setBuiltin(_ args: [String], ctx: ExecContext) -> Int32 {
        if args.isEmpty {
            for name in globals.keys.sorted() {
                ctx.stdout("\(name)=\(globals[name] ?? "")\n")
            }
            return 0
        }
        var words = args
        if let first = words.first, first.hasPrefix("-"), first != "--" {
            // set -e / -x / +o: accepted and ignored (no strict mode here).
            return 0
        }
        if words.first == "--" { words.removeFirst() }
        positionalStack[positionalStack.count - 1] = words
        return 0
    }

    private func exportBuiltin(_ args: [String], ctx: ExecContext) -> Int32 {
        if args.isEmpty {
            for name in exportedVars.sorted() {
                ctx.stdout("export \(name)='\(lookup(name) ?? "")'\n")
            }
            return 0
        }
        for arg in args {
            if let eq = arg.firstIndex(of: "=") {
                let name = String(arg[..<eq])
                let value = String(arg[arg.index(after: eq)...])
                guard ScanUtil.isValidName(name) else {
                    ctx.stderr("tethersh: export: `\(name)': not a valid identifier\n")
                    return 1
                }
                setVar(name, value)
                exportVar(name)
            } else {
                guard ScanUtil.isValidName(arg) else {
                    ctx.stderr("tethersh: export: `\(arg)': not a valid identifier\n")
                    return 1
                }
                exportVar(arg)
            }
        }
        return 0
    }

    private func localBuiltin(_ args: [String], ctx: ExecContext) -> Int32 {
        guard positionalStack.count > 1 else {
            ctx.stderr("tethersh: local: not in a function\n")
            return 1
        }
        for arg in args {
            let name: String
            let value: String
            if let eq = arg.firstIndex(of: "=") {
                name = String(arg[..<eq])
                value = String(arg[arg.index(after: eq)...])
            } else {
                name = arg
                value = ""
            }
            guard ScanUtil.isValidName(name) else {
                ctx.stderr("tethersh: local: `\(name)': not a valid identifier\n")
                return 1
            }
            localScopes[localScopes.count - 1][name] = value
        }
        return 0
    }

    private func unsetBuiltin(_ args: [String], ctx: ExecContext) -> Int32 {
        var names = args[...]
        var functionsMode = false
        if let first = names.first, first == "-f" || first == "-v" {
            functionsMode = first == "-f"
            names = names.dropFirst()
        }
        for name in names {
            if functionsMode {
                functions.removeValue(forKey: name)
            } else {
                unsetVar(name)
            }
        }
        return 0
    }

    // MARK: . / source

    private func dotBuiltin(_ args: [String], ctx: ExecContext) throws -> Int32 {
        guard let path = args.first else {
            ctx.stderr("tethersh: .: missing file argument\n")
            return 2
        }
        guard let text = virtualFile(path) else {
            ctx.stderr("tethersh: .: cannot open \(path)\n")
            return 1
        }
        let program: TetherProgram
        do {
            program = try parse(text)
        } catch let error as TetherShellParseError {
            ctx.stderr("tethersh: \(path): \(error)\n")
            return 2
        }
        // Sourced files run in the current shell; `exit`/`return` propagate.
        // Any arguments become the positional parameters for the duration.
        let savedPositional: [String]?
        if args.count > 1 {
            savedPositional = positionalStack[positionalStack.count - 1]
            positionalStack[positionalStack.count - 1] = Array(args.dropFirst())
        } else {
            savedPositional = nil
        }
        defer {
            if let savedPositional {
                positionalStack[positionalStack.count - 1] = savedPositional
            }
        }
        return try runItems(program.items, ctx: ctx)
    }

    // MARK: test / [

    private func runTest(_ args: [String], ctx: ExecContext) -> Int32 {
        do {
            var parser = TestParser(args, fs: self)
            let result = try parser.parseOr()
            guard parser.atEnd else {
                ctx.stderr("tethersh: test: unexpected extra argument\n")
                return 2
            }
            return result ? 0 : 1
        } catch {
            ctx.stderr("tethersh: test: syntax error\n")
            return 2
        }
    }
}

// MARK: - test expression parser

private struct TestParser {
    let args: [String]
    let shell: TetherShell
    var pos = 0

    enum TestError: Error { case syntax }

    init(_ args: [String], fs: TetherShell) {
        self.args = args
        self.shell = fs
    }

    var atEnd: Bool { pos >= args.count }
    var peek: String? { pos < args.count ? args[pos] : nil }

    @discardableResult
    mutating func take(_ s: String) -> Bool {
        if peek == s { pos += 1; return true }
        return false
    }

    mutating func parseOr() throws -> Bool {
        var value = try parseAnd()
        while take("-o") {
            let rhs = try parseAnd()
            value = value || rhs
        }
        return value
    }

    mutating func parseAnd() throws -> Bool {
        var value = try parseNot()
        while take("-a") {
            let rhs = try parseNot()
            value = value && rhs
        }
        return value
    }

    mutating func parseNot() throws -> Bool {
        if take("!") { return !(try parseNot()) }
        return try parsePrimary()
    }

    mutating func parsePrimary() throws -> Bool {
        if take("(") {
            let value = try parseOr()
            guard take(")") else { throw TestError.syntax }
            return value
        }
        guard let first = peek else { throw TestError.syntax }

        // Unary operators.
        if ["-z", "-n", "-e", "-f", "-d", "-s"].contains(first) {
            pos += 1
            guard let operand = peek else { throw TestError.syntax }
            pos += 1
            switch first {
            case "-z": return operand.isEmpty
            case "-n": return !operand.isEmpty
            case "-e":
                return shell.virtualFile(operand) != nil
                    || shell.isVirtualDirectory(operand)
            case "-f":
                return shell.virtualFile(operand) != nil
                    && !shell.isVirtualDirectory(operand)
            case "-d": return shell.isVirtualDirectory(operand)
            case "-s": return !(shell.virtualFile(operand) ?? "").isEmpty
            default: throw TestError.syntax
            }
        }

        pos += 1
        guard let op = peek else {
            // Single argument: true when non-empty.
            return !first.isEmpty
        }
        if ["=", "==", "!=", "-eq", "-ne", "-lt", "-le", "-gt", "-ge"].contains(op) {
            pos += 1
            guard let second = peek else { throw TestError.syntax }
            pos += 1
            switch op {
            case "=", "==": return first == second
            case "!=": return first != second
            default:
                guard let l = Int(first), let r = Int(second) else { throw TestError.syntax }
                switch op {
                case "-eq": return l == r
                case "-ne": return l != r
                case "-lt": return l < r
                case "-le": return l <= r
                case "-gt": return l > r
                default: return l >= r
                }
            }
        }
        // Unrecognized operator: treat `first` as a one-argument test.
        return !first.isEmpty
    }
}

extension TetherShell {
    /// Virtual directories exist implicitly when a file lives beneath them.
    func isVirtualDirectory(_ path: String) -> Bool {
        let key = normalizePath(path)
        if key == "/" { return true }
        let prefix = key + "/"
        return fileSystem.keys.contains { $0.hasPrefix(prefix) }
    }
}
