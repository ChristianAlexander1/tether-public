//
//  SnapshotFormatTests.swift
//  TetherSessionCoreTests
//
//  CRC32 vectors, round-trip under a seeded generator, byte-flip corruption
//  sweep, truncation cap, and version/reject paths.
//

import XCTest
@testable import TetherSessionCore

/// Deterministic PRNG so tests are reproducible (no system RNG).
private struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed & 0xFFFF_FFFF }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    mutating func nextInt(_ upper: UInt64) -> UInt64 {
        guard upper > 0 else { return 0 }
        return next() % upper
    }
    mutating func bytes(count: Int) -> Data {
        var data = Data(capacity: count)
        for _ in 0..<count {
            data.append(UInt8(nextInt(256)))
        }
        return data
    }
}

final class SnapshotFormatTests: XCTestCase {

    // MARK: CRC32 vectors

    func testCRC32KnownVectors() {
        // CRC32 of ASCII "123456789" is the canonical IEEE 802.3 check value.
        let check = Data("123456789".utf8)
        XCTAssertEqual(CRC32.checksum(of: check), 0xCBF4_3926)

        // Empty input CRC is 0.
        XCTAssertEqual(CRC32.checksum(of: Data()), 0x0000_0000)

        // A few more known vectors for the same polynomial.
        XCTAssertEqual(CRC32.checksum(of: Data("".utf8)), 0x0000_0000)
        XCTAssertEqual(CRC32.checksum(of: Data("a".utf8)), 0xE8B7_BE43)
        XCTAssertEqual(CRC32.checksum(of: Data("abcdefghijklmnopqrstuvwxyz".utf8)), 0x4C27_50BD)
    }

    // MARK: Round-trip

    func testRoundTripMultipleSeeds() {
        for seed: UInt64 in [1, 7, 42, 1234, 9001] {
            var gen = SeededGenerator(seed: seed)
            let cols = Int(gen.nextInt(200)) + 1
            let rows = Int(gen.nextInt(200)) + 1
            let rawLen = Int(gen.nextInt(4096))
            let stateLen = Int(gen.nextInt(64))
            let snapshot = ScrollbackSnapshot(
                cols: cols,
                rows: rows,
                rawBytes: gen.bytes(count: rawLen),
                trailingModeState: gen.bytes(count: stateLen)
            )

            let serialized = snapshot.serialized()
            let restored = try! ScrollbackSnapshot.deserialize(serialized)
            XCTAssertEqual(restored, snapshot, "round-trip mismatch for seed \(seed)")
            XCTAssertEqual(restored.rawBytes, snapshot.rawBytes)
            XCTAssertEqual(restored.cols, cols)
            XCTAssertEqual(restored.rows, rows)
        }
    }

    func testRoundTripEmptyAndZeroSized() {
        let snapshot = ScrollbackSnapshot(cols: 1, rows: 1, rawBytes: Data(), trailingModeState: Data())
        let restored = try! ScrollbackSnapshot.deserialize(snapshot.serialized())
        XCTAssertEqual(restored, snapshot)
    }

    func testTrailingModeStatePreserved() {
        let modeState = Data([0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x68]) // some DEC mode state
        let snapshot = ScrollbackSnapshot(cols: 80, rows: 24, rawBytes: Data([1, 2, 3]), trailingModeState: modeState)
        let restored = try! ScrollbackSnapshot.deserialize(snapshot.serialized())
        XCTAssertEqual(restored.trailingModeState, modeState)
    }

    // MARK: Corruption sweep

    func testEverySingleByteFlipThrows() {
        var gen = SeededGenerator(seed: 99)
        let snapshot = ScrollbackSnapshot(
            cols: 50,
            rows: 30,
            rawBytes: gen.bytes(count: 128),
            trailingModeState: Data([0xAA, 0xBB])
        )
        let serialized = snapshot.serialized()

        XCTAssertGreaterThan(serialized.count, 4)
        for index in 0..<serialized.count {
            var corrupted = serialized
            corrupted[index] = corrupted[index] ^ 0xFF
            XCTAssertThrowsError(try ScrollbackSnapshot.deserialize(corrupted),
                                 "byte at index \(index) flipped but did not throw")
        }
    }

    // MARK: Truncation cap

    func testRawBytesOver4MiBKeepsTail() {
        let cap = ScrollbackSnapshot.maxRawBytes
        let total = cap + 1024 * 1024        // 5 MiB
        let payload = Data(repeating: 0xAB, count: total)
        // Make the tail distinguishable from the head.
        let tail = Data(repeating: 0xCD, count: 6)

        let snapshot = ScrollbackSnapshot(cols: 80, rows: 24, rawBytes: payload + tail, trailingModeState: Data())
        let serialized = snapshot.serialized()

        let restored = try! ScrollbackSnapshot.deserialize(serialized)
        XCTAssertEqual(restored.rawBytes.count, cap)
        // The stored payload must be the LAST `cap` bytes (tail preserved).
        XCTAssertEqual(restored.rawBytes, (payload + tail).suffix(cap))
        XCTAssertTrue(restored.rawBytes.suffix(6) == Data(repeating: 0xCD, count: 6),
                      "tail (recent output) must be preserved, not the head")
    }

