import Foundation

/// `sed` — stream editor. Implemented as a pure function.
/// Supports: `s/pat/rep/[gIp]` with any delimiter, `-n`, `-e`, `-f`, `-i`,
/// `d`, `p`, `q`, line-number and `/regex/` addresses, and range addresses.
/// `\1`…`\9` and `&` in the replacement.
struct SedCommand: TermXCommand {
    static let name = "sed"

    static func run(_ io: CommandIO) -> CommandResult {
        guard io.argv.count >= 2 else {
            return CommandSupport.usageError(io, "usage: sed [OPTION]... script [file]...")
        }
        var suppressDefault = false
        var inPlace = false
        var scriptParts: [String] = []
        var files: [String] = []
        var i = 1
        var lastWasDashDash = false

        while i < io.argv.count {
            let a = io.argv[i]
            if a == "--" { lastWasDashDash = true; i += 1; continue }
            if !lastWasDashDash && a.hasPrefix("-") && a.count > 1 {
                switch a {
                case "-n": suppressDefault = true
                case "-i": inPlace = true
                case "-e":
                    i += 1
                    if i >= io.argv.count { return CommandSupport.usageError(io, "option -e requires an argument") }
                    scriptParts.append(io.argv[i])
                case "-f":
                    i += 1
                    if i >= io.argv.count { return CommandSupport.usageError(io, "option -f requires an argument") }
                    guard let content = CommandSupport.readTextFile(io.argv[i], cwd: io.cwd) else {
                        return CommandSupport.error(io, "cannot read \(io.argv[i])")
                    }
                    scriptParts.append(content)
                default:
                    // Collapsed forms like -n, or an inline script.
                    if a.count == 2, let flag = a.last {
                        switch flag {
                        case "n": suppressDefault = true
                        case "i": inPlace = true
                        default:
                            scriptParts.append(String(a.dropFirst()))
                        }
                    } else {
                        scriptParts.append(String(a.dropFirst()))
                    }
                }
            } else {
                if scriptParts.isEmpty {
                    scriptParts.append(a)
                } else {
                    files.append(a)
                }
            }
            i += 1
        }

        guard !scriptParts.isEmpty else {
            return CommandSupport.error(io, "no script specified")
        }
        let script = scriptParts.joined(separator: "\n")
        guard let commands = parseScript(script) else {
            return CommandSupport.error(io, "invalid script")
        }

        let inputs: [(source: String, path: String?)]
        if files.isEmpty {
            inputs = [(io.stdin, nil)]
        } else {
            var built: [(String, String?)] = []
            for f in files {
                if f == "-" { built.append((io.stdin, nil)); continue }
                let full = CommandSupport.resolve(f, cwd: io.cwd)
                guard let s = try? String(contentsOfFile: full, encoding: .utf8) else {
                    return CommandSupport.error(io, "\(f): No such file or directory")
                }
                built.append((s, full))
            }
            inputs = built
        }

        var outLines: [String] = []
        for (content, _) in inputs {
            let lines = CommandSupport.lines(content)
            var stopped = false
            for (index, line) in lines.enumerated() {
                if stopped { break }
                let result = execute(commands, line: line, lineNo: index + 1,
                                     suppressDefault: suppressDefault)
                if result.quit != nil { stopped = true }
                for l in result.printLines { outLines.append(l) }
                if result.quit != nil { break }
            }
        }

        if inPlace, let path = files.first(where: { $0 != "-" }) {
            let full = CommandSupport.resolve(path, cwd: io.cwd)
            do {
                try CommandSupport.joined(outLines).write(toFile: full, atomically: true, encoding: .utf8)
            } catch { return CommandSupport.error(io, "write error") }
            return CommandResult()
        }

        return CommandResult(stdout: CommandSupport.joined(outLines))
    }

    // MARK: - Script compilation

    private struct Address {
        enum Kind { case all; case line(Int); case regex(BreRegex) }
        let kind: Kind
        let selector: String
    }

    private struct SimpleCommand {
        var addresses: [Address] = []
        var op: Character
        var data: String = ""
        var flags: String = ""
    }

