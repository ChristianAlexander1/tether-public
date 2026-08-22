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
        var template: String?
        var i = 1
        var rest = false
        while i < io.argv.count {
            let a = io.argv[i]
            if !rest && a == "--" { rest = true }
            else if !rest && (a == "-d") { dir = true }
            else if !rest && a.hasPrefix("-t") { dir = false }
            else { template = a }
            i += 1
        }
        let tpl = template ?? "/tmp/tmp.XXXXXX"
        guard let result = makeTemp(template: tpl, isDir: dir) else {
            return CommandSupport.error(io, "failed to create \(dir ? "directory" : "file")")
        }
        return CommandResult(stdout: result + "\n")
    }

    private static func makeTemp(template: String, isDir: Bool) -> String? {
        var tpl = template
        if tpl.hasPrefix("/tmp/") || tpl.contains("/") {
            // keep as is
        } else if tpl.hasPrefix("tmp.XXXXXX") {
            tpl = "/tmp/" + tpl
        }
        guard let range = tpl.range(of: "XXXXXX") else { return nil }
        for _ in 0..<100 {
            var hex = ""
            for _ in 0..<6 {
                hex += String(UInt32.random(in: 0..<16), radix: 16)
            }
            let name = tpl.replacingCharacters(in: range, with: hex)
            if isDir {
                do {
                    try FileManager.default.createDirectory(atPath: name, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                    return name
                } catch { continue }
            } else {
                if FileManager.default.createFile(atPath: name, contents: nil, attributes: nil) {
                    return name
                }
                continue
            }
        }
        return nil
    }
}
