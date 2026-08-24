import Foundation
import TermXCommands
import TetherCommands

/// Registers pure-Swift commands from `External/TermXCommands` and `External/TetherCommands`
/// into the engine, adapting `CommandIO` to the fd-based `ProcessContext` model.
public enum ExternalCommands {

    /// Names already provided by `CoreCommands` / `ToolCommands` — keep the in-engine copy.
    private static let skipNames: Set<String> = ["base64"]

    /// TermXCommands wins on name collisions (sed, awk, stat, …).
    private static var termXNames: Set<String> {
        // Avoid a key-path over an existential metatype here. Swift 6.2.3 crashes
        // in SILGen when lowering `map(\.name)` for `[any TermXCommand.Type]`.
        // The closure is equivalent and compiles on both Swift 5.10 and Swift 6.
        Set(TermXCommandRegistry.all.map { $0.name })
    }

    public static func registerAll(into registry: CommandRegistry) {
        for cmdType in TermXCommandRegistry.all {
            guard !skipNames.contains(cmdType.name) else { continue }
            _ = registry.register(name: cmdType.name) { argv in
                runTermX(cmdType, argv: argv)
            }
        }
        for (name, cmdType) in TetherCommandRegistry.all {
            guard !skipNames.contains(name), !termXNames.contains(name) else { continue }
            _ = registry.register(name: name) { argv in
                runTether(cmdType, argv: argv)
            }
        }
    }

    private static func runTermX(_ cmdType: any TermXCommand.Type, argv: [String]) -> Int32 {
        let proc = ProcessContext.current
        let cwd = proc?.cwd ?? FileManager.default.currentDirectoryPath
        let environ = proc?.environ ?? [:]
        let stdin = CoreCommands.readAllStdin() ?? ""
        let io = TermXCommands.CommandIO(argv: argv, stdin: stdin, cwd: cwd, environment: environ)
        let result = cmdType.run(io)
        if !result.stdout.isEmpty { proc?.writeStdout(result.stdout) }
        if !result.stderr.isEmpty { proc?.writeStderr(result.stderr) }
        return result.exitCode
    }

    private static func runTether(_ cmdType: TetherCommand.Type, argv: [String]) -> Int32 {
        let proc = ProcessContext.current
        let cwd = proc?.cwd ?? FileManager.default.currentDirectoryPath
        let environ = proc?.environ ?? [:]
        let stdin = CoreCommands.readAllStdin() ?? ""
        let io = TetherCommands.CommandIO(argv: argv, stdin: stdin, cwd: cwd, environment: environ)
        let result = cmdType.run(io)
        if !result.stdout.isEmpty { proc?.writeStdout(result.stdout) }
        if !result.stderr.isEmpty { proc?.writeStderr(result.stderr) }
        return result.exitCode
    }
}
