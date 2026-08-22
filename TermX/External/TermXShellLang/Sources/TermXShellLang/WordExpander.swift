import Foundation

/// Brace and tilde expansion.
public enum WordExpander {

    // MARK: - Brace expansion

    /// Expands all brace groups in a word in shell order:
    ///
    ///     {a,b,c}      {1..9}      {a..e}      {1..9..2}
    ///
    /// Supports nesting and multiple groups per word. Groups that are not valid
    /// brace expressions (no comma and not a range, e.g. `{a}`) are left literal.
    public static func expandBraces(_ word: String) -> [String] {
        guard let group = findFirstGroup(word) else { return [word] }
        let content = group.content

        if let alts = parseAlternatives(content) {
            let prefix = group.prefix
            let suffix = group.suffix
            var result: [String] = []
            for alt in alts {
                for sub in expandBraces(alt) {
                    let candidate = prefix + sub + suffix
                    result += expandBraces(candidate)
                }
            }
            return result
        } else {
            // Invalid group (e.g. `{a}`): keep it literally, expand later groups.
            let literalGroup = "{\(content)}"
            let subResults = expandBraces(group.suffix)
            return subResults.map { group.prefix + literalGroup + $0 }
        }
    }

    private struct Group {
        let prefix: String
        let content: String
        let suffix: String
    }

    /// Locate the first (leftmost) unescaped `{ ... }` pair, honoring nesting.
    private static func findFirstGroup(_ word: String) -> Group? {
        let chars = Array(word)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "{" {
                var depth = 1
                var j = i + 1
                while j < chars.count {
                    if chars[j] == "\\" { j += 2; continue }
                    if chars[j] == "{" { depth += 1 }
                    else if chars[j] == "}" {
                        depth -= 1
                        if depth == 0 {
                            let prefix = String(chars[0..<i])
                            let content = String(chars[(i + 1)..<j])
                            let suffix = String(chars[(j + 1)...])
                            return Group(prefix: prefix, content: content, suffix: suffix)
                        }
                    }
                    j += 1
                }
                // No matching close — treat '{' literally and keep scanning.
                i += 1
                continue
            }
            i += 1
        }
        return nil
    }

    /// Split a brace group's content into its alternatives, or a sequence for a
    /// `start..end[..step]` range. Returns nil when the group is not expandable.
    private static func parseAlternatives(_ content: String) -> [String]? {
        if let sequence = parseRange(content) { return sequence }
        let parts = splitTopLevelCommas(content)
        if parts.count > 1 { return parts }
        return nil
    }

    private static func parseRange(_ content: String) -> [String]? {
        let tokens = content.components(separatedBy: "..")
        guard tokens.count == 2 || tokens.count == 3 else { return nil }
        let start = tokens[0]
        let end = tokens[1]
        let step: Int?
        if tokens.count == 3 {
            guard let s = Int(tokens[2]) else { return nil }
            step = s
        } else {
            step = nil
        }

        // Numeric range.
        if let s = Int(start), let e = Int(end) {
            return generateRange(from: s, to: e, step: step).map { String($0) }
        }
        // Single-letter alphabetic range.
        if let sc = start.first, let ec = end.first, start.count == 1, end.count == 1 {
            let stepN = step ?? 1
            guard stepN != 0 else { return nil }
            // Use the magnitude of the step (so a negative step just reverses
            // direction but still works), guarded against overflow/underflow.
            let stepMag = UInt32(abs(stepN))
            let startScalar = sc.unicodeScalars.first!.value
            let endScalar = ec.unicodeScalars.first!.value
            var result: [String] = []
            if startScalar <= endScalar {
                var v = startScalar
                while v <= endScalar {
                    result.append(String(UnicodeScalar(v)!))
                    if v > UInt32.max - stepMag { break }
                    v += stepMag
                }
            } else {
                var v = startScalar
                while v >= endScalar {
                    result.append(String(UnicodeScalar(v)!))
                    if v < stepMag { break }
                    v -= stepMag
                }
            }
            return result
        }
        return nil
    }

    private static func generateRange(from start: Int, to end: Int, step: Int?) -> [Int] {
        let stp = (step ?? 1)
        guard stp != 0 else { return [] }
        var result: [Int] = []
        if start <= end {
            var v = start
            while v <= end { result.append(v); v += abs(stp) }
        } else {
            var v = start
            while v >= end { result.append(v); v -= abs(stp) }
        }
        return result
    }

    /// Split on commas at the top nesting level (braces inside are preserved).
    private static func splitTopLevelCommas(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                current.append(c)
                if s.index(after: i) < s.endIndex {
                    current.append(s[s.index(after: i)])
                    i = s.index(i, offsetBy: 2)
                    continue
                }
            } else if c == "{" {
                depth += 1
                current.append(c)
            } else if c == "}" {
                depth -= 1
                current.append(c)
            } else if c == "," && depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i = s.index(after: i)
        }
        parts.append(current)
        return parts
    }

    // MARK: - Tilde expansion

    /// Expands `~` and `~/path` using `home`. Unknown `~user` is returned unchanged.
    public static func expandTilde(_ word: String, home: String) -> String {
        if word == "~" { return home }
        if word.hasPrefix("~/") {
            return home + "/" + String(word.dropFirst(2))
        }
        // `~user` / `~user/...` are not resolvable -> leave unchanged.
        if word.hasPrefix("~") {
            return word
        }
        return word
    }
}
