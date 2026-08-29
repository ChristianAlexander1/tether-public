import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Creates a pipe pair and returns (readFD, writeFD).
enum NodePipe {
    static func pair() -> (read: Int32, write: Int32)? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        return (fds[0], fds[1])
    }

    static func close(_ fd: Int32) {
        if fd >= 0 { _ = Darwin.close(fd) }
    }
}

enum NodeStdioBridge {
    /// Redirects process stdout/stderr to the job's PTY fds for the duration of `body`.
    ///
    /// Stdin is never bound to the PTY slave. nodejs-mobile fails to poll a
    /// borrowed fd after npm; live input travels over TJIP/2 `tty.stdin`
    /// instead (see `NodeStdinPump`). Output still needs the real descriptors
    /// so TUI bytes appear on the terminal.
    static func withRedirectedIO(
        stdinFD: Int32,
        stdoutFD: Int32,
        stderrFD: Int32,
        interactive: Bool,
        body: () -> Int32
    ) -> Int32 {
        _ = stdinFD
        _ = interactive
        guard stdoutFD >= 0 || stderrFD >= 0 else { return body() }

        let origOut = stdoutFD >= 0 ? dup(STDOUT_FILENO) : -1
        let origErr = stderrFD >= 0 ? dup(STDERR_FILENO) : -1

        if stdoutFD >= 0 { _ = dup2(stdoutFD, STDOUT_FILENO) }
        if stderrFD >= 0 { _ = dup2(stderrFD, STDERR_FILENO) }

        let code = body()

        if origOut >= 0 { dup2(origOut, STDOUT_FILENO); close(origOut) }
        if origErr >= 0 { dup2(origErr, STDERR_FILENO); close(origErr) }
        return code
    }

    /// Redirects process stdout/stderr to target fds for the duration of `body`.
    static func withRedirectedOutput(stdoutFD: Int32, stderrFD: Int32, body: () -> Int32) -> Int32 {
        withRedirectedIO(stdinFD: -1, stdoutFD: stdoutFD, stderrFD: stderrFD, interactive: false, body: body)
    }
}

/// Applies real termios raw/cooked mode on the Darwin PTY backing an interactive job.
/// Node's `tty.setRawMode` shim calls this over IPC so Ink-style TUIs get character input.
enum PtyTermios {
    private static let lock = NSLock()
    private static var saved: [Int32: termios] = [:]

    static func setRawMode(fd: Int32, enabled: Bool) -> Bool {
        guard fd >= 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        if enabled {
            var original = termios()
            guard tcgetattr(fd, &original) == 0 else { return false }
            if saved[fd] == nil {
                saved[fd] = original
            }
            var raw = original
            cfmakeraw(&raw)
            raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG)
            return tcsetattr(fd, TCSANOW, &raw) == 0
        } else {
            if var original = saved.removeValue(forKey: fd) {
                return tcsetattr(fd, TCSANOW, &original) == 0
            }
            var current = termios()
            guard tcgetattr(fd, &current) == 0 else { return false }
            current.c_lflag |= tcflag_t(ECHO | ICANON | ISIG)
            current.c_iflag |= tcflag_t(ICRNL | IXON)
            current.c_oflag |= tcflag_t(OPOST)
            return tcsetattr(fd, TCSANOW, &current) == 0
        }
    }

    /// Whether the terminal is currently in raw mode, read from the live
    /// termios rather than from bookkeeping — a program can change the mode
    /// behind our back, and the protocol must report what is true now.
    static func isRawMode(fd: Int32) -> Bool {
        guard fd >= 0 else { return false }
        var current = termios()
        guard tcgetattr(fd, &current) == 0 else { return false }
        return (current.c_lflag & tcflag_t(ICANON)) == 0 && (current.c_lflag & tcflag_t(ECHO)) == 0
    }

    static func windowSize(fd: Int32) -> (cols: Int, rows: Int)? {
        guard fd >= 0 else { return nil }
        var size = winsize()
        guard ioctl(fd, TIOCGWINSZ, &size) == 0 else { return nil }
        let cols = Int(size.ws_col)
        let rows = Int(size.ws_row)
        guard cols > 0, rows > 0 else { return nil }
        return (cols, rows)
    }

    /// Push a new window size onto a PTY master and notify the foreground job.
    @discardableResult
    static func setWindowSize(fd: Int32, cols: Int, rows: Int) -> Bool {
        guard fd >= 0, cols > 0, rows > 0 else { return false }
        var size = winsize()
        size.ws_col = UInt16(min(cols, Int(UInt16.max)))
        size.ws_row = UInt16(min(rows, Int(UInt16.max)))
        return ioctl(fd, TIOCSWINSZ, &size) == 0
    }
}

/// Drains a PTY slave (or other readable fd) and forwards bytes to the TJIP/2
/// session. Idle poll timeouts are not EOF — a terminal stays open.
final class NodeStdinPump {
    private let fd: Int32
    private let onBytes: (Data) -> Void
    private let lock = NSLock()
    private var stopped = false
    /// Signalled once `run()` has left its loop and restored the fd. `stop()`
    /// waits on this so no byte is consumed after the job it belonged to.
    private let finished = DispatchSemaphore(value: 0)
    private var started = false

    init(fd: Int32, onBytes: @escaping (Data) -> Void) {
        self.fd = fd
        self.onBytes = onBytes
    }

    func start() {
        lock.lock()
        started = true
        lock.unlock()
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "app.tether.node.stdin"
        thread.start()
    }

    /// Stops the pump and does not return until the reader thread has actually
    /// exited.
    ///
    /// This used to just set the flag and return. The pump shares the login
    /// PTY slave with the guest shell, so a thread still sitting in `read()`
    /// after the job finished would swallow the first keystrokes of the *next*
    /// prompt — which is what turned a typed `claude` into `clclaude`. The
    /// poll timeout bounds the wait to one tick; the extra margin is only a
    /// guard against a descriptor that never becomes readable.
    func stop() {
        lock.lock()
        stopped = true
        let wasStarted = started
        lock.unlock()
        guard wasStarted else { return }
        _ = finished.wait(timeout: .now() + 1.0)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func run() {
        // O_NONBLOCK lives on the open file description, which this PTY slave
        // shares with the guest login shell. Setting it and walking away left
        // the shell's own reads non-blocking for the rest of the session after
        // the very first host-backed job — a permanent, invisible degradation.
        // Take the flag for the pump's lifetime only, and always hand it back.
        let originalFlags = fcntl(fd, F_GETFL)
        if originalFlags >= 0 {
            _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
        }
        defer {
            if originalFlags >= 0 {
                _ = fcntl(fd, F_SETFL, originalFlags)
            }
            finished.signal()
        }
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while !isStopped {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 200)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            // Timeout: the user typed nothing. That is not stdin EOF.
            if ready == 0 { continue }
            if pfd.revents & Int16(POLLNVAL) != 0 { return }

            let n = read(fd, &buf, buf.count)
            if n > 0 {
                let chunk = Data(buf[0..<n])
                onBytes(chunk)
                continue
            }
            if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue
            }
            // Real EOF or a permanent error. The login PTY is still open for
            // the shell; this is the job's view of the slave going away.
            return
        }
    }
}

