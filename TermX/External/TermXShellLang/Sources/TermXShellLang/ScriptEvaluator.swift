import Foundation

/// Everything the evaluator needs from the outside world. The app implements this;
/// tests implement a fake that records command lines and returns canned exit codes.
public protocol ShellHost: AnyObject {
    /// Runs one already-expanded command line (may contain pipes/redirects) and
    /// returns its exit code. This library must never execute commands itself.
    func run(commandLine: String) -> Int32
    /// Writes to the shell's stdout / stderr.
    func write(_ text: String)
    func writeError(_ text: String)
    /// Variable storage shared with the surrounding shell.
    func value(for name: String) -> String?
    func setValue(_ value: String, for name: String)
}

public enum ShellLangError: Error, Equatable {
    case syntax(String)
    case parameterUnset(String)   // ${V:?msg}
    case arithmetic(String)
    case undefinedFunction(String)
}

public final class ScriptEvaluator {
    private let host: ShellHost
    private var functions: [String: ShellNode] = [:]
    private var posStack: [[String]] = []
    private var loopDepth = 0

    public init(host: ShellHost) {
        self.host = host
    }

    // MARK: - Public API

    /// Evaluates a parsed script and returns the exit code of the last command run.
    public func evaluate(_ node: ShellNode, variables: inout [String: String]) throws -> Int32 {
        let flow = try evalNode(node, variables: &variables)
        switch flow {
        case .normal(let code):
            return code
        case .breakFlow, .continueFlow:
            // A leftover break/continue that reached the top has no enclosing
            // loop; bash tolerates this (it just stops), so absorb it.
            return 0
        case .returnFlow(let code):
            return code ?? 0
        }
    }

    /// Calls a function defined earlier by `functionDefinition`, binding $1…$9,
    /// $#, $@, $*, and restoring the caller's positional parameters afterwards.
    public func callFunction(named: String, arguments: [String],
                             variables: inout [String: String]) throws -> Int32 {
        guard let body = functions[named] else {
            throw ShellLangError.undefinedFunction(named)
        }
        posStack.append(arguments)
        defer { posStack.removeLast() }
        let flow = try evalNode(body, variables: &variables)
        switch flow {
        case .normal(let code): return code
        case .returnFlow(let code): return code ?? 0
        case .breakFlow, .continueFlow:
            throw ShellLangError.undefinedFunction(named) // misuse inside function
        }
    }

    // MARK: - Internal control flow

    private enum Flow {
        case normal(Int32)
        case breakFlow(Int)
        case continueFlow(Int)
        case returnFlow(Int32?)
    }

    // MARK: - Node evaluation

