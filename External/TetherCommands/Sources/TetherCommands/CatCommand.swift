import Foundation
public enum CatCommand: TetherCommand {
    public static let name = "cat"
    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name), number = false
        if args.first == "-n" { number = true; args.removeFirst() }
        if args.isEmpty { args = ["-"] }
        var output = "", errors = ""
        for operand in args {
            do { output += try CommandSupport.read(operand, io: io) }
            catch { errors += "cat: \(operand): \(error.localizedDescription)\n" }
        }
        if number {
            let trailing = output.hasSuffix("\n")
            output = CommandSupport.lines(output).enumerated().map { String(format: "%6d\t%@", $0.offset + 1, $0.element) }.joined(separator: "\n") + (trailing ? "\n" : "")
        }
        return CommandResult(stdout: output, stderr: errors, exitCode: errors.isEmpty ? 0 : 1)
    }
}
