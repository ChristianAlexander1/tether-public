import Foundation

public typealias TermXPID = Int32

public struct SpawnRequest: Sendable {
    public let commandLine: String
    public let cwd: String
    public let environment: [String: String]
    public let interactive: Bool
    public init(commandLine: String, cwd: String, environment: [String: String] = [:], interactive: Bool = false) {
        self.commandLine = commandLine; self.cwd = cwd; self.environment = environment; self.interactive = interactive
    }
}

public protocol TerminalEngine: AnyObject {
    func startShell(cwd: String, env: [String: String], ptySlave: Int32, onExit: @escaping (Int32) -> Void) throws -> Int32
    func signal(pid: Int32, _ sig: Int32)
}

public enum TermXError: Error, LocalizedError, Equatable {
    case emptyCommand, invalidWorkingDirectory, commandNotFound(String), invalidPath(String), permissionDenied(String)
    public var errorDescription: String? {
        switch self { case .emptyCommand: return "Command cannot be empty."; case .invalidWorkingDirectory: return "Working directory is not accessible."; case .commandNotFound(let n): return "\(n): command not found"; case .invalidPath(let p): return "Invalid path: \(p)"; case .permissionDenied(let p): return "Permission denied: \(p)" }
    }
}

public struct ShellTokenizer {
    public static func tokenize(_ input: String) -> [String] {
        var result: [String] = [], current = "", quote: Character?, escaped = false
        for c in input {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if let q = quote { if c == q { quote = nil } else { current.append(c) }; continue }
            if c == "\"" || c == "'" { quote = c }
            else if c.isWhitespace { if !current.isEmpty { result.append(current); current = "" } }
            else { current.append(c) }
        }
        if escaped { current.append("\\") }; if !current.isEmpty { result.append(current) }; return result
    }
}

public struct CommandResult: Sendable, Equatable { public let output: String; public let exitCode: Int32; public init(output: String, exitCode: Int32) { self.output = output; self.exitCode = exitCode } }

public final class TermXCommandEngine {
    public static let shared = TermXCommandEngine()
    private var history: [String] = []
    private var lastExit: Int32 = 0
    private var variables: [String: String] = [:]
    private let lock = NSLock()
    public init() {}

