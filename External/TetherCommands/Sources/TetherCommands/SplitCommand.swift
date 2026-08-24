import Foundation

public enum SplitCommand: TetherCommand {
    public static let name = "split"

    public static func run(_ io: CommandIO) -> CommandResult {
        let args = CommandSupport.args(io, command: name)
        var lineCount = 1000
        var byteCount: Int?
        var suffixLength = 2
        var numeric = false
        var operands: [String] = []
        var index = 0

        while index < args.count {
            let argument = args[index]
            if ["-l", "-b", "-a"].contains(argument) {
                guard index + 1 < args.count else { return CommandSupport.error(name, "\(argument) requires an argument", usage: true) }
                if argument == "-l" { lineCount = Int(args[index + 1]) ?? 0 }
                if argument == "-b" { byteCount = parseSize(args[index + 1]) }
                if argument == "-a" { suffixLength = Int(args[index + 1]) ?? 0 }
                index += 2
            } else if argument == "-d" {
                numeric = true; index += 1
            } else if argument == "--" {
                operands.append(contentsOf: args.dropFirst(index + 1)); break
            } else if argument.hasPrefix("-") && argument != "-" {
                return CommandSupport.error(name, "invalid option \(argument)", usage: true)
            } else {
                operands.append(argument); index += 1
            }
        }
        guard lineCount > 0, suffixLength > 0, byteCount != 0, operands.count <= 2 else {
            return CommandSupport.error(name, "invalid size or operands", usage: true)
        }

        do {
            let data = try CommandSupport.readData(operands.first, io: io)
            let prefix = operands.count == 2 ? operands[1] : "x"
            let chunks = byteCount.map { byteChunks(data, size: $0) } ?? lineChunks(data, count: lineCount)
            for (chunkIndex, chunk) in chunks.enumerated() {
                guard let suffix = suffix(for: chunkIndex, length: suffixLength, numeric: numeric) else {
                    return CommandSupport.error(name, "output file suffixes exhausted")
                }
                try CommandSupport.writeData(chunk, to: CommandSupport.path(prefix + suffix, cwd: io.cwd))
            }
            return CommandResult()
        } catch {
            return CommandSupport.error(name, error.localizedDescription)
        }
    }

    private static func byteChunks(_ data: Data, size: Int) -> [Data] {
        guard !data.isEmpty else { return [] }
        return stride(from: 0, to: data.count, by: size).map {
            data.subdata(in: $0..<min($0 + size, data.count))
        }
    }

    private static func lineChunks(_ data: Data, count: Int) -> [Data] {
        guard !data.isEmpty else { return [] }
        var chunks: [Data] = []
        var current = Data()
        var lines = 0
        for byte in data {
            current.append(byte)
            if byte == 10 {
                lines += 1
                if lines == count { chunks.append(current); current = Data(); lines = 0 }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func suffix(for index: Int, length: Int, numeric: Bool) -> String? {
        let radix = numeric ? 10 : 26
        var capacity = 1
        for _ in 0..<length {
            let (next, overflow) = capacity.multipliedReportingOverflow(by: radix)
            if overflow { capacity = Int.max; break }
            capacity = next
        }
        guard index < capacity else { return nil }
        if numeric { return String(format: "%0*d", length, index) }
        var value = index
        var characters = Array(repeating: Character("a"), count: length)
        for position in stride(from: length - 1, through: 0, by: -1) {
            characters[position] = Character(UnicodeScalar(97 + value % 26)!)
            value /= 26
        }
        return String(characters)
    }

    private static func parseSize(_ text: String) -> Int? {
        guard let last = text.last else { return nil }
        let multiplier: Int
        let number: String
        switch last {
        case "k", "K": multiplier = 1024; number = String(text.dropLast())
        case "m", "M": multiplier = 1024 * 1024; number = String(text.dropLast())
        case "g", "G": multiplier = 1024 * 1024 * 1024; number = String(text.dropLast())
        default: multiplier = 1; number = text
        }
        guard let value = Int(number), value > 0 else { return nil }
        let (result, overflow) = value.multipliedReportingOverflow(by: multiplier)
        return overflow ? nil : result
    }
}
