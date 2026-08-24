import Foundation
public enum RealpathCommand: TetherCommand {
    public static let name = "realpath"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), allowMissing = false
        if args.first == "-m" { allowMissing = true; args.removeFirst() }
        guard !args.isEmpty else { return CommandSupport.error(name, "missing operand", usage: true) }
        var out: [String] = [], errors: [String] = []
        for operand in args {
            let path = URL(fileURLWithPath: CommandSupport.path(operand, cwd: io.cwd)).resolvingSymlinksInPath().standardizedFileURL.path
            if allowMissing || FileManager.default.fileExists(atPath: path) { out.append(path) } else { errors.append("realpath: \(operand): No such file or directory") }
        }
        return CommandResult(stdout: out.isEmpty ? "" : out.joined(separator: "\n") + "\n", stderr: errors.isEmpty ? "" : errors.joined(separator: "\n") + "\n", exitCode: errors.isEmpty ? 0 : 1)
    }
}
