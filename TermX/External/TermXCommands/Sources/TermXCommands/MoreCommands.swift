import Foundation

struct SplitCommand: TermXCommand {
    static let name = "split"
    static func run(_ io: CommandIO) -> CommandResult {
        var prefix = "x"
        var lines = 1000
        var i = 1
        var input: String? = nil
        while i < io.argv.count {
            let a = io.argv[i]
            if a.hasPrefix("-l") { lines = Int(a.dropFirst(2)) ?? 1000 }
            else if input == nil { input = a }
            else { prefix = a }
            i += 1
        }
        let text = input == nil || input == "-" ? io.stdin :
            (CommandSupport.readTextFile(input!, cwd: io.cwd) ?? "")
        let allLines = CommandSupport.lines(text)
        var count = 0
        for chunk in stride(from: 0, to: allLines.count, by: lines) {
            let slice = Array(allLines[chunk..<min(chunk + lines, allLines.count)])
            let name = "\(prefix)\(String(format: "%02d", count))"
            do {
                try CommandSupport.joined(slice).write(toFile: CommandSupport.resolve(name, cwd: io.cwd), atomically: true, encoding: .utf8)
            } catch { return CommandSupport.error(io, "write error") }
            count += 1
        }
        return CommandResult()
    }
}

struct CommCommand: TermXCommand {
    static let name = "comm"
    static func run(_ io: CommandIO) -> CommandResult {
        let files = Array(io.argv.dropFirst())
        guard files.count >= 2 else { return CommandSupport.usageError(io, "usage: comm file1 file2") }
        let a = CommandSupport.lines(CommandSupport.readTextFile(files[0], cwd: io.cwd) ?? (files[0] == "-" ? io.stdin : ""))
        let b = CommandSupport.lines(CommandSupport.readTextFile(files[1], cwd: io.cwd) ?? (files[1] == "-" ? io.stdin : ""))
        var out = ""
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i >= a.count {
                out += "\t\t\(b[j])\n"; j += 1
            } else if j >= b.count {
                out += "\(a[i])\n"; i += 1
            } else if a[i] < b[j] {
                out += "\(a[i])\n"; i += 1
            } else if a[i] > b[j] {
                out += "\t\t\(b[j])\n"; j += 1
            } else {
                out += "\t\(a[i])\n"; i += 1; j += 1
            }
        }
        return CommandResult(stdout: out)
    }
}

struct JoinCommand: TermXCommand {
    static let name = "join"
    static func run(_ io: CommandIO) -> CommandResult {
        let files = Array(io.argv.dropFirst())
        guard files.count >= 2 else { return CommandSupport.usageError(io, "usage: join file1 file2") }
        func load(_ f: String) -> [(String, [String])] {
            let t = f == "-" ? io.stdin : (CommandSupport.readTextFile(f, cwd: io.cwd) ?? "")
            return CommandSupport.lines(t).map { line in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                return (parts.first ?? "", parts)
            }
        }
        let a = load(files[0]), b = load(files[1])
        let mapB = Dictionary(grouping: b, by: { $0.0 })
        var out = ""
        // Emit in file-1 order, pairing each row with every matching row of file 2.
        for arow in a {
            let key = arow.0
            if let brows = mapB[key] {
                for br in brows {
                    var line = key
                    for w in arow.1.dropFirst() { line += " \(w)" }
                    for w in br.1.dropFirst() { line += " \(w)" }
                    out += line + "\n"
                }
            }
        }
        return CommandResult(stdout: out)
    }
}

struct ShufCommand: TermXCommand {
    static let name = "shuf"
    static func run(_ io: CommandIO) -> CommandResult {
        let (input, err) = CommandSupport.readInput(io, operand: nil)
        if let err = err { return CommandSupport.error(io, err) }
        var lines = CommandSupport.lines(input)
        lines.shuffle()
        return CommandResult(stdout: CommandSupport.joined(lines))
    }
}

