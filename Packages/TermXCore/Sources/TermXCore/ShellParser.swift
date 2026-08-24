import Foundation

// MARK: - Shell AST Types

/// Represents a parsed shell command pipeline with operators.
public indirect enum ShellAST: Equatable, Sendable {
    /// A simple command: `echo hello`
    case simple(SimpleCommand)
    /// A pipeline: `cmd1 | cmd2 | cmd3`
    case pipeline([SimpleCommand])
    /// Logical AND: `cmd1 && cmd2`
    case and(ShellAST, ShellAST)
    /// Logical OR: `cmd1 || cmd2`
    case or(ShellAST, ShellAST)
    /// Sequential: `cmd1 ; cmd2`
    case sequence(ShellAST, ShellAST)
    /// Background: `cmd &`
    case background(ShellAST)
    /// Subshell: `(cmd1; cmd2)`
    case subshell(ShellAST)
}

/// A single command with its arguments and redirections.
public struct SimpleCommand: Equatable, Sendable {
    public var argv: [String]
    /// Parallel to `argv`: true when the word was entirely single-quoted (no expansion).
    public var literalArgv: [Bool]
    public var redirections: [Redirection]
    public var assignmentWords: [String]  // VAR=value preceding the command

    public init(argv: [String] = [], literalArgv: [Bool] = [], redirections: [Redirection] = [], assignmentWords: [String] = []) {
        self.argv = argv
        self.literalArgv = literalArgv
        self.redirections = redirections
        self.assignmentWords = assignmentWords
    }

    public var commandName: String? { argv.first }
}

/// A file redirection.
public struct Redirection: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case inputFrom          // <
        case outputTo           // >
        case outputAppend       // >>
        case stderrTo           // 2>
        case stderrAppend       // 2>>
        case stderrToStdout     // 2>&1
        case hereString(String) // <<< "string"
    }
    public let kind: Kind
    public let target: String  // filename or fd number

    public init(kind: Kind, target: String = "") {
        self.kind = kind
        self.target = target
    }
}

// MARK: - Shell Parser

/// Parses a shell command line into an AST.
/// Supports: pipes, redirects, &&, ||, ;, &, $VAR, $(cmd), quotes, escapes, globs.
public enum ShellParser {

    public static func parse(_ input: String) -> ShellAST? {
        var tokens = tokenize(input)
        guard !tokens.isEmpty else { return nil }
        return parseSequence(&tokens)
    }

    // MARK: - Tokenizer

    enum Token: Equatable {
        case word(String, singleQuoted: Bool = false)
        case pipe            // |
        case andOp           // &&
        case orOp            // ||
        case semi            // ;
        case amp             // &
        case lparen          // (
        case rparen          // )
        case redirect(Redirection.Kind, String)  // redirection + target
    }

    static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(input)
        var i = 0

        while i < chars.count {
            // Skip whitespace
            if chars[i].isWhitespace {
                i += 1
                continue
            }

            // Two-char operators
            if i + 1 < chars.count {
                let two = String(chars[i...i+1])
                if two == "&&" { tokens.append(.andOp); i += 2; continue }
                if two == "||" { tokens.append(.orOp); i += 2; continue }
                if two == ">>" {
                    i += 2; skipWhitespace(chars, &i)
                    let target = readWord(chars, &i).0
                    tokens.append(.redirect(.outputAppend, target)); continue
                }
            }

            // 2> and 2>>
            if i + 1 < chars.count && chars[i] == "2" && chars[i+1] == ">" {
                if i + 2 < chars.count && chars[i+2] == "&" && i + 3 < chars.count && chars[i+3] == "1" {
                    tokens.append(.redirect(.stderrToStdout, "")); i += 4; continue
                }
                if i + 2 < chars.count && chars[i+2] == ">" {
                    i += 3; skipWhitespace(chars, &i)
                    let target = readWord(chars, &i).0
                    tokens.append(.redirect(.stderrAppend, target)); continue
                }
                i += 2; skipWhitespace(chars, &i)
                let target = readWord(chars, &i).0
                tokens.append(.redirect(.stderrTo, target)); continue
            }

            // Here-string <<<
            if i + 2 < chars.count && chars[i] == "<" && chars[i+1] == "<" && chars[i+2] == "<" {
                i += 3; skipWhitespace(chars, &i)
                let content = readWord(chars, &i).0
                tokens.append(.redirect(.hereString(content), "")); continue
            }

            // Single-char operators
            if chars[i] == "|" { tokens.append(.pipe); i += 1; continue }
            if chars[i] == ";" { tokens.append(.semi); i += 1; continue }
            if chars[i] == "&" { tokens.append(.amp); i += 1; continue }
            if chars[i] == "(" { tokens.append(.lparen); i += 1; continue }
            if chars[i] == ")" { tokens.append(.rparen); i += 1; continue }

            // Output redirect >
            if chars[i] == ">" {
                i += 1; skipWhitespace(chars, &i)
                let target = readWord(chars, &i).0
                tokens.append(.redirect(.outputTo, target)); continue
            }

            // Input redirect <
            if chars[i] == "<" {
                i += 1; skipWhitespace(chars, &i)
                let target = readWord(chars, &i).0
                tokens.append(.redirect(.inputFrom, target)); continue
            }

            // Comment
            if chars[i] == "#" { break }

            // Word (includes quoted strings, variable expansions, etc.)
            let (word, singleQuoted) = readWord(chars, &i)
            if !word.isEmpty {
                tokens.append(.word(word, singleQuoted: singleQuoted))
            }
        }

