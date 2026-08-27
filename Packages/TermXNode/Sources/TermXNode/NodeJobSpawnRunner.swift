import Foundation
import TermXFiles
import TetherJobControl
import TetherJobIPC

/// Runs the child jobs requested over TJIP/2's spawn domain.
///
/// The legacy bridge only had `spawnSync`: a command ran to completion and its
/// whole output came back in one reply, so a child could neither stream nor be
/// signalled. TJIP/2 requires a real lifecycle — start returns a pid
/// immediately, output flows as it is produced, and signals reach the running
/// job — so this type supplies one.
///
/// Job identity and signal routing are delegated to `TetherJobControl`'s
/// `JobTable`: pids handed to the client are `JobID`s from that table, which is
/// also what makes `spawn.kill` do something instead of silently succeeding.
final class NodeJobSpawnRunner {
    /// Everything the runner knows about one live child.
    private final class Job {
        let id: JobID
        var stdinWriteFD: Int32 = -1
        var ptyMasterFD: Int32 = -1
        var usesPTY = false
        var exited = false
        /// Descriptors this job owns and must close exactly once, after the
        /// threads reading them have stopped.
        var ownedFDs: [Int32] = []
        var openReaders = 0
        /// Exit status held back until every reader has drained, so the exit
        /// frame is genuinely the last frame for this pid.
        var pendingExit: (Int32?, String?)?

        init(id: JobID) { self.id = id }
    }

    private let executor: SpawnExecuting
    private let stdio: NodeJobStdio
    private let defaultCWD: String
    private let defaultEnv: [String: String]
    private let queue: DispatchQueue
    private let openTarget: (SystemOpen.Target, SystemOpen.OpenOrigin) -> SystemOpen.Result

    private let table: JobTable
    private var jobs: [Int32: Job] = [:]

    /// Set by the server once the session exists. All calls hop to `queue`.
    weak var session: JIPServerSession?

    init(
        executor: SpawnExecuting,
        stdio: NodeJobStdio,
        defaultCWD: String,
        defaultEnv: [String: String],
        queue: DispatchQueue,
        clock: JobClock,
        openTarget: @escaping (SystemOpen.Target, SystemOpen.OpenOrigin) -> SystemOpen.Result = {
            SystemOpen.open($0, origin: $1)
        }
    ) {
        self.executor = executor
        self.stdio = stdio
        self.defaultCWD = defaultCWD
        self.defaultEnv = defaultEnv
        self.queue = queue
        self.openTarget = openTarget
        let backend = NodeJobBackend(executor: executor)
        self.table = JobTable(backend: backend, clock: clock)
        backend.runner = self
    }

    /// The job table, for the PTY-level signal routing the terminal owns
    /// (Ctrl-C to the foreground job, SIGWINCH broadcast on resize).
    var jobTable: JobTable { table }

    // MARK: - Spawn domain

    func start(argv: [String], cwd: String, env: [String: String],
               stdio requestedStdio: [String], pty: Bool) throws -> Int32 {
        guard let file = argv.first, !file.isEmpty else {
            throw JIPError(code: JIPErrorCode.enoent, message: "empty argv")
        }
        let args = Array(argv.dropFirst())

        var jobEnv = defaultEnv
        jobEnv.merge(env) { _, new in new }
        let jobCWD = cwd.isEmpty ? defaultCWD : cwd

        // Desktop CLIs launch a browser or file viewer through an opener. The
        // interception is generic — the name list lives only in the dispatch
        // manifest that `SystemOpen.resolve` consults, never here.
        if let target = SystemOpen.resolve(command: file, arguments: args) {
            return try startOpenerJob(file: file, target: target)
        }

        let id = table.register(JobSpec(argv: argv, group: nil, isForegroundCandidate: true))
        let job = Job(id: id)
        jobs[id.raw] = job

        let stdinSpec = requestedStdio.count > 0 ? requestedStdio[0] : "pipe"
        let stdoutSpec = requestedStdio.count > 1 ? requestedStdio[1] : "pipe"
        let stderrSpec = requestedStdio.count > 2 ? requestedStdio[2] : "pipe"

        var childStdin: Int32 = -1
        var childStdout: Int32 = -1
        var childStderr: Int32 = -1

        if pty {
            // One PTY carries the child's whole stdio, exactly as a terminal
            // does; the master stays here for reading, resizing and EOF.
            var master: Int32 = -1
            var slave: Int32 = -1
            guard openpty(&master, &slave, nil, nil, nil) == 0 else {
                jobs.removeValue(forKey: id.raw)
                table.markExited(id, code: nil, signal: nil)
                throw JIPError(code: JIPErrorCode.eagain, message: "openpty failed")
            }
            if let size = PtyTermios.windowSize(fd: stdio.geometrySourceFD) {
                PtyTermios.setWindowSize(fd: master, cols: size.cols, rows: size.rows)
            }
            job.usesPTY = true
            job.ptyMasterFD = master
            job.stdinWriteFD = master
            job.ownedFDs.append(contentsOf: [master, slave])
            childStdin = slave
            childStdout = slave
            childStderr = slave
            startReader(fd: master, job: job, isStderr: false)
        } else {
            if stdinSpec == "pipe", let pipePair = NodePipe.pair() {
                childStdin = pipePair.read
                job.stdinWriteFD = pipePair.write
                job.ownedFDs.append(contentsOf: [pipePair.read, pipePair.write])
            } else if stdinSpec == "inherit" {
                childStdin = stdio.stdinFD
            }

            if stdoutSpec == "pipe", let pipePair = NodePipe.pair() {
                childStdout = pipePair.write
                job.ownedFDs.append(contentsOf: [pipePair.read, pipePair.write])
                startReader(fd: pipePair.read, job: job, isStderr: false)
            } else if stdoutSpec == "inherit" {
                childStdout = stdio.stdoutFD
            }

            if stderrSpec == "pipe", let pipePair = NodePipe.pair() {
                childStderr = pipePair.write
                job.ownedFDs.append(contentsOf: [pipePair.read, pipePair.write])
                startReader(fd: pipePair.read, job: job, isStderr: true)
            } else if stderrSpec == "inherit" {
                childStderr = stdio.stderrFD
            }
        }

        let interactive = pty || stdoutSpec == "inherit"
        table.markRunning(id)

        let executor = self.executor
        let worker = Thread { [weak self] in
            let result = executor.spawnSync(
                file: file, args: args, cwd: jobCWD, env: jobEnv,
                stdinFD: childStdin, stdoutFD: childStdout, stderrFD: childStderr,
                interactive: interactive
            )
            // Closing the child's write ends is what gives the readers EOF.
            self?.queue.async { [weak self] in
                self?.childDidFinish(id: id, result: result,
                                     childWriteFDs: pty ? [] : [childStdout, childStderr])
            }
        }
        worker.name = "app.tether.node.job"
        worker.start()

        return id.raw
    }

