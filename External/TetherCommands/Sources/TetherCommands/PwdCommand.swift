import Foundation
public enum PwdCommand: TetherCommand {
    public static let name = "pwd"
    public static func run(_ io: CommandIO) -> CommandResult {
        let args = CommandSupport.args(io, command: name)
        if args.contains(where: { $0 != "-L" && $0 != "-P" }) { return CommandSupport.error(name, "invalid option", usage: true) }
        let path = args.contains("-P") ? URL(fileURLWithPath: io.cwd).resolvingSymlinksInPath().path : io.cwd
        return CommandResult(stdout: path + "\n")
    }
}
