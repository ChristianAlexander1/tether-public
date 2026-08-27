import Foundation

/// A byte transport between the host app and the embedded Node.js runtime.
///
/// The transport is an **ordered, reliable byte stream**. Across the wire (and
/// between the two fakes in `JIPInMemoryTransportPair`) the unit of delivery is a
/// *raw chunk* of bytes — that chunk is a strict prefix of the byte stream and may
/// contain a partial frame, an exact frame, or many frames. Framing is the
/// responsibility of `JIPFrameCodec`, which consumes the byte stream.
///
/// The integrator owns the serialization of calls onto this transport. Per the
/// serial-queue discipline documented in HANDOFF.md, `onReceive` is invoked on the
/// integrator's single serial queue (never concurrently), and `send` is likewise
/// only ever called from that same queue.
public protocol JIPTransport: AnyObject {
    /// Callback for bytes arriving from the peer. Always invoked on the integrator's
    /// serial queue.
    var onReceive: ((Data) -> Void)? { get set }

    /// Write `data` to the byte stream. `data` must be a contiguous chunk of an
    /// ordered byte stream (the caller supplies framing). Throws if the transport is
    /// broken/closed.
    func send(_ data: Data) throws

    /// Close the underlying stream. Must be idempotent.
    func close()
}
