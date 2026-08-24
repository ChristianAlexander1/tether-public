import Foundation
import Dispatch

public enum TimeoutCommand: TetherCommand {
    public static let name = "timeout"

    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name)
        guard args.count >= 2, let limit = CommandSupport.parseDuration(args.removeFirst()) else {
            return CommandSupport.error(name, "duration and command required", usage: true)
        }
        let commandName = URL(fileURLWithPath: args[0]).lastPathComponent
        guard let command = TetherCommandRegistry.all[commandName], commandName != name else {
            return CommandResult(stderr: "timeout: \(args[0]): unavailable command\n", exitCode: 127)
        }

        // Sleep can be timed out cooperatively, avoiding a worker that would remain asleep.
        if commandName == SleepCommand.name {
            let sleepArgs = Array(args.dropFirst())
            let durations = sleepArgs.compactMap(CommandSupport.parseDuration)
            if durations.count == sleepArgs.count {
                let total = durations.reduce(0, +)
                if total > limit {
                    Thread.sleep(forTimeInterval: limit)
                    return CommandResult(exitCode: 124)
                }
            }
        }

        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let invocation = CommandIO(argv: args, stdin: io.stdin, cwd: io.cwd, environment: io.environment)
        DispatchQueue.global(qos: .userInitiated).async {
            box.store(command.run(invocation))
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + limit) == .timedOut {
            return CommandResult(exitCode: 124)
        }
        return box.load() ?? CommandResult(stderr: "timeout: command returned no result\n", exitCode: 1)
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: CommandResult?

        func store(_ value: CommandResult) {
            lock.lock(); defer { lock.unlock() }
            result = value
        }

        func load() -> CommandResult? {
            lock.lock(); defer { lock.unlock() }
            return result
        }
    }
}
