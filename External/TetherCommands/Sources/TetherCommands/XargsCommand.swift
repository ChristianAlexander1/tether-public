import Foundation
public enum XargsCommand: TetherCommand {
    public static let name = "xargs"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), maxArgs: Int?, replacement: String?, noRunIfEmpty = false
        var command: [String] = [], i = 0
        while i < args.count {
            if args[i] == "-n" {
                guard i + 1 < args.count, let value = Int(args[i + 1]), value > 0 else {
                    return CommandSupport.error(name, "-n requires a positive integer", usage: true)
                }
                maxArgs = value; i += 2
            }
            else if args[i] == "-I" {
                guard i + 1 < args.count, !args[i + 1].isEmpty else {
                    return CommandSupport.error(name, "-I requires a replacement string", usage: true)
                }
                replacement = args[i + 1]; i += 2
            }
            else if args[i] == "-r" { noRunIfEmpty = true; i += 1 }
            else if args[i].hasPrefix("-") { return CommandSupport.error(name, "unsupported option", usage: true) }
            else { command = Array(args[i...]); break }
        }
        if command.isEmpty { command = ["echo"] }
        let words = CommandSupport.shellWords(io.stdin)
        if words.isEmpty && noRunIfEmpty { return CommandResult() }
        let groups: [[String]]
        if replacement != nil { groups = CommandSupport.lines(io.stdin).filter { !$0.isEmpty }.map { [$0] } }
        else {
            let size = maxArgs ?? max(1, words.count)
            groups = words.isEmpty ? [[]] : stride(from: 0, to: words.count, by: size).map { Array(words[$0..<min($0 + size, words.count)]) }
        }
        var result = CommandResult()
        for group in groups {
            var invocation: [String]
            if let replacement { invocation = command.map { $0.replacingOccurrences(of: replacement, with: group[0]) } }
            else { invocation = command + group }
            let commandName = URL(fileURLWithPath: invocation[0]).lastPathComponent
            guard let implementation = TetherCommandRegistry.all[commandName], commandName != name else { return CommandResult(stdout: result.stdout, stderr: result.stderr + "xargs: \(invocation[0]): unavailable command\n", exitCode: 127) }
            let one = implementation.run(CommandIO(argv: invocation, stdin: "", cwd: io.cwd, environment: io.environment))
            result.stdout += one.stdout; result.stderr += one.stderr
            if one.exitCode != 0 { result.exitCode = one.exitCode; break }
        }
        return result
    }
}
