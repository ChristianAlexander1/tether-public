import Foundation
import zlib

/// In-process .tar.gz extraction for platforms without a tar binary (iOS).
/// Supports ustar + GNU long-name entries, regular files, directories, sym/hard links.
/// Lives in TermXCore so both the Linux lane (rootfs) and Node (npm bootstrap) can use it.
public enum TarGzExtractor {
    public enum ExtractError: Error, CustomStringConvertible {
        case gunzipFailed(String)
        case malformedTar(String)

        public var description: String {
            switch self {
            case .gunzipFailed(let why): return "gunzip failed: \(why)"
            case .malformedTar(let why): return "malformed tar: \(why)"
            }
        }
    }

    public static func extract(archive: URL, into destination: URL) throws {
        try extract(archive: archive, into: destination, shouldExtract: { _ in true })
    }

    /// - Parameter shouldExtract: return `false` to skip a member (e.g. docs/man).
    ///   Directories still need their children filtered individually.
    public static func extract(
        archive: URL,
        into destination: URL,
        shouldExtract: (String) -> Bool
    ) throws {
        let tarData = try gunzip(try Data(contentsOf: archive, options: .mappedIfSafe))
        try untar(tarData, into: destination, shouldExtract: shouldExtract)
    }

    // MARK: gzip

    private static func gunzip(_ input: Data) throws -> Data {
        var stream = z_stream()
        // 15 window bits + 32 enables automatic gzip/zlib header detection.
        var status = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw ExtractError.gunzipFailed("inflateInit2 status \(status)") }
        defer { inflateEnd(&stream) }

        var output = Data(capacity: max(input.count * 4, 1 << 20))
        let chunkSize = 1 << 18
        var outChunk = [UInt8](repeating: 0, count: chunkSize)

        try input.withUnsafeBytes { (rawIn: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: rawIn.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(input.count)
            repeat {
                try outChunk.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw ExtractError.gunzipFailed("inflate status \(status)")
                    }
                    output.append(outBuf.baseAddress!, count: chunkSize - Int(stream.avail_out))
                }
            } while status != Z_STREAM_END && stream.avail_in > 0
        }
        guard status == Z_STREAM_END else { throw ExtractError.gunzipFailed("truncated stream") }
        return output
    }

    // MARK: tar

    private static func untar(
        _ data: Data,
        into destination: URL,
        shouldExtract: (String) -> Bool
    ) throws {
        let fm = FileManager.default
        let destRoot = destination.standardizedFileURL
        var pendingLongName: String?

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            var offset = 0

            while offset + 512 <= count {
                let header = base + offset
                offset += 512

                // End-of-archive: two zero blocks. Cheap zero check on name field first.
                if header[0] == 0 && UnsafeBufferPointer(start: header, count: 512).allSatisfy({ $0 == 0 }) {
                    continue
                }

                func field(_ start: Int, _ end: Int) -> String {
                    let len = end - start
                    var i = 0
                    while i < len && header[start + i] != 0 { i += 1 }
                    return String(decoding: UnsafeBufferPointer(start: header + start, count: i), as: UTF8.self)
                }
                func octal(_ start: Int, _ end: Int) -> Int {
                    Int(field(start, end).trimmingCharacters(in: CharacterSet(charactersIn: " \0")), radix: 8) ?? 0
                }

                var name = field(0, 100)
                let mode = octal(100, 108)
                let size = octal(124, 136)
                let typeFlag = Character(UnicodeScalar(header[156]))
                let linkName = field(157, 257)
                let prefix = field(345, 500)
                if !prefix.isEmpty { name = prefix + "/" + name }
                if let long = pendingLongName { name = long; pendingLongName = nil }

                let payloadLength = (size + 511) & ~511
                defer { offset += payloadLength }

                if typeFlag == "L" {  // GNU long name
                    let payload = UnsafeBufferPointer(start: base + offset, count: size)
                    let end = payload.firstIndex(of: 0) ?? size
                    pendingLongName = String(decoding: payload.prefix(end), as: UTF8.self)
                    continue
                }
                if name.isEmpty || typeFlag == "g" || typeFlag == "x" { continue }

                if !shouldExtract(name) { continue }

                let target = destRoot.appendingPathComponent(name).standardizedFileURL
                guard target.path.hasPrefix(destRoot.path) else {
                    throw ExtractError.malformedTar("path escape: \(name)")
                }

                switch typeFlag {
                case "5":
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                case "0", "\0", "7":
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // Non-atomic: atomic write doubles I/O across thousands of
                    // small files and was a major bootstrap-time cost on iOS.
                    let payload = Data(bytes: base + offset, count: size)
                    try payload.write(to: target, options: [])
                    try? fm.setAttributes([.posixPermissions: mode == 0 ? 0o644 : mode], ofItemAtPath: target.path)
                case "2":
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: target)
                    try fm.createSymbolicLink(atPath: target.path, withDestinationPath: linkName)
                case "1":
                    let source = destRoot.appendingPathComponent(linkName).standardizedFileURL
                    try? fm.removeItem(at: target)
                    try? fm.linkItem(at: source, to: target)
                default:
                    continue
                }
            }
        }
    }
}
