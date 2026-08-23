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
        let tarData = try gunzip(try Data(contentsOf: archive))
        try untar(tarData, into: destination)
    }

    // MARK: gzip

    private static func gunzip(_ input: Data) throws -> Data {
        var stream = z_stream()
        // 15 window bits + 32 enables automatic gzip/zlib header detection.
        var status = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw ExtractError.gunzipFailed("inflateInit2 status \(status)") }
        defer { inflateEnd(&stream) }

        var output = Data(capacity: input.count * 4)
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

    private static func untar(_ data: Data, into destination: URL) throws {
        let fm = FileManager.default
        let destRoot = destination.standardizedFileURL
        var offset = 0
        var pendingLongName: String?

        while offset + 512 <= data.count {
            let header = data.subdata(in: offset..<offset + 512)
            offset += 512
            if header.allSatisfy({ $0 == 0 }) { continue }  // end-of-archive blocks

            func field(_ range: Range<Int>) -> String {
                let raw = header.subdata(in: range)
                let terminated = raw.prefix { $0 != 0 }
                return String(decoding: terminated, as: UTF8.self)
            }
            func octal(_ range: Range<Int>) -> Int {
                Int(field(range).trimmingCharacters(in: CharacterSet(charactersIn: " \0")), radix: 8) ?? 0
            }

            var name = field(0..<100)
            let mode = octal(100..<108)
            let size = octal(124..<136)
            let typeFlag = Character(UnicodeScalar(header[header.startIndex + 156]))
            let linkName = field(157..<257)
            let prefix = field(345..<500)
            if !prefix.isEmpty { name = prefix + "/" + name }
            if let long = pendingLongName { name = long; pendingLongName = nil }

            let payloadLength = (size + 511) & ~511
            defer { offset += payloadLength }

            if typeFlag == "L" {  // GNU long name: payload holds the real name
                let payload = data.subdata(in: offset..<offset + size)
                pendingLongName = String(decoding: payload.prefix { $0 != 0 }, as: UTF8.self)
                continue
            }
            if name.isEmpty || typeFlag == "g" || typeFlag == "x" { continue }  // pax metadata

            let target = destRoot.appendingPathComponent(name).standardizedFileURL
            guard target.path.hasPrefix(destRoot.path) else {
                throw ExtractError.malformedTar("path escape: \(name)")
            }

            switch typeFlag {
            case "5":
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            case "0", "\0", "7":
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let payload = data.subdata(in: offset..<offset + size)
                try payload.write(to: target)
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
                continue  // char/block/fifo devices: not creatable in sandbox, safely skipped
            }
        }
    }
}
