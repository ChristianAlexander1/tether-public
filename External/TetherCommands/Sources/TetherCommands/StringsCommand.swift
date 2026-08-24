import Foundation
public enum StringsCommand: TetherCommand {
    public static let name = "strings"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), minimum = 4
        if args.first == "-n", args.count >= 2 { minimum = Int(args[1]) ?? 0; args.removeFirst(2) }
        else if let first = args.first, first.hasPrefix("-") && Int(first.dropFirst()) != nil { minimum = Int(first.dropFirst())!; args.removeFirst() }
        guard minimum > 0 else { return CommandSupport.error(name, "invalid minimum length", usage: true) }
        if args.isEmpty { args = ["-"] }
        var found: [String] = [], errors: [String] = []
        for operand in args {
            do {
                let data: Data = operand == "-" ? Data(io.stdin.utf8) : try Data(contentsOf: URL(fileURLWithPath: CommandSupport.path(operand, cwd: io.cwd)))
                var current: [UInt8] = []
                func flush() { if current.count >= minimum { found.append(String(decoding: current, as: UTF8.self)) }; current.removeAll() }
                for byte in data { if byte >= 32 && byte <= 126 || byte == 9 { current.append(byte) } else { flush() } }; flush()
            } catch { errors.append("strings: \(operand): \(error.localizedDescription)") }
        }
        return CommandResult(stdout: found.isEmpty ? "" : found.joined(separator: "\n") + "\n", stderr: errors.isEmpty ? "" : errors.joined(separator: "\n") + "\n", exitCode: errors.isEmpty ? 0 : 1)
    }
}
