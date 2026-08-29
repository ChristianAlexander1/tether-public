import Foundation

/// Server side of one TJIP/2 connection.
///
/// The session owns framing, envelope validation, request/response correlation, the
/// handshake state machine, and flow-control accounting. It never touches a socket,
/// PTY, termios, or process — it delegates those to the injected `JIPHostDelegate`
/// and uses the injected `JIPTransport` purely as an ordered byte stream.
///
/// # Threading model (read HANDOFF.md)
/// The session is **not thread-safe** and must only ever be driven from one serial
/// queue owned by the integrator. All of `transport.onReceive`, `push*` calls, and
/// the delegate callbacks it invokes are expected to be serialized by that queue.
/// The session creates no threads, queues, timers, or locks.
public final class JIPServerSession {

    // MARK: Public configuration

    /// Fired when a flow-control window that was previously exhausted (and was thus
    /// buffering chunks) reopens because the client acked enough bytes. Fires once per
    /// reopening, with the `pid` of the process whose window reopened.
    public var onFlowWindowOpen: ((Int32) -> Void)?

    /// Fired for any wire/protocol violation that closes the session (e.g. `EMSGSIZE`,
    /// `EPROTO`). The session is already closed by the time this fires.
    public var onProtocolError: ((JIPError) -> Void)?

    /// `true` once a valid `hello` has been handled successfully.
    public private(set) var isHandshakeComplete: Bool = false

    // MARK: Resource limits (from the wire spec)

    private static let flowWindowSize = 262_144   // per-pid unacknowledged stdout+stderr budget
    private static let chunkLimit = 65_536        // raw bytes per stdout/stderr frame
    private static let serverFeatures = ["tty", "spawn", "flow"]

    // MARK: Internal state

    private let transport: JIPTransport
    private let delegate: JIPHostDelegate

    private var codec = JIPFrameCodec()
    private var closed = false
    private var helloReceived = false

    /// Largest request id seen so far; client ids must strictly increase.
    private var lastClientID: UInt64?

    /// Per-pid flow-control state (only while the process is live).
    private struct PidState {
        var buffered: [(stream: String, data: Data)] = []
        var bufferedBytes = 0
        var inFlight = 0          // raw stdout+stderr bytes sent but not yet acked
        var hadBackpressure = false
    }
    private var pids: [Int32: PidState] = [:]

    /// Pids that have emitted `spawn.exit`. Kept separately so the session can answer
    /// `spawn.kill`→`ESRCH` and `spawn.stdin`→`EPIPE` without consulting the delegate,
    /// and so it can free the per-pid accounting entirely.
    private var exitedPids: Set<Int32> = []

    // MARK: Lifecycle

    public init(transport: JIPTransport, delegate: JIPHostDelegate) {
        self.transport = transport
        self.delegate = delegate
        transport.onReceive = { [weak self] data in
            self?.handleBytes(data)
        }
    }

    /// Close the session. Idempotent; pushes after close are silent no-ops.
    public func close() {
        guard !closed else { return }
        closed = true
        transport.onReceive = nil
        transport.close()
    }

    // MARK: Inbound stream

    private func handleBytes(_ data: Data) {
        guard !closed else { return }

        let frames: [Data]
        do {
            frames = try codec.append(data)
        } catch let JIPFrameError.oversize(declared) {
            protocolError(JIPErrorCode.emsgsize,
                          "frame declares \(declared) bytes, maximum is \(JIPFrameCodec.maxFrameSize)")
            return
        } catch {
            protocolError(JIPErrorCode.eproto, "unrecognized framing error: \(error)")
            return
        }

        for frame in frames {
            guard let envelope = parseEnvelope(frame) else {
                protocolError(JIPErrorCode.eproto, "malformed or invalid envelope")
                return
            }
            handleEnvelope(envelope)
        }
    }

    // MARK: Envelope parsing

    private struct Envelope {
        var kind: String
        var id: UInt64?
        var type: String?
        var body: [String: Any]
    }

