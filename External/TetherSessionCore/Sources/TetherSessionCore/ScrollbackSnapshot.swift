//
//  ScrollbackSnapshot.swift
//  TetherSessionCore
//
//  A versioned, checksummed serialization format for the terminal's recent
//  output, so a session can restore its screen after the app is relaunched.
//
//  Format (version 1), all integers big-endian:
//    • ASCII magic "TSSB"                                (4 bytes)
//    • formatVersion                                     (4-byte BE)
//    • cols                                              (4-byte BE)
//    • rows                                              (4-byte BE)
//    • rawBytes length                                   (8-byte BE)
//    • rawBytes
//    • trailingModeState length                          (4-byte BE)
//    • trailingModeState
//    • CRC32 of everything before the checksum           (4-byte BE)
//
//  rawBytes is capped at 4 MiB. On serialize an oversized payload is
//  truncated to keep the TAIL (recent output matters). On deserialize an
//  oversized length field throws.
//
//  Errors are thrown, never `fatalError`, so callers can discard the blob and
//  start clean.
//

import Foundation

public enum ScrollbackSnapshotError: Error, Equatable, Sendable {
    /// The blob is shorter than the fixed header. Unrecoverable.
    case shortData(Int)
    /// Four-byte ASCII magic did not equal "TSSB".
    case badMagic
    /// `formatVersion` of the blob is not supported.
    case unsupportedVersion(UInt32)
    /// A length field exceeds the remaining bytes in the blob.
    case lengthExceedsData
    /// The `rawBytes` length exceeds the 4 MiB cap.
    case rawBytesTooLarge(UInt64)
    /// The trailing CRC32 does not match the computed checksum.
    case checksumMismatch
}

public struct ScrollbackSnapshot: Equatable, Sendable {

    /// The current serialization format version.
    public static let formatVersion: Int = 1

    /// Cap on stored scrollback bytes: 4 MiB.
    public static let maxRawBytes: Int = 4 * 1024 * 1024

    public var cols: Int
    public var rows: Int
    public var rawBytes: Data
    public var trailingModeState: Data

    public init(cols: Int, rows: Int, rawBytes: Data, trailingModeState: Data) {
        self.cols = cols
        self.rows = rows
        self.rawBytes = rawBytes
        self.trailingModeState = trailingModeState
    }

    // MARK: Serialize

    /// Serialize to the binary format described in the file header comment.
    /// `rawBytes` larger than `maxRawBytes` is truncated keeping the **tail**
    /// (recent output matters).
    public func serialized() -> Data {
        let raw = rawBytes.count > Self.maxRawBytes ? rawBytes.suffix(Self.maxRawBytes) : rawBytes

        var out = Data(capacity: 16 + raw.count + trailingModeState.count)
        out.append(contentsOf: Array("TSSB".utf8))
        out.append(contentsOf: BE.encode(UInt32(clamping: Self.formatVersion)))
        out.append(contentsOf: BE.encode(UInt32(clamping: cols)))
        out.append(contentsOf: BE.encode(UInt32(clamping: rows)))
        out.append(contentsOf: BE.encode(UInt64(raw.count)))
        out.append(raw)
        out.append(contentsOf: BE.encode(UInt32(clamping: trailingModeState.count)))
        out.append(trailingModeState)

        let crc = CRC32.checksum(of: out)
        out.append(contentsOf: BE.encode(crc))
        return out
    }

    // MARK: Deserialize

    /// Deserialize a blob produced by `serialized()`.
    ///
    /// Throws `ScrollbackSnapshotError` on any of: data shorter than the fixed
    /// header, bad magic, unsupported version, a length field exceeding the
    /// remaining data, a `rawBytes` size above the cap, or a checksum mismatch.
    public static func deserialize(_ data: Data) throws -> ScrollbackSnapshot {
        var index = 0

        guard data.count >= 16 else {
            throw ScrollbackSnapshotError.shortData(data.count)
        }

        // Magic.
        let magic = try read(data, at: &index, count: 4)
        guard magic == Data(Array("TSSB".utf8)) else {
            throw ScrollbackSnapshotError.badMagic
        }

        // Version.
        let versionBytes = try read(data, at: &index, count: 4)
        let version = UInt32(BE.decode(UInt32.self, versionBytes))
        guard version == UInt32(Self.formatVersion) else {
            throw ScrollbackSnapshotError.unsupportedVersion(version)
        }

        // cols / rows.
        let cols = Int(BE.decode(UInt32.self, try read(data, at: &index, count: 4)))
        let rows = Int(BE.decode(UInt32.self, try read(data, at: &index, count: 4)))

        // rawBytes (length stored as 8-byte BE).
        let rawLenBytes = try read(data, at: &index, count: 8)
        let rawLength = BE.decode(UInt64.self, rawLenBytes)

        guard rawLength <= UInt64(Self.maxRawBytes) else {
            throw ScrollbackSnapshotError.rawBytesTooLarge(rawLength)
        }
        guard rawLength <= UInt64(data.count - index) else {
            throw ScrollbackSnapshotError.lengthExceedsData
        }

        let raw = try read(data, at: &index, count: Int(rawLength))

        // trailingModeState (length stored as 4-byte BE).
        let stateLenBytes = try read(data, at: &index, count: 4)
        let stateLength = BE.decode(UInt32.self, stateLenBytes)
        guard stateLength <= UInt32(data.count - index) else {
            throw ScrollbackSnapshotError.lengthExceedsData
        }
        let trailingModeState = try read(data, at: &index, count: Int(stateLength))

        // Checksum: everything before this point must CRC to the stored value.
        guard data.count - index == 4 else {
            throw ScrollbackSnapshotError.lengthExceedsData
        }
        let storedChecksum = BE.decode(UInt32.self, try read(data, at: &index, count: 4))
        let payload = data.prefix(data.count - 4)
        let computed = CRC32.checksum(of: Data(payload))
        guard storedChecksum == computed else {
            throw ScrollbackSnapshotError.checksumMismatch
        }

        return ScrollbackSnapshot(
            cols: cols,
            rows: rows,
            rawBytes: raw,
            trailingModeState: trailingModeState
        )
    }

    // MARK: Private reader

    private static func read(_ data: Data, at index: inout Int, count: Int) throws -> Data {
        guard count >= 0, index + count <= data.count else {
            throw ScrollbackSnapshotError.lengthExceedsData
        }
        let result = data.subdata(in: index..<(index + count))
        index += count
        return result
    }
}

// MARK: - Big-endian helpers

private enum BE {
    static func encode(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    static func encode(_ value: UInt64) -> [UInt8] {
        [
            UInt8((value >> 56) & 0xFF),
            UInt8((value >> 48) & 0xFF),
            UInt8((value >> 40) & 0xFF),
            UInt8((value >> 32) & 0xFF),
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    static func decode<T: FixedWidthInteger>(_ type: T.Type, _ bytes: Data) -> UInt64 {
        var v: UInt64 = 0
        for b in bytes {
            v = (v << 8) | UInt64(b)
        }
        return v
    }
}

// MARK: - CRC32 (IEEE 802.3)

enum CRC32 {
    /// Reflected IEEE 802.3 polynomial.
    private static let polynomial: UInt32 = 0xEDB8_8320

    /// CRC32 (IEEE 802.3) of `data`. Standard init 0xFFFFFFFF and final XOR.
    /// Reference vector: CRC32 of ASCII "123456789" == 0xCBF43926.
    static func checksum(of data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ polynomial
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
