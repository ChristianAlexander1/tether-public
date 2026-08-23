import XCTest
import Foundation
import zlib
@testable import TermXCore

final class TarGzExtractorTests: XCTestCase {
    private var staging: URL!

    override func setUpWithError() throws {
        staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("targz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: staging)
    }

    func testExtractsRegularFileAndDirectory() throws {
        let archive = try makeArchive(members: [
            .dir("package/"),
            .file("package/hello.txt", "hello\n"),
            .file("package/bin/cli.js", "console.log(1)\n"),
        ])
        let dest = staging.appendingPathComponent("out")
        try TarGzExtractor.extract(archive: archive, into: dest)

        let hello = try String(contentsOf: dest.appendingPathComponent("package/hello.txt"), encoding: .utf8)
        XCTAssertEqual(hello, "hello\n")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("package/bin/cli.js").path))
    }

    func testShouldExtractFilterSkipsMembers() throws {
        let archive = try makeArchive(members: [
            .dir("package/"),
            .file("package/bin/cli.js", "ok\n"),
            .file("package/man/npm.1", "manual\n"),
            .file("package/docs/readme.md", "docs\n"),
        ])
        let dest = staging.appendingPathComponent("filtered")
        try TarGzExtractor.extract(archive: archive, into: dest) { name in
            if name.hasPrefix("package/man/") { return false }
            if name.hasPrefix("package/docs/") { return false }
            return true
        }

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("package/bin/cli.js").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("package/man/npm.1").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("package/docs/readme.md").path))
    }

    func testRejectsPathEscape() throws {
        // Foundation resolves `..` components after standardize, so a tar
        // member named `../../escape.txt` must not land outside dest.
        let archive = try makeArchive(members: [
            .file("../../escape.txt", "nope\n"),
        ])
        let dest = staging.appendingPathComponent("safe")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        XCTAssertThrowsError(try TarGzExtractor.extract(archive: archive, into: dest)) { err in
            let text = String(describing: err)
            XCTAssertTrue(text.contains("path escape") || text.contains("malformed"), text)
        }
    }

    // MARK: - fixture builder (ustar + gzip)

    private enum Member {
        case dir(String)
        case file(String, String)
    }

    private func makeArchive(members: [Member]) throws -> URL {
        var tar = Data()
        for member in members {
            switch member {
            case .dir(let name):
                tar.append(ustarHeader(name: name, typeFlag: "5", size: 0, mode: 0o755))
            case .file(let name, let body):
                let payload = Data(body.utf8)
                tar.append(ustarHeader(name: name, typeFlag: "0", size: payload.count, mode: 0o644))
                tar.append(payload)
                let pad = (512 - (payload.count % 512)) % 512
                if pad > 0 { tar.append(Data(count: pad)) }
            }
        }
        tar.append(Data(count: 1024)) // two zero blocks
        let gz = try gzip(tar)
        let url = staging.appendingPathComponent("fixture.tgz")
        try gz.write(to: url)
        return url
    }

    private func ustarHeader(name: String, typeFlag: String, size: Int, mode: Int) -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, _ start: Int, _ len: Int) {
            let bytes = Array(s.utf8.prefix(len - 1))
            for (i, b) in bytes.enumerated() { block[start + i] = b }
        }
        put(name, 0, 100)
        put(String(format: "%07o", mode), 100, 8)
        put("0000000", 108, 8) // uid
        put("0000000", 116, 8) // gid
        put(String(format: "%011o", size), 124, 12)
        put(String(format: "%011o", Int(Date().timeIntervalSince1970)), 136, 12)
        put("        ", 148, 8) // checksum blanked for calc
        block[156] = typeFlag.utf8.first!
        put("ustar", 257, 6)
        put("00", 263, 2)

        var sum = 0
        for b in block { sum += Int(b) }
        put(String(format: "%06o\0 ", sum), 148, 8)
        return Data(block)
    }

    private func gzip(_ input: Data) throws -> Data {
        var stream = z_stream()
        var status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                                   15 + 16, 8, Z_DEFAULT_STRATEGY,
                                   ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw NSError(domain: "gzip", code: Int(status)) }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunk = 1 << 16
        var outBuf = [UInt8](repeating: 0, count: chunk)
        try input.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var flush = Z_NO_FLUSH
            repeat {
                if stream.avail_in == 0 { flush = Z_FINISH }
                try outBuf.withUnsafeMutableBufferPointer { buf in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = deflate(&stream, flush)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw NSError(domain: "gzip", code: Int(status))
                    }
                    output.append(buf.baseAddress!, count: chunk - Int(stream.avail_out))
                }
            } while status != Z_STREAM_END
        }
        return output
    }
}
