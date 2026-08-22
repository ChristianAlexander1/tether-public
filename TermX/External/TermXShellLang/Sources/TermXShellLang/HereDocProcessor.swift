import Foundation

/// Processes a here-document: given the line containing `<<WORD` / `<<-WORD` /
/// `<<'WORD'` and the lines that follow, it returns the command line (with the
/// here-doc operator removed), the body (with expansions applied unless the
/// delimiter was quoted), and the remaining unconsumed script lines.
public enum HereDocProcessor {

    public struct Extraction: Equatable {
        public let commandLine: String
        public let body: String
        public let remainder: [String]
    }

    public static func extract(line: String,
                               following: [String],
                               variables: inout [String: String]) throws -> Extraction {
        guard let op = parseOperator(from: line) else {
            throw ShellLangError.syntax("here-document operator not found")
        }

        var terminatorIndex: Int? = nil
        for (idx, candidate) in following.enumerated() {
            let compare = op.stripTabs
                ? String(candidate.drop(while: { $0 == "\t" }))
                : candidate
            if compare == op.delimiter {
                terminatorIndex = idx
                break
            }
        }
        guard let terminator = terminatorIndex else {
            throw ShellLangError.syntax("unterminated here-document (expected '\(op.delimiter)')")
        }

        // The delimiter line itself is neither body nor remainder.
        let bodyLines = Array(following[0..<terminator])
        let remainder = Array(following[(terminator + 1)...])

        var body = bodyLines.joined(separator: "\n")
        if !bodyLines.isEmpty { body += "\n" }
        if op.stripTabs {
            body = body.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0.drop(while: { $0 == "\t" })) }
                .joined(separator: "\n")
        }

        if op.expand {
            body = try expandBody(body, variables: &variables)
        }

        return Extraction(commandLine: op.commandLine, body: body, remainder: remainder)
    }

    // MARK: - Operator parsing

    private struct Operator {
        let commandLine: String
        let delimiter: String
        let stripTabs: Bool
        let expand: Bool
    }

    private static func parseOperator(from line: String) -> Operator? {
        let chars = Array(line)
        var i = 0
        var inSingle = false
        var inDouble = false
        while i < chars.count {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "'" && !inDouble { inSingle = !inSingle; i += 1; continue }
            if c == "\"" && !inSingle { inDouble = !inDouble; i += 1; continue }
            if inSingle || inDouble { i += 1; continue }
            if c == "<", i + 1 < chars.count, chars[i + 1] == "<" {
                // Not a here-string (<<<).
                if i + 2 < chars.count, chars[i + 2] == "<" { i += 3; continue }

                var j = i + 2
                var strip = false
                if j < chars.count, chars[j] == "-" {
                    strip = true
                    j += 1
                }
                // Skip optional whitespace before delimiter.
                while j < chars.count && chars[j] == " " { j += 1 }

                // Read a (possibly quoted) delimiter word.
                var delim = ""
                var sawQuote = false
                var k = j
                while k < chars.count {
                    let d = chars[k]
                    if d == " " || d == "\t" || d == "\n" { break }
                    if d == "'" || d == "\"" {
                        sawQuote = true
                        k += 1
                        continue
                    }
                    if d == "\\" {
                        sawQuote = true
                        k += 2
                        continue
                    }
                    delim.append(d)
                    k += 1
                }
                guard !delim.isEmpty else { return nil }
                let delimiter = delim
                let expand = !sawQuote

                // commandLine = everything before '<<' plus anything after the
                // delimiter token (rare), trimmed.
                let before = String(chars[0..<i])
                let after = k < chars.count ? String(chars[k...]) : ""
                let commandLine = (before + " " + after).trimmingCharacters(in: .whitespaces)

                return Operator(commandLine: commandLine, delimiter: delimiter,
                                stripTabs: strip, expand: expand)
            }
            i += 1
        }
        return nil
    }

    // MARK: - Body expansion ($VAR, ${...}, $(( ... )); leaves $(...) alone)

    private static func expandBody(_ body: String,
                                   variables: inout [String: String]) throws -> String {
        var result = ""
        let chars = Array(body)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                result.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "$", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "{" {
                    if let close = findMatching(from: i + 1, chars: chars, open: "{", close: "}") {
                        let inner = String(chars[(i + 2)..<close])
                        result += try ParameterExpander.expand("${\(inner)}", variables: &variables)
                        i = close + 1
                        continue
                    }
                } else if next == "(" {
                    // $(( ... )) arithmetic, or a single $(...) command substitution.
                    if i + 2 < chars.count, chars[i + 2] == "(" {
                        if let close = findMatching(from: i + 1, chars: chars, open: "(", close: ")") {
                            let inner = String(chars[(i + 3)..<close])
                            var sub: [String: String] = variables
                            if let value = try? ArithmeticEvaluator.evaluate(inner, variables: &sub) {
                                variables = sub
                                result += String(value)
                            } else {
                                result += "$((\(inner)))"
                            }
                            i = close + 1
                            continue
                        }
                    } else {
                        // $( ... ) command substitution — leave for the app.
                        if let close = findMatching(from: i + 1, chars: chars, open: "(", close: ")") {
                            result += String(chars[i...close])
                            i = close + 1
                            continue
                        }
                    }
                } else if next == "_" || next.isLetter {
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
            result.append(c)
            i += 1
        }
        return result
    }

    private static func findMatching(from: Int, chars: [Character],
                                     open: Character, close: Character) -> Int? {
        var depth = 1
        var i = from + 1
        while i < chars.count {
            if chars[i] == open { depth += 1 }
            else if chars[i] == close {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }
}
