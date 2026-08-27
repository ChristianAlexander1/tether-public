import Foundation

/// An in-memory, in-process duplex byte-stream pair used for offline testing and
/// loopback. `a` and `b` are two ends of the same ordered stream: bytes sent on `a`
/// arrive on `b`'s `onReceive`, and vice versa, in order.
///
/// Delivery is **synchronous and same-threaded** (no queues or threads). This mirrors
/// the integrator's serial-queue call pattern and is safe when each end is driven from
/// the same serial queue.
public final class JIPInMemoryTransportPair {
    private final class MemoryTransport: JIPTransport {
        var onReceive: ((Data) -> Void)?
        weak var peer: MemoryTransport?
        private var isClosed = false
        var isClosedForTest: Bool { isClosed }

        func send(_ data: Data) throws {
            guard !isClosed else {
                throw JIPError(code: JIPErrorCode.epipe, message: "transport is closed")
            }
            guard let peer = peer, !peer.isClosed else {
                throw JIPError(code: JIPErrorCode.epipe, message: "peer transport is closed")
            }
            peer.deliver(data)
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            onReceive = nil
        }

        fileprivate func deliver(_ data: Data) {
            guard !isClosed else { return }
            onReceive?(data)
        }
    }

    private let aTransport = MemoryTransport()
    private let bTransport = MemoryTransport()

    public init() {
        aTransport.peer = bTransport
        bTransport.peer = aTransport
    }

    /// One end of the pair.
    public var a: JIPTransport { aTransport }

    /// The other end of the pair.
    public var b: JIPTransport { bTransport }

    /// Whether the `a` end has been closed (test convenience).
    public var isAClosed: Bool { aTransport.isClosedForTest }

    /// Whether the `b` end has been closed (test convenience).
    public var isBClosed: Bool { bTransport.isClosedForTest }
}
