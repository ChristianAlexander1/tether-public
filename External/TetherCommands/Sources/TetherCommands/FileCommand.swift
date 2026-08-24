import Foundation
public enum FileCommand: TetherCommand {
    public static let name = "file"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), brief = false
        if args.first == "-b" { brief = true; args.removeFirst() }
        guard !args.isEmpty else { return CommandSupport.error(name, "missing operand", usage: true) }
        var out: [String] = [], failed = false
        for operand in args {
            let path = CommandSupport.path(operand, cwd: io.cwd)
            let prefix = brief ? "" : "\(operand): "
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path), type = attributes[.type] as? FileAttributeType
                let description: String
                if type == .typeDirectory { description = "directory" }
                else if type == .typeSymbolicLink { description = "symbolic link to `\((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "?")'" }
                else {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
                    if data.isEmpty { description = "empty" }
                    else if data.starts(with: [0x7f, 0x45, 0x4c, 0x46]) { description = "ELF binary" }
                    else if data.starts(with: [0x89, 0x50, 0x4e, 0x47]) { description = "PNG image data" }
                    else if data.contains(0) { description = "data" }
                    else if String(data: data, encoding: .utf8) != nil { description = "Unicode text, UTF-8 text" }
                    else { description = "data" }
                }
                out.append(prefix + description)
            } catch { failed = true; out.append(prefix + "cannot open (\(error.localizedDescription))") }
        }
        return CommandResult(stdout: out.joined(separator: "\n") + "\n", exitCode: failed ? 1 : 0)
    }
}