        return tokens
    }

    private static func skipWhitespace(_ chars: [Character], _ i: inout Int) {
        while i < chars.count && chars[i].isWhitespace { i += 1 }
    }

    private static func readWord(_ chars: [Character], _ i: inout Int) -> (String, singleQuoted: Bool) {
        var result = ""
        var quote: Character? = nil
        var escaped = false
        var onlySingleQuoted = true
        var sawContent = false

        while i < chars.count {
            let c = chars[i]

            if escaped {
                // Inside double quotes a backslash is literal unless it escapes one of
                // $ ` " \ or a newline (POSIX), so `printf "a\nb"` still receives `\n`.
                if quote == "\"", !"$`\"\\\n".contains(c) {
                    result.append("\\")
                }
                result.append(c)
                escaped = false
                sawContent = true
                i += 1
                continue
            }

            if c == "\\" && quote != "'" {
                escaped = true
                i += 1
                continue
            }

            if let q = quote {
                if c == q {
                    quote = nil
                    i += 1
                    continue
                }
                result.append(c)
                sawContent = true
                i += 1
                continue
            }

            if c == "'" || c == "\"" {
                if c == "\"" { onlySingleQuoted = false }
                quote = c
                i += 1
                continue
            }

            // Break on unquoted operator characters or whitespace
            if c.isWhitespace || "|&;()<>".contains(c) { break }

            onlySingleQuoted = false
            sawContent = true
            if c == "$" && i + 1 < chars.count && chars[i+1] == "(" {
                result.append(c)
                i += 1
                var depth = 0
                while i < chars.count {
                    if chars[i] == "(" { depth += 1 }
                    if chars[i] == ")" { depth -= 1; if depth == 0 { result.append(chars[i]); i += 1; break } }
                    result.append(chars[i])
                    i += 1
                }
                continue
            }

            result.append(c)
            i += 1
        }

        return (result, singleQuoted: sawContent && onlySingleQuoted)
    }

    // MARK: - Recursive Descent Parser

    /// sequence := logicalExpr (';' logicalExpr)*
    private static func parseSequence(_ tokens: inout [Token]) -> ShellAST? {
        guard var left = parseLogical(&tokens) else { return nil }

        while tokens.first == .semi {
            tokens.removeFirst()
            if tokens.isEmpty { break }
            guard let right = parseLogical(&tokens) else { break }
            left = .sequence(left, right)
        }

        return left
    }

    /// logicalExpr := pipelineExpr (('&&'|'||') pipelineExpr)*
    private static func parseLogical(_ tokens: inout [Token]) -> ShellAST? {
        guard var left = parsePipelineOrBackground(&tokens) else { return nil }

        while let op = tokens.first, (op == .andOp || op == .orOp) {
            tokens.removeFirst()
            guard let right = parsePipelineOrBackground(&tokens) else { break }
            left = op == .andOp ? .and(left, right) : .or(left, right)
        }

        return left
    }

    /// pipelineOrBackground := pipelineExpr ['&']
    private static func parsePipelineOrBackground(_ tokens: inout [Token]) -> ShellAST? {
        guard let expr = parsePipeline(&tokens) else { return nil }

        if tokens.first == .amp {
            tokens.removeFirst()
            return .background(expr)
        }

        return expr
    }

    /// pipelineExpr := simpleCommand ('|' simpleCommand)*
    private static func parsePipeline(_ tokens: inout [Token]) -> ShellAST? {
        guard let first = parseSimple(&tokens) else { return nil }

        var commands = [first]
        while tokens.first == .pipe {
            tokens.removeFirst()
            guard let next = parseSimple(&tokens) else { break }
            commands.append(next)
        }

        if commands.count == 1 {
            return .simple(commands[0])
        }
        return .pipeline(commands)
    }

    /// simpleCommand := (word | redirect)*
    private static func parseSimple(_ tokens: inout [Token]) -> SimpleCommand? {
        var cmd = SimpleCommand()

        while let token = tokens.first {
            switch token {
            case .word(let w, let singleQuoted):
                tokens.removeFirst()
                // Check for assignment words (VAR=value before command name)
                if cmd.argv.isEmpty && w.contains("=") && !w.hasPrefix("=") {
                    let eqIdx = w.firstIndex(of: "=")!
                    let name = String(w[w.startIndex..<eqIdx])
                    if name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                        cmd.assignmentWords.append(w)
                        continue
                    }
                }
                cmd.argv.append(w)
                cmd.literalArgv.append(singleQuoted)
            case .redirect(let kind, let target):
                tokens.removeFirst()
                cmd.redirections.append(Redirection(kind: kind, target: target))
            case .lparen:
                // Subshell not handled at simple level
                break
            default:
                break
            }
            // Break on operators that end a simple command
            if case .word = token { continue }
            if case .redirect = token { continue }
            break
        }

        if cmd.argv.isEmpty && cmd.assignmentWords.isEmpty && cmd.redirections.isEmpty { return nil }
        return cmd
    }
}

