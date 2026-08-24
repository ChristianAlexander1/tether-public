public enum TrueCommand: TetherCommand {
    public static let name = "true"
    public static func run(_ io: CommandIO) -> CommandResult { CommandResult() }
}
