import Foundation
public enum PrintfCommand: TetherCommand {
    public static let name = "printf"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name)
        if args.first == "--" { args.removeFirst() }
        guard !args.isEmpty else { return CommandSupport.error(name, "missing format operand", usage: true) }
        let format = args.removeFirst(), arguments = args
        var output = "", consumed = 0, firstPass = true
        repeat {
            let pass = render(format, args: arguments, start: consumed)
            output += pass.text; consumed = pass.next
            if pass.stop { break }
            if pass.conversions == 0 { break }
            firstPass = false
        } while consumed < arguments.count || firstPass
        return CommandResult(stdout: output)
    }
    private static func render(_ format: String, args: [String], start: Int) -> (text: String, next: Int, conversions: Int, stop: Bool) {
        let chars = Array(format); var out = "", i = 0, argIndex = start, conversions = 0, stop = false
        while i < chars.count {
            if chars[i] == "\\" {
                let decoded = escape(chars, at: &i); out += decoded.text; if decoded.stop { stop = true; break }; continue
            }
            guard chars[i] == "%" else { out.append(chars[i]); i += 1; continue }
            if i + 1 < chars.count, chars[i + 1] == "%" { out.append("%"); i += 2; continue }
            let begin = i; i += 1
            while i < chars.count, "-+ 0#".contains(chars[i]) { i += 1 }
            while i < chars.count, chars[i].isNumber { i += 1 }
            if i < chars.count, chars[i] == "." { i += 1; while i < chars.count, chars[i].isNumber { i += 1 } }
            while i < chars.count, "hlLzjt".contains(chars[i]) { i += 1 }
            guard i < chars.count else { out += String(chars[begin...]); break }
            let conversion = chars[i], spec = String(chars[begin...i]); i += 1; conversions += 1
            let value = argIndex < args.count ? args[argIndex] : ""; argIndex += 1
            switch conversion {
            case "s": out += applyStringWidth(value, spec: spec)
            case "c": out += value.first.map(String.init) ?? ""
            case "d", "i": out += String(format: spec, Int64(value) ?? 0)
            case "u": out += String(format: spec, UInt64(value) ?? 0)
            case "o", "x", "X": out += String(format: spec, UInt64(value) ?? 0)
            case "f", "F", "e", "E", "g", "G": out += String(format: spec, Double(value) ?? 0)
            case "b":
                var j = 0, expanded = "", source = Array(value)
                while j < source.count { if source[j] == "\\" { let decoded = escape(source, at: &j); expanded += decoded.text; if decoded.stop { stop = true; break } } else { expanded.append(source[j]); j += 1 } }
                out += expanded
            default: out += spec
            }
            if stop { break }
        }
        return (out, argIndex, conversions, stop)
    }
    private static func escape(_ chars: [Character], at index: inout Int) -> (text: String, stop: Bool) {
        index += 1; guard index < chars.count else { return ("\\", false) }
        let c = chars[index]; index += 1
        switch c { case "a": return ("\u{7}", false); case "b": return ("\u{8}", false); case "c": return ("", true); case "e": return ("\u{1b}", false); case "f": return ("\u{c}", false); case "n": return ("\n", false); case "r": return ("\r", false); case "t": return ("\t", false); case "v": return ("\u{b}", false); case "\\": return ("\\", false); default: return ("\\" + String(c), false) }
    }
    private static func applyStringWidth(_ value: String, spec: String) -> String {
        let numbers = spec.dropFirst().prefix { $0.isNumber || $0 == "-" }
        guard let width = Int(numbers.filter(\.isNumber)), width > value.count else { return value }
        let padding = String(repeating: " ", count: width - value.count)
        return spec.contains("-") ? value + padding : padding + value
    }
}
