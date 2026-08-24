import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
public enum WhoamiCommand: TetherCommand {
    public static let name = "whoami"
    public static func run(_ io: CommandIO) -> CommandResult {
        let args = CommandSupport.args(io, command: name)
        guard args.isEmpty else { return CommandSupport.error(name, "extra operand", usage: true) }
        if let entry = getpwuid(geteuid()) { return CommandResult(stdout: String(cString: entry.pointee.pw_name) + "\n") }
        return CommandSupport.error(name, "cannot find name for user ID")
    }
}
