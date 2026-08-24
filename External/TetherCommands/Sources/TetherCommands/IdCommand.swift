import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
public enum IdCommand: TetherCommand {
    public static let name = "id"
    public static func run(_ io: CommandIO) -> CommandResult {
        let args = CommandSupport.args(io, command: name)
        let uid = getuid(), gid = getgid()
        let username = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
        let groupname = getgrgid(gid).map { String(cString: $0.pointee.gr_name) } ?? String(gid)
        if args == ["-u"] { return CommandResult(stdout: "\(uid)\n") }
        if args == ["-g"] { return CommandResult(stdout: "\(gid)\n") }
        if args == ["-un"] || args == ["-nu"] { return CommandResult(stdout: username + "\n") }
        if args == ["-gn"] || args == ["-ng"] { return CommandResult(stdout: groupname + "\n") }
        if !args.isEmpty { return CommandSupport.error(name, "unsupported operand or option", usage: true) }
        return CommandResult(stdout: "uid=\(uid)(\(username)) gid=\(gid)(\(groupname))\n")
    }
}
