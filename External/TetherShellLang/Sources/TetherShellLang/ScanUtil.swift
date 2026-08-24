import Foundation

/// Shared, quote-aware scanning helpers operating on a character array.
/// Used both by the lexer (word tokenizing) and by the expansion engine
/// (finding the end of `$( ... )`, `${ ... }`, quotes, backquotes).
enum ScanUtil {

    static func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }
    static func isNameStart(_ c: Character) -> Bool {
        c == "_" || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    }
    static func isNameChar(_ c: Character) -> Bool { isNameStart(c) || isDigit(c) }

    static func isValidName(_ s: String) -> Bool {
        guard let first = s.first, isNameStart(first) else { return false }
        return s.allSatisfy(isNameChar)
    }

    static func isMetachar(_ c: Character) -> Bool {
        switch c {
        case " ", "\t", "\n", "|", "&", ";", "(", ")", "<", ">":
            return true
        default:
            return false
        }
    }

    /// Index just past the closing `'` starting at `start` (which points at the
    /// opening quote). No escape processing inside single quotes.
    static func skipSingleQuoted(_ chars: [Character], from start: Int) throws -> Int {
        var i = start + 1
        while i < chars.count {
            if chars[i] == "'" { return i + 1 }
            i += 1
        }
        throw TetherShellParseError("unterminated single quote", line: -1)
    }

    /// Index just past the closing `"` starting at `start`. Handles backslash
    /// escapes, nested `$( ... )` and backquotes.
    static func skipDoubleQuoted(_ chars: [Character], from start: Int) throws -> Int {
        var i = start + 1
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                i += 2
            } else if c == "\"" {
                return i + 1
            } else if c == "`" {
                i = try skipBackquoted(chars, from: i)
            } else if c == "$", i + 1 < chars.count, chars[i + 1] == "(" {
                i = try skipCommandSub(chars, from: i + 1)
            } else if c == "$", i + 1 < chars.count, chars[i + 1] == "{" {
                i = try skipBraceParam(chars, from: i + 1)
            } else {
                i += 1
            }
        }
        throw TetherShellParseError("unterminated double quote", line: -1)
    }

    /// Index just past the closing backquote starting at `start`.
    static func skipBackquoted(_ chars: [Character], from start: Int) throws -> Int {
        var i = start + 1
        while i < chars.count {
            if chars[i] == "\\" {
                i += 2
            } else if chars[i] == "`" {
                return i + 1
            } else {
                i += 1
            }
        }
        throw TetherShellParseError("unterminated backquote", line: -1)
    }

    /// Index just past the `)` matching the `(` at `start`.
    /// Quote-, backquote- and nested `$( )`-aware.
    static func skipCommandSub(_ chars: [Character], from start: Int) throws -> Int {
        var depth = 1
        var i = start + 1
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                i += 2
            case "'":
                i = try skipSingleQuoted(chars, from: i)
            case "\"":
                i = try skipDoubleQuoted(chars, from: i)
            case "`":
                i = try skipBackquoted(chars, from: i)
            case "(":
                depth += 1
                i += 1
            case ")":
                depth -= 1
                i += 1
                if depth == 0 { return i }
            default:
                i += 1
            }
        }
        throw TetherShellParseError("unterminated $( ... )", line: -1)
    }

    /// Index just past the `}` matching the `{` at `start`. Handles nested
    /// `${ ... }`, quoted `}` characters and embedded `$( ... )`.
    static func skipBraceParam(_ chars: [Character], from start: Int) throws -> Int {
        var depth = 1
        var i = start + 1
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                i += 2
            case "'":
                i = try skipSingleQuoted(chars, from: i)
            case "\"":
                i = try skipDoubleQuoted(chars, from: i)
            case "`":
                i = try skipBackquoted(chars, from: i)
            case "$" where i + 1 < chars.count && chars[i + 1] == "(":
                i = try skipCommandSub(chars, from: i + 1)
            case "{":
                depth += 1
                i += 1
            case "}":
                depth -= 1
                i += 1
                if depth == 0 { return i }
            default:
                i += 1
            }
        }
        throw TetherShellParseError("unterminated ${ ... }", line: -1)
    }
}
