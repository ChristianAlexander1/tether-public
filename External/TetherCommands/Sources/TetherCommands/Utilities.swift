import Foundation

internal enum CommandSupport {
    static func args(_ io: CommandIO, command: String) -> [String] {
        guard let first = io.argv.first else { return [] }
        return (first == command || URL(fileURLWithPath: first).lastPathComponent == command) ? Array(io.argv.dropFirst()) : io.argv
    }

    static func path(_ value: String, cwd: String) -> String {
        if value.hasPrefix("/") { return URL(fileURLWithPath: value).standardizedFileURL.path }
        return URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(value).standardizedFileURL.path
    }

    static func read(_ operand: String?, io: CommandIO) throws -> String {
        guard let operand, operand != "-" else { return io.stdin }
        return try String(contentsOfFile: path(operand, cwd: io.cwd), encoding: .utf8)
    }

    static func readData(_ operand: String?, io: CommandIO) throws -> Data {
        guard let operand, operand != "-" else { return Data(io.stdin.utf8) }
        return try Data(contentsOf: URL(fileURLWithPath: path(operand, cwd: io.cwd)))
    }

    static func lines(_ text: String) -> [String] {
        var values = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { values.removeLast() }
        return values
    }

    static func shellWords(_ text: String) -> [String] {
        var words: [String] = [], current = ""
        var quote: Character?, escaped = false
        for ch in text {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && quote != "'" { escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch.isWhitespace {
                if !current.isEmpty { words.append(current); current = "" }
            } else { current.append(ch) }
        }
        if escaped { current.append("\\") }
        if !current.isEmpty { words.append(current) }
        return words
    }

    static func error(_ command: String, _ message: String, usage: Bool = false) -> CommandResult {
        CommandResult(stderr: "\(command): \(message)\n", exitCode: usage ? 2 : 1)
    }

    static func write(_ text: String, to path: String, append: Bool = false) throws {
        try writeData(Data(text.utf8), to: path, append: append)
    }

    static func writeData(_ data: Data, to path: String, append: Bool = false) throws {
        if append, FileManager.default.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    static func expandCharacterSet(_ pattern: String) -> [Character] {
        let chars = Array(pattern)
        var result: [Character] = [], i = 0
        while i < chars.count {
            if i + 2 < chars.count, chars[i + 1] == "-",
               let a = chars[i].asciiValue, let b = chars[i + 2].asciiValue, a <= b {
                for n in a...b { result.append(Character(UnicodeScalar(n))) }
                i += 3
            } else {
                result.append(chars[i]); i += 1
            }
        }
        return result
    }

    static func modeString(_ attributes: [FileAttributeKey: Any]) -> String {
        let type = attributes[.type] as? FileAttributeType
        let prefix = type == .typeDirectory ? "d" : (type == .typeSymbolicLink ? "l" : "-")
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let bits = [(0o400,"r"),(0o200,"w"),(0o100,"x"),(0o040,"r"),(0o020,"w"),(0o010,"x"),(0o004,"r"),(0o002,"w"),(0o001,"x")]
        return prefix + bits.map { mode & $0.0 != 0 ? $0.1 : "-" }.joined()
    }

    static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    static func executablePath(_ name: String, io: CommandIO) -> String? {
        if name.contains("/") {
            let candidate = path(name, cwd: io.cwd)
            return isExecutable(candidate) ? candidate : nil
        }
        for dir in (io.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false) {
            let base = dir.isEmpty ? io.cwd : String(dir)
            let candidate = path(name, cwd: base)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    static func parseDuration(_ value: String) -> Double? {
        guard !value.isEmpty else { return nil }
        let suffix = value.last!
        let multiplier: Double
        let number: String
        switch suffix {
        case "s": multiplier = 1; number = String(value.dropLast())
        case "m": multiplier = 60; number = String(value.dropLast())
        case "h": multiplier = 3600; number = String(value.dropLast())
        case "d": multiplier = 86400; number = String(value.dropLast())
        default: multiplier = 1; number = value
        }
        guard let d = Double(number), d.isFinite, d >= 0 else { return nil }
        let result = d * multiplier
        return result.isFinite ? result : nil
    }
}
