import Foundation

/// `stat` — display file status. Supports `-c`/`--format` with the common `%`
/// tokens, plus a reasonable default line for one file.
struct StatCommand: TermXCommand {
    static let name = "stat"

    static func run(_ io: CommandIO) -> CommandResult {
        var format: String? = nil
        var files: [String] = []
        var i = 1
        var rest = false
        while i < io.argv.count {
            let a = io.argv[i]
            if !rest && (a == "-c" || a == "-f") {
                if a == "-f" { return CommandSupport.usageError(io, "-f is unsupported; use -c") }
                i += 1
                if i >= io.argv.count { return CommandSupport.usageError(io, "\(a) requires an argument") }
                format = io.argv[i]
            } else if !rest && (a == "--format") {
                i += 1
                if i >= io.argv.count { return CommandSupport.usageError(io, "--format requires an argument") }
                format = io.argv[i]
            } else if !rest && a == "--" { rest = true }
            else {
                files.append(a)
            }
            i += 1
        }
        if files.isEmpty { return CommandSupport.usageError(io, "missing operand") }
        let fmt = format ?? "%F %n\n"

        var out = ""
        for f in files {
            let full = CommandSupport.resolve(f, cwd: io.cwd)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: full) else {
                return CommandSupport.error(io, "\(f): No such file or directory")
            }
            out += render(fmt, file: f, full: full, attrs: attrs)
        }
        return CommandResult(stdout: out)
    }

    private static func render(_ fmt: String, file: String, full: String, attrs: [FileAttributeKey: Any]) -> String {
        let permsInt = (attrs[.posixPermissions] as? Int) ?? 0
        let fileType: String
        switch (attrs[.type] as? FileAttributeType) {
        case .typeDirectory: fileType = "directory"
        case .typeSymbolicLink: fileType = "symbolic link"
        case .typeRegular: fileType = "regular file"
        default: fileType = "file"
        }
        let permStr = symbolicPerms(permsInt)
        let size = (attrs[.size] as? Int) ?? 0
        let modDate = (attrs[.modificationDate] as? Date) ?? Date()

        var out = ""
        var i = fmt.startIndex
        while i < fmt.endIndex {
            let c = fmt[i]
            if c == "%", fmt.index(after: i) < fmt.endIndex {
                let n = fmt[fmt.index(after: i)]
                switch n {
                case "n": out += file
                case "F": out += fileType
                case "s": out += String(size)
                case "a": out += String(permsInt, radix: 8)
                case "A": out += permStr
                case "f": out += String(permsInt, radix: 16)
                case "i": out += String((attrs[.systemFileNumber] as? Int) ?? 0)
                case "h": out += String((attrs[.referenceCount] as? Int) ?? 1)
                case "u": out += String((attrs[.ownerAccountID] as? Int) ?? 0)
                case "g": out += String((attrs[.groupOwnerAccountID] as? Int) ?? 0)
                case "Y": out += String(Int(modDate.timeIntervalSince1970))
                case "%": out += "%"
                default: out += "%" + String(n)
                }
                i = fmt.index(i, offsetBy: 2)
            } else {
                out.append(c)
                i = fmt.index(after: i)
            }
        }
        return out
    }

    private static func symbolicPerms(_ p: Int) -> String {
        var chars = Array("rwxrwxrwx")
        let slots: [(bit: Int, idx: Int)] = [
            (0o400, 0), (0o200, 1), (0o100, 2),
            (0o040, 3), (0o020, 4), (0o010, 5),
            (0o004, 6), (0o002, 7), (0o001, 8),
        ]
        for s in slots {
            if p & s.bit == 0 { chars[s.idx] = "." }
        }
        return String(chars)
    }
}
