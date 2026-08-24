import Foundation
public enum ExprCommand: TetherCommand {
    public static let name = "expr"
    public static func run(_ io: CommandIO) -> CommandResult {
        let args = CommandSupport.args(io, command: name)
        guard !args.isEmpty else { return CommandSupport.error(name, "missing operand", usage: true) }
        do {
            var parser = Parser(tokens: args); let value = try parser.expression()
            guard parser.index == args.count else { throw ParseError.message("syntax error") }
            return CommandResult(stdout: value + "\n", exitCode: isFalse(value) ? 1 : 0)
        } catch let e as ParseError { return CommandSupport.error(name, e.description, usage: e.isSyntax) }
        catch { return CommandSupport.error(name, error.localizedDescription) }
    }
    private static func isFalse(_ value: String) -> Bool { value.isEmpty || Int64(value) == 0 }
    private enum ParseError: Error { case message(String), division; var description: String { switch self { case .message(let s): return s; case .division: return "division by zero" } }; var isSyntax: Bool { if case .message = self { true } else { false } } }
    private struct Parser {
        let tokens: [String]; var index = 0
        mutating func expression() throws -> String { try comparison() }
        mutating func comparison() throws -> String {
            var left = try additive()
            while index < tokens.count, ["=", "==", "!=", "<", "<=", ">", ">="].contains(tokens[index]) {
                let op = tokens[index]; index += 1; let right = try additive()
                let numeric = Int64(left).flatMap { a in Int64(right).map { (a, $0) } }
                let cmp: Bool
                if let (a,b) = numeric { switch op { case "=", "==": cmp = a == b; case "!=": cmp = a != b; case "<": cmp = a < b; case "<=": cmp = a <= b; case ">": cmp = a > b; default: cmp = a >= b } }
                else { switch op { case "=", "==": cmp = left == right; case "!=": cmp = left != right; case "<": cmp = left < right; case "<=": cmp = left <= right; case ">": cmp = left > right; default: cmp = left >= right } }
                left = cmp ? "1" : "0"
            }
            return left
        }
        mutating func additive() throws -> String {
            var left = try multiplicative()
            while index < tokens.count, tokens[index] == "+" || tokens[index] == "-" { let op = tokens[index]; index += 1; let right = try integer(try multiplicative()); let a = try integer(left); left = String(op == "+" ? a + right : a - right) }
            return left
        }
        mutating func multiplicative() throws -> String {
            var left = try primary()
            while index < tokens.count, ["*", "/", "%"].contains(tokens[index]) { let op = tokens[index]; index += 1; let right = try integer(try primary()); let a = try integer(left); if right == 0 && op != "*" { throw ParseError.division }; left = String(op == "*" ? a * right : (op == "/" ? a / right : a % right)) }
            return left
        }
        mutating func primary() throws -> String {
            guard index < tokens.count else { throw ParseError.message("syntax error") }
            if tokens[index] == "(" { index += 1; let value = try expression(); guard index < tokens.count, tokens[index] == ")" else { throw ParseError.message("missing )") }; index += 1; return value }
            let value = tokens[index]; index += 1; return value
        }
        func integer(_ value: String) throws -> Int64 { guard let n = Int64(value) else { throw ParseError.message("non-integer argument") }; return n }
    }
}