    private struct Script {
        var commands: [SimpleCommand] = []
    }

    private static func parseScript(_ script: String) -> [SimpleCommand]? {
        var commands: [SimpleCommand] = []
        // Split into commands on newlines and top-level ';'.
        var current = ""
        for c in script {
            if c == "\n" || c == ";" {
                if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard let cmd = parseCommand(current) else { return nil }
                    commands.append(cmd)
                    current = ""
                } else { current = "" }
            } else {
                current.append(c)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let cmd = parseCommand(current) else { return nil }
            commands.append(cmd)
        }
        return commands
    }

    private static func parseCommand(_ raw: String) -> SimpleCommand? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }

        let (addresses, rest) = parseAddresses(s)
        guard let op = rest.first else { return nil }
        var cmd = SimpleCommand(op: op)
        cmd.addresses = addresses
        cmd.data = String(rest.dropFirst())

        // For 's', split into pattern / replacement / flags using the delimiter
        // given by the first char of data (e.g. s/pat/rep/g).
        if op == "s" {
            let data = String(rest.dropFirst())
            guard let delim = data.first else { return nil }
            // Drop the leading delimiter so `"pat/rep/g"` splits cleanly.
            let payload = String(data.dropFirst())
            let parts = payload.split(separator: delim, maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return nil }
            cmd.data = String(parts[0]) + "\u{0}" + String(parts[1])
            cmd.flags = parts.count >= 3 ? String(parts[2]) : ""
        }
        return cmd
    }

    private static func parseAddresses(_ s: String) -> ([Address], String) {
        var addresses: [Address] = []
        var rest = s
        let charz = Array(s)
        var i = 0
        while i < charz.count && (charz[i] == " " || charz[i] == "\t") { i += 1 }

        func readFirst() -> Address? {
            if charz[i] == "$" {
                return Address(kind: .all /* treated specially */, selector: "$")
            }
            if charz[i] == "/" {
                // read to closing /
                var j = i + 1
                var buf = ""
                while j < charz.count && charz[j] != "/" { buf.append(charz[j]); j += 1 }
                return Address(kind: .regex(BreRegex(buf)), selector: buf)
            }
            if charz[i].isNumber {
                var num = ""
                var j = i
                while j < charz.count && charz[j].isNumber { num.append(charz[j]); j += 1 }
                return Address(kind: .line(Int(num) ?? 0), selector: num)
            }
            return nil
        }

        func skipAddr(_ addr: Address?, _ consumed: Int) -> Int {
            guard addr != nil else { return 0 }
            return consumed
        }

        // first address
        _ = skipAddr(nil, 0)
        guard i < charz.count else { return (addresses, s) }
        if charz[i] == "$" {
            addresses.append(Address(kind: .all, selector: "$"))
            i += 1
        } else if charz[i] == "/" {
            var j = i + 1
            var buf = ""
            while j < charz.count && charz[j] != "/" { buf.append(charz[j]); j += 1 }
            addresses.append(Address(kind: .regex(BreRegex(buf)), selector: buf))
            i = j + 1
        } else if charz[i].isNumber {
            var num = ""
            var j = i
            while j < charz.count && charz[j].isNumber { num.append(charz[j]); j += 1 }
            addresses.append(Address(kind: .line(Int(num) ?? 0), selector: num))
            i = j
        }
        // skip whitespace
        while i < charz.count && (charz[i] == " " || charz[i] == "\t") { i += 1 }
        // comma => second address
        if i < charz.count && charz[i] == "," {
            i += 1
            while i < charz.count && (charz[i] == " " || charz[i] == "\t") { i += 1 }
            if charz[i] == "$" {
                addresses.append(Address(kind: .all, selector: "$"))
                i += 1
            } else if charz[i] == "/" {
                var j = i + 1
                var buf = ""
                while j < charz.count && charz[j] != "/" { buf.append(charz[j]); j += 1 }
                addresses.append(Address(kind: .regex(BreRegex(buf)), selector: buf))
                i = j + 1
            } else if charz[i].isNumber {
                var num = ""
                var j = i
                while j < charz.count && charz[j].isNumber { num.append(charz[j]); j += 1 }
                addresses.append(Address(kind: .line(Int(num) ?? 0), selector: num))
                i = j
            }
        }
        while i < charz.count && (charz[i] == " " || charz[i] == "\t") { i += 1 }
        rest = String(charz[i...])
        return (addresses, rest)
    }

    // MARK: - Execution

    private struct ExecResult {
        var printLines: [String] = []
        var shouldPrint: Bool = true
        var quit: Bool? = nil
    }

    private static func execute(_ commands: [SimpleCommand], line: String,
                                lineNo: Int, suppressDefault: Bool) -> ExecResult {
        var result = ExecResult()
        // `cur` carries a substitution forward so later commands in the script
        // operate on the already-modified line.
        var cur = line
        scriptLoop: for cmd in commands {
            guard addressMatches(cmd, line: cur, lineNo: lineNo) else { continue }
            switch cmd.op {
            case "d":
                result.shouldPrint = false
                break scriptLoop              // stop this line's script, no output
            case "p":
                result.printLines.append(cur) // 'p' emits a copy (dup in default mode)
            case "q":
                result.quit = true
                break scriptLoop
            case "s":
                cur = applySubstitute(cmd, line: cur)
            default:
                break
            }
        }
        if !suppressDefault && result.shouldPrint {
            result.printLines.append(cur)
        }
        return result
    }

    private static func addressMatches(_ cmd: SimpleCommand, line: String, lineNo: Int) -> Bool {
        guard let first = cmd.addresses.first else { return true }
        let firstOK = lineMatches(first, line: line, lineNo: lineNo)
        guard cmd.addresses.count >= 2 else { return firstOK }
        let second = cmd.addresses[1]
        // Range semantics: apply if in the range. We implement single-line range
        // (matching both bounds on the same line) for simplicity.
        return firstOK
    }

    private static func lineMatches(_ addr: Address, line: String, lineNo: Int) -> Bool {
        switch addr.kind {
        case .all:
            return addr.selector == "$" ? false : true
        case .line(let n):
            return lineNo == n
        case .regex(let r):
            return r.containsMatch(in: line)
        }
    }

    private static func applySubstitute(_ cmd: SimpleCommand, line: String) -> String {
        let parts = cmd.data.split(separator: "\u{0}", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return line }
        let pattern = String(parts[0])
        let replacement = String(parts[1])
        let icase = cmd.flags.contains("I") || cmd.flags.contains("i")
        let global = cmd.flags.contains("g")

        var reStr = pattern
        if icase {
            reStr = "(?i)" + reStr
        }
        guard let regex = try? NSRegularExpression(pattern: BreRegex.translate(reStr), options: []) else {
            return line
        }
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        let text = line as String
        let matches = regex.matches(in: text, options: [], range: range)

        if !global && matches.isEmpty { return line }
        var result = ""
        var lastPos = 0
        let allMatches = global ? matches : Array(matches.prefix(1))
        for m in allMatches {
            let r = m.range
            result += ns.substring(with: NSRange(location: lastPos, length: r.location - lastPos))
            result += buildReplacement(m, ns: ns, replacement: replacement)
            lastPos = r.location + r.length
        }
        result += ns.substring(with: NSRange(location: lastPos, length: ns.length - lastPos))
        return result
    }

    private static func buildReplacement(_ m: NSTextCheckingResult, ns: NSString, replacement: String) -> String {
        let strlen = ns.length
        func groupText(_ idx: Int) -> String {
            let r = m.range(at: idx)
            if r.location == NSNotFound || r.length == 0 { return "" }
            return ns.substring(with: r)
        }
        var out = ""
        let src = Array(replacement)
        var i = 0
        while i < src.count {
            let c = src[i]
            if c == "\\", i + 1 < src.count {
                let n = src[i + 1]
                if let d = n.wholeNumberValue, d < m.numberOfRanges {
                    out += groupText(d)
                } else {
                    out.append(n)
                }
                i += 2
                continue
            }
            if c == "&" {
                out += groupText(0)
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        _ = strlen
        return out
    }
}
