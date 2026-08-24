import Foundation

public struct CommandIO {
    public let argv: [String]
    public let stdin: String
    public let cwd: String
    public let environment: [String: String]

    public init(argv: [String], stdin: String = "", cwd: String = FileManager.default.currentDirectoryPath, environment: [String: String] = ProcessInfo.processInfo.environment) {
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

public protocol TetherCommand {
    static var name: String { get }
    static func run(_ io: CommandIO) -> CommandResult
}
