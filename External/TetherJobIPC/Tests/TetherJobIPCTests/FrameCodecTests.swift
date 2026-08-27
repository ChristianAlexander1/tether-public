import XCTest
import Foundation
import TetherJobIPC

/// Framing resilience: chunk matrix, header splits, oversize.
final class FrameCodecTests: XCTestCase {

    private func payload(_ s: String) -> Data { Data(s.utf8) }

    // MARK: Behavior 1 — framing resilience

    func testFrameDeliveredOneByteAtATime() throws {
        var codec = JIPFrameCodec()
        let frame = JIPFrameCodec.encode(payload(#"{"a":1}"#))
        var collected: [Data] = []
        for byte in frame {
            collected.append(contentsOf: try codec.append(Data([byte])))
        }
        XCTAssertEqual(collected.count, 1)
        XCTAssertEqual(collected[0], payload(#"{"a":1}"#))
    }

    func testTwoFramesInOneChunk() throws {
        var codec = JIPFrameCodec()
        let f1 = JIPFrameCodec.encode(payload("abc"))
        let f2 = JIPFrameCodec.encode(payload("defgh"))
        let frames = try codec.append(f1 + f2)
        XCTAssertEqual(frames, [payload("abc"), payload("defgh")])
    }

    func testFrameBoundarySplittingFourByteHeader() throws {
        var codec = JIPFrameCodec()
        let frame = JIPFrameCodec.encode(payload("hello world"))
        // Split inside the 4-byte length header (only 2 length bytes delivered).
        XCTAssertEqual(try codec.append(frame.prefix(2)).count, 0)
        // Deliver the rest of the header + body in a second, differently-sized split.
        XCTAssertEqual(try codec.append(frame.dropFirst(2).prefix(1)).count, 0)
        XCTAssertEqual(try codec.append(frame.dropFirst(3)), [payload("hello world")])
    }

    func testSplitsAcrossManyBoundariesResetToExactInput() throws {
        for split in [1, 2, 3, 4, 5, 7, 8, 16] {
            var codec = JIPFrameCodec()
            let original = payload("ABCDEFGHIJ0123456789")
            let frame = JIPFrameCodec.encode(original)
            var frames: [Data] = []
            var i = 0
            while i < frame.count {
                let end = min(i + split, frame.count)
                frames.append(contentsOf: try codec.append(frame[i..<end]))
                i = end
            }
            XCTAssertEqual(frames, [original], "split width \(split)")
        }
    }

    func testEmptyPayloadFrame() throws {
        var codec = JIPFrameCodec()
        let frame = JIPFrameCodec.encode(Data())
        XCTAssertEqual(frame, Data([0, 0, 0, 0]))
        XCTAssertEqual(try codec.append(frame), [Data()])
    }

    func testResetClearsBufferedPartialFrame() throws {
        var codec = JIPFrameCodec()
        let frame = JIPFrameCodec.encode(payload("later"))
        _ = try codec.append(frame.prefix(3))
        XCTAssertEqual(codec.bufferedBytes, 3)
        codec.reset()
        XCTAssertEqual(codec.bufferedBytes, 0)
        XCTAssertEqual(try codec.append(frame), [payload("later")])
    }

    // MARK: Behavior 2 — oversize frame

    func testOversizeDeclaredLengthThrows() throws {
        var codec = JIPFrameCodec()
        let declared = 2_000_000
        var len = UInt32(declared).bigEndian
        let header = withUnsafeBytes(of: &len) { Data($0) }
        XCTAssertThrowsError(try codec.append(header)) { error in
            XCTAssertEqual(error as? JIPFrameError, .oversize(declared: declared))
        }
    }

    func testSizedAtMaximumIsAccepted() throws {
        var codec = JIPFrameCodec()
        let big = Data(repeating: 0x41, count: JIPFrameCodec.maxFrameSize)
        let frame = JIPFrameCodec.encode(big)
        XCTAssertEqual(try codec.append(frame), [big])
    }

    // MARK: encode<->decode round trip

    func testEncodeThenDecodeRoundTrip() throws {
        var codec = JIPFrameCodec()
        let payload = Data(#"{"v":2,"kind":"evt","type":"tty.resize","body":{"cols":120,"rows":30}}"#.utf8)
        let framed = JIPFrameCodec.encode(payload)
        // Length prefix is the big-endian 32-bit payload length.
        let prefix = framed.prefix(4)
        var n: UInt32 = 0
        for b in prefix { n = (n << 8) | UInt32(b) }
        XCTAssertEqual(Int(n), payload.count)
        XCTAssertEqual(try codec.append(framed), [payload])
    }
}
