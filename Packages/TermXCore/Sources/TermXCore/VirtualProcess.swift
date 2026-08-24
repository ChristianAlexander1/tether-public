import Foundation

// MARK: - VirtualProcess — the in-process "process" model for iOS

/// Each command runs as a VirtualProcess: its own thread, cwd, environ, fds, exit code,
/// and signal handler. This replaces fork/exec on iOS where those syscalls are forbidden.
///
/// In-process command state matching the public `termx_core.h` contract.
public final class VirtualProcess: @unchecked Sendable {
    public let pid: TermXPID
    public private(set) var threadID: UInt64 = 0
    public var cwd: String
    public var environ: [String: String]
    public let stdinFD: Int32
    public let stdoutFD: Int32
    public let stderrFD: Int32
    public let interactive: Bool
    public private(set) var exitCode: Int32 = 0
    public private(set) var isRunning: Bool = false
    public private(set) var isSignalled: Bool = false
    private var _shouldTerminate: Bool = false

    /// When stdout/stderr fds are unavailable, output is routed here (shell session capture).
    public var stdoutWriter: ((String) -> Void)?
    public var stderrWriter: ((String) -> Void)?

    private var signalHandlers: [Int32: () -> Void] = [:]
    private let lock = NSLock()
    private var thread: Thread?

    public init(pid: TermXPID, cwd: String, environ: [String: String],
                stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32, interactive: Bool) {
        self.pid = pid
        self.cwd = cwd
        self.environ = environ
        self.stdinFD = stdinFD
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
        self.interactive = interactive
    }

    /// Install a handler for a specific signal.
    public func onSignal(_ sig: Int32, handler: @escaping () -> Void) {
        lock.lock()
        signalHandlers[sig] = handler
        lock.unlock()
    }

    /// Signals that request cooperative cancellation of the running command.
    private static let interruptingSignals: Set<Int32> = [SIGINT, SIGQUIT]
    /// Signals that ask the process itself to end.
    private static let terminatingSignals: Set<Int32> = [SIGTERM, SIGHUP, SIGKILL]

    /// Deliver a signal to this process.
    ///
    /// Informational signals (SIGWINCH, SIGCONT, SIGCHLD, …) run their handler without
    /// flagging cancellation — a window resize must never interrupt or end the shell.
    public func deliverSignal(_ sig: Int32) {
        lock.lock()
        if Self.interruptingSignals.contains(sig) { isSignalled = true }
        // We already own `lock`; assigning through the public property would try
        // to acquire the same non-recursive lock again and deadlock on SIGTERM.
        if Self.terminatingSignals.contains(sig) { _shouldTerminate = true }
        let handler = signalHandlers[sig]
        lock.unlock()
        handler?()
    }

    /// Check if this process has received a signal (for cooperative cancellation).
    public var interrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isSignalled
    }

    /// True once a terminating signal (SIGTERM/SIGHUP/SIGKILL) has been delivered.
    public var shouldTerminate: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _shouldTerminate }
        set { lock.lock(); _shouldTerminate = newValue; lock.unlock() }
    }

    /// Clear the signal flag (after handling).
    public func clearSignal() {
        lock.lock()
        isSignalled = false
        lock.unlock()
    }

    /// Mark as running on the current thread.
    func markRunning() {
        lock.lock()
        isRunning = true
        lock.unlock()
    }

    /// Mark as finished with the given exit code.
    func markFinished(exitCode: Int32) {
        lock.lock()
        self.exitCode = exitCode
        self.isRunning = false
        lock.unlock()
    }

    /// Write data to this process's stdout fd.
    public func writeStdout(_ string: String) {
        if stdoutFD < 0, let stdoutWriter {
            stdoutWriter(string)
            return
        }
        guard stdoutFD >= 0 else { return }
        let data = Array(string.utf8)
        data.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let written = write(stdoutFD, base.advanced(by: offset), remaining)
                if written <= 0 { break }
                offset += written
                remaining -= written
            }
        }
    }

    /// Write data to this process's stderr fd.
    public func writeStderr(_ string: String) {
        if stderrFD < 0, let stderrWriter {
            stderrWriter(string)
            return
        }
        guard stderrFD >= 0 else { return }
        let data = Array(string.utf8)
        data.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let written = write(stderrFD, base.advanced(by: offset), remaining)
                if written <= 0 { break }
                offset += written
                remaining -= written
            }
        }
    }
}

// MARK: - PID Allocator

/// Thread-safe PID allocator. PIDs start at 1 and increment monotonically.
public final class PIDAllocator: @unchecked Sendable {
    private var next: TermXPID = 1
    private let lock = NSLock()

    public init() {}

    public func allocate() -> TermXPID {
        lock.lock()
        defer { lock.unlock() }
        let pid = next
        next += 1
        return pid
    }
}

// MARK: - Process Table

/// Global table of all running virtual processes, indexed by PID.
public final class ProcessTable: @unchecked Sendable {
    private var processes: [TermXPID: VirtualProcess] = [:]
    private let lock = NSLock()

    public init() {}

    public func register(_ process: VirtualProcess) {
        lock.lock()
        processes[process.pid] = process
        lock.unlock()
    }

    public func remove(_ pid: TermXPID) {
        lock.lock()
        processes.removeValue(forKey: pid)
        lock.unlock()
    }

    public func get(_ pid: TermXPID) -> VirtualProcess? {
        lock.lock()
        defer { lock.unlock() }
        return processes[pid]
    }

    public func signal(_ pid: TermXPID, _ sig: Int32) -> Bool {
        lock.lock()
        let process = processes[pid]
        lock.unlock()
        guard let process else { return false }
        process.deliverSignal(sig)
        return true
    }

    public var allProcesses: [VirtualProcess] {
        lock.lock()
        defer { lock.unlock() }
        return Array(processes.values)
    }
}

// MARK: - Thread-Local Current Process

/// Provides thread-local access to the currently running VirtualProcess.
/// This enables per-"process" cwd, environ, and fd isolation — the core of
/// ios_system's in-process model.
public enum ProcessContext {
    private static let key = "com.termx.currentProcess"

    public static var current: VirtualProcess? {
        get { Thread.current.threadDictionary[key] as? VirtualProcess }
        set { Thread.current.threadDictionary[key] = newValue }
    }
}
