import Foundation
public enum DirnameCommand: TetherCommand {
    public static let name = "dirname"
    public static func run(_ io: CommandIO) -> CommandResult {
        let args = CommandSupport.args(io, command: name)
        guard !args.isEmpty else { return CommandSupport.error(name, "missing operand", usage: true) }
        let out = args.map { value -> String in
            if !value.contains("/") { return "." }
            var v = value
            while v.count > 1 && v.hasSuffix("/") { v.removeLast() }
            let result = (v as NSString).deletingLastPathComponent
            return result.isEmpty ? (v.hasPrefix("/") ? "/" : ".") : result
        }.joined(separator: "\n")
        return CommandResult(stdout: out + "\n")
    }
}
