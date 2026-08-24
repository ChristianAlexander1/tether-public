import Foundation

/// A single shell pattern (`case` alternatives, `${var#pat}` trimming,
/// pathname expansion) compiled to a token list. Quoted pattern characters
/// arrive as `.literal`, so quoting "disarms" wildcards as POSIX requires.
public enum TetherPatToken {
    case literal(Character)
    case anyString                       // *
    case anyChar                         // ?
    case charClass(negated: Bool, items: [TetherPatClassItem])
}

public enum TetherPatClassItem {
    case char(Character)
    case range(Character, Character)
}

public enum TetherGlob {

    /// Builds pattern tokens from an *unquoted* piece of text where wildcard
    /// characters are active.
    public static func tokens(fromUnquoted text: String) -> [TetherPatToken] {
        let chars = Array(text)
        var out: [TetherPatToken] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                out.append(.anyString); i += 1
            case "?":
                out.append(.anyChar); i += 1
            case "[":
                if let (item, next) = parseClass(chars, from: i) {
                    out.append(item); i = next
                } else {
                    out.append(.literal("[")); i += 1
                }
            default:
                out.append(.literal(c)); i += 1
            }
        }
        return out
    }

    public static func literals(_ text: String) -> [TetherPatToken] {
        text.map { .literal($0) }
    }

    public static func hasWildcards(_ tokens: [TetherPatToken]) -> Bool {
        tokens.contains { tok in
            if case .literal = tok { return false }
            return true
        }
    }

    private static func parseClass(_ chars: [Character], from start: Int)
        -> (TetherPatToken, Int)?
    {
        var i = start + 1
        guard i < chars.count else { return nil }
        var negated = false
        if chars[i] == "!" || chars[i] == "^" {
            negated = true; i += 1
        }
        var items: [TetherPatClassItem] = []
        // A `]` as the very first class character is a literal.
        var first = true
        while i < chars.count {
            let c = chars[i]
            if c == "]", !first {
                guard !items.isEmpty || negated else { return nil }
                return (.charClass(negated: negated, items: items), i + 1)
            }
            first = false
            if i + 2 < chars.count, chars[i + 1] == "-", chars[i + 2] != "]" {
                items.append(.range(c, chars[i + 2]))
                i += 3
            } else {
                items.append(.char(c))
                i += 1
            }
        }
        return nil // unterminated `[` → caller treats it as a literal
    }

    private static func matchOne(_ token: TetherPatToken, _ c: Character) -> Bool {
        switch token {
        case .literal(let l):
            return l == c
        case .anyString:
            return false // handled by the backtracking driver
        case .anyChar:
            return true
        case .charClass(let negated, let items):
            var hit = false
            for item in items {
                switch item {
                case .char(let x) where x == c: hit = true
                case .range(let lo, let hi) where lo <= c && c <= hi: hit = true
                default: break
                }
                if hit { break }
            }
            return negated ? !hit : hit
        }
    }

    /// Classic iterative glob match with `*` backtracking.
    public static func match(_ pattern: [TetherPatToken], _ string: String) -> Bool {
        let s = Array(string)
        var p = 0, si = 0
        var starP: Int? = nil, starS = 0
        while si < s.count {
            if p < pattern.count {
                if case .anyString = pattern[p] {
                    starP = p; starS = si; p += 1
                    continue
                }
                if matchOne(pattern[p], s[si]) {
                    p += 1; si += 1
                    continue
                }
            }
            if let sp = starP {
                p = sp + 1; starS += 1; si = starS
            } else {
                return false
            }
        }
        while p < pattern.count {
            if case .anyString = pattern[p] { p += 1 } else { return false }
        }
        return true
    }
}
