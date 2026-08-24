import Foundation
@testable import TetherShellLang

/// Mock host used by every test: captures output, replays canned command
/// responses, and holds a small environment. No processes, no real I/O.
final class MockShellHost: ShellHost {
    struct Response {
        var stdout: String?
        var code: Int32
    }

    var env: [String: String] = [:]
    var responses: [String: Response] = [:]
    var defaultCode: Int32 = 0
    private(set) var stdout = ""
    private(set) var stderr = ""
    private(set) var ranCommands: [String] = []

    func run(commandLine: String) -> Int32 {
        ranCommands.append(commandLine)
        if let response = responses[commandLine] {
            if let out = response.stdout { write(out) }
            return response.code
        }
        return defaultCode
    }

    func write(_ text: String) { stdout += text }
    func writeError(_ text: String) { stderr += text }
    func value(for name: String) -> String? { env[name] }
    func setValue(_ value: String?, for name: String) { env[name] = value }
}

/// Turns a mock into the transcript compared against `.expected` files:
/// stdout verbatim, then a `[stderr]` block when anything hit stderr.
func transcript(of host: MockShellHost) -> String {
    var text = host.stdout
    if !host.stderr.isEmpty {
        text += "[stderr]\n"
        text += host.stderr
    }
    return text
}

// MARK: - Fixture directives

/// Test-side knobs for fixtures, embedded as `#@` shell comments:
///
///     #@ argv: a b c                  positional parameters
///     #@ env: NAME=VALUE              host environment entry
///     #@ cmd: EXACT LINE => N         canned host exit code
///     #@ cmdout: EXACT LINE => N :: TEXT   plus canned stdout (\n escapes)
///     #@ file: PATH :: TEXT           pre-seed the virtual file system
///     #@ want: EXACT LINE             assert the host ran this command line
///     #@ status: N                    assert the final exit status
///     #@ verify-env: NAME=VALUE       assert host env afterwards (empty → unset)
struct Directives {
    var argv: [String] = []
    var env: [String: String] = [:]
    var responses: [String: MockShellHost.Response] = [:]
    var files: [(String, String)] = []
    var wants: [String] = []
    var expectedStatus: Int32?
    var verifyEnv: [(String, String?)] = []

    static func unescape(_ text: String) -> String {
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\\", text.index(after: i) < text.endIndex {
                let n = text[text.index(after: i)]
                switch n {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\\": out.append("\\")
                default: out.append(n)
                }
                i = text.index(i, offsetBy: 2)
            } else {
                out.append(c)
                i = text.index(after: i)
            }
        }
        return out
    }

    static func parse(_ source: String) -> Directives {
        var d = Directives()
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            guard rawLine.hasPrefix("#@") else { continue }
            let line = String(rawLine.dropFirst(2))
                .trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            switch key {
            case "argv":
                d.argv = value.split(separator: " ").map(String.init)
            case "env":
                if let eq = value.firstIndex(of: "=") {
                    d.env[String(value[..<eq])] = String(value[value.index(after: eq)...])
                }
            case "cmd", "cmdout":
                // VALUE := COMMAND " => " CODE [ " :: " TEXT ]
                guard let arrow = value.range(of: " => ") else { continue }
                let command = String(value[..<arrow.lowerBound])
                var spec = String(value[arrow.upperBound...])
                var stdout: String? = nil
                if let sep = spec.range(of: " :: ") {
                    stdout = unescape(String(spec[sep.upperBound...]))
                    spec = String(spec[..<sep.lowerBound])
                }
                let code = Int32(spec.trimmingCharacters(in: .whitespaces)) ?? 0
                d.responses[command] = MockShellHost.Response(stdout: stdout, code: code)
            case "file":
                guard let sep = value.range(of: " :: ") else { continue }
                let path = String(value[..<sep.lowerBound])
                let text = unescape(String(value[sep.upperBound...]))
                d.files.append((path, text))
            case "want":
                d.wants.append(value)
            case "status":
                d.expectedStatus = Int32(value)
            case "verify-env":
                if let eq = value.firstIndex(of: "=") {
                    let name = String(value[..<eq])
                    let expected = String(value[value.index(after: eq)...])
                    d.verifyEnv.append((name, expected.isEmpty ? nil : expected))
                } else {
                    d.verifyEnv.append((value, nil))
                }
            default:
                continue
            }
        }
        return d
    }
}

/// Runs one fixture pair; returns a failure description, or nil on success.
func runFixture(script: String, expected: String, name: String) -> String? {
    let directives = Directives.parse(script)
    let host = MockShellHost()
    host.env = directives.env
    host.responses = directives.responses
    let shell = TetherShell(host: host)
    shell.scriptName = name
    shell.arguments = directives.argv
    for (path, text) in directives.files {
        shell.setVirtualFile(path, contents: text)
    }

    do {
        _ = try shell.run(script)
    } catch {
        return "\(name): threw \(error)"
    }

    var problems: [String] = []
    let actual = transcript(of: host)
    if actual != expected {
        problems.append(diffExpected(expected: expected, actual: actual))
    }
    if let want = directives.expectedStatus, shell.lastStatus != want {
        problems.append("last status \(shell.lastStatus), expected \(want)")
    }
    for want in directives.wants where !host.ranCommands.contains(want) {
        problems.append("host never ran `\(want)` (ran: \(host.ranCommands))")
    }
    for (name, expected) in directives.verifyEnv where host.env[name] != expected {
        problems.append("env \(name) = \(host.env[name] ?? "<unset>"), expected \(expected ?? "<unset>")")
    }
    return problems.isEmpty ? nil : "\(name):\n  " + problems.joined(separator: "\n  ")
}

private func diffExpected(expected: String, actual: String) -> String {
    let e = expected.split(separator: "\n", omittingEmptySubsequences: false)
    let a = actual.split(separator: "\n", omittingEmptySubsequences: false)
    var lines: [String] = []
    let count = max(e.count, a.count)
    for i in 0..<count {
        let exp = i < e.count ? String(e[i]) : "<missing>"
        let act = i < a.count ? String(a[i]) : "<missing>"
        if exp != act {
            lines.append("line \(i + 1): expected \(exp.debugDescription), got \(act.debugDescription)")
        }
    }
    return "output mismatch (\(a.count) vs \(e.count) lines): "
        + lines.prefix(6).joined(separator: "; ")
}
