import Foundation

public enum OdCommand: TetherCommand {
    public static let name = "od"

    public static func run(_ io: CommandIO) -> CommandResult {
        let args = CommandSupport.args(io, command: name)
        var mode = "o"
        var suppressAddress = false
        var files: [String] = []
        var index = 0

        while index < args.count {
            let argument = args[index]
            switch argument {
            case "--": files.append(contentsOf: args.dropFirst(index + 1)); index = args.count
            case "-An": suppressAddress = true; index += 1
            case "-A":
                guard index + 1 < args.count else { return CommandSupport.error(name, "-A requires an argument", usage: true) }
                suppressAddress = args[index + 1] == "n"; index += 2
            case "-c": mode = "c"; index += 1
            case "-x": mode = "x"; index += 1
            case "-b": mode = "o"; index += 1
            case "-t":
                guard index + 1 < args.count else { return CommandSupport.error(name, "-t requires a type", usage: true) }
                let type = args[index + 1]
                if type.hasPrefix("x") { mode = "x" }
                else if type == "c" { mode = "c" }
                else if type.hasPrefix("o") { mode = "o" }
                else { return CommandSupport.error(name, "unsupported output type '\(type)'", usage: true) }
                index += 2
            default:
                if argument.hasPrefix("-") && argument != "-" { return CommandSupport.error(name, "invalid option \(argument)", usage: true) }
                files.append(argument); index += 1
            }
        }
        if files.isEmpty { files = ["-"] }

        do {
            var data = Data()
            for file in files { data.append(try CommandSupport.readData(file, io: io)) }
            let bytes = [UInt8](data)
            var lines: [String] = []
            for offset in stride(from: 0, to: bytes.count, by: 16) {
                let chunk = bytes[offset..<min(offset + 16, bytes.count)]
                let values: String
                switch mode {
                case "c": values = chunk.map(characterDescription).joined(separator: " ")
                case "x": values = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
                default: values = chunk.map { String(format: "%03o", $0) }.joined(separator: " ")
                }
                lines.append((suppressAddress ? "" : String(format: "%07o ", offset)) + values)
            }
            if !suppressAddress { lines.append(String(format: "%07o", bytes.count)) }
            return CommandResult(stdout: lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
        } catch {
            return CommandSupport.error(name, error.localizedDescription)
        }
    }

    private static func characterDescription(_ byte: UInt8) -> String {
        switch byte {
        case 0: return "\\0"
        case 7: return "\\a"
        case 8: return "\\b"
        case 9: return "\\t"
        case 10: return "\\n"
        case 12: return "\\f"
        case 13: return "\\r"
        case 32..<127: return "  " + String(UnicodeScalar(byte))
        default: return String(format: "%03o", byte)
        }
    }
}
