import Foundation
public enum JoinCommand: TetherCommand {
    public static let name = "join"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), field1 = 1, field2 = 1, separator: Character?
        var files: [String] = [], i = 0
        while i < args.count {
            if ["-1", "-2", "-t"].contains(args[i]), i + 1 < args.count {
                if args[i] == "-1" { field1 = Int(args[i + 1]) ?? 0 }
                else if args[i] == "-2" { field2 = Int(args[i + 1]) ?? 0 }
                else { separator = args[i + 1].first }
                i += 2
            } else if args[i].hasPrefix("-") && args[i] != "-" { return CommandSupport.error(name, "invalid option", usage: true) }
            else { files.append(args[i]); i += 1 }
        }
        guard files.count == 2, field1 > 0, field2 > 0 else { return CommandSupport.error(name, "two files are required", usage: true) }
        do {
            func fields(_ line: String) -> [String] { separator.map { line.split(separator: $0, omittingEmptySubsequences: false).map(String.init) } ?? line.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
            let left = CommandSupport.lines(try CommandSupport.read(files[0], io: io)).map(fields)
            let right = CommandSupport.lines(try CommandSupport.read(files[1], io: io)).map(fields)
            let sep = separator.map(String.init) ?? " "
            var output: [String] = []
            for a in left where a.count >= field1 {
                for b in right where b.count >= field2 && a[field1 - 1] == b[field2 - 1] {
                    let line = [a[field1 - 1]] + a.enumerated().filter { $0.offset != field1 - 1 }.map(\.element) + b.enumerated().filter { $0.offset != field2 - 1 }.map(\.element)
                    output.append(line.joined(separator: sep))
                }
            }
            return CommandResult(stdout: output.isEmpty ? "" : output.joined(separator: "\n") + "\n")
        } catch { return CommandSupport.error(name, error.localizedDescription) }
    }
}
