import Foundation
public enum TeeCommand: TetherCommand {
    public static let name = "tee"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), append = false
        if args.first == "-a" || args.first == "--append" { append = true; args.removeFirst() }
        var errors = ""
        for file in args {
            do { try CommandSupport.write(io.stdin, to: CommandSupport.path(file, cwd: io.cwd), append: append) }
            catch { errors += "tee: \(file): \(error.localizedDescription)\n" }
        }
        return CommandResult(stdout: io.stdin, stderr: errors, exitCode: errors.isEmpty ? 0 : 1)
    }
}
