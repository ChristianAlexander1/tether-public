import Foundation
public enum SleepCommand: TetherCommand {
    public static let name = "sleep"
    public static func run(_ io: CommandIO) -> CommandResult {
        let args = CommandSupport.args(io, command: name)
        guard !args.isEmpty else { return CommandSupport.error(name, "missing operand", usage: true) }
        var duration = 0.0
        for arg in args { guard let value = CommandSupport.parseDuration(arg) else { return CommandSupport.error(name, "invalid time interval '\(arg)'", usage: true) }; duration += value }
        Thread.sleep(forTimeInterval: duration)
        return CommandResult()
    }
}
