import Foundation

// MARK: - Terminal engine protocol

public protocol TerminalEngine: AnyObject {
    func startShell(cwd: String, env: [String: String],
                    ptySlave: Int32, onExit: @escaping (Int32) -> Void) throws -> Int32
    func signal(pid: Int32, _ sig: Int32)
}

// MARK: - TermXShellEngine Implementation

public final class TermXShellEngine: TerminalEngine {
    public let registry: CommandRegistry
    public let processTable: ProcessTable
    public let pidAllocator: PIDAllocator
    public let jobs: JobTable

    private var activeSessions: [TermXPID: ShellSession] = [:]
    private let lock = NSLock()

    /// Integration hook: runs after each interactive ShellSession is created, before any
    /// input is processed — the app uses it to register runtime commands (python3, node,
    /// claude, linux, …) into the session's registry.
    public var sessionConfigurator: ((ShellSession) -> Void)?

    public init(registry: CommandRegistry = CommandRegistry(),
                processTable: ProcessTable = ProcessTable(),
                pidAllocator: PIDAllocator = PIDAllocator(),
                jobs: JobTable = JobTable()) {
        self.registry = registry
        self.processTable = processTable
        self.pidAllocator = pidAllocator
        self.jobs = jobs
        SignalPolicy.installOnce()
    }

    // MARK: - TerminalEngine Conformance

    public func startShell(cwd: String, env: [String: String],
                           ptySlave: Int32, onExit: @escaping (Int32) -> Void) throws -> Int32 {
        let pid = pidAllocator.allocate()

        let session = ShellSession(cwd: cwd, environment: env) { output in
            if ptySlave >= 0 {
                let data = Array(output.utf8)
                data.withUnsafeBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    var remaining = data.count
                    var offset = 0
                    while remaining > 0 {
                        let written = write(ptySlave, base.advanced(by: offset), remaining)
                        if written <= 0 { break }
                        offset += written
                        remaining -= written
                    }
                }
            }
        }

        sessionConfigurator?(session)

        lock.lock()
        activeSessions[pid] = session
        lock.unlock()

        let proc = VirtualProcess(
            pid: pid, cwd: cwd, environ: env,
            stdinFD: ptySlave, stdoutFD: ptySlave, stderrFD: ptySlave, interactive: true
        )
        processTable.register(proc)

        // Read commands from ptySlave in background thread
        Thread.detachNewThread { [weak self, weak proc] in
            guard let self, let proc else { return }
            proc.markRunning()
            ProcessContext.current = proc

            // Print welcome banner and initial prompt
            let welcome = "TermX Shell 1.0 (iOS in-process engine)\n"
            let prompt = session.prompt
            if ptySlave >= 0 {
                let initial = welcome + prompt
                let data = Array(initial.utf8)
                _ = data.withUnsafeBufferPointer { buf in
                    write(ptySlave, buf.baseAddress!, data.count)
                }
            }

            var lineBuffer = ""
            var byteBuffer = [UInt8](repeating: 0, count: 1024)

            // The interactive shell ends only on EOF (Ctrl-D), `exit`, or a terminating
            // signal — never on SIGINT (which cancels the current line) or SIGWINCH.
            while proc.isRunning && !proc.shouldTerminate {
                guard ptySlave >= 0 else { break }

                var pfd = pollfd(fd: ptySlave, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 200)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if ready == 0 { continue }
                if proc.shouldTerminate { break }

                let bytesRead = read(ptySlave, &byteBuffer, byteBuffer.count)
                if bytesRead < 0 && errno == EINTR { continue }
                if bytesRead <= 0 { break }
                if proc.interrupted { proc.clearSignal() }

                for i in 0..<bytesRead {
                    let byte = byteBuffer[i]
                    if byte == 0x0A || byte == 0x0D { // Newline
                        let line = lineBuffer
                        lineBuffer = ""
                        if !line.isEmpty {
                            _ = session.eval(line)
                        }
                        // Write next prompt
                        let nextPrompt = session.prompt
                        let promptData = Array(nextPrompt.utf8)
                        _ = promptData.withUnsafeBufferPointer { buf in
                            write(ptySlave, buf.baseAddress!, promptData.count)
                        }
                    } else if byte == 0x03 { // Ctrl-C
                        lineBuffer = ""
                        let cancelMsg = "^C\n" + session.prompt
                        let cancelData = Array(cancelMsg.utf8)
                        _ = cancelData.withUnsafeBufferPointer { buf in
                            write(ptySlave, buf.baseAddress!, cancelData.count)
                        }
                    } else if byte == 0x04 { // Ctrl-D (EOF)
                        if lineBuffer.isEmpty {
                            proc.markFinished(exitCode: 0)
                            break
                        }
                    } else if byte == 0x7F || byte == 0x08 { // Backspace
                        if !lineBuffer.isEmpty {
                            lineBuffer.removeLast()
                        }
                    } else {
                        let scalar = UnicodeScalar(byte)
                        if Character(scalar).isASCII {
                            lineBuffer.append(Character(scalar))
                        }
                    }
                }
            }

            proc.markFinished(exitCode: 0)
            self.processTable.remove(pid)
            self.lock.lock()
            self.activeSessions.removeValue(forKey: pid)
            self.lock.unlock()

            DispatchQueue.main.async {
                onExit(proc.exitCode)
            }
        }

        return pid
    }

    public func signal(pid: Int32, _ sig: Int32) {
        _ = processTable.signal(pid, sig)
    }

    // MARK: - termx_core.h C-Bridge Equivalent API

    @discardableResult
    public func termxSpawn(_ req: SpawnRequest) -> TermXPID {
        let pid = pidAllocator.allocate()
        let proc = VirtualProcess(
            pid: pid, cwd: req.cwd, environ: req.environment,
            stdinFD: req.stdinFD, stdoutFD: req.stdoutFD, stderrFD: req.stderrFD,
            interactive: req.interactive
        )
        processTable.register(proc)

        Thread.detachNewThread { [weak self, weak proc] in
            guard let self, let proc else { return }
            proc.markRunning()
            ProcessContext.current = proc

            let tokens = ShellLexer.lex(req.cmdline)
            let exitCode: Int32
            if let cmd = tokens.first, let entry = self.registry.entry(for: cmd) {
                exitCode = entry(tokens)
            } else {
                exitCode = self.registry.run(req) { out in
                    proc.writeStdout(out)
                }
            }

            proc.markFinished(exitCode: exitCode)
        }

        return pid
    }

    public func termxWait(_ pid: TermXPID, exitCode: inout Int32) -> Int32 {
        while true {
            guard let proc = processTable.get(pid) else {
                exitCode = -1
                return -1
            }
            if !proc.isRunning {
                exitCode = proc.exitCode
                processTable.remove(pid)
                return 0
            }
            usleep(10_000) // 10ms poll
        }
    }

    public func termxRun(_ req: SpawnRequest, exitCode: inout Int32) -> Int32 {
        let pid = termxSpawn(req)
        guard pid > 0 else { return -1 }
        return termxWait(pid, exitCode: &exitCode)
    }
}
