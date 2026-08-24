import Foundation
public enum WcCommand: TetherCommand {
    public static let name = "wc"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), flags: Set<Character> = []
        while let first = args.first, first.hasPrefix("-") && first != "-" {
            flags.formUnion(first.dropFirst()); args.removeFirst()
        }
        if flags.isEmpty { flags = ["l", "w", "c"] }
        if !flags.isSubset(of: ["l", "w", "c", "m"]) { return CommandSupport.error(name, "invalid option", usage: true) }
        if args.isEmpty { args = ["-"] }
        var out: [String] = [], errors: [String] = []
        for operand in args {
            do {
                let text = try CommandSupport.read(operand, io: io)
                var fields: [String] = []
                if flags.contains("l") { fields.append(String(text.filter { $0 == "\n" }.count)) }
                if flags.contains("w") { fields.append(String(text.split(whereSeparator: { $0.isWhitespace }).count)) }
                if flags.contains("c") { fields.append(String(text.utf8.count)) }
                if flags.contains("m") { fields.append(String(text.count)) }
                if operand != "-" { fields.append(operand) }
                out.append(fields.joined(separator: " "))
            } catch { errors.append("wc: \(operand): \(error.localizedDescription)") }
        }
        return CommandResult(
            stdout: out.isEmpty ? "" : out.joined(separator: "\n") + "\n",
            stderr: errors.isEmpty ? "" : errors.joined(separator: "\n") + "\n",
            exitCode: errors.isEmpty ? 0 : 1
        )
    }
}
