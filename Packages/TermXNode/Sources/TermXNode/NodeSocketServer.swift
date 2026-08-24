import Foundation

/// Unix domain socket IPC for @termx/shim ↔ Swift spawn bridge (works across Process boundaries).
final class NodeSocketServer {
    private let socketPath: String
    private var serverFD: Int32 = -1
    private var acceptThread: Thread?
    private var running = false
    private let lock = NSLock()

    init?(directory: String) {
        _ = directory
        socketPath = "/tmp/tether-\(UUID().uuidString.prefix(8)).sock"
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let pathPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                strncpy(pathPtr, cstr, 104)
            }
        }
        unlink(socketPath)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFD, $0, size)
            }
        }
        guard bindResult == 0, listen(serverFD, 8) == 0 else {
            close(serverFD)
            return nil
        }
    }

    func start(bridge: NodeSpawnBridge, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
               cwd: String, env: [String: String], interactive: Bool) {
        lock.lock()
        running = true
        lock.unlock()
        acceptThread = Thread { [weak self] in
            guard let self else { return }
            usleep(10_000)
            while self.isRunning {
                var clientAddr = sockaddr()
                var len: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
                let client = accept(self.serverFD, &clientAddr, &len)
                if client < 0 { continue }
                // A preload keeps one asynchronous IPC socket open for the life of
                // Node, while spawnSync uses a short-lived helper connection. Serving
                // clients inline would let the persistent connection monopolize the
                // accept loop and deadlock every synchronous child-process request.
                let clientThread = Thread { [weak self] in
                    guard let self else {
                        close(client)
                        return
                    }
                    self.handleClient(
                        client, bridge: bridge, stdinFD: stdinFD, stdoutFD: stdoutFD,
                        stderrFD: stderrFD, cwd: cwd, env: env, interactive: interactive
                    )
                    close(client)
                }
                clientThread.name = "com.tether.node.ipc-client"
                clientThread.start()
            }
        }
        acceptThread?.start()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
        unlink(socketPath)
    }

    var path: String { socketPath }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func handleClient(_ client: Int32, bridge: NodeSpawnBridge,
                                stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
                                cwd: String, env: [String: String], interactive: Bool) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let range = buffer.firstRange(of: Data([0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                guard !line.isEmpty else { continue }
                let response = bridge.handle(
                    requestData: line, stdinFD: stdinFD, stdoutFD: stdoutFD, stderrFD: stderrFD,
                    defaultCWD: cwd, defaultEnv: env, interactive: interactive
                )
                Self.writeAll(response, to: client)
            }
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = write(fd, base.advanced(by: written), raw.count - written)
                if count > 0 {
                    written += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    deinit { stop() }
}

private extension Data {
    func firstRange(of sub: Data) -> Range<Data.Index>? {
        guard !sub.isEmpty, count >= sub.count else { return nil }
        for i in 0...(count - sub.count) {
            if self[i..<(i + sub.count)] == sub { return i..<(i + sub.count) }
        }
        return nil
    }
}
