import Foundation

#if canImport(Darwin)
import Darwin

/// Owns the master/slave descriptor pair for one interactive terminal session.
/// The slave is handed to TermXCore; the master is used by the SwiftTerm bridge.
public final class PtyPair {
    public let master: Int32
    public let slave: Int32
    private var closed = false
    private var storedCols: Int
    private var storedRows: Int
    /// True when this pair is an emulated stream (a Unix socketpair) rather
    /// than a real PTY device. The iOS sandbox on physical devices denies
    /// opening a terminal device (openpty fails with EPERM), which the
    /// Simulator never reproduces, so device builds fall back to a
    /// bidirectional stream pair behind the same master/slave interface.
    /// The byte flow is identical for the session and engines; only kernel
    /// termios behaviour (isatty, winsize ioctls) is absent, and the size is
    /// tracked in memory instead.
    public let isEmulated: Bool

    public init(cols: Int = 80, rows: Int = 24) throws {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var emulated = false
        if openpty(&masterFD, &slaveFD, nil, nil, nil) != 0 {
            var fds: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
                throw PtyError.openFailed(errno)
            }
            masterFD = fds[0]
            slaveFD = fds[1]
            emulated = true
        }
        self.master = masterFD
        self.slave = slaveFD
        self.isEmulated = emulated
        self.storedCols = max(1, cols)
        self.storedRows = max(1, rows)
        resize(cols: cols, rows: rows)
    }

    public func resize(cols: Int, rows: Int) {
        storedCols = max(1, cols)
        storedRows = max(1, rows)
        var size = winsize(ws_row: UInt16(storedRows), ws_col: UInt16(storedCols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    public func currentSize() -> (cols: Int, rows: Int) {
        var size = winsize()
        if ioctl(master, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 {
            return (Int(size.ws_col), Int(size.ws_row))
        }
        return (storedCols, storedRows)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        _ = Darwin.close(master)
        _ = Darwin.close(slave)
    }

    deinit { close() }
}

public enum PtyError: Error, Equatable, LocalizedError {
    case openFailed(Int32)
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .openFailed(let code):
            return "Could not open a terminal device (errno \(code))."
        case .unsupported:
            return "PTY sessions are not supported on this platform."
        }
    }
}
#else
/// POSIX PTYs are supplied by Darwin on iOS. This declaration keeps the package
/// importable by documentation and source-indexing tools on non-Darwin hosts.
public final class PtyPair {
    public let master: Int32 = -1
    public let slave: Int32 = -1
    public init(cols: Int = 80, rows: Int = 24) throws { throw PtyError.unsupported }
    public func resize(cols: Int, rows: Int) {}
    public func close() {}
}
public enum PtyError: Error, Equatable { case unsupported }
#endif
