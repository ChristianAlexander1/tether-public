import Foundation

/// POSIX pathname/glob pattern matching shared by `${V#pat}`/`${V%pat}` expansion
/// and `case` patterns. Supports `*`, `?`, and `[ ... ]` character classes with
/// optional `!`/`^` negation and `a-z` ranges.
enum ShellGlob {

    enum MatchResult {
        case noMatch
        /// Character at which the match ended (an index into `string`).
        case end(Int)
    }

    /// Does `pattern` match the *entire* `string`?
    static func matches(pattern: String, string: String) -> Bool {
        let p = Array(pattern).map(String.init)
        let s = Array(string).map(String.init)
        return match(p, 0, s, 0)
    }

    /// Shortest length k (0...count) such that `pattern` matches `String(prefix)`,
    /// or `nil` if no prefix (including the full string) matches.
    /// This is what `${V#pat}` uses (strip the shortest matching prefix).
    static func shortestMatchLength(pattern: String, string: String) -> Int? {
        let p = Array(pattern).map(String.init)
        let s = Array(string).map(String.init)
        for k in 0...s.count {
            if match(p, 0, s, 0, endExclusive: k) { return k }
        }
        return nil
    }

    /// Longest k (0...count) such that `pattern` matches `String(prefix)`.
    /// This is what `${V##pat}` uses.
    static func longestMatchLength(pattern: String, string: String) -> Int? {
        let p = Array(pattern).map(String.init)
        let s = Array(string).map(String.init)
        var result: Int?
        for k in 0...s.count {
            if match(p, 0, s, 0, endExclusive: k) { result = k }
        }
        return result
    }

    /// Longest k such that the *suffix* `String(suffix of length k)` matches pattern.
    /// Used by `${V%pat}` (shortest) and `${V%%pat}` (longest).
    static func suffixMatchLength(pattern: String, string: String, longest: Bool) -> Int? {
        let p = Array(pattern).map(String.init)
        let s = Array(string).map(String.init)
        // Materialise both orderings as [Int] so the ternary has a single type.
        let ks: [Int] = longest
            ? Array(stride(from: s.count, through: 0, by: -1))
            : Array(stride(from: 0, through: s.count, by: 1))
        for k in ks {
            // The suffix of length k starts at s.count - k.
            let start = s.count - k
            if match(p, 0, s, start) { return k }
        }
        return nil
    }

    // MARK: - Core matcher (classic recursion over * / ? / [...])

    /// Match p[pIndex...] against s[sIndex...]. When `endExclusive` is provided,
    /// the part of `s` in range sIndex..<endExclusive must match exactly.
    private static func match(_ p: [String], _ pi: Int, _ s: [String], _ si: Int,
                              endExclusive: Int? = nil) -> Bool {
        let sEnd = endExclusive ?? s.count
        if pi == p.count {
            return si == sEnd
        }
        let c = p[pi]
        if c == "*" {
            // '*' may match zero or more characters (including none).
            let j = pi + 1
            if j == p.count { return true }
            var k = si
            while k <= sEnd {
                if match(p, j, s, k, endExclusive: sEnd) { return true }
                k += 1
            }
            return false
        }
        if si >= sEnd { return false }
        if c == "?" {
            return match(p, pi + 1, s, si + 1, endExclusive: sEnd)
        }
        if c == "[" {
            let clsRes = matchClass(p, pi, s[si])
            if let nextIndex = clsRes {
                return match(p, nextIndex, s, si + 1, endExclusive: sEnd)
            }
            return false
        }
        if c == s[si] {
            return match(p, pi + 1, s, si + 1, endExclusive: sEnd)
        }
        return false
    }

    /// Returns the index in `p` after the class if `char` is in the class,
    /// else nil. Handles `[!...]`/`[^...]` negation and `a-z` ranges.
    private static func matchClass(_ p: [String], _ pi: Int, _ char: String) -> Int? {
        var i = pi + 1
        var negate = false
        if i < p.count, p[i] == "!" || p[i] == "^" {
            negate = true
            i += 1
        }
        var matched = false
        var first = true
        var classClosed = false
        var rangeStart: String?
        while i < p.count {
            if p[i] == "]" && !first {
                classClosed = true
                break
            }
            first = false
            let token = p[i]
            if token == "-", rangeStart != nil, i + 1 < p.count, p[i + 1] != "]" {
                i += 1
                let end = p[i]
                if isCharInRange(char, from: rangeStart!, to: end) { matched = true }
                rangeStart = nil
                i += 1
                continue
            }
            if token == char { matched = true }
            rangeStart = token
            i += 1
        }
        guard classClosed else { return nil }
        let hit = negate ? !matched : matched
        return hit ? i + 1 : nil
    }

    private static func isCharInRange(_ c: String, from a: String, to b: String) -> Bool {
        guard let cv = c.unicodeScalars.first, let av = a.unicodeScalars.first,
              let bv = b.unicodeScalars.first else { return false }
        return cv.value >= av.value && cv.value <= bv.value
    }
}
