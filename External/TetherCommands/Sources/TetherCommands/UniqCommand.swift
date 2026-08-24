import Foundation
public enum UniqCommand: TetherCommand {
    public static let name = "uniq"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), count = false, repeated = false, unique = false, insensitive = false
        while let a = args.first, a.hasPrefix("-") && a != "-" {
            for flag in a.dropFirst() {
                switch flag { case "c": count = true; case "d": repeated = true; case "u": unique = true; case "i": insensitive = true; default: return CommandSupport.error(name, "invalid option -- \(flag)", usage: true) }
            }
            args.removeFirst()
        }
        guard args.count <= 2 else { return CommandSupport.error(name, "extra operand", usage: true) }
        do {
            let input = try CommandSupport.read(args.first, io: io)
            var groups: [(String, Int)] = []
            for line in CommandSupport.lines(input) {
                let key = insensitive ? line.lowercased() : line
                if let last = groups.last, (insensitive ? last.0.lowercased() : last.0) == key { groups[groups.count - 1].1 += 1 }
                else { groups.append((line, 1)) }
            }
            let lines = groups.compactMap { pair -> String? in
                if repeated && pair.1 == 1 { return nil }
                if unique && pair.1 != 1 { return nil }
                return count ? String(format: "%7d %@", pair.1, pair.0) : pair.0
            }
            let output = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            if args.count == 2 { try CommandSupport.write(output, to: CommandSupport.path(args[1], cwd: io.cwd)); return CommandResult() }
            return CommandResult(stdout: output)
        } catch { return CommandSupport.error(name, error.localizedDescription) }
    }
}
