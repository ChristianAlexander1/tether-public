import Foundation

public enum DateCommand: TetherCommand {
    public static let name = "date"

    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name)
        var utc = false
        var seconds: TimeInterval?
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--" { args.remove(at: index); break }
            if argument == "-u" || argument == "--utc" {
                utc = true
                args.remove(at: index)
            } else if argument == "-r" {
                guard index + 1 < args.count, let value = TimeInterval(args[index + 1]), value.isFinite else {
                    return CommandSupport.error(name, "-r requires a finite epoch value", usage: true)
                }
                seconds = value
                args.removeSubrange(index...(index + 1))
            } else {
                index += 1
            }
        }
        guard args.count <= 1, args.first == nil || args.first!.hasPrefix("+") else {
            return CommandSupport.error(name, "invalid date", usage: true)
        }

        let date = Date(timeIntervalSince1970: seconds ?? Date().timeIntervalSince1970)
        let timeZone = utc ? TimeZone(secondsFromGMT: 0)! : (io.environment["TZ"].flatMap(TimeZone.init(identifier:)) ?? TimeZone.current)
        if let format = args.first {
            return CommandResult(stdout: render(String(format.dropFirst()), date: date, timeZone: timeZone) + "\n")
        }

        let formatter = makeFormatter("EEE MMM dd HH:mm:ss z yyyy", timeZone: timeZone)
        return CommandResult(stdout: formatter.string(from: date) + "\n")
    }

    private static func render(_ format: String, date: Date, timeZone: TimeZone) -> String {
        let characters = Array(format)
        var output = ""
        var index = 0
        let calendar = Calendar(identifier: .gregorian)
        while index < characters.count {
            guard characters[index] == "%", index + 1 < characters.count else {
                output.append(characters[index]); index += 1; continue
            }
            index += 1
            let directive = characters[index]
            index += 1
            let pattern: String?
            switch directive {
            case "%": output.append("%"); continue
            case "n": output.append("\n"); continue
            case "t": output.append("\t"); continue
            case "s": output += String(Int64(date.timeIntervalSince1970)); continue
            case "w":
                var adjusted = calendar; adjusted.timeZone = timeZone
                output += String(adjusted.component(.weekday, from: date) - 1); continue
            case "u":
                var adjusted = calendar; adjusted.timeZone = timeZone
                let weekday = adjusted.component(.weekday, from: date)
                output += String(weekday == 1 ? 7 : weekday - 1); continue
            case "Y": pattern = "yyyy"
            case "y": pattern = "yy"
            case "m": pattern = "MM"
            case "d": pattern = "dd"
            case "e": pattern = " d"
            case "H": pattern = "HH"
            case "I": pattern = "hh"
            case "M": pattern = "mm"
            case "S": pattern = "ss"
            case "z": pattern = "Z"
            case "Z": pattern = "z"
            case "a": pattern = "EEE"
            case "A": pattern = "EEEE"
            case "b", "h": pattern = "MMM"
            case "B": pattern = "MMMM"
            case "j": pattern = "DDD"
            case "p": pattern = "a"
            case "R": pattern = "HH:mm"
            case "T": pattern = "HH:mm:ss"
            case "F": pattern = "yyyy-MM-dd"
            case "D": pattern = "MM/dd/yy"
            case "c": pattern = "EEE MMM dd HH:mm:ss yyyy"
            default: pattern = nil
            }
            if let pattern { output += makeFormatter(pattern, timeZone: timeZone).string(from: date) }
            else { output += "%" + String(directive) }
        }
        return output
    }

    private static func makeFormatter(_ pattern: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter
    }
}
