import Foundation
import TetherJobIPC

/// A decoded TJIP/2 message, normalized for easy assertions.
public struct TestMessage {
    public let kind: String
    public let id: UInt64?
    public let type: String?
    public let body: [String: Any]

    public func bool(_ key: String) -> Bool? { body[key] as? Bool }
    public func int(_ key: String) -> Int? { (body[key] as? NSNumber)?.intValue }
    public func int32(_ key: String) -> Int32? { (body[key] as? NSNumber)?.int32Value }
    public func string(_ key: String) -> String? { body[key] as? String }
    public func array(_ key: String) -> [Any]? { body[key] as? [Any] }

    public var ok: Bool? { bool("ok") }
    public var code: String? { string("code") }
}

/// Drives a `JIPServerSession` from the client side of an in-memory transport pair.
/// All inbound (client→server) framing is done by the caller; outbound (server→client)
/// frames are decoded here and recorded for assertions.
public final class JIPTestHarness {
    public let pair = JIPInMemoryTransportPair()
    public let delegate = FakeHostDelegate()
    public let session: JIPServerSession

    private var codec = JIPFrameCodec()

    /// Decoded messages the server has sent to the client, in order.
    public private(set) var received: [TestMessage] = []
    /// Raw frame *payloads* (JSON bytes) the server sent, in order.
    public private(set) var receivedPayloads: [Data] = []

    /// onFlowWindowOpen bookkeeping.
    public private(set) var flowWindowReopens = 0
    public private(set) var flowWindowPids: [Int32] = []
    /// onProtocolError bookkeeping.
    public private(set) var protocolErrors: [JIPError] = []

    public init() {
        session = JIPServerSession(transport: pair.a, delegate: delegate)
        session.onFlowWindowOpen = { [weak self] pid in
            self?.flowWindowReopens += 1
            self?.flowWindowPids.append(pid)
        }
        session.onProtocolError = { [weak self] err in
            self?.protocolErrors.append(err)
        }
        pair.b.onReceive = { [weak self] data in
            self?.ingest(data)
        }
    }

    // MARK: Sending (client → server)

    public func sendJSON(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        try! pair.b.send(JIPFrameCodec.encode(data))
    }

    public func sendRequest(type: String, id: UInt64, body: [String: Any] = [:]) {
        sendJSON(["v": 2, "kind": "req", "id": id, "type": type, "body": body])
    }

    public func sendEvent(type: String, body: [String: Any]) {
        sendJSON(["v": 2, "kind": "evt", "type": type, "body": body])
    }

    public func sendHello(id: UInt64 = 1,
                          proto: Int = 2,
                          role: String = "node-shim",
                          features: [String] = ["tty", "spawn", "flow"]) {
        sendRequest(type: "hello", id: id,
                    body: ["proto": proto, "role": role, "features": features])
    }

    /// Send a raw framed chunk straight to the session (for framing/oversize tests).
    public func sendFramedChunk(_ data: Data) {
        try! pair.b.send(data)
    }

    // MARK: Accessors

    public func resetReceived() {
        received.removeAll()
        receivedPayloads.removeAll()
    }

    public var last: TestMessage? { received.last }

    public func messages(ofType t: String) -> [TestMessage] {
        received.filter { $0.type == t }
    }

    public func response(id: UInt64) -> TestMessage? {
        received.first { $0.kind == "res" && $0.id == id }
    }

    /// Sum of raw payload bytes decoded from `type` frames.
    public func rawBytes(ofType t: String) -> Int {
        received.compactMap { $0.type == t ? $0.string("dataB64") : nil }
            .compactMap { Data(base64Encoded: $0) }
            .reduce(0) { $0 + $1.count }
    }

    private func ingest(_ data: Data) {
        guard let frames = try? codec.append(data) else { return }
        for payload in frames {
            receivedPayloads.append(payload)
            if let envelope = Self.parse(payload) {
                received.append(envelope)
            }
        }
    }

    private static func parse(_ payload: Data) -> TestMessage? {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let kind = obj["kind"] as? String else { return nil }
        let id = (obj["id"] as? NSNumber)?.uint64Value
        let type = obj["type"] as? String
        let body = obj["body"] as? [String: Any] ?? [:]
        return TestMessage(kind: kind, id: id, type: type, body: body)
    }
}