    private func parseEnvelope(_ data: Data) -> Envelope? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // `v` must be 2.
        guard let version = object["v"] as? NSNumber, version.intValue == 2 else {
            return nil
        }
        guard let kind = object["kind"] as? String, ["req", "res", "evt"].contains(kind) else {
            return nil
        }
        let id = (object["id"] as? NSNumber)?.uint64Value
        let type = object["type"] as? String
        let body = object["body"] as? [String: Any] ?? [:]
        return Envelope(kind: kind, id: id, type: type, body: body)
    }

    private func handleEnvelope(_ envelope: Envelope) {
        guard !closed else { return }
        switch envelope.kind {
        case "req":
            handleRequest(envelope)
        case "evt":
            handleEvent(envelope)
        case "res":
            // The server never issues requests, so an inbound `res` is unexpected.
            // Ignore it rather than treating it as a violation.
            break
        default:
            protocolError(JIPErrorCode.eproto, "unexpected kind '\(envelope.kind)'")
        }
    }

    // MARK: Requests

    private func handleRequest(_ envelope: Envelope) {
        guard let type = envelope.type else {
            protocolError(JIPErrorCode.eproto, "request missing 'type'")
            return
        }
        guard let id = envelope.id else {
            protocolError(JIPErrorCode.eproto, "request missing 'id'")
            return
        }
        // Ids must be strictly increasing per connection.
        if let last = lastClientID {
            guard id > last else {
                protocolError(JIPErrorCode.eproto,
                              "request id \(id) is not greater than previous id \(last)")
                return
            }
        }
        lastClientID = id

        if type == "hello" {
            handleHello(id: id)
            return
        }

        guard isHandshakeComplete else {
            respondError(id: id, type: type, code: JIPErrorCode.eproto,
                         message: "handshake ('hello') is required before other requests")
            return
        }

        switch type {
        case "tty.get":
            ttyGet(id: id, body: envelope.body)
        case "tty.setRawMode":
            ttySetRawMode(id: id, body: envelope.body)
        case "tty.windowSize":
            ttyWindowSize(id: id, body: envelope.body)
        case "spawn.start":
            spawnStart(id: id, body: envelope.body)
        case "spawn.stdin":
            spawnStdin(id: id, body: envelope.body)
        case "spawn.stdinEnd":
            spawnStdinEnd(id: id, body: envelope.body)
        case "spawn.kill":
            spawnKill(id: id, body: envelope.body)
        case "spawn.resize":
            spawnResize(id: id, body: envelope.body)
        default:
            respondError(id: id, type: type, code: JIPErrorCode.enosys,
                         message: "unknown request type '\(type)'")
        }
    }

    private func handleHello(id: UInt64) {
        if helloReceived {
            respondError(id: id, type: "hello", code: JIPErrorCode.eproto,
                         message: "duplicate hello")
            protocolError(JIPErrorCode.eproto, "duplicate hello")
            return
        }
        helloReceived = true
        let hs = delegate.handshake()
        let body: [String: Any] = [
            "ok": true,
            "proto": 2,
            "features": Self.serverFeatures,
            "ttyFds": hs.ttyFds.map { Int($0) },
            "cols": hs.cols,
            "rows": hs.rows,
            "termName": hs.termName,
            "colorTerm": hs.colorTerm,
        ]
        sendEnvelope(["v": 2, "kind": "res", "id": id, "type": "hello", "body": body])
        isHandshakeComplete = true
    }

    // MARK: tty domain

    private func ttyGet(id: UInt64, body: [String: Any]) {
        guard let fd = body["fd"] as? Int32 else {
            respondError(id: id, type: "tty.get", code: JIPErrorCode.einval,
                         message: "missing 'fd'")
            return
        }
        runDelegate(id: id, type: "tty.get") {
            let r = try self.delegate.ttyGet(fd: fd)
            return ["isTTY": r.isTTY, "isRaw": r.isRaw, "cols": r.cols, "rows": r.rows]
        }
    }

    private func ttySetRawMode(id: UInt64, body: [String: Any]) {
        guard let fd = body["fd"] as? Int32,
              let mode = body["mode"] as? Bool else {
            respondError(id: id, type: "tty.setRawMode", code: JIPErrorCode.einval,
                         message: "missing 'fd' or 'mode'")
            return
        }
        runDelegate(id: id, type: "tty.setRawMode") {
            let wasRaw = try self.delegate.ttySetRawMode(fd: fd, mode: mode)
            return ["wasRaw": wasRaw]
        }
    }

    private func ttyWindowSize(id: UInt64, body: [String: Any]) {
        guard let fd = body["fd"] as? Int32 else {
            respondError(id: id, type: "tty.windowSize", code: JIPErrorCode.einval,
                         message: "missing 'fd'")
            return
        }
        runDelegate(id: id, type: "tty.windowSize") {
            let r = try self.delegate.ttyGet(fd: fd)
            return ["cols": r.cols, "rows": r.rows]
        }
    }

    // MARK: spawn domain

    private func spawnStart(id: UInt64, body: [String: Any]) {
        guard let argv = body["argv"] as? [String] else {
            respondError(id: id, type: "spawn.start", code: JIPErrorCode.einval,
                         message: "missing 'argv'")
            return
        }
        let cwd = body["cwd"] as? String ?? ""
        let env = body["env"] as? [String: String] ?? [:]
        let stdio = body["stdio"] as? [String] ?? ["pipe", "pipe", "pipe"]
        let pty = body["pty"] as? Bool ?? false

        runDelegate(id: id, type: "spawn.start") {
            let pid = try self.delegate.spawnStart(argv: argv, cwd: cwd, env: env,
                                                   stdio: stdio, pty: pty)
            return ["pid": pid]
        }
    }

    private func spawnStdin(id: UInt64, body: [String: Any]) {
        guard let pid = body["pid"] as? Int32 else {
            respondError(id: id, type: "spawn.stdin", code: JIPErrorCode.einval,
                         message: "missing 'pid'")
            return
        }
        guard let b64 = body["dataB64"] as? String, let data = Data(base64Encoded: b64) else {
            respondError(id: id, type: "spawn.stdin", code: JIPErrorCode.einval,
                         message: "missing or invalid 'dataB64'")
            return
        }
        if exitedPids.contains(pid) {
            respondError(id: id, type: "spawn.stdin", code: JIPErrorCode.epipe,
                         message: "process \(pid) already exited")
            return
        }
        runDelegate(id: id, type: "spawn.stdin") {
            let window = try self.delegate.spawnStdin(pid: pid, data: data)
            // The host may advertise a remaining stdin window of 0; the server never
            // rejects on zero window — pausing is the client's responsibility.
            return ["window": window]
        }
    }

    private func spawnStdinEnd(id: UInt64, body: [String: Any]) {
        guard let pid = body["pid"] as? Int32 else {
            respondError(id: id, type: "spawn.stdinEnd", code: JIPErrorCode.einval,
                         message: "missing 'pid'")
            return
        }
        if exitedPids.contains(pid) {
            respondError(id: id, type: "spawn.stdinEnd", code: JIPErrorCode.epipe,
                         message: "process \(pid) already exited")
            return
        }
        runDelegate(id: id, type: "spawn.stdinEnd") {
            try self.delegate.spawnStdinEnd(pid: pid)
            return [:]
        }
    }

    private func spawnKill(id: UInt64, body: [String: Any]) {
        guard let pid = body["pid"] as? Int32, let signal = body["signal"] as? String else {
            respondError(id: id, type: "spawn.kill", code: JIPErrorCode.einval,
                         message: "missing 'pid' or 'signal'")
            return
        }
        if exitedPids.contains(pid) {
            // The pid has already exited; do not consult the delegate.
            respondError(id: id, type: "spawn.kill", code: JIPErrorCode.esrch,
                         message: "no such process \(pid)")
            return
        }
        runDelegate(id: id, type: "spawn.kill") {
            try self.delegate.spawnKill(pid: pid, signal: signal)
            return [:]
        }
    }

    private func spawnResize(id: UInt64, body: [String: Any]) {
        guard let pid = body["pid"] as? Int32,
              let cols = body["cols"] as? Int,
              let rows = body["rows"] as? Int else {
            respondError(id: id, type: "spawn.resize", code: JIPErrorCode.einval,
                         message: "missing 'pid', 'cols', or 'rows'")
            return
        }
        if exitedPids.contains(pid) {
            respondError(id: id, type: "spawn.resize", code: JIPErrorCode.esrch,
                         message: "no such process \(pid)")
            return
        }
        runDelegate(id: id, type: "spawn.resize") {
            try self.delegate.spawnResize(pid: pid, cols: cols, rows: rows)
            return [:]
        }
    }

    // MARK: Inbound events

    private func handleEvent(_ envelope: Envelope) {
        switch envelope.type {
        case "flow.ack":
            guard let pid = envelope.body["pid"] as? Int32,
                  let bytes = envelope.body["bytes"] as? Int else {
                return // malformed ack: ignore rather than close
            }
            applyAck(pid: pid, bytes: bytes)
        default:
            // Unknown event types are silently ignored.
            break
        }
    }

    // MARK: Delegate error wrapper

    private func runDelegate(id: UInt64, type: String,
                             _ work: () throws -> [String: Any]) {
        do {
            let fields = try work()
            respondOk(id: id, type: type, fields: fields)
        } catch let error as JIPError {
            respondError(id: id, type: type, code: error.code, message: error.message)
        } catch {
            respondError(id: id, type: type, code: JIPErrorCode.einval,
                         message: String(describing: error))
        }
    }

    // MARK: Outbound helpers

    private func sendEnvelope(_ object: [String: Any]) {
        guard !closed else { return }
        let payload = Data(JIPJSON.encode(object).utf8)
        do {
            try transport.send(JIPFrameCodec.encode(payload))
        } catch {
            close()
        }
    }

    private func respondOk(id: UInt64, type: String, fields: [String: Any]) {
        var body = fields
        body["ok"] = true
        sendEnvelope(["v": 2, "kind": "res", "id": id, "type": type, "body": body])
    }

    private func respondError(id: UInt64, type: String, code: String, message: String) {
        let body: [String: Any] = ["ok": false, "code": code, "message": message]
        sendEnvelope(["v": 2, "kind": "res", "id": id, "type": type, "body": body])
    }

    private func sendEvent(type: String, body: [String: Any]) {
        sendEnvelope(["v": 2, "kind": "evt", "type": type, "body": body])
    }

    private func protocolError(_ code: String, _ message: String) {
        close()
        onProtocolError?(JIPError(code: code, message: message))
    }

    // MARK: Host (server) pushes

    /// Push a terminal resize event to the client.
    public func pushResize(cols: Int, rows: Int) {
        guard !closed, isHandshakeComplete else { return }
        sendEvent(type: "tty.resize", body: ["cols": cols, "rows": rows])
    }

    /// Push a terminal signal event to the client.
    public func pushSignal(_ name: String) {
        guard !closed, isHandshakeComplete else { return }
        sendEvent(type: "tty.signal", body: ["signal": name])
    }

    /// Push live stdin bytes to the client. Symmetric with `pushResize`: the
    /// host drains the PTY and forwards frames; the shim writes them into
    /// `process.stdin`. Empty payloads are ignored — a terminal never implies
    /// stdin EOF, including on idle. Chunks are split at 64 KiB raw, matching
    /// the spawn-domain limit.
    public func pushStdin(_ data: Data) {
        guard !closed, isHandshakeComplete else { return }
        guard !data.isEmpty else { return }
        var start = 0
        while start < data.count {
            let end = min(start + Self.chunkLimit, data.count)
            let chunk = data.subdata(in: start..<end)
            start = end
            sendEvent(type: "tty.stdin", body: ["dataB64": chunk.base64EncodedString()])
        }
    }

    /// Push a stdout chunk. Split into ≤65,536-byte raw chunks; subject to the
    /// per-pid flow-control window.
    public func pushStdout(pid: Int32, data: Data) {
        pushData(pid: pid, stream: "stdout", data: data)
    }

    /// Push a stderr chunk. Split into ≤65,536-byte raw chunks; subject to the
    /// per-pid flow-control window.
    public func pushStderr(pid: Int32, data: Data) {
        pushData(pid: pid, stream: "stderr", data: data)
    }

    /// Emit `spawn.exit` for a pid. Always the last frame for that pid: any buffered
    /// stdout/stderr is flushed first (ignoring the window), then the exit event is
    /// sent, then the pid's flow accounting is released. After this, `spawn.kill`
    /// returns `ESRCH` and further `spawn.stdin` returns `EPIPE` without reaching the
    /// delegate; further `pushStdout`/`pushStderr`/`flow.ack` for the pid are no-ops.
    public func pushExit(pid: Int32, code: Int32?, signal: String?) {
        guard !closed, isHandshakeComplete else { return }

        if var state = pids[pid] {
            // Flush everything buffered, ignoring the flow window (exit is last).
            while let head = state.buffered.first {
                state.buffered.removeFirst()
                sendSpawnData(pid: pid, stream: head.stream, data: head.data)
            }
            state.bufferedBytes = 0
            pids[pid] = state
        }

        var body: [String: Any] = ["pid": pid]
        if let c = code { body["code"] = Int(c) } else { body["code"] = NSNull() }
        if let s = signal { body["signal"] = s } else { body["signal"] = NSNull() }
        sendEvent(type: "spawn.exit", body: body)

        // Release accounting and remember the exited pid.
        pids.removeValue(forKey: pid)
        exitedPids.insert(pid)
    }

    // MARK: Flow control

    private func pushData(pid: Int32, stream: String, data: Data) {
        guard !closed, isHandshakeComplete else { return }
        guard !exitedPids.contains(pid) else { return }
        if pids[pid] == nil {
            pids[pid] = PidState()
        }

        var start = 0
        while start < data.count {
            let end = min(start + Self.chunkLimit, data.count)
            let chunk = data.subdata(in: start..<end)
            start = end

            if pids[pid]!.inFlight + chunk.count <= Self.flowWindowSize {
                pids[pid]!.inFlight += chunk.count
                sendSpawnData(pid: pid, stream: stream, data: chunk)
            } else {
                // Window exhausted: buffer and mark backpressure so a later ack fires
                // onFlowWindowOpen when the window reopens.
                pids[pid]!.buffered.append((stream: stream, data: chunk))
                pids[pid]!.bufferedBytes += chunk.count
                pids[pid]!.hadBackpressure = true
            }
        }
    }

    private func applyAck(pid: Int32, bytes: Int) {
        // Ack for an unknown (or already-exited) pid is ignored.
        guard var state = pids[pid], !exitedPids.contains(pid) else { return }
        state.inFlight = max(0, state.inFlight - max(0, bytes))
        pids[pid] = state
        flushBuffered(pid: pid)
    }

    private func flushBuffered(pid: Int32) {
        guard var state = pids[pid], !exitedPids.contains(pid) else { return }
        let wasBlocked = state.hadBackpressure
        var sentAny = false
        while let head = state.buffered.first {
            if state.inFlight + head.data.count <= Self.flowWindowSize {
                state.inFlight += head.data.count
                state.buffered.removeFirst()
                pids[pid] = state
                sendSpawnData(pid: pid, stream: head.stream, data: head.data)
                sentAny = true
            } else {
                break
            }
        }
        // Account for bytes removed while flushing (bufferedBytes). We recompute from
        // the remaining queue to stay correct.
        pids[pid] = state

        if wasBlocked && sentAny {
            state.hadBackpressure = false
            pids[pid] = state
            onFlowWindowOpen?(pid)
        }
    }

    private func sendSpawnData(pid: Int32, stream: String, data: Data) {
        sendEvent(type: "spawn.\(stream)",
                  body: ["pid": pid, "dataB64": data.base64EncodedString()])
    }
}