    func testExactlyAtCapIsPreserved() {
        let cap = ScrollbackSnapshot.maxRawBytes
        let payload = Data(repeating: 0xEE, count: cap)
        let snapshot = ScrollbackSnapshot(cols: 10, rows: 10, rawBytes: payload, trailingModeState: Data())
        let restored = try! ScrollbackSnapshot.deserialize(snapshot.serialized())
        XCTAssertEqual(restored.rawBytes.count, cap)
        XCTAssertEqual(restored.rawBytes, payload)
    }

    // MARK: Version & reject paths

    func testVersion2ThrowsVersionSpecificError() {
        // Hand-build a version-2 blob (valid structure, version field = 2).
        let raw = Data([1, 2, 3])
        let state = Data([4, 5])
        var body = Data()
        body.append(contentsOf: Array("TSSB".utf8))
        body.append(contentsOf: Self.uint32(2))
        body.append(contentsOf: Self.uint32(80))
        body.append(contentsOf: Self.uint32(24))
        let rawLen: UInt64 = UInt64(raw.count)
        body.append(contentsOf: Self.uint64(rawLen))
        body.append(raw)
        body.append(contentsOf: Self.uint32(UInt32(state.count)))
        body.append(state)
        body.append(contentsOf: Self.uint32(CRC32.checksum(of: body)))

        do {
            _ = try ScrollbackSnapshot.deserialize(body)
            XCTFail("version-2 blob should throw")
        } catch let e as ScrollbackSnapshotError {
            XCTAssertEqual(e, .unsupportedVersion(2))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testBadMagicThrows() {
        let snapshot = ScrollbackSnapshot(cols: 80, rows: 24, rawBytes: Data([1]), trailingModeState: Data())
        var serialized = snapshot.serialized()
        serialized[0] = 0x58 // 'X'
        do {
            _ = try ScrollbackSnapshot.deserialize(serialized)
            XCTFail("bad magic should throw")
        } catch let e as ScrollbackSnapshotError {
            XCTAssertEqual(e, .badMagic)
        } catch {
            XCTFail("unexpected error type")
        }
    }

    func testShortDataThrows() {
        let data = Data([0x54, 0x53, 0x53, 0x42, 0, 0])
        do {
            _ = try ScrollbackSnapshot.deserialize(data)
            XCTFail("short data should throw")
        } catch let e as ScrollbackSnapshotError {
            XCTAssertEqual(e, .shortData(6))
        } catch {
            XCTFail("unexpected error type")
        }
    }

    func testChecksumMismatchThrows() {
        let snapshot = ScrollbackSnapshot(cols: 80, rows: 24, rawBytes: Data("hello".utf8), trailingModeState: Data())
        var serialized = snapshot.serialized()
        // Flip a byte inside the payload region (index ≥ 24 = first raw byte),
        // NOT in the length field or checksum, to corrupt content.
        serialized[25] = serialized[25] ^ 0x01
        do {
            _ = try ScrollbackSnapshot.deserialize(serialized)
            XCTFail("corrupted payload should throw checksum mismatch")
        } catch let e as ScrollbackSnapshotError {
            XCTAssertEqual(e, .checksumMismatch)
        } catch {
            XCTFail("unexpected error type")
        }
    }

    func testRawBytesLengthExceedingDataThrows() {
        // Hand-build a blob whose rawBytes length field exceeds the remaining data.
        var body = Data()
        body.append(contentsOf: Array("TSSB".utf8))
        body.append(contentsOf: Self.uint32(1))
        body.append(contentsOf: Self.uint32(80))
        body.append(contentsOf: Self.uint32(24))
        body.append(contentsOf: Self.uint64(9999)) // far more than remaining bytes
        body.append(contentsOf: Data([0x00]))
        body.append(contentsOf: Self.uint32(0))
        // CRC is ignored because the length check fires first.
        body.append(contentsOf: Self.uint32(0))

        do {
            _ = try ScrollbackSnapshot.deserialize(body)
            XCTFail("overflowing rawBytes length should throw")
        } catch let e as ScrollbackSnapshotError {
            XCTAssertEqual(e, .lengthExceedsData)
        } catch {
            XCTFail("unexpected error type")
        }
    }

    func testTrailingModeLengthOverflowingDataThrows() {
        var body = Data()
        body.append(contentsOf: Array("TSSB".utf8))
        body.append(contentsOf: Self.uint32(1))
        body.append(contentsOf: Self.uint32(80))
        body.append(contentsOf: Self.uint32(24))
        body.append(contentsOf: Self.uint64(0))   // no rawBytes
        body.append(contentsOf: Self.uint32(500)) // state length exceeds remaining
        body.append(contentsOf: Self.uint32(0))   // placeholder
        do {
            _ = try ScrollbackSnapshot.deserialize(body)
            XCTFail("overflowing state length should throw")
        } catch let e as ScrollbackSnapshotError {
            XCTAssertEqual(e, .lengthExceedsData)
        } catch {
            XCTFail("unexpected error type")
        }
    }

    // MARK: helpers

    private static func uint32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static func uint64(_ v: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8((v >> shift) & 0xFF))
        }
        return out
    }
}
