import Foundation
import TermXShellLang

/// Bridges `TermXShellLang`'s `ShellHost` protocol to `ShellSession` + `PipelineExecutor`.
final class ShellSessionHost: ShellHost {
    private weak var session: ShellSession?

    init(session: ShellSession) {
        self.session = session
    }

    func run(commandLine: String) -> Int32 {
        session?.evalCommandLine(commandLine) ?? 127
    }

    func write(_ text: String) {
        session?.writeOutput(text)
    }

    func writeError(_ text: String) {
        session?.writeError(text)
    }

    func value(for name: String) -> String? {
        session?.state.environ[name]
    }

    func setValue(_ value: String, for name: String) {
        session?.state.environ[name] = value
    }
}

/// Script-level evaluation (if/while/case/functions/here-docs) wired into the shell.
enum ShellLangIntegration {

    /// Evaluates a multi-line script, expanding here-documents when present.
    @discardableResult
    static func evalScript(_ source: String, session: ShellSession) -> Int32 {
        if containsHereDoc(source) {
            return evalScriptWithHereDocs(source, session: session)
        }
        do {
            if let node = try ScriptParser.parse(source) {
                return try evaluateNode(node, session: session)
            }
        } catch let err as ShellLangError {
            return reportShellLangError(err, session: session)
        } catch {
            session.writeError("syntax error\n")
            session.state.lastExitCode = 2
            return 2
        }
        var lastCode: Int32 = 0
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            lastCode = session.evalCommandLine(trimmed)
        }
        return lastCode
    }

    private static func containsHereDoc(_ source: String) -> Bool {
        source.contains("<<") && !source.contains("<<<")
    }

    private static func evalScriptWithHereDocs(_ source: String, session: ShellSession) -> Int32 {
        var lines = source.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        var index = 0
        var lastCode: Int32 = 0
        while index < lines.count {
            let line = lines[index]
            if line.contains("<<") && !line.contains("<<<") {
                let following = Array(lines[(index + 1)...])
                var vars = session.state.environ
                do {
                    let extraction = try HereDocProcessor.extract(
                        line: line, following: following, variables: &vars
                    )
                    session.state.environ = vars
                    lastCode = session.evalCommandLine(
                        extraction.commandLine, stdinText: extraction.body
                    )
                    let consumed = following.count - extraction.remainder.count + 1
                    index += 1 + consumed
                    continue
                } catch {
                    session.writeError("syntax error: \(error)\n")
                    return 2
                }
            }
            lastCode = session.evalCommandLine(line)
            index += 1
        }
        return lastCode
    }

    /// Tries the shell-language parser; returns a result when the construct was handled.
    static func tryEvaluate(_ source: String, session: ShellSession) -> Int32? {
        if source.contains("\n") {
            return evalScript(source, session: session)
        }
        do {
            if let node = try ScriptParser.parse(source) {
                return try evaluateNode(node, session: session)
            }
            // Arithmetic expansion and other word ops not handled by the pipeline parser.
            if source.range(of: #"\$\(\("#, options: .regularExpression) != nil {
                return try evaluateNode(.command(source), session: session)
            }
            return nil
        } catch let err as ShellLangError {
            return reportShellLangError(err, session: session)
        } catch {
            session.writeError("syntax error\n")
            session.state.lastExitCode = 2
            return 2
        }
    }

    private static func evaluateNode(_ node: ShellNode, session: ShellSession) throws -> Int32 {
        let host = ShellSessionHost(session: session)
        let evaluator = ScriptEvaluator(host: host)
        var variables = session.state.environ
        let code = try evaluator.evaluate(node, variables: &variables)
        session.state.environ = variables
        session.state.lastExitCode = code
        return code
    }

    private static func reportShellLangError(_ err: ShellLangError, session: ShellSession) -> Int32 {
        switch err {
        case .syntax(let msg):
            session.writeError("syntax error: \(msg)\n")
        case .parameterUnset(let msg):
            session.writeError("\(msg)\n")
        case .arithmetic(let msg):
            session.writeError("arithmetic error: \(msg)\n")
        case .undefinedFunction(let name):
            session.writeError("\(name): command not found\n")
        }
        session.state.lastExitCode = 2
        return 2
    }
}
