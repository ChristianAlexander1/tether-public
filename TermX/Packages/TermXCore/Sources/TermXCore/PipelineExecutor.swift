import Foundation

// MARK: - Pipeline Executor

/// Executes parsed shell ASTs: wires pipes between stages, handles redirections,
/// manages background jobs, and routes to the command registry.
public final class PipelineExecutor {
    public let registry: CommandRegistry
    public let jobs: JobTable
    public let processTable: ProcessTable
    public let pidAllocator: PIDAllocator
    private let writeCallback: (String) -> Void

    /// Shared shell state (environment, cwd, aliases, etc.)
    public var shellState: ShellState

    public init(registry: CommandRegistry, jobs: JobTable, processTable: ProcessTable,
                pidAllocator: PIDAllocator, shellState: ShellState,
                write: @escaping (String) -> Void) {
        self.registry = registry
        self.jobs = jobs
        self.processTable = processTable
        self.pidAllocator = pidAllocator
        self.shellState = shellState
        self.writeCallback = write
    }

    /// Run a command string and capture stdout (for `$(cmd)` substitution).
    /// Captures through a real pipe so fd-writing commands (python3, rg, …) are
    /// captured exactly like closure-writing builtins.
    public func evaluateCommandSubstitution(_ cmdline: String) -> VariableExpander.CommandSubstitutionResult {
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { return ("", 1) }
        let readFD = pipeFDs[0]
        let writeFD = pipeFDs[1]

        let subState = ShellState(cwd: shellState.cwd, environ: shellState.environ)
        subState.lastExitCode = shellState.lastExitCode
        subState.lastBgPID = shellState.lastBgPID
        subState.stdinFD = -1
        subState.stdoutFD = writeFD
        // stderr is NOT captured by $(…): inherit the surrounding effective stderr.
        subState.stderrFD = shellState.stderrFD >= 0 ? shellState.stderrFD : (ProcessContext.current?.stderrFD ?? -1)

        let capture = SubstitutionCapture()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(readFD, &buffer, buffer.count)
                if count <= 0 { break }
                capture.append(buffer, count: count)
            }
            done.signal()
        }

        let subExecutor = PipelineExecutor(
            registry: registry,
            jobs: JobTable(),
            processTable: ProcessTable(),
            pidAllocator: PIDAllocator(),
            shellState: subState,
            write: { text in
                let bytes = Array(text.utf8)
                bytes.withUnsafeBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    var remaining = bytes.count
                    var offset = 0
                    while remaining > 0 {
                        let written = write(writeFD, base.advanced(by: offset), remaining)
                        if written <= 0 { break }
                        offset += written
                        remaining -= written
                    }
                }
            }
        )

        let code: Int32
        if let ast = ShellParser.parse(cmdline) {
            code = subExecutor.execute(ast)
        } else {
            code = 2
        }
        close(writeFD)
        done.wait()
        close(readFD)
        return (capture.string, code)
    }

    private func expandWord(_ word: String, environ: [String: String]) -> String {
        VariableExpander.expand(
            word, environ: environ,
            lastExitCode: shellState.lastExitCode,
            shellPID: 1,
            lastBgPID: shellState.lastBgPID,
            commandRunner: { [weak self] cmd in
                guard let self else { return ("", 127) }
                return self.evaluateCommandSubstitution(cmd)
            }
        )
    }

    /// Execute a parsed AST and return the exit code.
    @discardableResult
    public func execute(_ ast: ShellAST) -> Int32 {
        switch ast {
        case .simple(let cmd):
            return executeSimple(cmd)

        case .pipeline(let commands):
            return executePipeline(commands)

        case .and(let left, let right):
            let code = execute(left)
            shellState.lastExitCode = code
            if code == 0 { return execute(right) }
            return code

        case .or(let left, let right):
            let code = execute(left)
            shellState.lastExitCode = code
            if code != 0 { return execute(right) }
            return code

        case .sequence(let left, let right):
            let code = execute(left)
            shellState.lastExitCode = code
            return execute(right)

        case .background(let inner):
            let pid = pidAllocator.allocate()
            let commandDescription = describeAST(inner)
            let jobID = jobs.add(pid: pid, command: commandDescription)
            let process = VirtualProcess(
                pid: pid, cwd: shellState.cwd, environ: shellState.environ,
                stdinFD: -1, stdoutFD: -1, stderrFD: -1, interactive: false
            )
            processTable.register(process)
            process.onSignal(2) { process.markFinished(exitCode: 130) }
            Thread.detachNewThread { [weak self] in
                guard let self else { return }
                process.markRunning()
                ProcessContext.current = process
                let code = self.execute(inner)
                process.markFinished(exitCode: code)
                self.processTable.remove(pid)
                self.jobs.finish(pid: pid)
                self.writeCallback("[done] [\(jobID)] \(commandDescription) (exit \(code))\n")
            }
            shellState.lastBgPID = pid
            writeCallback("[\(jobID)] \(pid)\n")
            return 0

        case .subshell(let inner):
            // Subshells inherit but don't modify the parent env
            let savedEnv = shellState.environ
            let savedCwd = shellState.cwd
            let code = execute(inner)
            shellState.environ = savedEnv
            shellState.cwd = savedCwd
            return code
        }
    }

    // MARK: - Simple Command Execution

    private final class SubstitutionCapture: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ buffer: [UInt8], count: Int) {
            lock.lock(); data.append(contentsOf: buffer[0..<count]); lock.unlock()
        }
        var string: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func executeSimple(_ cmd: SimpleCommand) -> Int32 {
        // Handle assignment-only commands (VAR=value with no command)
        if cmd.argv.isEmpty && !cmd.assignmentWords.isEmpty {
            for assignment in cmd.assignmentWords {
                if let eqIdx = assignment.firstIndex(of: "=") {
                    let name = String(assignment[assignment.startIndex..<eqIdx])
                    let value = String(assignment[assignment.index(after: eqIdx)...])
                    shellState.environ[name] = VariableExpander.expand(value, environ: shellState.environ, lastExitCode: shellState.lastExitCode)
                }
            }
            return 0
        }

        // Expand variables and command substitutions in argv (skip single-quoted words).
        var expandedArgv: [String] = []
        for (index, word) in cmd.argv.enumerated() {
            let literal = index < cmd.literalArgv.count && cmd.literalArgv[index]
            if literal {
                expandedArgv.append(word)
            } else {
                expandedArgv.append(expandWord(word, environ: shellState.environ))
            }
        }

        // Glob expansion
        expandedArgv = expandedArgv.flatMap { word -> [String] in
            if GlobExpander.containsGlobChars(word) {
                return GlobExpander.expand(word, in: shellState.cwd)
            }
            return [word]
        }

        guard let commandName = expandedArgv.first else { return 0 }

        // Apply aliases
        if let alias = shellState.aliases[commandName] {
            let aliasTokens = ShellLexer.lex(alias)
            expandedArgv = aliasTokens + Array(expandedArgv.dropFirst())
        }

        // Handle temporary env assignments
        var tempEnv = shellState.environ
        for assignment in cmd.assignmentWords {
            if let eqIdx = assignment.firstIndex(of: "=") {
                let name = String(assignment[assignment.startIndex..<eqIdx])
                let value = String(assignment[assignment.index(after: eqIdx)...])
                tempEnv[name] = VariableExpander.expand(value, environ: tempEnv, lastExitCode: shellState.lastExitCode)
            }
        }

        // Set up redirections
        let savedStdout = shellState.stdoutFD
        let savedStderr = shellState.stderrFD
        let savedStdin = shellState.stdinFD
        var openedFDs: [Int32] = []

        for redir in cmd.redirections {
            switch redir.kind {
            case .outputTo:
                let expandedTarget = VariableExpander.expand(redir.target, environ: tempEnv)
                let path = resolvePath(expandedTarget)
                let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                if fd >= 0 { shellState.stdoutFD = fd; openedFDs.append(fd) }

            case .outputAppend:
                let expandedTarget = VariableExpander.expand(redir.target, environ: tempEnv)
                let path = resolvePath(expandedTarget)
                let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
                if fd >= 0 { shellState.stdoutFD = fd; openedFDs.append(fd) }

            case .inputFrom:
                let expandedTarget = VariableExpander.expand(redir.target, environ: tempEnv)
                let path = resolvePath(expandedTarget)
                let fd = open(path, O_RDONLY)
                if fd >= 0 { shellState.stdinFD = fd; openedFDs.append(fd) }

            case .stderrTo:
                let expandedTarget = VariableExpander.expand(redir.target, environ: tempEnv)
                let path = resolvePath(expandedTarget)
                let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                if fd >= 0 { shellState.stderrFD = fd; openedFDs.append(fd) }

            case .stderrAppend:
                let expandedTarget = VariableExpander.expand(redir.target, environ: tempEnv)
                let path = resolvePath(expandedTarget)
                let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
                if fd >= 0 { shellState.stderrFD = fd; openedFDs.append(fd) }

            case .stderrToStdout:
                shellState.stderrFD = shellState.stdoutFD

            case .hereString(let content):
                var pipeFDs: [Int32] = [0, 0]
                if pipe(&pipeFDs) == 0 {
                    let data = Array((content + "\n").utf8)
                    _ = data.withUnsafeBufferPointer { buf in
                        write(pipeFDs[1], buf.baseAddress!, data.count)
                    }
                    close(pipeFDs[1])
                    shellState.stdinFD = pipeFDs[0]
                    openedFDs.append(pipeFDs[0])
                }
            }
        }

        // Effective fds: redirection wins; otherwise inherit the surrounding process
        // (the interactive shell's pty) so unredirected commands still reach the screen.
        let previousContext = ProcessContext.current
        let effectiveIn = shellState.stdinFD >= 0 ? shellState.stdinFD : (previousContext?.stdinFD ?? -1)
        let effectiveOut = shellState.stdoutFD >= 0 ? shellState.stdoutFD : (previousContext?.stdoutFD ?? -1)
        let effectiveErr = shellState.stderrFD >= 0 ? shellState.stderrFD : (previousContext?.stderrFD ?? -1)

        // Build the SpawnRequest
        let request = SpawnRequest(
            cmdline: expandedArgv.joined(separator: " "),
            stdinFD: effectiveIn,
            stdoutFD: effectiveOut,
            stderrFD: effectiveErr,
            cwd: shellState.cwd,
            environment: tempEnv,
            interactive: false
        )

        // Run inside a process context carrying the effective fds so fd-writing commands
        // honor redirections; fd-less contexts (host tests) fall back to the callback.
        let proc = VirtualProcess(
            pid: previousContext?.pid ?? -1, cwd: shellState.cwd, environ: tempEnv,
            stdinFD: effectiveIn, stdoutFD: effectiveOut, stderrFD: effectiveErr, interactive: false
        )
        proc.stdoutWriter = { [weak self] text in self?.writeCallback(text) }
        proc.stderrWriter = { [weak self] text in self?.writeCallback(text) }
        proc.markRunning()
        ProcessContext.current = proc

        let exitCode = registry.run(argv: expandedArgv, request: request) { text in proc.writeStdout(text) }

        ProcessContext.current = previousContext

        // Restore FDs
        shellState.stdoutFD = savedStdout
        shellState.stderrFD = savedStderr
        shellState.stdinFD = savedStdin
        for fd in openedFDs { close(fd) }

        shellState.lastExitCode = exitCode
        return exitCode
    }

    // MARK: - Pipeline Execution

    private func executePipeline(_ commands: [SimpleCommand]) -> Int32 {
        guard !commands.isEmpty else { return 0 }
        if commands.count == 1 { return executeSimple(commands[0]) }

        // Apply file redirections from the last stage to the pipeline stdout target.
        var lastCmd = commands[commands.count - 1]
        let savedStdout = shellState.stdoutFD
        let savedStderr = shellState.stderrFD
        var openedFDs: [Int32] = []

        for redir in lastCmd.redirections {
            switch redir.kind {
            case .outputTo:
                let path = resolvePath(VariableExpander.expand(redir.target, environ: shellState.environ))
                let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                if fd >= 0 { shellState.stdoutFD = fd; openedFDs.append(fd) }
            case .outputAppend:
                let path = resolvePath(VariableExpander.expand(redir.target, environ: shellState.environ))
                let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
                if fd >= 0 { shellState.stdoutFD = fd; openedFDs.append(fd) }
            case .stderrTo:
                let path = resolvePath(VariableExpander.expand(redir.target, environ: shellState.environ))
                let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                if fd >= 0 { shellState.stderrFD = fd; openedFDs.append(fd) }
            case .stderrAppend:
                let path = resolvePath(VariableExpander.expand(redir.target, environ: shellState.environ))
                let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
                if fd >= 0 { shellState.stderrFD = fd; openedFDs.append(fd) }
            case .stderrToStdout:
                shellState.stderrFD = shellState.stdoutFD
            default:
                break
            }
        }
        lastCmd.redirections.removeAll {
            switch $0.kind {
            case .outputTo, .outputAppend, .stderrTo, .stderrAppend, .stderrToStdout: return true
            default: return false
            }
        }

        var pipelineCommands = commands
        pipelineCommands[pipelineCommands.count - 1] = lastCmd

        defer {
            shellState.stdoutFD = savedStdout
            shellState.stderrFD = savedStderr
            for fd in openedFDs { close(fd) }
        }

        // Create pipes between stages
        var pipes: [(Int32, Int32)] = []
        for _ in 0..<(pipelineCommands.count - 1) {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else {
                writeCallback("pipe: failed to create pipe\n")
                return 1
            }
            pipes.append((fds[0], fds[1]))
        }

        var lastExitCode: Int32 = 0
        let group = DispatchGroup()
        let exitCodes = UnsafeMutableBufferPointer<Int32>.allocate(capacity: pipelineCommands.count)
        exitCodes.initialize(repeating: 0)

        for (index, cmd) in pipelineCommands.enumerated() {
            group.enter()

            let stdinFD: Int32
            let stdoutFD: Int32

            if index == 0 {
                stdinFD = shellState.stdinFD
                stdoutFD = pipes[0].1
            } else if index == pipelineCommands.count - 1 {
                stdinFD = pipes[index - 1].0
                stdoutFD = shellState.stdoutFD
            } else {
                stdinFD = pipes[index - 1].0
                stdoutFD = pipes[index].1
            }

            let capturedIndex = index
            let environ = shellState.environ
            let cwd = shellState.cwd
            let stderrFD = shellState.stderrFD

            Thread.detachNewThread { [weak self] in
                guard let self else { group.leave(); return }

                let expandedArgv: [String] = cmd.argv.enumerated().map { index, word in
                    let literal = index < cmd.literalArgv.count && cmd.literalArgv[index]
                    return literal ? word : self.expandWord(word, environ: environ)
                }

                let proc = VirtualProcess(
                    pid: Int32(capturedIndex + 1000), cwd: cwd, environ: environ,
                    stdinFD: stdinFD, stdoutFD: stdoutFD, stderrFD: stderrFD, interactive: false
                )
                proc.stdoutWriter = { [weak self] text in
                    if stdoutFD < 0 { self?.writeCallback(text) }
                    else { proc.writeStdout(text) }
                }
                proc.stderrWriter = { [weak self] text in
                    if stderrFD < 0 { self?.writeCallback(text) }
                    else { proc.writeStderr(text) }
                }
                ProcessContext.current = proc

                let request = SpawnRequest(
                    cmdline: expandedArgv.joined(separator: " "),
                    stdinFD: stdinFD,
                    stdoutFD: stdoutFD,
                    stderrFD: stderrFD,
                    cwd: cwd,
                    environment: environ,
                    interactive: false
                )

                let code = self.registry.run(argv: expandedArgv, request: request, write: { output in
                    if stdoutFD >= 0 {
                        proc.writeStdout(output)
                    } else {
                        self.writeCallback(output)
                    }
                })

                exitCodes[capturedIndex] = code
                ProcessContext.current = nil

                if capturedIndex > 0 { close(stdinFD) }
                if capturedIndex < pipelineCommands.count - 1 { close(stdoutFD) }

                group.leave()
            }
        }

        group.wait()
        lastExitCode = exitCodes[pipelineCommands.count - 1]
        exitCodes.deallocate()

        return lastExitCode
    }

    // MARK: - Helpers

    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return (shellState.cwd as NSString).appendingPathComponent(path)
    }

    private func describeAST(_ ast: ShellAST) -> String {
        switch ast {
        case .simple(let cmd): return cmd.argv.joined(separator: " ")
        case .pipeline(let cmds): return cmds.map { $0.argv.joined(separator: " ") }.joined(separator: " | ")
        case .and(let l, let r): return "\(describeAST(l)) && \(describeAST(r))"
        case .or(let l, let r): return "\(describeAST(l)) || \(describeAST(r))"
        case .sequence(let l, let r): return "\(describeAST(l)); \(describeAST(r))"
        case .background(let inner): return "\(describeAST(inner)) &"
        case .subshell(let inner): return "(\(describeAST(inner)))"
        }
    }
}

// MARK: - Shell State

/// Mutable state shared across a shell session.
public final class ShellState {
    public var environ: [String: String]
    public var cwd: String
    public var aliases: [String: String] = [:]
    public var history: [String] = []
    public var lastExitCode: Int32 = 0
    public var lastBgPID: TermXPID = 0
    public var stdinFD: Int32 = 0
    public var stdoutFD: Int32 = 1
    public var stderrFD: Int32 = 2
    public var maxHistorySize: Int = 5000

    public init(cwd: String, environ: [String: String]) {
        self.cwd = cwd
        self.environ = environ
    }

    /// Add a line to history, trimming if needed.
    public func addHistory(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Don't add duplicates of the last entry
        if history.last != trimmed {
            history.append(trimmed)
        }
        if history.count > maxHistorySize {
            history.removeFirst(history.count - maxHistorySize)
        }
    }

    /// Load history from file.
    public func loadHistory(from path: String) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        history = content.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// Save history to file.
    public func saveHistory(to path: String) {
        let content = history.suffix(maxHistorySize).joined(separator: "\n")
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
