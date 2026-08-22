import Foundation
import TermXCommands

/// Registers pure-Swift commands from `TermX/External/TermXCommands` into the engine,
/// adapting `CommandIO` to the fd-based `ProcessContext` model.
public enum ExternalCommands {

    /// Names already provided by `CoreCommands` / `ToolCommands` — keep the in-engine copy.
    private static let skipNames: Set<String> = ["base64"]

    public static func registerAll(into registry: CommandRegistry) {
        for cmdType in TermXCommandRegistry.all {
            guard !skipNames.contains(cmdType.name) else { continue }
            _ = registry.register(name: cmdType.name) { argv in
                run(cmdType, argv: argv)
            }
        }
    }

    private static func run(_ cmdType: any TermXCommand.Type, argv: [String]) -> Int32 {
        let proc = ProcessContext.current
        let cwd = proc?.cwd ?? FileManager.default.currentDirectoryPath
        let environ = proc?.environ ?? [:]
        // Only piped/redirected stdin is consumed; readAllStdin() returns nil for a tty.
        let stdin = CoreCommands.readAllStdin() ?? ""
        let io = CommandIO(argv: argv, stdin: stdin, cwd: cwd, environment: environ)
        let result = cmdType.run(io)
        if !result.stdout.isEmpty {
            proc?.writeStdout(result.stdout)
        }
        if !result.stderr.isEmpty {
            proc?.writeStderr(result.stderr)
        }
        return result.exitCode
    }
}
