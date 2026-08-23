import Foundation

// MARK: - Shell Control Flow (for / while loops)

/// Parses and executes POSIX-style `for` loops without a full mksh port.
/// Syntax: `for NAME in WORD ...; do BODY; done`
public enum ShellControlFlow {

    /// Returns exit code if the line was a for-loop; nil if not a for-loop.
    public static func evalForLoop(_ input: String, executor: PipelineExecutor,
                                    shellState: ShellState) -> Int32? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("for ") else { return nil }

        guard let parsed = parseForLoop(trimmed) else { return 2 }

        let items = expandForItems(parsed.itemsPart, executor: executor, shellState: shellState)

        let runLoop: () -> Int32 = {
            var lastCode: Int32 = 0
            for item in items {
                shellState.environ[parsed.variable] = item
                for bodyLine in parsed.bodyLines {
                    let bodyTrimmed = bodyLine.trimmingCharacters(in: .whitespaces)
                    if bodyTrimmed.isEmpty || bodyTrimmed.hasPrefix("#") { continue }
                    if let forCode = evalForLoop(bodyTrimmed, executor: executor, shellState: shellState) {
                        lastCode = forCode
                    } else if let ast = ShellParser.parse(bodyTrimmed) {
                        lastCode = executor.execute(ast)
                    }
                }
            }
            return lastCode
        }

        let lastCode: Int32
        if parsed.redirectSpec.isEmpty {
            lastCode = runLoop()
        } else {
            lastCode = RedirectScope.run(spec: parsed.redirectSpec, state: shellState, body: runLoop)
        }
        shellState.lastExitCode = lastCode
        return lastCode
    }

    struct ParsedForLoop {
        let variable: String
        let itemsPart: String
        let bodyLines: [String]
        /// Redirections trailing `done` (`for …; done > f`); empty when none.
        let redirectSpec: String
    }

    static func parseForLoop(_ input: String) -> ParsedForLoop? {
        // `for VAR in ITEMS; do BODY; done`
        guard input.hasPrefix("for ") else { return nil }

        let rest = String(input.dropFirst(4))
        guard let inRange = rest.range(of: " in ") else { return nil }
        let varName = String(rest[rest.startIndex..<inRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !varName.isEmpty else { return nil }

        let afterIn = String(rest[inRange.upperBound...])
        guard let doRange = afterIn.range(of: "; do") ?? afterIn.range(of: " do") else { return nil }

        let itemsPart = String(afterIn[afterIn.startIndex..<doRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let afterDo = String(afterIn[doRange.upperBound...])

        guard let doneRange = afterDo.range(of: "; done") ?? afterDo.range(of: " done") else { return nil }
        let bodyPart = String(afterDo[afterDo.startIndex..<doneRange.lowerBound])

        let bodyLines = bodyPart.components(separatedBy: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }

        // Anything after `done` that looks like a redirection is applied around
        // the whole loop; other trailing text keeps the old (ignored) behavior.
        let afterDone = String(afterDo[doneRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        let redirectSpec: String
        if let first = afterDone.first,
           first == ">" || first == "<" || first == "&" || first.isNumber,
           afterDone.contains(">") || afterDone.contains("<") {
            redirectSpec = afterDone
        } else {
            redirectSpec = ""
        }

        return ParsedForLoop(variable: varName, itemsPart: itemsPart, bodyLines: bodyLines,
                             redirectSpec: redirectSpec)
    }

    /// Expand for-loop item list (supports globs and quoted words).
    static func expandForItems(_ itemsPart: String, executor: PipelineExecutor?,
                                shellState: ShellState?) -> [String] {
        let tokens = ShellLexer.lex(itemsPart)
        var result: [String] = []
        for token in tokens {
            var expanded = token
            if let shellState {
                expanded = VariableExpander.expand(
                    token, environ: shellState.environ,
                    lastExitCode: shellState.lastExitCode,
                    lastBgPID: shellState.lastBgPID,
                    commandRunner: executor.map { exec in
                        { cmd in exec.evaluateCommandSubstitution(cmd) }
                    }
                )
            }
            if GlobExpander.containsGlobChars(expanded), let shellState {
                result.append(contentsOf: GlobExpander.expand(expanded, in: shellState.cwd))
            } else {
                result.append(expanded)
            }
        }
        return result
    }
}