    public func run(_ request: SpawnRequest) async throws -> Int32 { let r = try await execute(request.commandLine, cwd: request.cwd, environment: request.environment); if !r.output.isEmpty { print(r.output, terminator: "") }; return r.exitCode }
    public func execute(_ commandLine: String, cwd: String, environment: [String: String] = [:]) async throws -> CommandResult {
        guard !commandLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TermXError.emptyCommand }
        var isDir: ObjCBool = false; guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { throw TermXError.invalidWorkingDirectory }
        lock.lock(); history.append(commandLine); lock.unlock()
        let expanded = expand(commandLine, environment: environment)
        var output = ""; var code: Int32 = 0
        for sequence in splitTopLevel(expanded, separator: "&&") { let r = try await executeSequence(sequence, cwd: cwd, environment: environment); output += r.output; code = r.exitCode; if code != 0 { break } }
        lock.lock(); lastExit = code; lock.unlock(); return CommandResult(output: output, exitCode: code)
    }

    private func executeSequence(_ input: String, cwd: String, environment: [String: String]) async throws -> CommandResult {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines); if text.hasSuffix("&") { text.removeLast() }
        let pipeline = splitTopLevel(text, separator: "|"); var data = ""; var code: Int32 = 0
        for (index, stage) in pipeline.enumerated() { let parsed = parseRedirect(stage); let result = try executeBuiltin(parsed.argv, cwd: cwd, stdin: data, environment: environment); data = result.output; code = result.exitCode; if let path = parsed.redirect { try data.write(toFile: resolve(path, cwd: cwd), atomically: true, encoding: .utf8) }; if index == pipeline.count - 1 { break } }
        return CommandResult(output: data, exitCode: code)
    }

    private func executeBuiltin(_ args: [String], cwd: String, stdin: String, environment: [String: String]) throws -> CommandResult {
        guard let command = args.first else { return CommandResult(output: "", exitCode: 0) }; let a = Array(args.dropFirst()); let fm = FileManager.default
        func path(_ p: String) -> String { resolve(p, cwd: cwd) }
        switch command {
        case "help": return CommandResult(output: "TermX shell commands: cd pwd ls cat echo printf touch mkdir rm cp mv grep head tail wc find clear env export history which date uname jobs kill help\n", exitCode: 0)
        case "pwd": return CommandResult(output: cwd + "\n", exitCode: 0)
        case "echo": return CommandResult(output: a.joined(separator: " ") + "\n", exitCode: 0)
        case "printf": return CommandResult(output: a.joined(separator: " "), exitCode: 0)
        case "clear": return CommandResult(output: "\u{001B}[2J\u{001B}[H", exitCode: 0)
        case "history": lock.lock(); let h = history.enumerated().map { "\($0.offset + 1)  \($0.element)" }.joined(separator: "\n"); lock.unlock(); return CommandResult(output: h + (h.isEmpty ? "" : "\n"), exitCode: 0)
        case "cd": return CommandResult(output: "", exitCode: 0) // cwd mutation is owned by the terminal session
        case "ls":
            let target = path(a.first ?? "."); let names = try fm.contentsOfDirectory(atPath: target).sorted(); return CommandResult(output: names.map { $0 + "\n" }.joined(), exitCode: 0)
        case "cat":
            let files = a.isEmpty ? [] : a; if files.isEmpty { return CommandResult(output: stdin, exitCode: 0) }; var out = ""; for f in files { out += try String(contentsOfFile: path(f), encoding: .utf8) }; return CommandResult(output: out, exitCode: 0)
        case "touch": for f in a { let p = path(f); if !fm.fileExists(atPath: p) { fm.createFile(atPath: p, contents: Data()) } }; return CommandResult(output: "", exitCode: 0)
        case "mkdir": for f in a.filter({ !$0.hasPrefix("-") }) { try fm.createDirectory(atPath: path(f), withIntermediateDirectories: a.contains("-p")) }; return CommandResult(output: "", exitCode: 0)
        case "rm": for f in a.filter({ !$0.hasPrefix("-") }) { try fm.removeItem(atPath: path(f)) }; return CommandResult(output: "", exitCode: 0)
        case "cp": guard a.count >= 2 else { return CommandResult(output: "cp: missing operand\n", exitCode: 1) }; try fm.copyItem(atPath: path(a[0]), toPath: path(a[1])); return CommandResult(output: "", exitCode: 0)
        case "mv": guard a.count >= 2 else { return CommandResult(output: "mv: missing operand\n", exitCode: 1) }; try fm.moveItem(atPath: path(a[0]), toPath: path(a[1])); return CommandResult(output: "", exitCode: 0)
        case "grep": guard let needle = a.first else { return CommandResult(output: "grep: missing pattern\n", exitCode: 2) }; let source = a.dropFirst().first.map { try String(contentsOfFile: path($0), encoding: .utf8) } ?? stdin; let lines = source.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.localizedCaseInsensitiveContains(needle) }; return CommandResult(output: lines.map(String.init).joined(separator: "\n") + (lines.isEmpty ? "" : "\n"), exitCode: lines.isEmpty ? 1 : 0)
        case "head", "tail": let n = Int(a.first ?? "10") ?? 10; let lines = stdin.split(separator: "\n", omittingEmptySubsequences: false); let selected = command == "head" ? lines.prefix(n) : lines.suffix(n); return CommandResult(output: selected.map(String.init).joined(separator: "\n") + (selected.isEmpty ? "" : "\n"), exitCode: 0)
        case "wc": let lines = stdin.split(separator: "\n", omittingEmptySubsequences: false).count; return CommandResult(output: "\(lines)\n", exitCode: 0)
        case "env": lock.lock(); let vars = variables; lock.unlock(); return CommandResult(output: vars.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n") + "\n", exitCode: 0)
        case "export": for value in a { let parts = value.split(separator: "=", maxSplits: 1).map(String.init); if parts.count == 2 { lock.lock(); variables[parts[0]] = parts[1]; lock.unlock() } }; return CommandResult(output: "", exitCode: 0)
        case "which": return CommandResult(output: a.first.map { "/bin/\($0)\n" } ?? "", exitCode: a.isEmpty ? 1 : 0)
        case "date": return CommandResult(output: ISO8601DateFormatter().string(from: Date()) + "\n", exitCode: 0)
        case "uname": return CommandResult(output: "Darwin\n", exitCode: 0)
        case "jobs": return CommandResult(output: "\n", exitCode: 0)
        default: throw TermXError.commandNotFound(command)
        }
    }

    private func parseRedirect(_ input: String) -> (argv: [String], redirect: String?) { let parts = input.split(separator: ">", maxSplits: 1).map(String.init); return (ShellTokenizer.tokenize(parts[0]), parts.count == 2 ? ShellTokenizer.tokenize(parts[1]).first : nil) }
    private func splitTopLevel(_ text: String, separator: String) -> [String] { text.components(separatedBy: separator) }
    private func expand(_ text: String, environment: [String: String]) -> String { var out = text; let merged = environment.merging(variables) { _, new in new }; for (k, v) in merged { out = out.replacingOccurrences(of: "$\(k)", with: v) }; lock.lock(); out = out.replacingOccurrences(of: "$?", with: "\(lastExit)"); lock.unlock(); return out }
    private func resolve(_ value: String, cwd: String) -> String { let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : URL(fileURLWithPath: cwd).appendingPathComponent(value); return url.standardizedFileURL.path }
    public static func defaultEnvironment(home: String) -> [String: String] { ["HOME": home, "PATH": "/bin:\(home)/wasm/bin:\(home)/node/bin:\(home)/python/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8"] }
}
