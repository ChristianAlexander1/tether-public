import Foundation

#if canImport(Darwin)
import Darwin

/// Owns the master/slave descriptor pair for one interactive terminal session.
/// The slave is handed to TermXCore; the master is used by the SwiftTerm bridge.
public final class PtyPair {
    public let master: Int32
    public let slave: Int32
    private var closed = false

    public init(cols: Int = 80, rows: Int = 24) throws {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            throw PtyError.openFailed(errno)
        }
        self.master = masterFD
        self.slave = slaveFD
        resize(cols: cols, rows: rows)
    }

    public func resize(cols: Int, rows: Int) {
        var size = winsize(ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(1, cols)), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    public func currentSize() -> (cols: Int, rows: Int) {
        var size = winsize()
        _ = ioctl(master, TIOCGWINSZ, &size)
        return (max(1, Int(size.ws_col)), max(1, Int(size.ws_row)))
    }

    public func close() {
        guard !closed else { return }
        closed = true
        _ = Darwin.close(master)
        _ = Darwin.close(slave)
    }

    deinit { close() }
}

public enum PtyError: Error, Equatable {
    case openFailed(Int32)
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