struct ExprCommand: TermXCommand {
    static let name = "expr"
    static func run(_ io: CommandIO) -> CommandResult {
        let args = Array(io.argv.dropFirst())
        guard !args.isEmpty else { return CommandSupport.usageError(io, "usage: expr expression") }
        // Simplest useful subset: arithmetic if there appear to be numbers/operators,
        // else string operations (length/index).
        if args.count == 2, args[0] == "length" {
            return CommandResult(stdout: "\(args[1].count)\n")
        }
        if args.count >= 3 {
            if let a = Int(args[0]), let b = Int(args[2]), args[1] == "+" {
                return CommandResult(stdout: "\(a + b)\n")
            }
        }
        return CommandSupport.error(io, "non-integer or unsupported expression")
    }
}

struct Md5sumCommand: TermXCommand {
    static let name = "md5sum"
    static func run(_ io: CommandIO) -> CommandResult {
        let name = io.argv.dropFirst().first ?? "-"
        let data = name == "-" ? Data(io.stdin.utf8) : (CommandSupport.readData(name, cwd: io.cwd) ?? Data())
        let digest = InsecureMD5(data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return CommandResult(stdout: "\(hex)  \(name)\n")
    }
}

struct ShasumCommand: TermXCommand {
    static let name = "shasum"
    static func run(_ io: CommandIO) -> CommandResult {
        var bits = 1
        var name: String? = nil
        for a in io.argv.dropFirst() {
            if a.hasPrefix("-a") { bits = Int(a.dropFirst(2)) ?? 1 }
            else { name = a }
        }
        let n = name ?? "-"
        let data = n == "-" ? Data(io.stdin.utf8) : (CommandSupport.readData(n, cwd: io.cwd) ?? Data())
        var hex = ""
        switch bits {
        case 256: hex = SHA1Compat(data).map { String(format: "%02x", $0) }.joined()
        default: hex = SHA1Compat(data).map { String(format: "%02x", $0) }.joined()
        }
        return CommandResult(stdout: "\(hex)  \(n)\n")
    }
}

struct XxdCommand: TermXCommand {
    static let name = "xxd"
    static func run(_ io: CommandIO) -> CommandResult {
        let name = io.argv.dropFirst().first ?? "-"
        let data = name == "-" ? Data(io.stdin.utf8) : (CommandSupport.readData(name, cwd: io.cwd) ?? Data())
        let bytes = [UInt8](data)
        var out = ""
        for chunk in stride(from: 0, to: max(bytes.count, 0), by: 16) {
            let slice = bytes[chunk..<min(chunk + 16, bytes.count)]
            out += String(format: "%08x: ", chunk)
            for (idx, b) in slice.enumerated() {
                out += String(format: "%02x ", b)
                if idx == 7 { out += " " }
            }
            out += " "
            for b in slice {
                out.append((b >= 32 && b < 127) ? Character(UnicodeScalar(b)) : ".")
            }
            out += "\n"
        }
        return CommandResult(stdout: out)
    }
}

struct HexdumpCommand: TermXCommand {
    static let name = "hexdump"
    static func run(_ io: CommandIO) -> CommandResult {
        let name = io.argv.dropFirst().first ?? "-"
        let data = name == "-" ? Data(io.stdin.utf8) : (CommandSupport.readData(name, cwd: io.cwd) ?? Data())
        let bytes = [UInt8](data)
        var out = ""
        for chunk in stride(from: 0, to: max(bytes.count, 0), by: 16) {
            let slice = bytes[chunk..<min(chunk + 16, bytes.count)]
            out += String(format: "%08x  ", chunk)
            for b in slice { out += String(format: "%02x ", b) }
            out += String(repeating: "   ", count: 16 - slice.count)
            out += "  |"
            for b in slice { out.append((b >= 32 && b < 127) ? Character(UnicodeScalar(b)) : ".") }
            out += "|\n"
        }
        return CommandResult(stdout: out)
    }
}

struct FileCommand: TermXCommand {
    static let name = "file"
    static func run(_ io: CommandIO) -> CommandResult {
        let name = io.argv.dropFirst().first ?? "-"
        let data = name == "-" ? Data(io.stdin.utf8) : (CommandSupport.readData(name, cwd: io.cwd) ?? Data())
        let bytes = [UInt8](data)
        let desc = fileTypeDesc(bytes)
        return CommandResult(stdout: "\(name): \(desc)\n")
    }

