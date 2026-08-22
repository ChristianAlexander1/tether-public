import Foundation

// MARK: - Interactive Shell Session

/// Manages an interactive shell session (repl, environment, line parsing, .profile loading).
public final class ShellSession {
    public let state: ShellState
    public let executor: PipelineExecutor
    public let registry: CommandRegistry
    public let jobs: JobTable
    public let processTable: ProcessTable
    public let pidAllocator: PIDAllocator
    public let builtins: Builtins

    private var isTerminated = false
    private let outputHandler: (String) -> Void

    public init(cwd: String, environment: [String: String], outputHandler: @escaping (String) -> Void) {
        SignalPolicy.installOnce()
        self.outputHandler = outputHandler
        self.state = ShellState(cwd: cwd, environ: environment)
        self.state.stdinFD = -1
        self.state.stdoutFD = -1
        self.state.stderrFD = -1
        self.registry = CommandRegistry()
        self.jobs = JobTable()
        self.processTable = ProcessTable()
        self.pidAllocator = PIDAllocator()
        self.builtins = Builtins()

        self.executor = PipelineExecutor(
            registry: registry,
            jobs: jobs,
            processTable: processTable,
            pidAllocator: pidAllocator,
            shellState: state,
            write: outputHandler
        )
        self.builtins.executor = executor

        // Install builtins and core Unix commands
        builtins.install(into: registry)
        CoreCommands.registerAll(into: registry)
        ToolCommands.registerAll(into: registry)
        ExternalCommands.registerAll(into: registry)
        installDefaultBuiltins()

        // Load profile
        loadProfile()
    }

    /// Evaluates a single command line (e.g. from user input or script).
    @discardableResult
    public func eval(_ cmdline: String) -> Int32 {
        let trimmed = cmdline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        state.addHistory(trimmed)

        if trimmed.contains("\n") {
            let code = ShellLangIntegration.evalScript(trimmed, session: self)
            state.lastExitCode = code
            return code
        }

        if let forCode = ShellControlFlow.evalForLoop(trimmed, executor: executor, shellState: state) {
            state.lastExitCode = forCode
            return forCode
        }

        if let langCode = ShellLangIntegration.tryEvaluate(trimmed, session: self) {
            return langCode
        }

        return evalCommandLine(trimmed)
    }

    /// Runs one command line through the pipeline executor (no shell-language constructs).
    @discardableResult
    public func evalCommandLine(_ cmdline: String, stdinText: String? = nil) -> Int32 {
        let trimmed = cmdline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        var readEnd: Int32 = -1
        let savedStdin = state.stdinFD
        if let stdinText {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { return 1 }
            readEnd = fds[0]
            let payload = Array(stdinText.utf8)
            payload.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                _ = write(fds[1], base, payload.count)
            }
            close(fds[1])
            state.stdinFD = readEnd
        }
        defer {
            state.stdinFD = savedStdin
            if readEnd >= 0 { close(readEnd) }
        }

        guard let ast = ShellParser.parse(trimmed) else {
            outputHandler("syntax error\n")
            state.lastExitCode = 2
            return 2
        }

        let exitCode = executor.execute(ast)
        state.lastExitCode = exitCode
        return exitCode
    }

    /// Writes to the session output stream (stdout).
    func writeOutput(_ text: String) {
        outputHandler(text)
    }

    /// Writes to the session output stream as stderr (same handler in interactive mode).
    func writeError(_ text: String) {
        outputHandler(text)
    }

    /// Generates the shell prompt string (PS1).
    public var prompt: String {
        let home = state.environ["HOME"] ?? ""
        var displayPath = state.cwd
        if !home.isEmpty && displayPath.hasPrefix(home) {
            displayPath = "~" + displayPath.dropFirst(home.count)
        }
        let lastComponent = (displayPath as NSString).lastPathComponent
        let folderName = lastComponent.isEmpty ? "/" : lastComponent
        return "\(folderName) % "
    }

    /// Load ~/.profile or ~/.termxrc if present.
    private func loadProfile() {
        let home = state.environ["HOME"] ?? ""
        guard !home.isEmpty else { return }

        let profilePaths = [
            (home as NSString).appendingPathComponent(".profile"),
            (home as NSString).appendingPathComponent(".termxrc")
        ]

        for path in profilePaths {
            if FileManager.default.fileExists(atPath: path) {
                builtins.install(into: registry) // ensure builtins ready
                if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                    for line in content.components(separatedBy: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                        eval(trimmed)
                    }
                }
            }
        }
    }

    private func installDefaultBuiltins() {
        registry.register(name: "true") { _ in 0 }
        registry.register(name: "false") { _ in 1 }
        registry.register(name: "echo") { [weak self] argv in
            let text = Array(argv.dropFirst()).joined(separator: " ")
            self?.outputHandler(text + "\n")
            return 0
        }
        registry.register(name: "pwd") { [weak self] _ in
            if let cwd = self?.state.cwd {
                self?.outputHandler(cwd + "\n")
            }
            return 0
        }
        registry.register(name: "jobs") { [weak self] _ in
            guard let self else { return 0 }
            for job in self.jobs.all() {
                let status = job.running ? "Running" : "Done"
                self.outputHandler("[\(job.id)]  \(status)  \(job.command)\n")
            }
            return 0
        }
    }
}
