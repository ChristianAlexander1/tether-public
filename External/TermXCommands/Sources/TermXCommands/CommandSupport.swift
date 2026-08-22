import Foundation

/// Internal helpers shared by all commands. Not part of the public interface.
enum CommandSupport {

    static let usageExit: Int32 = 2
    static let failureExit: Int32 = 1

    /// Resolve a (possibly relative) path against `cwd`; absolute paths pass through.
    static func resolve(_ path: String, cwd: String) -> String {
        if path.hasPrefix("/") { return path }
        if cwd.isEmpty { return path }
        return cwd + "/" + path
    }

    /// Read a text file, resolving relative paths against `cwd`. Returns nil on error.
    static func readTextFile(_ path: String, cwd: String) -> String? {
        let full = resolve(path, cwd: cwd)
        do {
            return try String(contentsOfFile: full, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Read raw file data.
    static func readData(_ path: String, cwd: String) -> Data? {
        let full = resolve(path, cwd: cwd)
        return try? Data(contentsOf: URL(fileURLWithPath: full))
    }

    /// The command's name (argv[0]), or a fallback.
    static func name(_ io: CommandIO) -> String {
        return io.argv.first ?? ""
    }

    /// "name: message"
    static func error(_ io: CommandIO, _ message: String) -> CommandResult {
        return CommandResult(stdout: "", stderr: "\(name(io)): \(message)", exitCode: failureExit)
    }

    /// Usage error (exit code 2).
    static func usageError(_ io: CommandIO, _ message: String) -> CommandResult {
        return CommandResult(stdout: "", stderr: "\(name(io)): \(message)", exitCode: usageExit)
    }

    /// The default input stream: if there are no more file operands, or the operand
    /// is `-`, read `io.stdin`; otherwise read the named file.
    /// Returns (text, errorMessage) where errorMessage is non-nil on a read failure.
    static func readInput(_ io: CommandIO, operand: String?) -> (String, String?) {
        if let operand = operand, operand != "-" {
            guard let content = readTextFile(operand, cwd: io.cwd) else {
                return ("", "\(operand): No such file or directory")
            }
            return (content, nil)
        }
        return (io.stdin, nil)
    }

    /// Split stdin/input into lines, preserving the final line without a trailing
    /// newline as a short trailing element if present.
    static func lines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var result = text.components(separatedBy: "\n")
        if result.last == "" { result.removeLast() }
        return result
    }

    /// Join lines back with newlines, adding a trailing newline (Unix convention).
    static func joined(_ lines: [String]) -> String {
        if lines.isEmpty { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Split path component delimiter used by the global `PATH`.
    static func pathComponents(_ environment: [String: String]) -> [String] {
        guard let p = environment["PATH"] else { return [] }
        return p.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }
}

/// Standard foundation for commands that operate textually over input in/out.
enum TextUtil {
    /// Split on whitespace (used for simple field-based commands).
    static func fields(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        for c in line {
            if c == " " || c == "\t" {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