    /// `open`/`xdg-open`-style launches complete immediately in the host UI;
    /// they still get a real pid and a real exit event so the client's
    /// ChildProcess lifecycle is identical to any other job.
    private func startOpenerJob(file: String, target: SystemOpen.Target) throws -> Int32 {
        let id = table.register(JobSpec(argv: [file], group: nil, isForegroundCandidate: false))
        let job = Job(id: id)
        jobs[id.raw] = job
        table.markRunning(id)
        let result = openTarget(target, .hostRuntime)
        queue.async { [weak self] in
            guard let self else { return }
            if case .failed(let why) = result {
                self.session?.pushStderr(pid: id.raw, data: Data("\(file): \(why)\n".utf8))
                self.finish(id: id, code: 1, signal: nil)
            } else {
                self.finish(id: id, code: 0, signal: nil)
            }
        }
        return id.raw
    }

    private func childDidFinish(id: JobID, result: SpawnResult, childWriteFDs: [Int32]) {
        for fd in childWriteFDs where fd >= 0 {
            // Only close descriptors this runner created; inherited job fds
            // belong to the terminal session.
            if jobs[id.raw]?.ownedFDs.contains(fd) == true { NodePipe.close(fd) }
        }
        // ENOENT is the one failure the client must see as a spawn error rather
        // than an exit; the executor signals it the only way it can, with 127.
        finish(id: id, code: result.exitCode, signal: result.signal)
    }

    private func finish(id: JobID, code: Int32?, signal: String?) {
        guard let job = jobs[id.raw], !job.exited else { return }
        job.exited = true
        table.markExited(id, code: code, signal: signal)
        // Readers may still be draining buffered output; the exit frame must be
        // last for the pid, so wait for them before pushing it.
        if job.openReaders == 0 {
            emitExit(job: job, code: code, signal: signal)
        } else {
            job.pendingExit = (code, signal)
        }
    }

    private func emitExit(job: Job, code: Int32?, signal: String?) {
        session?.pushExit(pid: job.id.raw, code: code, signal: signal)
        for fd in job.ownedFDs where fd >= 0 { NodePipe.close(fd) }
        job.ownedFDs.removeAll()
        jobs.removeValue(forKey: job.id.raw)
        _ = table.reapExited()
    }

