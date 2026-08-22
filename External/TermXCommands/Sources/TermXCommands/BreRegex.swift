import Foundation

/// A regex helper backed by Foundation's `NSRegularExpression` (available on
/// Linux via swift-corelibs-foundation and on macOS). It translates the sed-style
/// Basic-regex group delimiters (`\(` / `\)`) into ICU group delimiters so that
/// `s/pat/repl/` with `\1`…`\9` backreferences and the `&` whole-match token work
/// as expected. `.`, `*`, `+`, `?`, `^`, `$`, and `[… ]` are supported.
struct BreRegex {

    private let regex: NSRegularExpression?
    let patterns: String

    init(_ pattern: String) {
        self.patterns = pattern
        self.regex = try? NSRegularExpression(pattern: BreRegex.translate(pattern), options: [])
    }

    /// Translate BRE `\(…\)` to `(…)` and leave backreferences `\1` intact.
    static func translate(_ p: String) -> String {
        // Convert \( and \) to unescaped parens so they become capture groups.
        var out = ""
        var i = p.startIndex
        while i < p.endIndex {
            let c = p[i]
            if c == "\\", p.index(after: i) < p.endIndex {
                let n = p[p.index(after: i)]
                if n == "(" || n == ")" {
                    out.append(n)
                } else if n == "{" {
                    out.append("{")
                } else {
                    out.append(c); out.append(n)
                }
                i = p.index(i, offsetBy: 2)
            } else {
                out.append(c)
                i = p.index(after: i)
            }
        }
        return out
    }

    struct Match {
        let range: Range<String.Index>
        let captures: [Range<String.Index>]   // groups 1…; index 0 is whole match
    }

    /// Find the first (leftmost) match. `text` must be a Swift String.
    func firstMatch(in text: String) -> Match? {
        guard let regex = regex, !text.isEmpty else { return nil }
        let ns = text as NSString
        let length = ns.length
        let range = NSRange(location: 0, length: length)
        if let first = regex.firstMatch(in: ns as String, options: [], range: range) {
            return makeMatch(first, text: text)
        }
        return nil
    }

    /// Does the pattern match somewhere in `text`?
    func containsMatch(in text: String) -> Bool {
        return firstMatch(in: text) != nil
    }

    private func makeMatch(_ result: NSTextCheckingResult, text: String) -> Match {
        let ns = text as NSString
        let fullRange = result.range
        let fullStart = text.index(text.startIndex, offsetBy: fullRange.location)
        let fullEnd = text.index(fullStart, offsetBy: fullRange.length)
        var captures: [Range<String.Index>] = [fullStart..<fullEnd]
        for g in 1..<result.numberOfRanges {
            let r = result.range(at: g)
            if r.location == NSNotFound || r.length == 0 {
                captures.append(fullStart..<fullStart)
            } else {
                let s = text.index(text.startIndex, offsetBy: r.location)
                let e = text.index(s, offsetBy: r.length)
                captures.append(s..<e)
            }
        }
        return Match(range: fullStart..<fullEnd, captures: captures)
    }

    /// Expand a replacement string substituting `\1`…`\9`, `\0` and `&`.
    /// `match` supplies the captured ranges. Returns the replacement text.
    func expand(_ replacement: String, for match: Match, in text: String) -> String {
        return BreRegex.buildReplacement(replacement, match: match, text: text)
    }

    static func buildReplacement(_ replacement: String, match: Match, text: String) -> String {
        var out = ""
        var i = replacement.startIndex
        while i < replacement.endIndex {
            let c = replacement[i]
            if c == "\\", replacement.index(after: i) < replacement.endIndex {
                let n = replacement[replacement.index(after: i)]
                if let d = n.wholeNumberValue, d < match.captures.count {
                    // captures[0] is the whole match; captures[d] is group d.
                    out += String(text[match.captures[d]])
                } else if n == "\\" {
                    out.append("\\")
                } else {
                    out.append(n)
                }
                i = replacement.index(i, offsetBy: 2)
                continue
            }
            if c == "&" {
                out += String(text[match.captures[0]])
                i = replacement.index(after: i)
                continue
            }
            out.append(c)
            i = replacement.index(after: i)
        }
        return out
    }
}
