import Foundation
public enum StatCommand: TetherCommand {
    public static let name = "stat"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), format: String?
        if args.first == "-c" || args.first == "-f", args.count >= 2 { format = args[1]; args.removeFirst(2) }
        guard !args.isEmpty else { return CommandSupport.error(name, "missing operand", usage: true) }
        var out: [String] = [], errors: [String] = []
        for operand in args {
            do {
                let path = CommandSupport.path(operand, cwd: io.cwd), a = try FileManager.default.attributesOfItem(atPath: path)
                let size = (a[.size] as? NSNumber)?.uint64Value ?? 0, mode = CommandSupport.modeString(a), type = (a[.type] as? FileAttributeType)?.rawValue ?? "unknown"
                let modified = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                if var format {
                    format = format.replacingOccurrences(of: "%n", with: operand).replacingOccurrences(of: "%s", with: String(size)).replacingOccurrences(of: "%F", with: type).replacingOccurrences(of: "%A", with: mode).replacingOccurrences(of: "%Y", with: String(Int64(modified)))
                    out.append(format)
                } else { out.append("  File: \(operand)\n  Size: \(size)\tType: \(type)\nAccess: (\(mode))\nModify: \(Int64(modified))") }
            } catch { errors.append("stat: \(operand): \(error.localizedDescription)") }
        }
        return CommandResult(stdout: out.isEmpty ? "" : out.joined(separator: "\n") + "\n", stderr: errors.isEmpty ? "" : errors.joined(separator: "\n") + "\n", exitCode: errors.isEmpty ? 0 : 1)
    }
}
