import Foundation
public enum ReadlinkCommand: TetherCommand {
    public static let name = "readlink"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), canonical = false, noNewline = false
        while let a = args.first, a.hasPrefix("-") {
            if a == "-f" || a == "-e" { canonical = true }
            else if a == "-n" { noNewline = true }
            else { return CommandSupport.error(name, "invalid option", usage: true) }; args.removeFirst()
        }
        guard args.count == 1 else { return CommandSupport.error(name, "missing operand", usage: true) }
        let path = CommandSupport.path(args[0], cwd: io.cwd)
        do {
            let value = canonical ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path : try FileManager.default.destinationOfSymbolicLink(atPath: path)
            if canonical && !FileManager.default.fileExists(atPath: value) { return CommandSupport.error(name, "\(args[0]): No such file") }
            return CommandResult(stdout: value + (noNewline ? "" : "\n"))
        } catch { return CommandSupport.error(name, "\(args[0]): \(error.localizedDescription)") }
    }
}
