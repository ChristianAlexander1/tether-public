import Foundation

/// Expands a single word's `${ ... }` forms:
///
///     ${V}          ${V:-d}   ${V:=d}   ${V:?msg}   ${V:+alt}
///     ${#V}         ${V:off}  ${V:off:len}
///     ${V#pat}      ${V##pat} ${V%pat}  ${V%%pat}
///     ${V/a/b}      ${V//a/b}
///
/// `$VAR`, `$(...)` and `$((...))` are left untouched — other layers handle them.
/// Patterns (`pat`) are shell globs (`*`, `?`, `[...]`). `:?` (and `?`) throw.
public enum ParameterExpander {

    public static func expand(_ word: String,
                              variables: inout [String: String]) throws -> String {
        var result = ""
        var i = word.startIndex
        while i < word.endIndex {
            let c = word[i]
            if c == "$", word.index(after: i) < word.endIndex,
               word[word.index(after: i)] == "{" {
                // Find matching '}'.
                guard let close = findClosingBrace(in: word, from: word.index(i, offsetBy: 2)) else {
                    result.append("${")
                    i = word.index(after: i)
                    continue
                }
                let contentStart = word.index(i, offsetBy: 2)
                let content = String(word[contentStart..<close])
                let expanded = try expandBraced(content, variables: &variables)
                result += expanded
                i = word.index(after: close)
            } else {
                result.append(c)
                i = word.index(after: i)
            }
        }
        return result
    }

    // MARK: - ${...} content handling

    private static func expandBraced(_ content: String,
                                     variables: inout [String: String]) throws -> String {
        // Special: ${#V} length form (content begins with '#' and the rest a name).
        if content.hasPrefix("#") {
            let rest = String(content.dropFirst())
            if let name = leadingIdentifier(rest), name.count == rest.count {
                let v = variables[name] ?? ""
                return String(v.count)
            }
        }

        guard let name = leadingIdentifier(content) else {
            // Not a valid ${...} expansion — leave the braces intact.
            return "${" + content + "}"
        }

        let nameEnd = content.index(content.startIndex, offsetBy: name.count)
        let rest = String(content[nameEnd...])

        if rest.isEmpty {
            return variables[name] ?? ""
        }

        let first = rest.first!

        // ${V:-d}, ${V:=d}, ${V:?msg}, ${V:+alt}  (with ':': test set AND non-empty)
        if first == ":" {
            if rest.count >= 2 {
                let op = String(rest[rest.index(after: rest.startIndex)])
                if ["-", "=", "?", "+"].contains(op) {
                    let word = String(rest.dropFirst(2))
                    return try applyParameterOp(name, op, word, variables: &variables, requireNonNull: true)
                }
            }
            // Substring form ${V:offset} / ${V:offset:length}.
            let spec = String(rest.dropFirst())
            return try applySubstring(name, spec, variables: &variables)
        }

        // ${V-d}, ${V=d}, ${V?msg}, ${V+alt}  (no ':': test only SET-ness)
        if ["-", "=", "?", "+"].contains(first) {
            let op = String(first)
            let word = String(rest.dropFirst())
            return try applyParameterOp(name, op, word, variables: &variables, requireNonNull: false)
        }

        // ${V#pat} / ${V##pat}
        if first == "#" {
            let longest = rest.hasPrefix("##")
            let pat = String(rest.dropFirst(longest ? 2 : 1))
            let value = variables[name] ?? ""
            if let k = longest
                ? ShellGlob.longestMatchLength(pattern: pat, string: value)
                : ShellGlob.shortestMatchLength(pattern: pat, string: value) {
                return String(value.dropFirst(k))
            }
            return value
        }

        // ${V%pat} / ${V%%pat}
        if first == "%" {
            let longest = rest.hasPrefix("%%")
            let pat = String(rest.dropFirst(longest ? 2 : 1))
            let value = variables[name] ?? ""
            if let k = ShellGlob.suffixMatchLength(pattern: pat, string: value, longest: longest) {
                return String(value.dropLast(k))
            }
            return value
        }

        // ${V/a/b} / ${V//a/b}
        if first == "/" {
            let all = rest.hasPrefix("//")
            let body = String(rest.dropFirst(all ? 2 : 1))
            let slashIndex = body.firstIndex(of: "/")
            let pattern: String
            let replacement: String
            if let idx = slashIndex {
                pattern = String(body[..<idx])
                replacement = String(body[body.index(after: idx)...])
            } else {
                pattern = body
                replacement = ""
            }
            let value = variables[name] ?? ""
            return try substitute(value: value, pattern: pattern, replacement: replacement,
                                  replaceAll: all, variables: &variables)
        }

        return variables[name] ?? ""
    }

