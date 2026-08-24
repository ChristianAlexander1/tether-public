import Foundation
public enum BasenameCommand: TetherCommand {
    public static let name = "basename"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), suffix: String?
        if args.first == "-s", args.count >= 3 { suffix = args[1]; args.removeFirst(2) }
        guard !args.isEmpty else { return CommandSupport.error(name, "missing operand", usage: true) }
        if suffix == nil, args.count == 2 { suffix = args[1]; args = [args[0]] }
        let values = args.map { value -> String in
            var base = URL(fileURLWithPath: value).lastPathComponent
            if base.isEmpty { base = "/" }
            if let suffix, !suffix.isEmpty, base.hasSuffix(suffix) { base.removeLast(suffix.count) }
            return base
        }
        return CommandResult(stdout: values.joined(separator: "\n") + "\n")
    }
}
