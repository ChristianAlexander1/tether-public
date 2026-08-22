import Foundation

public typealias TermXPID = Int32

public struct SpawnRequest: Sendable {
    public let cmdline: String
    public let stdinFD: Int32
    public let stdoutFD: Int32
    public let stderrFD: Int32
    public let cwd: String
    public let environment: [String: String]
    public let interactive: Bool

    public init(cmdline: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
                cwd: String, environment: [String: String], interactive: Bool) {
        self.cmdline = cmdline
        self.stdinFD = stdinFD
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
        self.cwd = cwd
        self.environment = environment
        self.interactive = interactive
    }
}

public typealias CommandMain = (_ argv: [String]) -> Int32
public typealias FallbackRunner = (_ request: SpawnRequest) -> Int32

public final class CommandRegistry {
    private var commands: [String: CommandMain] = [:]
    private var fallback: FallbackRunner?
    private let lock = NSLock()

    public init() {}

    @discardableResult
    public func register(name: String, entry: @escaping CommandMain) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard commands[name] == nil else { return false }
        commands[name] = entry
        return true
    }

    public func registerFallback(_ runner: @escaping FallbackRunner) {
        lock.lock()
        fallback = runner
        lock.unlock()
    }

    public func entry(for name: String) -> CommandMain? {
        lock.lock()
        defer { lock.unlock() }
        return commands[name]
    }

    public func run(_ request: SpawnRequest, write: @escaping (String) -> Void) -> Int32 {
        let trimmed = request.cmdline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let isComplex = trimmed.contains("|") || trimmed.contains(">") || trimmed.contains("<") ||
                        trimmed.contains("&&") || trimmed.contains("||") || trimmed.contains(";") ||
                        trimmed.contains("$")

        if isComplex, let ast = ShellParser.parse(trimmed) {
            let state = ShellState(cwd: request.cwd, environ: request.environment)
            state.stdinFD = request.stdinFD
            state.stdoutFD = request.stdoutFD
            state.stderrFD = request.stderrFD
            let executor = PipelineExecutor(
                registry: self,
                jobs: JobTable(),
                processTable: ProcessTable(),
                pidAllocator: PIDAllocator(),
                shellState: state,
                write: write
            )
            return executor.execute(ast)
        }

        return run(argv: ShellLexer.lex(request.cmdline), request: request, write: write)
    }

    /// Run a command with an already-parsed argv (preserves quoting from the shell parser).
    public func run(argv: [String], request: SpawnRequest, write: @escaping (String) -> Void) -> Int32 {
        guard let command = argv.first else { return 0 }

        if command == "echo" {
            let expanded = argv.dropFirst().map {
                VariableExpander.expand($0, environ: request.environment)
            }
            write(expanded.joined(separator: " ") + "\n")
            return 0
        }
        if command == "pwd" { write(request.cwd + "\n"); return 0 }

        if let entry = entry(for: command) {
            if ProcessContext.current != nil {
                return entry(argv)
            }
            let proc = VirtualProcess(
                pid: 1, cwd: request.cwd, environ: request.environment,
                stdinFD: request.stdinFD, stdoutFD: request.stdoutFD, stderrFD: request.stderrFD,
                interactive: request.interactive
            )
            proc.stdoutWriter = { write($0) }
            proc.stderrWriter = { write($0) }
            let prev = ProcessContext.current
            ProcessContext.current = proc
            defer { ProcessContext.current = prev }
            return entry(argv)
        }

        if let fallback { return fallback(request) }
        write("\(command): command not found\n")
        return 127
    }
}

public final class JobTable {
    public struct Job: Identifiable, Sendable {
        public let id: Int
        public let pid: TermXPID
        public var command: String
        public var running: Bool
    }
    private var jobs: [Int: Job] = [:]
    private var nextID = 1
    private let lock = NSLock()

    public init() {}

    @discardableResult
    public func add(pid: TermXPID, command: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        jobs[id] = Job(id: id, pid: pid, command: command, running: true)
        return id
    }

    public func finish(pid: TermXPID) {
        lock.lock()
        defer { lock.unlock() }
        for id in jobs.keys where jobs[id]?.pid == pid {
            jobs[id]?.running = false
        }
    }

    public func all() -> [Job] {
        lock.lock()
        defer { lock.unlock() }
        return jobs.values.sorted { $0.id < $1.id }
    }
}

public enum ShellLexer {
    public static func lex(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in input {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" && quote != "'" { escaped = true; continue }
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
                continue
            }
            if character == "'" || character == "\"" { quote = character; continue }
            if character.isWhitespace {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

public final class TermXCommandEngine {
    public let registry: CommandRegistry
    public let jobs: JobTable

    public init(registry: CommandRegistry = CommandRegistry(), jobs: JobTable = JobTable()) {
        SignalPolicy.installOnce()
        self.registry = registry
        self.jobs = jobs
        installBuiltins()
    }

    public func run(_ request: SpawnRequest, write: @escaping (String) -> Void) -> Int32 {
        registry.run(request, write: write)
    }

    private func installBuiltins() {
        _ = registry.register(name: "true") { _ in 0 }
        _ = registry.register(name: "false") { _ in 1 }
        CoreCommands.registerAll(into: registry)
        ToolCommands.registerAll(into: registry)
        ExternalCommands.registerAll(into: registry)
    }
}
