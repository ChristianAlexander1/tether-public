import Foundation
public enum CutCommand: TetherCommand {
    public static let name = "cut"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), delimiter = "\t", spec: String?, characters = false, onlyDelimited = false
        var files: [String] = [], i = 0
        while i < args.count {
            let a = args[i]
            if a == "-d" || a == "-f" || a == "-c" {
                guard i + 1 < args.count else { return CommandSupport.error(name, "option requires an argument", usage: true) }
                if a == "-d" { delimiter = args[i + 1] } else { spec = args[i + 1]; characters = a == "-c" }
                i += 2
            } else if a.hasPrefix("-d") { delimiter = String(a.dropFirst(2)); i += 1
            } else if a.hasPrefix("-f") { spec = String(a.dropFirst(2)); i += 1
            } else if a.hasPrefix("-c") { spec = String(a.dropFirst(2)); characters = true; i += 1
            } else if a == "-s" { onlyDelimited = true; i += 1
            } else if a.hasPrefix("-") && a != "-" { return CommandSupport.error(name, "invalid option \(a)", usage: true)
            } else { files.append(a); i += 1 }
        }
        guard delimiter.count == 1, let spec, let selected = parseList(spec) else { return CommandSupport.error(name, "invalid field/character list", usage: true) }
        if files.isEmpty { files = ["-"] }
        var output = "", errors = ""
        for file in files {
            do {
                let input = try CommandSupport.read(file, io: io)
                let trailing = input.hasSuffix("\n")
                let transformedLines = CommandSupport.lines(input).compactMap { line -> String? in
                    if characters {
                        let chars = Array(line)
                        return chars.enumerated().filter { isSelected($0.offset + 1, ranges: selected) }.map { String($0.element) }.joined()
                    }
                    if !line.contains(delimiter) { return onlyDelimited ? nil : line }
                    let fields = line.components(separatedBy: delimiter)
                    return fields.enumerated().filter { isSelected($0.offset + 1, ranges: selected) }.map(\.element).joined(separator: delimiter)
                }
                if !transformedLines.isEmpty {
                    output += transformedLines.joined(separator: "\n")
                    if trailing { output += "\n" }
                }
            } catch { errors += "cut: \(file): \(error.localizedDescription)\n" }
        }
        return CommandResult(stdout: output, stderr: errors, exitCode: errors.isEmpty ? 0 : 1)
    }
    private static func parseList(_ text: String) -> [ClosedRange<Int>]? {
        var result: [ClosedRange<Int>] = []
        for part in text.split(separator: ",") {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
            if bounds.count == 1, let number = Int(bounds[0]), number > 0 {
                result.append(number...number)
            } else if bounds.count == 2, !(bounds[0].isEmpty && bounds[1].isEmpty) {
                let low = bounds[0].isEmpty ? 1 : Int(bounds[0])
                let high = bounds[1].isEmpty ? Int.max : Int(bounds[1])
                guard let low, let high, low > 0, high >= low else { return nil }
                result.append(low...high)
            } else {
                return nil
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func isSelected(_ index: Int, ranges: [ClosedRange<Int>]) -> Bool {
        ranges.contains { $0.contains(index) }
    }
}