    /// `requireNonNull == true` for the `:` form (tests set AND non-empty);
    /// `false` for the plain form (tests only whether the variable is declared).
    private static func applyParameterOp(_ name: String, _ op: String, _ word: String,
                                         variables: inout [String: String],
                                         requireNonNull: Bool) throws -> String {
        // The operand word is itself subject to ${...} expansion.
        let expandedWord = try expand(word, variables: &variables)
        let isSet = variables[name] != nil
        let isEmpty = (variables[name] ?? "").isEmpty
        // "null" means we should fall back / error.
        let isNull = requireNonNull ? (!isSet || isEmpty) : !isSet
        let useDefault = (op == "-" || op == "=") && isNull
        let useAlt = (op == "+") && (requireNonNull ? (isSet && !isEmpty) : isSet)

        switch op {
        case "-":
            return useDefault ? expandedWord : (variables[name] ?? "")
        case "+":
            return useAlt ? expandedWord : ""
        case "=":
            if isNull {
                variables[name] = expandedWord
            }
            return variables[name] ?? ""
        case "?":
            if isNull {
                let msg = expandedWord.isEmpty ? "parameter null or not set" : expandedWord
                throw ShellLangError.parameterUnset("\(name): \(msg)")
            }
            return variables[name] ?? ""
        default:
            return variables[name] ?? ""
        }
    }

    private static func applySubstring(_ name: String, _ spec: String,
                                       variables: inout [String: String]) throws -> String {
        let value = variables[name] ?? ""
        let chars = Array(value)
        let parts = spec.components(separatedBy: ":")
        let offsetStr = parts.count >= 1 ? parts[0] : "0"
        let lengthStr = parts.count >= 2 ? parts[1] : nil

        // Offsets/lengths may reference other variables (e.g. ${V:$start}), so
        // expand them first, then evaluate as arithmetic.
        let offsetText = try expand(offsetStr, variables: &variables).trimmingCharacters(in: .whitespaces)
        guard var offset = parseArith(offsetText, variables: variables) else {
            return value
        }
        let length: Int?
        if let lengthStr = lengthStr {
            let lenText = try expand(lengthStr, variables: &variables).trimmingCharacters(in: .whitespaces)
            guard let l = parseArith(lenText, variables: variables) else { return value }
            length = l
        } else {
            length = nil
        }
        if offset < 0 {
            offset += chars.count
        }
        // Clamp negative to 0.
        if offset < 0 { offset = 0 }
        if offset > chars.count { return "" }
        if let length = length {
            if length < 0 {
                // Negative length: starts at max(0, offset+length) ends at offset.
                var lo = offset + length
                if lo < 0 { lo = 0 }
                let hi = offset
                if lo >= chars.count || hi <= lo { return "" }
                return String(chars[lo..<min(chars.count, hi)])
            }
            let endIndex = min(offset + length, chars.count)
            if endIndex <= offset { return "" }
            return String(chars[offset..<endIndex])
        }
        return String(chars[offset...])
    }

    /// Substitution: replace occurrences of `pattern` (a glob) with `replacement`.
    private static func substitute(value: String, pattern: String, replacement: String,
                                   replaceAll: Bool,
                                   variables: inout [String: String]) throws -> String {
        if pattern.isEmpty {
            return replaceAll ? value : value
        }
        let chars = Array(value)
        var result = ""
        var i = 0
        let expandedReplacement = try expand(replacement, variables: &variables)

        // Determine how long a match at each position can be (glob).
        func matchLen(at pos: Int) -> Int? {
            // Longest glob match starting at pos.
            var best: Int?
            for k in 0...(chars.count - pos) {
                let sub = String(chars[pos..<(pos + k)])
                if ShellGlob.matches(pattern: pattern, string: sub) {
                    best = k
                }
            }
            return best
        }

        var replacedOnce = false
        while i < chars.count {
            guard let mlen = matchLen(at: i) else {
                result.append(chars[i])
                i += 1
                continue
            }
            // Match found at i..<i+mlen.
            result += expandedReplacement
            i += mlen
            if !replaceAll {
                replacedOnce = true
                break
            }
        }
        if replacedOnce && !replaceAll {
            // Append the rest untouched.
            if i <= chars.count {
                result += String(chars[i...])
            }
        } else if !replaceAll {
            // No match found -> unchanged.
            return value
        }
        return result
    }

    // MARK: - Helpers

    private static func leadingIdentifier(_ s: String) -> String? {
        var name = ""
        for c in s {
            if c.isLetter || c == "_" || (name.isEmpty ? c.isLetter || c == "_" : (c.isNumber || c.isLetter || c == "_")) {
                name.append(c)
            } else {
                break
            }
        }
        return name.isEmpty ? nil : name
    }

    /// Find the index of the matching '}' for a ${...} group, honoring nesting.
    private static func findClosingBrace(in word: String, from start: String.Index) -> String.Index? {
        var depth = 1
        var i = start
        while i < word.endIndex {
            let c = word[i]
            if c == "$", word.index(after: i) < word.endIndex,
               word[word.index(after: i)] == "{" {
                depth += 1
                i = word.index(i, offsetBy: 2)
                continue
            }
            if c == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = word.index(after: i)
        }
        return nil
    }

    /// Evaluate a small integer expression for offsets/lengths. Uses the
    /// ArithmeticEvaluator with the surrounding shell variables in scope.
    private static func parseArith(_ s: String, variables: [String: String]) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        // Arithmetic context: `$start` and `start` are the same reference, so strip the
        // sigil (and `${start}` braces) before evaluating.
        let stripped = trimmed
            .replacingOccurrences(of: "\\$\\{([A-Za-z_][A-Za-z0-9_]*)\\}",
                                  with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\$([A-Za-z_][A-Za-z0-9_]*)",
                                  with: "$1", options: .regularExpression)
        var scope = variables
        return try? ArithmeticEvaluator.evaluate(stripped, variables: &scope)
    }
}
