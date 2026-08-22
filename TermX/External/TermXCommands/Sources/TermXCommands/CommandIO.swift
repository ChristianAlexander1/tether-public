import Foundation

/// The input/output contract shared by every TermX command. Commands are pure
/// functions over text: they never touch file descriptors directly — the app
/// wires `argv`, `stdin`, `cwd` and `environment` to the real terminal/pipe.
public struct CommandIO {
    public let argv: [String]          // argv[0] is the command name
    public let stdin: String           // "" when nothing is piped in
    public let cwd: String             // absolute; resolve relative paths against it
    public let environment: [String: String]
    public init(argv: [String], stdin: String = "", cwd: String, environment: [String: String] = [:]) {
        self.argv = argv
        self.stdin = stdin
        self.cwd = cwd
        self.environment = environment
    }
}

public struct CommandResult: Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public protocol TermXCommand {
    /// The name typed in the shell, e.g. "sed".
    static var name: String { get }
    /// Runs the command. Must never spawn a process, never call exit(), never crash.
    static func run(_ io: CommandIO) -> CommandResult
}

/// Lookup table the maintainer registers with the app.
/// `all` and `command(named:)` are defined in Registry.swift.
public enum TermXCommandRegistry {}
