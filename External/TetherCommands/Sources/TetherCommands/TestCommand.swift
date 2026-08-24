import Foundation
public enum TestCommand: TetherCommand {
    public static let name = "test"
    public static func run(_ io: CommandIO) -> CommandResult {
        let bracketInvocation = io.argv.first.map { URL(fileURLWithPath: $0).lastPathComponent == "[" } ?? false
        var args = bracketInvocation ? Array(io.argv.dropFirst()) : CommandSupport.args(io, command: name)
        if bracketInvocation {
            guard args.last == "]" else { return CommandSupport.error("[", "missing ]", usage: true) }
            args.removeLast()
        }
        do { return CommandResult(exitCode: try evaluate(args, io: io) ? 0 : 1) }
        catch { return CommandSupport.error(name, error.localizedDescription, usage: true) }
    }
    private struct SyntaxError: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func evaluate(_ args: [String], io: CommandIO) throws -> Bool {
        if args.isEmpty { return false }
        if args[0] == "!" { return try !evaluate(Array(args.dropFirst()), io: io) }
        if args.first == "(", args.last == ")", enclosesWholeExpression(args) {
            return try evaluate(Array(args.dropFirst().dropLast()), io: io)
        }
        if let index = topLevelOperator("-o", in: args) {
            return try evaluate(Array(args[..<index]), io: io) || evaluate(Array(args[(index + 1)...]), io: io)
        }
        if let index = topLevelOperator("-a", in: args), index > 0 {
            return try evaluate(Array(args[..<index]), io: io) && evaluate(Array(args[(index + 1)...]), io: io)
        }
        if args.count == 1 { return !args[0].isEmpty }
        if args.count == 2 {
            switch args[0] {
            case "-n": return !args[1].isEmpty
            case "-z": return args[1].isEmpty
            case "-a", "-e": return FileManager.default.fileExists(atPath: CommandSupport.path(args[1], cwd: io.cwd))
            case "-f": var d: ObjCBool = false; let exists = FileManager.default.fileExists(atPath: CommandSupport.path(args[1], cwd: io.cwd), isDirectory: &d); return exists && !d.boolValue
            case "-d": var d: ObjCBool = false; return FileManager.default.fileExists(atPath: CommandSupport.path(args[1], cwd: io.cwd), isDirectory: &d) && d.boolValue
            case "-L", "-h": return (try? FileManager.default.destinationOfSymbolicLink(atPath: CommandSupport.path(args[1], cwd: io.cwd))) != nil
            case "-b": return fileType(args[1], io: io) == .typeBlockSpecial
            case "-c": return fileType(args[1], io: io) == .typeCharacterSpecial
            case "-p": return fileType(args[1], io: io)?.rawValue == "NSFileTypeFIFO"
            case "-S": return fileType(args[1], io: io) == .typeSocket
            case "-r": return FileManager.default.isReadableFile(atPath: CommandSupport.path(args[1], cwd: io.cwd))
            case "-w": return FileManager.default.isWritableFile(atPath: CommandSupport.path(args[1], cwd: io.cwd))
            case "-x": return FileManager.default.isExecutableFile(atPath: CommandSupport.path(args[1], cwd: io.cwd))
            case "-s": let a = try? FileManager.default.attributesOfItem(atPath: CommandSupport.path(args[1], cwd: io.cwd)); return (a?[.size] as? NSNumber)?.intValue ?? 0 > 0
            default: throw SyntaxError(message: "unknown unary operator")
            }
        }
        if args.count == 3 {
            switch args[1] {
            case "=", "==": return args[0] == args[2]
            case "!=": return args[0] != args[2]
            case "<": return args[0] < args[2]
            case ">": return args[0] > args[2]
            case "-eq", "-ne", "-lt", "-le", "-gt", "-ge":
                guard let a = Int64(args[0]), let b = Int64(args[2]) else { throw SyntaxError(message: "integer expression expected") }
                switch args[1] { case "-eq": return a == b; case "-ne": return a != b; case "-lt": return a < b; case "-le": return a <= b; case "-gt": return a > b; default: return a >= b }
            case "-nt", "-ot":
                let aa = try? FileManager.default.attributesOfItem(atPath: CommandSupport.path(args[0], cwd: io.cwd)); let bb = try? FileManager.default.attributesOfItem(atPath: CommandSupport.path(args[2], cwd: io.cwd))
                guard let ad = aa?[.modificationDate] as? Date, let bd = bb?[.modificationDate] as? Date else { return false }; return args[1] == "-nt" ? ad > bd : ad < bd
            case "-ef":
                let aa = try? FileManager.default.attributesOfItem(atPath: CommandSupport.path(args[0], cwd: io.cwd))
                let bb = try? FileManager.default.attributesOfItem(atPath: CommandSupport.path(args[2], cwd: io.cwd))
                return (aa?[.systemNumber] as? NSNumber) == (bb?[.systemNumber] as? NSNumber)
                    && (aa?[.systemFileNumber] as? NSNumber) == (bb?[.systemFileNumber] as? NSNumber)
                    && aa != nil && bb != nil
            default: throw SyntaxError(message: "unknown binary operator")
            }
        }
        throw SyntaxError(message: "too many arguments")
    }

    private static func fileType(_ operand: String, io: CommandIO) -> FileAttributeType? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: CommandSupport.path(operand, cwd: io.cwd))
        return attributes?[.type] as? FileAttributeType
    }

    private static func topLevelOperator(_ target: String, in args: [String]) -> Int? {
        var depth = 0
        for (index, argument) in args.enumerated() {
            if argument == "(" { depth += 1 }
            else if argument == ")" { depth -= 1 }
            else if depth == 0, argument == target { return index }
        }
        return nil
    }

    private static func enclosesWholeExpression(_ args: [String]) -> Bool {
        var depth = 0
        for (index, argument) in args.enumerated() {
            if argument == "(" { depth += 1 }
            if argument == ")" { depth -= 1 }
            if depth == 0, index != args.count - 1 { return false }
            if depth < 0 { return false }
        }
        return depth == 0
    }
}
