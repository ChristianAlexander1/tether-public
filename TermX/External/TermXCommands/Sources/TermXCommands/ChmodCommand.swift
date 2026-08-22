import Foundation

/// `chmod` — change file mode bits. Supports octal (`755`) and symbolic
/// (`u+x`, `go-w`, `a=r`, `u=rwx,go=r`) mode, plus `-R` for recursion.
struct ChmodCommand: TermXCommand {
    static let name = "chmod"

    static func run(_ io: CommandIO) -> CommandResult {
        var recursive = false
        var i = 1
        var mode: String?
        var paths: [String] = []
        var rest = false
        while i < io.argv.count {
            let a = io.argv[i]
            if !rest && a == "--" { rest = true; i += 1; continue }
            if !rest && (a == "-R" || a == "-r") {
                recursive = true
            } else if !rest && a.hasPrefix("-") && a.count > 1 {
                mode = String(a.dropFirst())
            } else {
                mode = a
                i += 1
                while i < io.argv.count { paths.append(io.argv[i]); i += 1 }
                break
            }
            i += 1
        }
        guard let mode = mode, !paths.isEmpty else {
            return CommandSupport.usageError(io, "usage: chmod [-R] mode file...")
        }

        for p in paths {
            let full = CommandSupport.resolve(p, cwd: io.cwd)
            do {
                // Recursion over directory contents.
                var targets: [String] = [full]
                if recursive {
                    targets = allFiles(under: full)
                }
                for t in targets {
                    let attrs = try FileManager.default.attributesOfItem(atPath: t)
                    let current = (attrs[.posixPermissions] as? Int) ?? 0o644
                    let newPerms = try applyMode(mode, base: current)
                    try FileManager.default.setAttributes([.posixPermissions: newPerms], ofItemAtPath: t)
                }
            } catch let e as NSError {
                _ = e
                return CommandSupport.error(io, "\(p): cannot change mode")
            }
        }
        return CommandResult()
    }

    fileprivate static func allFiles(under path: String) -> [String] {
        var result = [path]
        if let items = try? FileManager.default.contentsOfDirectory(atPath: path) {
            for item in items {
                let full = path + "/" + item
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: full, isDirectory: &isDir) {
                    if isDir.boolValue { result += allFiles(under: full) }
                    else { result.append(full) }
                }
            }
        }
        return result
    }

    /// Apply a mode spec to `base` permissions, returning the new bits.
    fileprivate static func applyMode(_ mode: String, base: Int) throws -> Int {
        let m = mode.trimmingCharacters(in: .whitespaces)
        if let oct = Int(m, radix: 8), m.allSatisfy({ $0 >= "0" && $0 <= "7" }), !m.isEmpty {
            return oct
        }
        var perms = base
        for part in m.split(separator: ",", omittingEmptySubsequences: false) {
            guard let result = applySymbolic(String(part), base: perms) else {
                throw NSError(domain: "chmod", code: 1)
            }
            perms = result
        }
        return perms
    }

    private static func applySymbolic(_ sym: String, base: Int) -> Int? {
        let chars = Array(sym)
        var whoSelect = 0
        var idx = 0
        while idx < chars.count && "ugoa".contains(chars[idx]) {
            switch chars[idx] {
            case "u": whoSelect |= 0o700
            case "g": whoSelect |= 0o070
            case "o": whoSelect |= 0o007
            case "a": whoSelect |= 0o777
            default: break
            }
            idx += 1
        }
        if whoSelect == 0 { whoSelect = 0o777 }   // default 'a'
        guard idx < chars.count else { return nil }
        let op = chars[idx]
        idx += 1
        guard idx <= chars.count else { return nil }
        let permsChars = chars[idx...]

        var addBits = 0
        for c in permsChars {
            switch c {
            case "r": addBits |= 0o444
            case "w": addBits |= 0o222
            case "x": addBits |= 0o111
            default: break
            }
        }
        switch op {
        case "+": return base | (whoSelect & addBits)
        case "-": return base & ~(whoSelect & addBits) & 0o7777
        case "=": return (base & ~(whoSelect & 0o777) & 0o7777) | (whoSelect & addBits)
        default: return nil
        }
    }
}
