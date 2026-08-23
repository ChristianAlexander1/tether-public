import Foundation

/// Reads bytes from a shell pipe fd before handing work to the embedded Node engine.
///
/// nodejs-mobile often fails to poll borrowed pipe fds after heavy CLIs (npm). Slurping
/// in Swift (same process, same fds) avoids JS spin-waits and guarantees EOF.
enum NodeStdinSlurp {
    private static let chunkSize = 64 * 1024
    private static let defaultMaxBytes = 8 * 1024 * 1024
    private static let defaultTimeoutMs = 2_000

    /// Returns slurped bytes for a non-TTY readable fd, or `nil` when stdin should stay default.
    static func readPipeIfNeeded(fd: Int32, maxBytes: Int = defaultMaxBytes,
                                 timeoutMs: Int = defaultTimeoutMs) -> Data? {
        guard fd >= 0, isatty(fd) == 0 else { return nil }

        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var collected = Data()
        collected.reserveCapacity(min(maxBytes, chunkSize))
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000

        while collected.count < maxBytes {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                collected.append(contentsOf: buffer[0..<n])
                continue
            }
            if n == 0 { break }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                if DispatchTime.now().uptimeNanoseconds >= deadline { break }
                usleep(5_000)
                continue
            }
            break
        }
        return collected
    }
}
