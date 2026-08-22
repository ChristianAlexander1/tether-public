import Foundation

// A group of simple, low-risk line/character/text commands, one type per command.
// Each is a pure function over CommandIO per the design contract (no file operands
// => read stdin; `-` means stdin; errors to stderr; exit codes 1/2).

struct TacCommand: TermXCommand {
    static let name = "tac"
    static func run(_ io: CommandIO) -> CommandResult {
        let (input, err) = CommandSupport.readInput(io, operand: fileOperand(io))
        if let err = err { return CommandSupport.error(io, err) }
        let lines = CommandSupport.lines(input)
        return CommandResult(stdout: CommandSupport.joined(lines.reversed()))
    }
    private static func fileOperand(_ io: CommandIO) -> String? { io.argv.dropFirst().first }
}

struct RevCommand: TermXCommand {
    static let name = "rev"
    static func run(_ io: CommandIO) -> CommandResult {
        let (input, err) = CommandSupport.readInput(io, operand: fileOperand(io))
        if let err = err { return CommandSupport.error(io, err) }
        let lines = CommandSupport.lines(input)
        return CommandResult(stdout: CommandSupport.joined(lines.map { String($0.reversed()) }))
    }
    private static func fileOperand(_ io: CommandIO) -> String? { io.argv.dropFirst().first }
}

struct NlCommand: TermXCommand {
    static let name = "nl"
    static func run(_ io: CommandIO) -> CommandResult {
        var num = 1
        var out = ""
        for line in CommandSupport.lines(io.stdin) {
            // Avoid "%@" (needs NSString on all platforms); build the number
            // prefix separately.
            out += String(format: "%6d\t", num) + line + "\n"
            num += 1
        }
        return CommandResult(stdout: out)
    }
}

struct PasteCommand: TermXCommand {
    static let name = "paste"
    static func run(_ io: CommandIO) -> CommandResult {
        let files = Array(io.argv.dropFirst()).filter { $0 != "-" }
        if files.isEmpty {
            // side-by-side of stdin is a single column.
            return CommandResult(stdout: CommandSupport.joined(CommandSupport.lines(io.stdin)))
        }
        var lists: [[String]] = []
        for f in files {
            lists.append(CommandSupport.lines(CommandSupport.readTextFile(f, cwd: io.cwd) ?? ""))
        }
        let count = lists.map { $0.count }.max() ?? 0
        var out = ""
        for i in 0..<count {
            var line = ""
            for (idx, list) in lists.enumerated() {
                if idx > 0 { line += "\t" }
                line += i < list.count ? list[i] : ""
            }
            out += line + "\n"
        }
        return CommandResult(stdout: out)
    }
}

struct FoldCommand: TermXCommand {
    static let name = "fold"
    static func run(_ io: CommandIO) -> CommandResult {
        var width = 80
        for a in io.argv.dropFirst() {
            if a.hasPrefix("-w") { width = Int(a.dropFirst(2)) ?? 80 }
            else if let w = Int(a) { width = w }
        }
        let (input, err) = CommandSupport.readInput(io, operand: nil)
        if let err = err { return CommandSupport.error(io, err) }
        var out = ""
        for line in CommandSupport.lines(input) {
            var count = 0
            for c in line {
                out.append(c)
                count += 1
                if count == width { out += "\n"; count = 0 }
            }
            out += "\n"
        }
        return CommandResult(stdout: out)
    }
}

struct ExpandCommand: TermXCommand {
    static let name = "expand"
    static func run(_ io: CommandIO) -> CommandResult {
        var tab = 8
        for a in io.argv.dropFirst() {
            if a.hasPrefix("-t") { tab = Int(a.dropFirst(2)) ?? 8 }
        }
        let (input, err) = CommandSupport.readInput(io, operand: nil)
        if let err = err { return CommandSupport.error(io, err) }
        var out = ""
        for line in CommandSupport.lines(input) {
            var col = 0
            for c in line {
                if c == "\t" {
                    let spaces = tab - (col % tab)
                    out += String(repeating: " ", count: spaces)
                    col += spaces
                } else {
                    out.append(c)
                    col += 1
                }
            }
            out += "\n"
        }
        return CommandResult(stdout: out)
    }
}

struct UnexpandCommand: TermXCommand {
    static let name = "unexpand"
    static func run(_ io: CommandIO) -> CommandResult {
        var tab = 8
        for a in io.argv.dropFirst() {
            if a.hasPrefix("-t") { tab = Int(a.dropFirst(2)) ?? 8 }
        }
        let (input, err) = CommandSupport.readInput(io, operand: nil)
        if let err = err { return CommandSupport.error(io, err) }
        var out = ""
        for line in CommandSupport.lines(input) {
            var col = 0
            var outLine = ""
            var spaceRun = 0
            for c in line {
                if c == " " {
                    spaceRun += 1
                } else {
                    // flush blanks
                    while spaceRun >= tab {
                        outLine += "\t"
                        spaceRun -= tab
                    }
                    outLine += String(repeating: " ", count: spaceRun)
                    outLine.append(c)
                    spaceRun = 0
                    col += 1
                }
            }
            while spaceRun >= tab { outLine += "\t"; spaceRun -= tab }
            outLine += String(repeating: " ", count: spaceRun)
            out += outLine + "\n"
        }
        return CommandResult(stdout: out)
    }
}

struct PrintenvCommand: TermXCommand {
    static let name = "printenv"
    static func run(_ io: CommandIO) -> CommandResult {
        let want = io.argv.dropFirst().first
        if let want = want {
            if let v = io.environment[want] { return CommandResult(stdout: v + "\n") }
            return CommandResult(exitCode: 1)
        }
        var out = ""
        for (k, v) in io.environment.sorted(by: { $0.key < $1.key }) {
            out += "\(k)=\(v)\n"
        }
        return CommandResult(stdout: out)
    }
}

struct IdCommand: TermXCommand {
    static let name = "id"
    static func run(_ io: CommandIO) -> CommandResult {
        // The app provides no passwd/group database, and retrieving a real uid
        // requires importing platform-specific C functions, which we must not do.
        // Report credible default values; the app can override via environment.
        let user = io.environment["USER"] ?? "user"
        let uid = io.environment["UID"] ?? "0"
        let gid = io.environment["GID"] ?? "0"
        let groups = io.environment["GROUPS"] ?? gid
        return CommandResult(stdout: "uid=\(uid)(\(user)) gid=\(gid) groups=\(groups)\n")
    }
}
