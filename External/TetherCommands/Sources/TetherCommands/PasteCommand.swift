import Foundation
public enum PasteCommand: TetherCommand {
    public static let name = "paste"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), serial = false, delimiters = [Character("\t")]
        var files: [String] = [], i = 0
        while i < args.count {
            if args[i] == "-s" { serial = true; i += 1 }
            else if args[i] == "-d", i + 1 < args.count { delimiters = Array(args[i + 1]); if delimiters.isEmpty { delimiters = ["\t"] }; i += 2 }
            else if args[i].hasPrefix("-") && args[i] != "-" { return CommandSupport.error(name, "invalid option", usage: true) }
            else { files.append(args[i]); i += 1 }
        }
        if files.isEmpty { files = ["-"] }
        do {
            let all = try files.map { CommandSupport.lines(try CommandSupport.read($0, io: io)) }
            var output: [String] = []
            if serial {
                for lines in all { output.append(lines.enumerated().map { $0.offset == 0 ? $0.element : String(delimiters[($0.offset - 1) % delimiters.count]) + $0.element }.joined()) }
            } else {
                let maximumRows = all.map { $0.count }.max() ?? 0
                for row in 0..<maximumRows {
                    var values: [String] = []
                    for lines in all { values.append(row < lines.count ? lines[row] : "") }
                    var joined = ""
                    for (column, value) in values.enumerated() {
                        if column > 0 { joined.append(delimiters[(column - 1) % delimiters.count]) }
                        joined += value
                    }
                    output.append(joined)
                }
            }
            return CommandResult(stdout: output.isEmpty ? "" : output.joined(separator: "\n") + "\n")
        } catch { return CommandSupport.error(name, error.localizedDescription) }
    }
}
