import Foundation
import TetherJobIPC

/// `JIPTransport` over an accepted `AF_UNIX` stream socket.
///
/// `TetherJobIPC` is deliberately free of sockets and threads: it assumes one
/// serial queue owns both directions of a connection. This type supplies that
/// discipline. A dedicated reader thread does the blocking `read(2)` and hands
/// every chunk to the session on `queue`; `send` is only ever called from that
/// same queue, so no lock is needed around the fd.
final class JIPSocketTransport: JIPTransport {
    var onReceive: ((Data) -> Void)?

    private let fd: Int32
    private let queue: DispatchQueue
    private var readerThread: Thread?
    private let stateLock = NSLock()
    private var closed = false

    /// Called once the peer disconnects or the socket errors.
    var onDisconnect: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    func startReading() {
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "app.tether.jip.reader"
        thread.stackSize = 512 * 1024
        thread.start()
        readerThread = thread
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while !isClosed {
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress, raw.count)
            }
            if n > 0 {
                let data = Data(chunk[0..<n])
                queue.async { [weak self] in self?.onReceive?(data) }
                continue
            }
            if n < 0 && errno == EINTR { continue }
            break // EOF or unrecoverable error
        }
        queue.async { [weak self] in self?.onDisconnect?() }
    }

    func send(_ data: Data) throws {
        guard !isClosed else {
            throw JIPError(code: JIPErrorCode.eio, message: "transport closed")
        }
        var written = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while written < raw.count {
                let n = write(fd, base.advanced(by: written), raw.count - written)
                if n > 0 { written += n; continue }
                if n < 0 && errno == EINTR { continue }
                throw JIPError(code: JIPErrorCode.eio,
                               message: "short write on IPC socket (errno \(errno))")
            }
        }
    }

    func close() {
        stateLock.lock()
        let alreadyClosed = closed
        closed = true
        stateLock.unlock()
        guard !alreadyClosed else { return }
        // Wakes the blocked reader; the fd itself is closed by the owner of the
        // accept loop once the reader has stopped touching it.
        shutdown(fd, SHUT_RDWR)
    }

    /// Closes the descriptor. Only safe once the reader thread has exited, which
    /// `onDisconnect` signals — the repo invariant is never to close a
    /// descriptor a thread is still blocked on.
    func releaseDescriptor() {
        Darwin.close(fd)
    }

    private var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }
}
