import Foundation
import TetherJobIPC
import XCTest
@testable import TermXNode

/// The interop gate required before any production wiring of TJIP/2: the Swift
/// server's golden frames and the JavaScript client's framing implementation
/// must agree on **every fixture byte**, in both directions.
///
/// The two sides were written independently against one frozen wire spec and
/// have never run in the same process. This test is the only thing that proves
/// the spec was read the same way twice — so it runs the real
/// `External/tether-shim-v2/lib/ipc/framing.js` under the host `node`, exactly
/// as `HostNodeRuntime`'s tests do.
final class JIPInteropGateTests: XCTestCase {
    private static let repoRoot: URL = {
        // .../Packages/TermXNode/Tests/TermXNodeTests/<file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TermXNodeTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // TermXNode
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
    }()

    private static var fixturesURL: URL {
        repoRoot.appendingPathComponent("External/TetherJobIPC/Fixtures/frames.txt")
    }

    private static var framingURL: URL {
        repoRoot.appendingPathComponent("External/tether-shim-v2/lib/ipc/framing.js")
    }

    private static func hostNode() -> String? {
        for candidate in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    /// Parse `Fixtures/frames.txt` into (name, canonical JSON, wire bytes).
    private func loadFixtures() throws -> [(name: String, json: String, hex: String)] {
        let text = try String(contentsOf: Self.fixturesURL, encoding: .utf8)
        var results: [(String, String, String)] = []
        var name: String?
        var json: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("== "), trimmed.hasSuffix(" ==") {
                name = String(trimmed.dropFirst(3).dropLast(3))
                json = nil
            } else if trimmed.hasPrefix("Payload JSON: ") {
                json = String(trimmed.dropFirst("Payload JSON: ".count))
            } else if trimmed.hasPrefix("Hex ("), let range = trimmed.range(of: "): ") {
                let hex = String(trimmed[range.upperBound...])
                if let name, let json { results.append((name, json, hex)) }
            }
        }
        return results
    }

    func testFixturesAreWellFormedAndDecodeInSwift() throws {
        let fixtures = try loadFixtures()
        XCTAssertGreaterThanOrEqual(fixtures.count, 20, "expected the full golden set")

        for fixture in fixtures {
            let bytes = try XCTUnwrap(Data(hexEncoded: fixture.hex), "bad hex in \(fixture.name)")
            XCTAssertGreaterThan(bytes.count, 4, "\(fixture.name): frame shorter than its header")

            let declared = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            XCTAssertEqual(
                Int(declared), bytes.count - 4,
                "\(fixture.name): length prefix disagrees with payload size"
            )
            let payload = String(decoding: bytes.dropFirst(4), as: UTF8.self)
            XCTAssertEqual(payload, fixture.json, "\(fixture.name): payload is not the documented JSON")
        }
    }

    /// Feed every golden frame through the JS `FrameParser`, one byte at a
    /// time, and require the JS side to re-encode byte-identical frames.
    func testJavaScriptFramingAgreesWithSwiftGoldenFrames() throws {
        guard let node = Self.hostNode() else {
            throw XCTSkip("no host node available for the interop gate")
        }
        guard FileManager.default.fileExists(atPath: Self.framingURL.path) else {
            throw XCTSkip("tether-shim-v2 not present")
        }
        let fixtures = try loadFixtures()

        let payload = try JSONSerialization.data(withJSONObject: fixtures.map {
            ["name": $0.name, "hex": $0.hex]
        })
        let script = """
        const { FrameParser, encodeFrame } = require(process.argv[1]);
        const fixtures = JSON.parse(process.argv[2]);
        const failures = [];
        for (const f of fixtures) {
          const wire = Buffer.from(f.hex, 'hex');
          const seen = [];
          const parser = new FrameParser((env) => seen.push(env));
          // Byte-at-a-time: proves the parser handles split headers and bodies.
          for (const byte of wire) parser.consume(Buffer.from([byte]));
          if (seen.length !== 1) {
            failures.push(`${f.name}: parsed ${seen.length} frames, expected 1`);
            continue;
          }
          const reencoded = encodeFrame(seen[0]);
          if (!reencoded.equals(wire)) {
            failures.push(`${f.name}: re-encode mismatch\\n  want ${wire.toString('hex')}\\n  got  ${reencoded.toString('hex')}`);
          }
        }
        process.stdout.write(JSON.stringify({ checked: fixtures.length, failures }));
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["-e", script, Self.framingURL.path, String(decoding: payload, as: UTF8.self)]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(
            process.terminationStatus, 0,
            "node failed: \(String(decoding: errData, as: UTF8.self))"
        )
        let result = try XCTUnwrap(
            JSONSerialization.jsonObject(with: outData) as? [String: Any],
            "unparseable interop output: \(String(decoding: outData, as: UTF8.self))"
        )
        let failures = (result["failures"] as? [String]) ?? []
        XCTAssertTrue(failures.isEmpty, "wire disagreement:\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(result["checked"] as? Int, fixtures.count)
    }

    /// The reverse direction: frames the JS client produces must decode in the
    /// Swift codec with the same envelope fields.
    func testSwiftCodecDecodesJavaScriptEncodedFrames() throws {
        guard let node = Self.hostNode() else {
            throw XCTSkip("no host node available for the interop gate")
        }
        let script = """
        const { encodeFrame } = require(process.argv[1]);
        const envelopes = [
          { v: 2, kind: 'req', id: 1, type: 'hello',
            body: { proto: 2, role: 'node-shim', features: ['tty', 'spawn', 'flow'] } },
          { v: 2, kind: 'req', id: 2, type: 'tty.get', body: { fd: 0 } },
          { v: 2, kind: 'evt', type: 'flow.ack', body: { pid: 7, bytes: 4096 } },
        ];
        const frames = envelopes.map((e) => encodeFrame(e));
        process.stdout.write(Buffer.concat(frames).toString('hex'));
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["-e", script, Self.framingURL.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let hex = String(decoding: outData, as: UTF8.self)
        let bytes = try XCTUnwrap(Data(hexEncoded: hex))

        // Feed the concatenated stream in awkward slices; the codec must find
        // exactly three frames regardless of how the bytes were chunked.
        var codec = JIPFrameCodec()
        var decoded: [Data] = []
        var offset = 0
        let chunkSizes = [1, 7, 3, 64, 5]
        var sizeIndex = 0
        while offset < bytes.count {
            let size = min(chunkSizes[sizeIndex % chunkSizes.count], bytes.count - offset)
            sizeIndex += 1
            let chunk = bytes.subdata(in: offset..<(offset + size))
            offset += size
            decoded.append(contentsOf: try codec.append(chunk))
        }
        XCTAssertEqual(decoded.count, 3, "Swift codec did not recover the JS frames")

        let types = decoded.compactMap { frame -> String? in
            guard let obj = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
                return nil
            }
            return obj["type"] as? String
        }
        XCTAssertEqual(types, ["hello", "tty.get", "flow.ack"])
    }
}

private extension Data {
    init?(hexEncoded hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
