import Foundation

/// Raised by `JIPFrameCodec.append` when a frame declares a length above the
/// protocol maximum. The caller closes the session with `EMSGSIZE`.
public enum JIPFrameError: Error, Equatable {
    case oversize(declared: Int)
}

/// Length-prefixed frame encoder/decoder for the TJIP/2 wire format.
///
/// Frame = 4-byte big-endian unsigned length `N`, followed by `N` bytes of UTF-8 JSON.
/// The length counts the JSON bytes only; the maximum is `maxFrameSize` (1,048,576).
///
/// `encode` turns a payload into a complete framed chunk. `append` is incremental:
/// feed it any chunk of the byte stream and it returns the complete frames decoded
/// so far, tolerating arbitrary partial-boundary splits, frames delivered one byte
/// at a time, and multiple frames in a single chunk.
///
/// This type is intentionally `public` so the integrator can reuse it for loopback
/// tests and so the test suite can assert against exact wire bytes.
public struct JIPFrameCodec {
    /// Maximum frame payload (JSON body) size in bytes.
    public static let maxFrameSize = 1_048_576

    /// Header (length prefix) size in bytes.
    public static let headerSize = 4

    /// Backing byte buffer of the incoming stream.
    private var pending = Data()
    /// Number of leading bytes in `pending` already retired into complete frames.
    private var offset = 0

    public init() {}

    /// Encode `payload` into a single framed chunk (length prefix + payload).
    public static func encode(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + headerSize)
        var n = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Restore the decoder to its initial (empty) state.
    public mutating func reset() {
        pending = Data()
        offset = 0
    }

    /// Number of bytes currently buffered waiting for a complete frame.
    public var bufferedBytes: Int { pending.count - offset }

    /// Feed a chunk of the incoming byte stream. Returns the payload (JSON) bytes of
    /// every frame completed by this chunk. Throws `JIPFrameError.oversize` if a frame
    /// declares a length above `maxFrameSize` (in which case the stream is unusable and
    /// the caller must close the session).
    public mutating func append(_ chunk: Data) throws -> [Data] {
        pending.append(chunk)
        var frames: [Data] = []

        while bufferedBytes >= Self.headerSize {
            let declared = readUInt32BE(at: offset)
            if declared > Self.maxFrameSize {
                throw JIPFrameError.oversize(declared: declared)
            }
            let total = Self.headerSize + declared
            guard bufferedBytes >= total else { break }
            let start = offset + Self.headerSize
            frames.append(pending.subdata(in: start..<(start + declared)))
            offset += total
        }

        compact()
        return frames
    }

    /// Read the 4-byte big-endian length at absolute offset `index` of `pending`.
    private func readUInt32BE(at index: Int) -> Int {
        var n: UInt32 = 0
        pending.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<Self.headerSize {
                n = (n << 8) | UInt32(base[index + i])
            }
        }
        return Int(n)
    }

    /// Retire the already-consumed prefix so the buffer does not grow unbounded.
    private mutating func compact() {
        guard offset > 0 else { return }
        if offset == pending.count {
            pending.removeAll()
        } else {
            pending = pending.subdata(in: offset..<pending.count)
        }
        offset = 0
    }
}
