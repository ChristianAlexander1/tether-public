import Foundation
import XCTest
@testable import TetherShellLang

/// Runs every `NN_name.sh` / `NN_name.expected` pair from
/// `fixtures/` against a fresh mock host and compares transcripts.
final class FixtureTests: XCTestCase {

    private func fixturesDirectory() throws -> URL {
        guard let url = Bundle.module.url(forResource: "fixtures", withExtension: nil) else {
            throw NSError(domain: "FixtureTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "fixtures directory missing"])
        }
        return url
    }

    func testAllFixtures() throws {
        let dir = try fixturesDirectory()
        let scripts = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sh" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertGreaterThanOrEqual(scripts.count, 50,
                                    "track requires at least 50 fixture pairs, found \(scripts.count)")

        var failures: [String] = []
        for scriptURL in scripts {
            let base = scriptURL.deletingPathExtension().lastPathComponent
            let expectedURL = scriptURL.deletingPathExtension()
                .appendingPathExtension("expected")
            guard let expected = try? String(contentsOf: expectedURL, encoding: .utf8) else {
                failures.append("\(base): missing .expected file")
                continue
            }
            let script = try String(contentsOf: scriptURL, encoding: .utf8)
            if let failure = runFixture(script: script, expected: expected, name: base) {
                failures.append(failure)
            }
        }

        XCTAssert(failures.isEmpty,
                  "\(failures.count) fixture(s) failed:\n\n" + failures.joined(separator: "\n\n"))
    }
}
