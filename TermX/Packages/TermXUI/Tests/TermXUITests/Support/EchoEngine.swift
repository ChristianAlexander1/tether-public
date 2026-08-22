import Foundation
@testable import TermXUI

#if canImport(Darwin)
import Darwin

/// Echo test double: decouples PTY slave reads and writes onto separate threads.
final class EchoEngine: TerminalEngine {
    private let lock = NSLock()
    private var shouldStop = false

    func startShell(cwd: String, env: [String: String], ptySlave: Int32, onExit: @escaping (Int32) -> Void) throws -> Int32 {
        lock.lock()
        shouldStop = false
        lock.unlock()

        let pending = EchoBuffer()
        let pid: Int32 = 42_001

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while self?.shouldStop == false {
                let count = Darwin.read(ptySlave, &buffer, buffer.count)
                if count > 0 {
                    pending.append(Data(buffer[0..<count]))
                } else if count < 0 && errno != EINTR {
                    break
                }
            }
            onExit(0)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while self?.shouldStop == false {
                guard let chunk = pending.take(), !chunk.isEmpty else {
                    usleep(2000)
                    continue
                }
                chunk.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    var remaining = chunk.count
                    var offset = 0
                    while remaining > 0 {
                        let written = Darwin.write(ptySlave, base.advanced(by: offset), remaining)
                        if written > 0 {
                            offset += written
                            remaining -= written
                            continue
                        }
                        if written < 0 && errno == EINTR { continue }
                        pending.prepend(Data(chunk[offset...]))
                        usleep(2000)
                        break
                    }
                }
            }
        }

        return pid
    }

    func signal(pid: Int32, _ sig: Int32) {
        if sig == SIGINT || sig == SIGTERM {
            lock.lock()
            shouldStop = true
            lock.unlock()
        }
    }
}

private final class EchoBuffer {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func prepend(_ chunk: Data) {
        lock.lock()
        data.insert(contentsOf: chunk, at: 0)
        lock.unlock()
    }

    func take() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !data.isEmpty else { return nil }
        let chunk = data
        data = Data()
        return chunk
    }
}
#endif
