public enum PrintenvCommand: TetherCommand {
    public static let name = "printenv"
    public static func run(_ io: CommandIO) -> CommandResult {
        let args = CommandSupport.args(io, command: name)
        if args.isEmpty {
            let output = io.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            return CommandResult(stdout: output.isEmpty ? "" : output + "\n")
        }
        let values = args.compactMap { io.environment[$0] }
        return CommandResult(stdout: values.isEmpty ? "" : values.joined(separator: "\n") + "\n", exitCode: values.count == args.count ? 0 : 1)
    }
}
