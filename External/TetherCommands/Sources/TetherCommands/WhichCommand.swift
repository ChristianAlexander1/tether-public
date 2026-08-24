import Foundation
public enum WhichCommand: TetherCommand {
    public static let name = "which"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), all = false
        if args.first == "-a" { all = true; args.removeFirst() }
        guard !args.isEmpty else { return CommandSupport.error(name, "missing command", usage: true) }
        var output: [String] = [], missing = false
        for command in args {
            var matches: [String] = []
            if command.contains("/"), let path = CommandSupport.executablePath(command, io: io) { matches = [path] }
            else {
                for part in (io.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false) {
                    let candidate = CommandSupport.path(command, cwd: part.isEmpty ? io.cwd : String(part))
                    if CommandSupport.isExecutable(candidate) { matches.append(candidate); if !all { break } }
                }
            }
            if matches.isEmpty { missing = true } else { output += matches }
        }
        return CommandResult(stdout: output.isEmpty ? "" : output.joined(separator: "\n") + "\n", exitCode: missing ? 1 : 0)
    }
}