// MARK: - Variable Expansion

public enum VariableExpander {

    /// Result of running a command substitution `$(cmd)`.
    public typealias CommandSubstitutionResult = (output: String, exitCode: Int32)
    public typealias CommandRunner = (String) -> CommandSubstitutionResult

    /// Expand `$VAR`, `${VAR}`, `${VAR:-default}`, `$?`, `$$`, `$!`, `~`, `$(cmd)` in a string.
    public static func expand(_ input: String, environ: [String: String],
                               lastExitCode: Int32 = 0, shellPID: Int32 = 1,
                               lastBgPID: Int32 = 0,
                               commandRunner: CommandRunner? = nil) -> String {
        var result = ""
        let chars = Array(input)
        var i = 0

        while i < chars.count {
            if chars[i] == "\\" && i + 1 < chars.count {
                // Quote removal already ran in the lexer. Here a backslash only hides a
                // `$` from expansion; every other one is data (`printf "a\\nb"`).
                if chars[i + 1] != "$" { result.append("\\") }
                result.append(chars[i + 1])
                i += 2
                continue
            }

            // Tilde expansion at start
            if chars[i] == "~" && i == 0 && (i + 1 >= chars.count || chars[i + 1] == "/") {
                result.append(environ["HOME"] ?? "~")
                i += 1
                continue
            }

            if chars[i] == "$" {
                i += 1
                if i >= chars.count { result.append("$"); continue }

                // Command substitution $(cmd)
                if chars[i] == "(" {
                    i += 1
                    var depth = 1
                    var cmd = ""
                    while i < chars.count && depth > 0 {
                        if chars[i] == "(" { depth += 1 }
                        if chars[i] == ")" {
                            depth -= 1
                            if depth == 0 { i += 1; break }
                        }
                        cmd.append(chars[i])
                        i += 1
                    }
                    if let commandRunner {
                        let subResult = commandRunner(cmd.trimmingCharacters(in: .whitespaces))
                        // Unquoted substitutions are word-split by a POSIX shell, which
                        // collapses surrounding whitespace (so `$(ls | wc -l)` is "3").
                        result.append(subResult.output.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    continue
                }

                // Special variables
                if chars[i] == "?" { result.append(String(lastExitCode)); i += 1; continue }
                if chars[i] == "$" { result.append(String(shellPID)); i += 1; continue }
                if chars[i] == "!" { result.append(String(lastBgPID)); i += 1; continue }
                // This lightweight expander runs at the top-level shell, where
                // there are no positional parameters. Function/script
                // positionals are handled by TermXShellLang.
                if chars[i] == "#" { result.append("0"); i += 1; continue }

                // ${VAR} or ${VAR:-default}
                if chars[i] == "{" {
                    i += 1
                    var name = ""
                    var defaultVal: String? = nil
                    while i < chars.count && chars[i] != "}" {
                        if chars[i] == ":" && i + 1 < chars.count && chars[i+1] == "-" {
                            i += 2
                            var def = ""
                            while i < chars.count && chars[i] != "}" {
                                def.append(chars[i]); i += 1
                            }
                            defaultVal = def
                            break
                        }
                        name.append(chars[i])
                        i += 1
                    }
                    if i < chars.count && chars[i] == "}" { i += 1 }
                    let value = environ[name]
                    if let value, !value.isEmpty {
                        result.append(value)
                    } else if let defaultVal {
                        result.append(defaultVal)
                    }
                    continue
                }

                // $VAR
                var name = ""
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    name.append(chars[i]); i += 1
                }
                if name.isEmpty { result.append("$"); continue }
                result.append(environ[name] ?? "")
                continue
            }

            result.append(chars[i])
            i += 1
        }

        return result
    }

    /// Expand variables in all elements of an argv array.
    public static func expandArgv(_ argv: [String], environ: [String: String],
                                   lastExitCode: Int32 = 0) -> [String] {
        argv.map { expand($0, environ: environ, lastExitCode: lastExitCode) }
    }
}
