import Foundation

/// Registers every command implemented in this module. The app can look up a
/// command by name to dispatch; the test suite uses the same registry.
extension TermXCommandRegistry {
    public static let all: [any TermXCommand.Type] = [
        // Priority 1
        SedCommand.self,
        AwkCommand.self,
        DiffCommand.self,
        ChmodCommand.self,
        StatCommand.self,
        ReadlinkCommand.self,
        MktempCommand.self,
        // Priority 2
        TacCommand.self,
        RevCommand.self,
        NlCommand.self,
        PasteCommand.self,
        FoldCommand.self,
        ExpandCommand.self,
        UnexpandCommand.self,
        PrintenvCommand.self,
        IdCommand.self,
        SplitCommand.self,
        CommCommand.self,
        JoinCommand.self,
        ShufCommand.self,
        ExprCommand.self,
        Md5sumCommand.self,
        ShasumCommand.self,
        XxdCommand.self,
        HexdumpCommand.self,
        FileCommand.self,
        TruncateCommand.self,
        TreeCommand.self,
        Base64Command.self,
        TimeoutCommand.self,
    ]

    public static func command(named: String) -> (any TermXCommand.Type)? {
        return all.first { $0.name == named }
    }
}
