import Foundation
public enum LnCommand: TetherCommand {
    public static let name = "ln"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), symbolic = false, force = false
        while let a = args.first, a.hasPrefix("-") {
            if a == "-s" { symbolic = true } else if a == "-f" { force = true } else if a == "-sf" || a == "-fs" { symbolic = true; force = true } else { return CommandSupport.error(name, "invalid option", usage: true) }
            args.removeFirst()
        }
        guard args.count == 2 else { return CommandSupport.error(name, "source and target required", usage: true) }
        let sourcePath = CommandSupport.path(args[0], cwd: io.cwd)
        var targetPath = CommandSupport.path(args[1], cwd: io.cwd)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: targetPath, isDirectory: &isDirectory), isDirectory.boolValue {
            let sourceName = URL(fileURLWithPath: args[0]).lastPathComponent
            targetPath = (targetPath as NSString).appendingPathComponent(sourceName)
        }
        do {
            if force && (FileManager.default.fileExists(atPath: targetPath) || (try? FileManager.default.destinationOfSymbolicLink(atPath: targetPath)) != nil) { try FileManager.default.removeItem(atPath: targetPath) }
            if symbolic { try FileManager.default.createSymbolicLink(atPath: targetPath, withDestinationPath: args[0]) }
            else { try FileManager.default.linkItem(atPath: sourcePath, toPath: targetPath) }
            return CommandResult()
        } catch { return CommandSupport.error(name, error.localizedDescription) }
    }
}
