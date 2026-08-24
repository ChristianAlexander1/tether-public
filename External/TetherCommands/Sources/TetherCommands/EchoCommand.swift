import Foundation

public enum EchoCommand: TetherCommand {
    public static let name = "echo"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), newline = true, escapes = false
        while let first = args.first, first == "-n" || first == "-e" || first == "-E" {
            if first == "-n" { newline = false }
            if first == "-e" { escapes = true }
            if first == "-E" { escapes = false }
            args.removeFirst()
        }
        var text = args.joined(separator: " ")
        if escapes { text = decodeEscapes(text) }
        return CommandResult(stdout: text + (newline ? "\n" : ""))
    }
    private static func decodeEscapes(_ value: String) -> String {
        var out = "", iterator = value.makeIterator()
        while let c = iterator.next() {
            guard c == "\\", let n = iterator.next() else { out.append(c); continue }
            switch n { case "n": out.append("\n"); case "t": out.append("\t"); case "r": out.append("\r"); case "\\": out.append("\\"); default: out.append("\\"); out.append(n) }
        }
        return out
    }
}
