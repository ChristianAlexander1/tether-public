import Foundation

public enum EnvCommand: TetherCommand {
    public static let name = "env"

    public static func run(_ io: CommandIO) -> CommandResult {
        let args = CommandSupport.args(io, command: name)
        var environment = io.environment
        var index = 0

        while index < args.count {
            let argument = args[index]
            if argument == "-i" || argument == "--ignore-environment" || argument == "-" {
                environment = [:]
                index += 1
            } else if argument == "-u" || argument == "--unset" {
                guard index + 1 < args.count else { return CommandSupport.error(name, "option requires an argument", usage: true) }
                environment.removeValue(forKey: args[index + 1])
                index += 2
            } else if argument.hasPrefix("--unset=") {
                environment.removeValue(forKey: String(argument.dropFirst("--unset=".count)))
                index += 1
            } else if argument == "--" {
                index += 1
                break
            } else if let equals = argument.firstIndex(of: "=") {
                let key = String(argument[..<equals])
                guard !key.isEmpty else { return CommandSupport.error(name, "invalid empty variable name", usage: true) }
                environment[key] = String(argument[argument.index(after: equals)...])
                index += 1
            } else {
                break
            }
        }

        if index == args.count {
            let output = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            return CommandResult(stdout: output.isEmpty ? "" : output + "\n")
        }

        let commandArgs = Array(args[index...])
        let commandName = URL(fileURLWithPath: commandArgs[0]).lastPathComponent
        guard let command = TetherCommandRegistry.all[commandName] else {
            return CommandResult(stderr: "env: \(commandArgs[0]): No such command\n", exitCode: 127)
        }
        return command.run(CommandIO(argv: commandArgs, stdin: io.stdin, cwd: io.cwd, environment: environment))
    }
}
