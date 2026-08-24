import Foundation

public enum SeqCommand: TetherCommand {
    public static let name = "seq"

    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name)
        var separator = "\n"
        var equalWidth = false
        var format: String?

        while let first = args.first {
            if first == "--" { args.removeFirst(); break }
            if first == "-w" { equalWidth = true; args.removeFirst(); continue }
            if first == "-s" || first == "-f" {
                guard args.count >= 2 else { return CommandSupport.error(name, "\(first) requires an argument", usage: true) }
                if first == "-s" { separator = args[1] } else { format = args[1] }
                args.removeFirst(2)
                continue
            }
            if first.hasPrefix("-"), Double(first) == nil {
                return CommandSupport.error(name, "invalid option \(first)", usage: true)
            }
            break
        }

        guard (1...3).contains(args.count), let last = Double(args.last!), last.isFinite else {
            return CommandSupport.error(name, "invalid floating point argument", usage: true)
        }
        let first = args.count == 1 ? 1 : (Double(args[0]) ?? .nan)
        let increment = args.count == 3 ? (Double(args[1]) ?? .nan) : 1
        guard first.isFinite, increment.isFinite, increment != 0 else {
            return CommandSupport.error(name, "invalid increment", usage: true)
        }

        var values: [Double] = []
        var value = first
        let tolerance = abs(increment) * 1e-12
        while increment > 0 ? value <= last + tolerance : value >= last - tolerance {
            values.append(value)
            let next = value + increment
            guard next != value else { return CommandSupport.error(name, "increment is too small") }
            value = next
        }

        let integral = args.allSatisfy { !$0.contains(".") && !$0.lowercased().contains("e") }
        var strings = values.map { number -> String in
            if let format { return String(format: format, number) }
            if integral, number >= Double(Int64.min), number < Double(Int64.max) {
                return String(Int64(number))
            }
            return integral ? String(format: "%.0f", number) : String(format: "%.12g", number)
        }
        if equalWidth, let width = strings.map(\.count).max() {
            strings = strings.map { padWithZeroes($0, width: width) }
        }
        return CommandResult(stdout: strings.isEmpty ? "" : strings.joined(separator: separator) + "\n")
    }

    private static func padWithZeroes(_ value: String, width: Int) -> String {
        guard value.count < width else { return value }
        if value.hasPrefix("-") {
            return "-" + String(repeating: "0", count: width - value.count) + value.dropFirst()
        }
        return String(repeating: "0", count: width - value.count) + value
    }
}
