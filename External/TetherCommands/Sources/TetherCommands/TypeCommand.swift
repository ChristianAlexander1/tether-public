import Foundation
public enum TypeCommand: TetherCommand {
    public static let name = "type"
    public static func run(_ io: CommandIO) -> CommandResult {
        let args = CommandSupport.args(io, command: name)
        guard !args.isEmpty else { return CommandSupport.error(name, "missing command", usage: true) }
        var out: [String] = [], err: [String] = []
        for command in args {
            if TetherCommandRegistry.all[command] != nil { out.append("\(command) is a Tether command") }
            else if let path = CommandSupport.executablePath(command, io: io) { out.append("\(command) is \(path)") }
            else { err.append("type: \(command): not found") }
        }
        return CommandResult(stdout: out.isEmpty ? "" : out.joined(separator: "\n") + "\n", stderr: err.isEmpty ? "" : err.joined(separator: "\n") + "\n", exitCode: err.isEmpty ? 0 : 1)
    }
}
