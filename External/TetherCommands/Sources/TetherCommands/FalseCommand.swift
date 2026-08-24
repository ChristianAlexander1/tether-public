public enum FalseCommand: TetherCommand {
    public static let name = "false"
    public static func run(_ io: CommandIO) -> CommandResult { CommandResult(exitCode: 1) }
}