    private func evalNode(_ node: ShellNode, variables: inout [String: String]) throws -> Flow {
        switch node {
        case .command(let line):
            let expanded = try expandLine(line, variables: &variables)
            // If the command names a function defined earlier in the script, and
            // it is a *simple* command (no pipeline / redirection / separator),
            // invoke it (binding $1…$9, $#, $@, $*) instead of running it.
            if isSimpleCommand(expanded),
               let (name, args) = splitCommand(expanded), let body = functions[name] {
                posStack.append(args)
                defer { posStack.removeLast() }
                let flow = try evalNode(body, variables: &variables)
                switch flow {
                case .normal(let code): return .normal(code)
                case .returnFlow(let code): return .normal(code ?? 0)
                case .breakFlow(let n): return .breakFlow(n)
                case .continueFlow(let n): return .continueFlow(n)
                }
            }
            // A plain `NAME=value` assignment must update the evaluator's own variables,
            // otherwise a later `$NAME` in the same script (a loop condition, say) still
            // expands from the stale copy. Keep the host in sync too.
            if let (name, value) = Self.simpleAssignment(expanded) {
                variables[name] = value
                host.setValue(value, for: name)
                return .normal(0)
            }
            let code = host.run(commandLine: expanded)
            return .normal(code)

        case .sequence(let nodes):
            var last: Int32 = 0
            for n in nodes {
                let f = try evalNode(n, variables: &variables)
                switch f {
                case .normal(let code): last = code
                case .breakFlow, .continueFlow, .returnFlow:
                    return f
                }
            }
            return .normal(last)

        case .ifStatement(let conditions, let elseBranch):
            for (cond, body) in conditions {
                let cf = try evalNode(cond, variables: &variables)
                if case .normal(let code) = cf, code == 0 {
                    return try evalNode(body, variables: &variables)
                }
            }
            if let elseBranch = elseBranch {
                return try evalNode(elseBranch, variables: &variables)
            }
            return .normal(0)

        case .whileLoop(let condition, let body, let isUntil):
            loopDepth += 1
            defer { loopDepth -= 1 }
            var last: Int32 = 0
            loop: while true {
                let cf = try evalNode(condition, variables: &variables)
                let truth: Bool
                if case .normal(let code) = cf {
                    truth = (code == 0)
                } else {
                    return cf
                }
                let shouldRun = isUntil ? !truth : truth
                if !shouldRun { break }

                let bf = try evalNode(body, variables: &variables)
                switch bf {
                case .normal(let code): last = code
                case .breakFlow(let n):
                    if n <= 1 { break loop }
                    if loopDepth > 1 { return .breakFlow(n - 1) }
                    break loop            // excess absorbed: no enclosing loop
                case .continueFlow(let n):
                    if n <= 1 { continue loop }
                    if loopDepth > 1 { return .continueFlow(n - 1) }
                    continue loop         // excess absorbed: continue current loop
                case .returnFlow(let code): return .returnFlow(code)
                }
            }
            return .normal(last)

        case .caseStatement(let subject, let cases):
            let subj = try expandLine(subject, variables: &variables)
            for entry in cases {
                for pattern in entry.patterns {
                    let p = try expandLine(pattern, variables: &variables)
                    if ShellGlob.matches(pattern: p, string: subj) {
                        return try evalNode(entry.body, variables: &variables)
                    }
                }
            }
            return .normal(0)

        case .functionDefinition(let name, let body):
            functions[name] = body
            return .normal(0)

        case .breakLoop(let levels):
            return .breakFlow(levels)

        case .continueLoop(let levels):
            return .continueFlow(levels)

        case .returnFromFunction(let code):
            return .returnFlow(code)
        }
    }

    // MARK: - Word/line expansion (variables, positionals, arithmetic)

    private func expandLine(_ line: String, variables: inout [String: String]) throws -> String {
        let substituted = try substituteDollars(line, variables: &variables)
        return try braceAndTilde(substituted, variables: &variables)
    }

