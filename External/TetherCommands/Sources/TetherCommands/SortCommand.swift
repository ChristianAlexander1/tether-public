import Foundation
public enum SortCommand: TetherCommand {
    public static let name = "sort"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), reverse = false, numeric = false, unique = false, fold = false
        var files: [String] = []
        for a in args {
            if a.hasPrefix("-") && a != "-" {
                for flag in a.dropFirst() {
                    switch flag { case "r": reverse = true; case "n": numeric = true; case "u": unique = true; case "f": fold = true; default: return CommandSupport.error(name, "invalid option -- \(flag)", usage: true) }
                }
            } else { files.append(a) }
        }
        if files.isEmpty { files = ["-"] }
        var input = ""
        do { for f in files { input += try CommandSupport.read(f, io: io) } }
        catch { return CommandSupport.error(name, error.localizedDescription) }
        var lines = CommandSupport.lines(input)
        lines.sort {
            let a = fold ? $0.lowercased() : $0, b = fold ? $1.lowercased() : $1
            if numeric { return (Double(a.trimmingCharacters(in: .whitespaces)) ?? 0) < (Double(b.trimmingCharacters(in: .whitespaces)) ?? 0) }
            return a < b
        }
        if reverse { lines.reverse() }
        if unique {
            var seen: Set<String> = []
            lines = lines.filter { seen.insert(fold ? $0.lowercased() : $0).inserted }
        }
        return CommandResult(stdout: lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
    }
}
