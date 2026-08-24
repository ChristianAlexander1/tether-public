import Foundation
public enum YesCommand: TetherCommand {
    public static let name = "yes"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), count: Int?
        if args.first == "-n" {
            guard args.count >= 2, let value = Int(args[1]), value >= 0 else {
                return CommandSupport.error(name, "-n requires a nonnegative integer", usage: true)
            }
            count = value
            args.removeFirst(2)
        }
        let configured = Int(io.environment["TETHER_MAX_OUTPUT_LINES"] ?? "1000") ?? 1000
        let maxLines = max(0, count ?? configured)
        let value = args.isEmpty ? "y" : args.joined(separator: " ")
        return CommandResult(stdout: String(repeating: value + "\n", count: maxLines))
    }
}