    private func substituteDollars(_ s: String, variables: inout [String: String]) throws -> String {
        var result = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                // Preserve escaped next char as-is (match shell: quotes/escapes).
                if i + 1 < chars.count {
                    result.append(chars[i + 1])
                    i += 2
                } else {
                    result.append(c); i += 1
                }
                continue
            }
            if c == "'" {
                // Single quotes: literal, no expansion.
                result.append(c)
                i += 1
                while i < chars.count && chars[i] != "'" { result.append(chars[i]); i += 1 }
                if i < chars.count { result.append(chars[i]); i += 1 }
                continue
            }
            if c == "$" {
                if i + 1 < chars.count {
                    let next = chars[i + 1]
                    if next == "{", let close = balancedClose(chars, at: i + 1, open: "{", close: "}") {
                        let inner = String(chars[(i + 2)..<close])
                        result += try ParameterExpander.expand("${\(inner)}", variables: &variables)
                        i = close + 1
                        continue
                    }
                    if next == "(", i + 2 < chars.count, chars[i + 2] == "(",
                       let close = balancedClose(chars, at: i + 1, open: "(", close: ")") {
                        let inner = String(chars[(i + 3)..<close])
                        var sub = variables
                        if let v = try? ArithmeticEvaluator.evaluate(inner, variables: &sub) {
                            variables = sub
                            result += String(v)
                        } else {
                            result += "$((\(inner)))"
                        }
                        i = close + 1
                        continue
                    }
                    if next == "(",
                       let close = balancedClose(chars, at: i + 1, open: "(", close: ")") {
                        // Command substitution — leave for the host/app.
                        result += String(chars[i...close])
                        i = close + 1
                        continue
                    }
                    if next == "#" {
                        result += String(currentPositionals().count)
                        i += 2
                        continue
                    }
                    if next == "@" || next == "*" {
                        result += currentPositionals().joined(separator: " ")
                        i += 2
                        continue
                    }
                    if next.isNumber {
                        var digits = ""
                        var k = i + 1
                        while k < chars.count && chars[k].isNumber {
                            digits.append(chars[k]); k += 1
                        }
                        let idx = Int(digits) ?? 0
                        let pos = currentPositionals()
                        if idx >= 1 && idx <= pos.count {
                            result += pos[idx - 1]
                        }
                        i = k
                        continue
                    }
                    if next == "_" || next.isLetter {
                        var name = ""
                        var k = i + 1
                        while k < chars.count && (chars[k] == "_" || chars[k].isLetter || chars[k].isNumber) {
                            name.append(chars[k]); k += 1
                        }
                        result += variables[name] ?? ""
                        i = k
                        continue
                    }
                }
            }
            result.append(c)
            i += 1
        }
        return result
    }

    private func braceAndTilde(_ s: String, variables: inout [String: String]) throws -> String {
        guard s.contains("{") || s.contains("~") else { return s }
        let home = host.value(for: "HOME") ?? ""
        var out: [String] = []
        for token in s.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let t = String(token)
            var expanded = WordExpander.expandTilde(t, home: home)
            let braces = WordExpander.expandBraces(expanded)
            for b in braces { out.append(b) }
        }
        return out.joined(separator: " ")
    }

    private func currentPositionals() -> [String] {
        return posStack.last ?? []
    }

    /// Split a command line into `(name, arguments)`, honoring simple quotes and
    /// escapes. Used to detect named-function invocations.
    private func splitCommand(_ line: String) -> (String, [String])? {
        var words: [String] = []
        var cur = ""
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" {
                if !cur.isEmpty { words.append(cur); cur = "" }
                i += 1
                continue
            }
            if c == "\\", i + 1 < chars.count {
                cur.append(chars[i + 1]); i += 2; continue
            }
            if c == "'" {
                i += 1
                while i < chars.count && chars[i] != "'" { cur.append(chars[i]); i += 1 }
                i += 1
                continue
            }
            if c == "\"" {
                i += 1
                while i < chars.count && chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count, chars[i+1] == "\"" {
                        cur.append("\""); i += 2; continue
                    }
                    cur.append(chars[i]); i += 1
                }
                i += 1
                continue
            }
            cur.append(c)
            i += 1
        }
        if !cur.isEmpty { words.append(cur) }
        guard let name = words.first, !name.isEmpty else { return nil }
        return (name, Array(words.dropFirst()))
    }

    /// True when `line` contains no shell operators that would make it a compound
    /// command (pipes, redirections, separators, backgrounding, logic operators).
    /// Function invocation is only intercepted for simple commands.
    /// Recognises `NAME=value` (and `NAME=`) with no command following it.
    static func simpleAssignment(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let name = String(trimmed[trimmed.startIndex..<eq])
        guard !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              !(name.first?.isNumber ?? true) else { return nil }
        let value = String(trimmed[trimmed.index(after: eq)...])
        // `a=b c` is an assignment prefix on a command, not a plain assignment.
        guard !value.contains(" ") || (value.hasPrefix("\"") && value.hasSuffix("\"")) else { return nil }
        return (name, value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
    }

    private func isSimpleCommand(_ line: String) -> Bool {
        for c in line {
            if c == "|" || c == "&" || c == ";" || c == "<" || c == ">" { return false }
        }
        return true
    }

    /// Find the matching close index for an opener at `openIdx`.
    private func balancedClose(_ chars: [Character], at openIdx: Int,
                               open: Character, close: Character) -> Int? {
        var depth = 1
        var i = openIdx + 1
        while i < chars.count {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "'" {
                i += 1
                while i < chars.count && chars[i] != "'" { i += 1 }
                i += 1
                continue
            }
            if c == "\"" { i += 1; continue }
            if c == open { depth += 1 }
            if c == close {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }
}
