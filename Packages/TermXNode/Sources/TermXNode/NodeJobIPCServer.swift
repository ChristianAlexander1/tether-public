import Foundation
#if canImport(Darwin)
import Darwin
#endif
import TermXFiles
import TetherJobControl
import TetherJobIPC

/// TJIP/2 server: accepts shim connections on a Unix socket and drives one
/// `JIPServerSession` per connection.
///
/// Replaces the newline-delimited ad-hoc JSON of `NodeSocketServer`. Each
/// connection gets its own serial queue, which is the discipline `TetherJobIPC`
/// requires: inbound bytes, host pushes, and delegate calls are all serialized
/// there, so the session itself needs no locks.
final class NodeJobIPCServer {
    private final class Connection {
        let transport: JIPSocketTransport
        let session: JIPServerSession
        let runner: NodeJobSpawnRunner
        let queue: DispatchQueue

        init(transport: JIPSocketTransport, session: JIPServerSession,
             runner: NodeJobSpawnRunner, queue: DispatchQueue) {
            self.transport = transport
            self.session = session
            self.runner = runner
            self.queue = queue
        }
    }

    private let socketPath: String
    private var serverFD: Int32 = -1
    private var acceptThread: Thread?
    private let lock = NSLock()
    private var running = false
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var connectionSerial = 0

    private let executor: SpawnExecuting
    private let clock: JobClock

    init?(executor: SpawnExecuting, clock: JobClock = DispatchJobClock()) {
        self.executor = executor
        self.clock = clock
        socketPath = "/tmp/tether-jip-\(UUID().uuidString.prefix(8)).sock"
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
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverFD, $0, size) }
        }
        guard bound == 0, listen(serverFD, 8) == 0 else {
            close(serverFD)
            serverFD = -1
            return nil
        }
    }

    var path: String { socketPath }

    func start(stdio: NodeJobStdio, cwd: String, env: [String: String]) {
        lock.lock(); running = true; lock.unlock()
        let thread = Thread { [weak self] in
            guard let self else { return }
            while self.isRunning {
                var clientAddr = sockaddr()
                var len = socklen_t(MemoryLayout<sockaddr>.size)
                let client = accept(self.serverFD, &clientAddr, &len)
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                self.acceptConnection(fd: client, stdio: stdio, cwd: cwd, env: env)
            }
        }
        thread.name = "app.tether.jip.accept"
        thread.start()
        acceptThread = thread
    }

    private func acceptConnection(fd: Int32, stdio: NodeJobStdio, cwd: String, env: [String: String]) {
        lock.lock()
        connectionSerial += 1
        let serial = connectionSerial
        lock.unlock()

        // One serial queue per connection: both directions of the protocol and
        // every delegate call run here, which is what lets the session and the
        // job table stay lock-free.
        let queue = DispatchQueue(label: "app.tether.jip.conn.\(serial)", qos: .userInitiated)
        let transport = JIPSocketTransport(fd: fd, queue: queue)
        let runner = NodeJobSpawnRunner(
            executor: executor, stdio: stdio, defaultCWD: cwd, defaultEnv: env,
            queue: queue, clock: clock
        )
        let host = NodeJobHost(stdio: stdio, env: env, runner: runner)
        let session = JIPServerSession(transport: transport, delegate: host)
        runner.session = session

        let connection = Connection(transport: transport, session: session, runner: runner, queue: queue)
        let key = ObjectIdentifier(connection)

        session.onProtocolError = { error in
            SystemOpen.log("jip: protocol error \(error.code): \(error.message)")
        }
        transport.onDisconnect = { [weak self] in
            transport.releaseDescriptor()
            self?.removeConnection(key)
        }

        lock.lock(); connections[key] = connection; lock.unlock()
        transport.startReading()
    }

    private func removeConnection(_ key: ObjectIdentifier) {
        lock.lock()
        let connection = connections.removeValue(forKey: key)
        lock.unlock()
        connection?.queue.async { connection?.session.close() }
    }

    // MARK: - Host pushes

    /// Push a new terminal geometry to every live shim. This is what delivers a
    /// real `SIGWINCH` into a Node TUI — the old shim polled for its size and
    /// therefore never reflowed on rotation.
    func pushResize(cols: Int, rows: Int) {
        forEachConnection { connection in
            connection.session.pushResize(cols: cols, rows: rows)
            connection.runner.signalForeground(.winch)
        }
    }

    /// Route a terminal-generated signal (Ctrl-C and friends) to the shim and
    /// to the foreground job of that connection.
    func pushSignal(_ name: String) {
        forEachConnection { connection in
            connection.session.pushSignal(name)
            if let signal = JobSignal(rawValue: name) {
                connection.runner.signalForeground(signal)
            }
        }
    }

    private func forEachConnection(_ body: @escaping (Connection) -> Void) {
        lock.lock()
        let live = Array(connections.values)
        lock.unlock()
        for connection in live {
            connection.queue.async { body(connection) }
        }
    }

    func stop() {
        lock.lock()
        running = false
        let live = Array(connections.values)
        connections.removeAll()
        let fd = serverFD
        serverFD = -1
        lock.unlock()

        for connection in live {
            connection.transport.close()
            connection.queue.async { connection.session.close() }
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(socketPath)
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    deinit { stop() }
}

/// `JobClock` backed by `DispatchQueue.asyncAfter`, for the termination
/// escalation timers. `TetherJobControl` ships only a deterministic fake so it
/// can stay dependency-free; this is the real one.
final class DispatchJobClock: JobClock {
    private let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue(label: "app.tether.jobclock")) {
        self.queue = queue
    }

    private final class Token: JobClockToken {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    func schedule(afterMillis: Int, _ work: @escaping () -> Void) -> JobClockToken {
        let token = Token()
        queue.asyncAfter(deadline: .now() + .milliseconds(max(0, afterMillis))) {
            guard !token.isCancelled else { return }
            work()
        }
        return token
    }
}
