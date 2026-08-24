import Foundation
public enum MktempCommand: TetherCommand {
    public static let name = "mktemp"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), directory = false, quiet = false, baseDirectory: String?
        var template: String?, i = 0
        while i < args.count {
            if args[i] == "-d" { directory = true; i += 1 }
            else if args[i] == "-q" { quiet = true; i += 1 }
            else if args[i] == "-p", i + 1 < args.count { baseDirectory = args[i + 1]; i += 2 }
            else if args[i].hasPrefix("-") { return CommandSupport.error(name, "invalid option", usage: true) }
            else if template == nil { template = args[i]; i += 1 }
            else { return CommandSupport.error(name, "too many templates", usage: true) }
        }
        let base = baseDirectory.map { CommandSupport.path($0, cwd: io.cwd) } ?? io.cwd
        let pattern = template ?? "tmp.XXXXXXXXXX"
        guard let range = pattern.range(of: "X+$", options: .regularExpression), pattern[range].count >= 3 else { return CommandSupport.error(name, "template must end in at least 3 Xs", usage: true) }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        for _ in 0..<100 {
            let suffix = String((0..<pattern[range].count).map { _ in alphabet.randomElement()! })
            let namePart = pattern.replacingCharacters(in: range, with: suffix)
            let path = CommandSupport.path(namePart, cwd: base)
            guard !FileManager.default.fileExists(atPath: path) else { continue }
            do {
                if directory { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false) }
                else {
                    guard FileManager.default.createFile(atPath: path, contents: Data()) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                return CommandResult(stdout: path + "\n")
            } catch { if !quiet { return CommandSupport.error(name, error.localizedDescription) }; return CommandResult(exitCode: 1) }
        }
        return quiet ? CommandResult(exitCode: 1) : CommandSupport.error(name, "failed to create temporary item")
    }
}