    private func startReader(fd: Int32, job: Job, isStderr: Bool) {
        job.openReaders += 1
        let pid = job.id.raw
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { raw -> Int in
                    read(fd, raw.baseAddress, raw.count)
                }
                if n > 0 {
                    let data = Data(buffer[0..<n])
                    self?.queue.async { [weak self] in
                        guard let self, self.jobs[pid] != nil else { return }
                        if isStderr {
                            self.session?.pushStderr(pid: pid, data: data)
                        } else {
                            self.session?.pushStdout(pid: pid, data: data)
                        }
                    }
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                break // EOF, or the PTY master reporting EIO after slave close
            }
            self?.queue.async { [weak self] in self?.readerDidFinish(pid: pid) }
        }
        thread.name = isStderr ? "app.tether.node.job.stderr" : "app.tether.node.job.stdout"
        thread.start()
    }

    private func readerDidFinish(pid: Int32) {
        guard let job = jobs[pid] else { return }
        job.openReaders -= 1
        if job.openReaders == 0, let pending = job.pendingExit {
            emitExit(job: job, code: pending.0, signal: pending.1)
        }
    }

    // MARK: - stdin

    func writeStdin(pid: Int32, data: Data) throws -> Int {
        guard let job = jobs[pid], !job.exited else {
            throw JIPError(code: JIPErrorCode.epipe, message: "pid \(pid) has exited")
        }
        guard job.stdinWriteFD >= 0 else {
            throw JIPError(code: JIPErrorCode.epipe, message: "pid \(pid) has no stdin")
        }
        var written = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while written < raw.count {
                let n = write(job.stdinWriteFD, base.advanced(by: written), raw.count - written)
                if n > 0 { written += n; continue }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
                throw JIPError(code: JIPErrorCode.epipe,
                               message: "stdin write failed (errno \(errno))")
            }
        }
        // Advisory remaining capacity: what the pipe buffer can still take.
        return max(0, Self.pipeCapacity - written)
    }

    private static let pipeCapacity = 64 * 1024

    func endStdin(pid: Int32) throws {
        guard let job = jobs[pid], !job.exited else {
            throw JIPError(code: JIPErrorCode.epipe, message: "pid \(pid) has exited")
        }
        guard job.stdinWriteFD >= 0 else { return }
        if job.usesPTY {
            // A PTY has no half-close; EOT is how a terminal signals EOF.
            var eot: UInt8 = 0x04
            _ = write(job.stdinWriteFD, &eot, 1)
            return
        }
        NodePipe.close(job.stdinWriteFD)
        job.ownedFDs.removeAll { $0 == job.stdinWriteFD }
        job.stdinWriteFD = -1
    }

    // MARK: - Signals and geometry

    func kill(pid: Int32, signal: String) throws {
        guard let job = jobs[pid], !job.exited else {
            throw JIPError(code: JIPErrorCode.esrch, message: "no such job \(pid)")
        }
        guard let sig = JobSignal(rawValue: signal) else {
            throw JIPError(code: JIPErrorCode.einval, message: "unknown signal \(signal)")
        }
        let outcome = table.signal(sig, to: .job(job.id))
        if outcome.noSuchTarget {
            throw JIPError(code: JIPErrorCode.esrch, message: "no such job \(pid)")
        }
    }

    func resize(pid: Int32, cols: Int, rows: Int) throws {
        guard let job = jobs[pid], !job.exited else {
            throw JIPError(code: JIPErrorCode.esrch, message: "no such job \(pid)")
        }
        guard job.usesPTY, job.ptyMasterFD >= 0 else {
            throw JIPError(code: JIPErrorCode.einval, message: "pid \(pid) has no pty")
        }
        guard PtyTermios.setWindowSize(fd: job.ptyMasterFD, cols: cols, rows: rows) else {
            throw JIPError(code: JIPErrorCode.einval, message: "TIOCSWINSZ failed")
        }
        _ = table.signal(.winch, to: .job(job.id))
    }

    /// Deliver a signal to whatever job is in the foreground — the routing the
    /// PTY performs when the user presses Ctrl-C, and on window resize.
    func signalForeground(_ signal: JobSignal) {
        _ = table.signal(signal, to: .foreground)
    }

    /// Called by the backend when a lane cannot deliver a signal itself.
    func forceTerminate(_ id: JobID) {
        guard let job = jobs[id.raw] else { return }
        // Dropping the child's PTY master / stdin ends its I/O, which is the
        // strongest lever this lane has over an in-process job.
        if job.ptyMasterFD >= 0 { shutdown(job.ptyMasterFD, SHUT_RDWR) }
    }
}

/// Maps `JobTable` signal delivery onto the embedded-Node lane.
private final class NodeJobBackend: JobBackend {
    private let executor: SpawnExecuting
    weak var runner: NodeJobSpawnRunner?

    init(executor: SpawnExecuting) { self.executor = executor }

    func deliver(_ signal: JobSignal, to job: JobID) -> Bool {
        switch signal {
        case .int, .term, .kill, .hup, .quit:
            executor.signal(pid: job.raw, signal: Self.number(signal))
            return true
        case .winch:
            // Geometry was already pushed onto the PTY; nothing further to do.
            return true
        case .tstp, .cont:
            // No suspend/resume state exists for in-process jobs. Reporting
            // failure is honest: the caller decides policy, and `JobTable`
            // leaves the job's state unchanged.
            return false
        }
    }

    func forceTerminate(_ job: JobID) {
        runner?.forceTerminate(job)
    }

    private static func number(_ signal: JobSignal) -> Int32 {
        switch signal {
        case .int: return Int32(SIGINT)
        case .term: return Int32(SIGTERM)
        case .kill: return Int32(SIGKILL)
        case .hup: return Int32(SIGHUP)
        case .quit: return Int32(SIGQUIT)
        case .winch: return Int32(SIGWINCH)
        case .tstp: return Int32(SIGTSTP)
        case .cont: return Int32(SIGCONT)
        }
    }
}
