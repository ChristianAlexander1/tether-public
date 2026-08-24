import Foundation

/// `readlink` — print the target of a symbolic link, or canonicalize a path
/// with `-f` (resolving symlinks and `..`).
struct ReadlinkCommand: TermXCommand {
    static let name = "readlink"

    static func run(_ io: CommandIO) -> CommandResult {
        var canonical = false
        var files: [String] = []
        var i = 1
        var rest = false
        while i < io.argv.count {
            let a = io.argv[i]
            if !rest && a == "--" { rest = true }
            else if !rest && a.hasPrefix("-f") { canonical = true }
            else { files.append(a) }
            i += 1
        }
        if files.isEmpty { return CommandSupport.usageError(io, "missing operand") }

        for f in files {
            let full = CommandSupport.resolve(f, cwd: io.cwd)
            if canonical {
                let resolved = (full as NSString).resolvingSymlinksInPath
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir)
                return CommandResult(stdout: resolved + "\n")
            } else {
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: full) {
                    return CommandResult(stdout: target + "\n")
                } else {
                    return CommandSupport.error(io, "\(f): No such file or directory")
                }
            }
        }
        return CommandResult()
    }
}

/// `mktemp` — create a temporary file or directory from a template.
struct MktempCommand: TermXCommand {
    static let name = "mktemp"

    static func run(_ io: CommandIO) -> CommandResult {
        var dir = false
        var useTemporaryDirectory = false
        var template: String?
        var i = 1
        var rest = false
        while i < io.argv.count {
            let a = io.argv[i]
            if !rest && a == "--" { rest = true }
            else if !rest && a == "-d" { dir = true }
            else if !rest && a == "-t" { useTemporaryDirectory = true }
            else { template = a }
            i += 1
        }
        var tpl = template ?? "tmp.XXXXXX"
        if useTemporaryDirectory || template == nil {
            let tempRoot = io.environment["TMPDIR"] ?? NSTemporaryDirectory()
            if !tpl.hasSuffix("XXXXXX") { tpl += ".XXXXXX" }
            tpl = (tempRoot as NSString).appendingPathComponent(tpl)
        } else if !tpl.hasPrefix("/") {
            tpl = (io.cwd as NSString).appendingPathComponent(tpl)
        }
        guard let result = makeTemp(template: tpl, isDir: dir) else {
            return CommandSupport.error(io, "failed to create \(dir ? "directory" : "file")")
        }
        return CommandResult(stdout: result + "\n")
    }

    private static func makeTemp(template: String, isDir: Bool) -> String? {
        guard template.hasSuffix("XXXXXX") else { return nil }
        var buffer = Array(template.utf8CString)
        return buffer.withUnsafeMutableBufferPointer { chars in
            guard let base = chars.baseAddress else { return nil }
            if isDir {
                guard mkdtemp(base) != nil else { return nil }
            } else {
                let fd = mkstemp(base)
                guard fd >= 0 else { return nil }
                _ = close(fd)
            }
            return String(cString: base)
        }
    }
}
