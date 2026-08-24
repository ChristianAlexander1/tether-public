import XCTest
import TetherShellLang

final class TetherShellConformanceTests: XCTestCase {
    private final class RecordingHost: ShellHost {
        var output = ""
        var errors = ""
        var environment: [String: String] = [:]
        var commands: [String] = []

        func run(commandLine: String) -> Int32 {
            commands.append(commandLine)
            return 0
        }

        func write(_ text: String) { output += text }
        func writeError(_ text: String) { errors += text }
        func value(for name: String) -> String? { environment[name] }
        func setValue(_ value: String?, for name: String) { environment[name] = value }
    }

    func testDeliveredParserAcceptsProductionCompoundSyntax() throws {
        let host = RecordingHost()
        let shell = TetherShell(host: host)
        let status = try shell.run("""
        value=ready
        if test "$value" = ready; then
          for item in one two; do printf '%s\\n' "$item"; done
        fi
        """)

        XCTAssertEqual(status, 0)
        XCTAssertEqual(host.output, "one\ntwo\n")
        XCTAssertTrue(host.errors.isEmpty)
    }
}