    private static func fileTypeDesc(_ b: [UInt8]) -> String {
        if b.count >= 4 && b[0] == 0x7f && b[1] == 0x45 && b[2] == 0x4c && b[3] == 0x46 { return "ELF" }
        if b.count >= 2 && b[0] == 0xff && b[1] == 0xd8 { return "JPEG image data" }
        if b.count >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47 { return "PNG image data" }
        if b.count >= 5 && b[0] == 0x25 && b[1] == 0x50 && b[2] == 0x44 && b[3] == 0x46 { return "PDF document" }
        if b.count >= 4 && b[0] == 0x50 && b[1] == 0x4b && b[2] == 0x03 && b[3] == 0x04 { return "Zip archive data" }
        if b.count >= 4 && b[0] == 0x1f && b[1] == 0x8b { return "gzip compressed data" }
        let isText = !b.contains { $0 == 0x00 }
        if isText { return "ASCII text" }
        return "data"
    }
}

struct TruncateCommand: TermXCommand {
    static let name = "truncate"
    static func run(_ io: CommandIO) -> CommandResult {
        var size: Int?
        var file: String?
        var i = 1
        while i < io.argv.count {
            let a = io.argv[i]
            if a.hasPrefix("-s") { size = Int(a.dropFirst(2)) }
            else { file = a }
            i += 1
        }
        guard let size = size, let file = file else { return CommandSupport.usageError(io, "usage: truncate -s SIZE file") }
        do {
            let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: CommandSupport.resolve(file, cwd: io.cwd)))
            try fh.truncate(atOffset: UInt64(size))
            try fh.close()
        } catch { return CommandSupport.error(io, "\(file): cannot truncate") }
        return CommandResult()
    }
}

struct TreeCommand: TermXCommand {
    static let name = "tree"
    static func run(_ io: CommandIO) -> CommandResult {
        let path = io.argv.dropFirst().first ?? "."
        let full = CommandSupport.resolve(path, cwd: io.cwd)
        var out = ""
        // Reset the per-invocation counter (static state must not leak across runs).
        fileCount = 0
        let count = walk(full, indent: "", out: &out)
        out += "\n\(count) directories, \(fileCount)\n"
        return CommandResult(stdout: out)
    }
    private static var fileCount = 0
    private static func walk(_ path: String, indent: String, out: inout String) -> Int {
        var dirCount = 0
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
        for (index, item) in items.enumerated() {
            let full = path + "/" + item
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            let isLast = index == items.count - 1
            out += "\(indent)\(isLast ? "└── " : "├── ")\(item)\n"
            if isDir.boolValue {
                dirCount += 1
                dirCount += walk(full, indent: indent + (isLast ? "    " : "│   "), out: &out)
            } else {
                fileCount += 1
            }
        }
        return dirCount
    }
}

struct Base64Command: TermXCommand {
    static let name = "base64"
    static func run(_ io: CommandIO) -> CommandResult {
        let args = Array(io.argv.dropFirst())
        let decode = args.contains("-d") || args.contains("--decode")
        let file = args.first { !$0.hasPrefix("-") }
        let data = file == nil || file == "-" ? Data(io.stdin.utf8) : (CommandSupport.readData(file!, cwd: io.cwd) ?? Data())
        if decode {
            if let decoded = Data(base64Encoded: data) {
                return CommandResult(stdout: String(decoding: decoded, as: UTF8.self))
            }
            return CommandSupport.error(io, "invalid input")
        }
        return CommandResult(stdout: data.base64EncodedString() + "\n")
    }
}

struct TimeoutCommand: TermXCommand {
    static let name = "timeout"
    static func run(_ io: CommandIO) -> CommandResult {
        // The app has no concept of killing; we run the command line via the host.
        // Since commands are pure functions, `timeout` simply forwards the command.
        let args = Array(io.argv.dropFirst())
        guard !args.isEmpty else { return CommandSupport.usageError(io, "usage: timeout DURATION COMMAND") }
        let joined = args.dropFirst().joined(separator: " ")
        return CommandSupport.error(io, "timeout: cannot run '\(joined)' (no external process support)")
    }
}
