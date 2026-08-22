import Foundation

/// `awk` — a compact line-oriented interpreter. Supports the commonly used
/// subset described in the design doc. See HANDOFF for the precise feature set.
struct AwkCommand: TermXCommand {
    static let name = "awk"
    static let builtinName = "awk"

    static func run(_ io: CommandIO) -> CommandResult {
        var fs: String = " "
        var vars: [String: String] = [:]
        var program: String?
        var files: [String] = []
        var i = 1
        var rest = false
        while i < io.argv.count {
            let a = io.argv[i]
            if !rest && a == "--" { rest = true }
            else if !rest && a == "-F" {
                i += 1
                if i >= io.argv.count { return CommandSupport.usageError(io, "-F requires an argument") }
                fs = io.argv[i]
            } else if !rest && a.hasPrefix("-F") {
                fs = String(a.dropFirst(2))
            } else if !rest && a == "-v" {
                i += 1
                if i >= io.argv.count { return CommandSupport.usageError(io, "-v requires an argument") }
                if let eq = io.argv[i].firstIndex(of: "=") {
                    vars[String(io.argv[i][..<eq])] = String(io.argv[i][io.argv[i].index(after: eq)...])
                }
            } else if !rest && a.hasPrefix("-v") {
                let v = String(a.dropFirst(2))
                if let eq = v.firstIndex(of: "=") {
                    vars[String(v[..<eq])] = String(v[v.index(after: eq)...])
                }
            } else if program == nil {
                program = a
            } else {
                files.append(a)
            }
            i += 1
        }
        guard let prog = program else { return CommandSupport.usageError(io, "missing program") }

        // Build input.
        var inputs: [String] = []
        if files.isEmpty {
            inputs = [io.stdin]
        } else {
            for f in files {
                if f == "-" { inputs.append(io.stdin); continue }
                guard let s = CommandSupport.readTextFile(f, cwd: io.cwd) else {
                    return CommandSupport.error(io, "\(f): No such file or directory")
                }
                inputs.append(s)
            }
        }

        let interpreter = AwkInterpreter(program: prog, fs: fs, initial: vars)
        do {
            let result = try interpreter.run(inputs)
            return CommandResult(stdout: result)
        } catch let e as AwkError {
            return CommandSupport.error(io, e.message)
        } catch {
            return CommandSupport.error(io, "execution error")
        }
    }
}

struct AwkError: Error { let message: String }

enum AwkValue { case num(Double); case str(String)
    var d: Double { switch self { case .num(let n): return n; case .str(let s): return Double(s) ?? 0 } }
    var s: String {
        switch self {
        case .num(let n):
            // awk prints integral values without a decimal part (OFMT is %.6g).
            if n == n.rounded(), abs(n) < 1e16 { return String(Int64(n)) }
            return String(format: "%.6g", n)
        case .str(let s):
            return s
        }
    }
    var isNumeric: Bool { if case .num = self { return true }; return false }
}

final class AwkInterpreter {
    private let program: String
    private var fs: String
    private var ofs = " "
    private var ors = "\n"
    private var vars: [String: AwkValue]
    private var fields: [AwkValue] = [.str(""), .str("")]
    private var nf = 0
    private var nr = 0

    init(program: String, fs: String, initial: [String: String]) {
        self.program = program
        self.fs = fs
        self.vars = initial.mapValues { AwkValue.str($0) }
        self.vars["FS"] = .str(fs)
        self.vars["OFS"] = .str(" ")
        self.vars["ORS"] = .str("\n")
    }

    func run(_ inputs: [String]) throws -> String {
        let parsed = try AwkParser(program).parseProgram()
        var output = ""
        output += try runBlock(parsed.begin)
        // process input
        for input in inputs {
            let lines = CommandSupport.lines(input)
            for line in lines {
                nr += 1
                setFields(line)
                output += try runBody(parsed.rules)
                if parsed.exitEarly { break }
            }
        }
        output += try runBlock(parsed.end)
        return output
    }

    // MARK: field handling

    private func setFields(_ line: String) {
        fields = [AwkValue.str(line)]
        var parts = line.split(separator: Character(fs.count == 1 ? fs : " "), omittingEmptySubsequences: fs == " " ? true : false)
        if fs.count > 1 {
            parts = line.components(separatedBy: fs).map({ Substring($0) })
        }
        for p in parts { fields.append(.str(String(p))) }
        nf = fields.count - 1
        vars["NF"] = .num(Double(nf))
        vars["NR"] = .num(Double(nr))
        vars["FS"] = .str(fs)
        vars["OFS"] = .str(ofs)
        vars["ORS"] = .str(ors)
    }

    private func field(_ index: Int) -> AwkValue {
        if index < 0 || index >= fields.count { return .str("") }
        return fields[index]
    }

    // MARK: runtime

    private func runBlock(_ block: [AwkStmt]?) throws -> String {
        guard let block = block else { return "" }
        var output = ""
        for s in block { output += try evalStatement(s) }
        return output
    }

    private func runBody(_ rules: [AwkRule]) throws -> String {
        var out = ""
        for rule in rules {
            let match = try ruleMatches(rule)
            if match {
                for s in rule.actions {
                    out += try evalStatement(s)
                    if exitRequested { break }
                }
            }
            if exitRequested { break }
        }
        return out
    }

    private var exitRequested = false

    private func ruleMatches(_ rule: AwkRule) throws -> Bool {
        switch rule.pattern {
        case .none: return true
        case .regex(let re): return BreRegex(re).containsMatch(in: field(0).s)
        case .expr(let e): return try value(of: e).d != 0
        }
    }

    // MARK: statements & expressions

    private func evalStatement(_ s: AwkStmt) throws -> String {
        var out = ""
        switch s {
        case .print(let exprs):
            var parts: [String] = []
            for e in exprs { parts.append(try value(of: e).s) }
            out = parts.joined(separator: ofs) + ors
        case .printf(let fmt, let args):
            let format = try value(of: fmt).s
            let vals = try args.map { try value(of: $0) }
            out = sprintf(format: format, args: vals)
        case .assign(let name, let expr):
            vars[name] = try value(of: expr)
        case .ifStmt(let cond, let then, let els):
            if try value(of: cond).d != 0 {
                for s in then { out += try evalStatement(s) }
            } else if let els = els {
                for s in els { out += try evalStatement(s) }
            }
        case .whileStmt(let cond, let body):
            while try value(of: cond).d != 0 {
                for s in body { out += try evalStatement(s) }
            }
        case .forStmt:
            // awk `for (init; cond; incr)` is not modelled by this subset's
            // parser, so this is intentionally a no-op rather than a wrong guess.
            break
        case .next:
            try exit()
        case .exit:
            exitRequested = true
        case .delete:
            break
        }
        return out
    }

    private func value(of expr: AwkExpr) throws -> AwkValue {
        switch expr {
        case .number(let n): return .num(n)
        case .string(let s): return .str(s)
        case .field(let idx): return try fieldValue(idx)
        case .variable(let name): return vars[name] ?? .str("")
        case .regexMatch: return .num(0)
        case .unary(let op, let e):
            let v = try value(of: e)
            if op == "-" { return .num(-v.d) }
            if op == "!" { return .num(v.d == 0 ? 1 : 0) }
            return .num(v.d)
        case .binary(let op, let l, let r):
            return try apply(op, l, r)
        case .ternary(let c, let t, let f):
            return try value(of: c).d != 0 ? try value(of: t) : try value(of: f)
        case .concat(let l, let r):
            return .str((try value(of: l).s) + (try value(of: r).s))
        case .assign(let name, let e):
            let v = try value(of: e)
            vars[name] = v
            return v
        case .call(let funcName, let args):
            return try callFunction(funcName, args: args)
        }
    }

    private func fieldValue(_ idx: Int) throws -> AwkValue {
        switch idx {
        case -1: return field(nf)          // "$NF" = value of the last field
        case 0: return field(0)            // "$0"  = whole record
        default: return field(idx)
        }
    }

    private func apply(_ op: String, _ l: AwkExpr, _ r: AwkExpr) throws -> AwkValue {
        let lv = try value(of: l)
        let rv = try value(of: r)
        let ld = lv.d, rd = rv.d
        switch op {
        case "+": return .num(ld + rd)
        case "-": return .num(ld - rd)
        case "*": return .num(ld * rd)
        case "/": return rd == 0 ? .num(0) : .num(ld / rd)
        case "%": return rd == 0 ? .num(0) : .num(ld.truncatingRemainder(dividingBy: rd))
        case "**": return .num(mathPow(ld, rd))
        case "==": return lv.s == rv.s ? .num(1) : .num(0)
        case "!=": return lv.s != rv.s ? .num(1) : .num(0)
        case "<": return ld < rd ? .num(1) : .num(0)
        case ">": return ld > rd ? .num(1) : .num(0)
        case "<=": return ld <= rd ? .num(1) : .num(0)
        case ">=": return ld >= rd ? .num(1) : .num(0)
        case "&&": return (ld != 0 && rd != 0) ? .num(1) : .num(0)
        case "||": return (ld != 0 || rd != 0) ? .num(1) : .num(0)
        default: return .num(0)
        }
    }

    private func callFunction(_ name: String, args: [AwkExpr]) throws -> AwkValue {
        let vals = try args.map { try value(of: $0) }
        switch name {
        case "length": return .num(Double(vals.isEmpty ? field(0).s.count : vals[0].s.count))
        case "toupper": return .str((vals.first?.s ?? "").uppercased())
        case "tolower": return .str((vals.first?.s ?? "").lowercased())
        case "substr":
            let s = vals[0].s
            let start = Int(vals.count > 1 ? vals[1].d : 0)
            let len = Int(vals.count > 2 ? vals[2].d : Double(s.count))
            let chars = Array(s)
            let lo = max(0, start - 1)
            if len <= 0 { return .str("") }
            let hi = min(chars.count, lo + len)
            if lo >= chars.count { return .str("") }
            return .str(String(chars[lo..<hi]))
        case "index":
            let s = vals[0].s, t = vals[1].s
            if let r = s.range(of: t) { return .num(Double(s.distance(from: s.startIndex, to: r.lowerBound)) + 1) }
            return .num(0)
        case "split":
            let s = vals[0].s
            let sep = vals.count > 1 ? vals[1].s : " "
            let parts = s.components(separatedBy: sep)
            return .num(Double(parts.count))
        case "gsub", "sub":
            let pat = vals[0].s, rep = vals[1].s
            return .num(Double(substitute(pat, rep, in: vals[2].s, all: name == "gsub")))
        case "match":
            let pat = BreRegex(vals[0].s)
            if let m = pat.firstMatch(in: vals[1].s) {
                let pos = vals[1].s.distance(from: vals[1].s.startIndex, to: m.range.lowerBound) + 1
                vars["RSTART"] = .num(Double(pos))
                vars["RLENGTH"] = .num(Double(vals[1].s.distance(from: m.range.lowerBound, to: m.range.upperBound)))
                return .num(Double(pos))
            }
            vars["RSTART"] = .num(0)
            vars["RLENGTH"] = .num(-1)
            return .num(0)
        case "sprintf":
            let format = vals[0].s
            return .str(sprintf(format: format, args: Array(vals.dropFirst())))
        default:
            // try to index a user array (no-op)
            return .str("")
        }
    }

    private func substitute(_ pat: String, _ rep: String, in str: String, all: Bool) -> Int {
        guard let regex = try? NSRegularExpression(pattern: BreRegex.translate(pat), options: []) else { return 0 }
        let ns = str as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: str, options: [], range: range)
        let m = all ? matches : Array(matches.prefix(1))
        var out = ""
        var last = 0
        for match in m {
            let r = match.range
            out += ns.substring(with: NSRange(location: last, length: r.location - last))
            out += expandRep(rep, match: match, ns: ns)
            last = r.location + r.length
        }
        out += ns.substring(with: NSRange(location: last, length: ns.length - last))
        // mutate $0
        fields[0] = .str(out)
        return m.count
    }

    private func expandRep(_ rep: String, match: NSTextCheckingResult, ns: NSString) -> String {
        var out = ""
        let src = Array(rep)
        var i = 0
        while i < src.count {
            let c = src[i]
            if c == "\\", i + 1 < src.count {
                let n = src[i + 1]
                if let d = n.wholeNumberValue, d < match.numberOfRanges {
                    let r = match.range(at: d)
                    out += r.location == NSNotFound ? "" : ns.substring(with: r)
                } else { out.append(n) }
                i += 2
                continue
            }
            if c == "&" {
                let r = match.range(at: 0)
                out += r.location == NSNotFound ? "" : ns.substring(with: r)
                i += 1
                continue
            }
            out.append(c); i += 1
        }
        return out
    }

    /// Local `x ** y` for non-negative integer exponents (no libm dependency).
    private func mathPow(_ x: Double, _ y: Double) -> Double {
        guard y >= 0, y.truncatingRemainder(dividingBy: 1) == 0 else {
            return y < 0 ? 0 : x // non-integer/negative exponent ~ 0
        }
        var result = 1.0
        for _ in 0..<Int(y) { result *= x }
        return result
    }

    private func sprintf(format: String, args: [AwkValue]) -> String {
        var out = ""
        var argIdx = 0
        var i = format.startIndex
        let chars = Array(format)
        var ci = 0
        while ci < chars.count {
            let c = chars[ci]
            if c == "%" {
                // read until conversion char
                var spec = "%"
                var j = ci + 1
                while j < chars.count {
                    spec.append(chars[j])
                    j += 1
                    if isConversion(chars[j - 1]) { break }
                }
                if let conv = spec.last {
                    let val = argIdx < args.count ? args[argIdx] : .str("")
                    argIdx += 1
                    switch conv {
                    case "s": out += val.s
                    case "d": out += String(Int(val.d))
                    case "f": out += String(val.d)
                    default: out += spec
                    }
                }
                ci = j
            } else {
                out.append(c)
                ci += 1
            }
        }
        _ = i
        return out
    }

    private func isConversion(_ c: Character) -> Bool {
        return "sdfegcxiXo%%".contains(c)
    }

    private func exit() throws -> Int {
        exitRequested = true
        return 0
    }
}

// MARK: - Program parser

indirect enum AwkStmt {
    case print([AwkExpr])
    case printf(AwkExpr, [AwkExpr])
    case assign(String, AwkExpr)
    case ifStmt(AwkExpr, [AwkStmt], [AwkStmt]?)
    case whileStmt(AwkExpr, [AwkStmt])
    case forStmt([AwkStmt]?, AwkExpr?, AwkExpr?, [AwkStmt])
    case next
    case exit
    case delete(String)
}

indirect enum AwkExpr {
    case number(Double)
    case string(String)
    case field(Int)
    case variable(String)
    case regexMatch
    case unary(String, AwkExpr)
    case binary(String, AwkExpr, AwkExpr)
    case concat(AwkExpr, AwkExpr)
    case ternary(AwkExpr, AwkExpr, AwkExpr)
    case assign(String, AwkExpr)
    case call(String, [AwkExpr])
}

indirect enum AwkPattern {
    case none
    case regex(String)
    case expr(AwkExpr)
}

struct AwkRule { var pattern: AwkPattern; var actions: [AwkStmt] }

struct AwkProgram { var begin: [AwkStmt]?; var rules: [AwkRule]; var end: [AwkStmt]?; var exitEarly: Bool }

struct AwkParser {
    let program: String
    init(_ s: String) { self.program = s }

    func parseProgram() throws -> AwkProgram {
        var begin: [AwkStmt] = []
        var end: [AwkStmt] = []
        var rules: [AwkRule] = []
        var exitEarly = false

        var i = program.startIndex
        while i < program.endIndex {
            if word(at: i) == "BEGIN" {
                i = skip(to: "{", from: i)
                (begin, i) = try readBlock(from: i)
            } else if word(at: i) == "END" {
                i = skip(to: "{", from: i)
                (end, i) = try readBlock(from: i)
            } else if peekChar(at: i) == "/" {
                if let re = readRegex(from: i) {
                    i = skipWs(from: re.end)
                    let body: [AwkStmt]
                    (body, i) = try readBlock(from: i)
                    rules.append(AwkRule(pattern: .regex(re.pattern), actions: body))
                } else { i = program.index(after: i) }
            } else if peekChar(at: i) == "{" {
                let body: [AwkStmt]
                (body, i) = try readBlock(from: i)
                rules.append(AwkRule(pattern: .none, actions: body))
            } else {
                // expression/substitution pattern
                if let (cond, j) = try parseExpr(from: i) {
                    let body: [AwkStmt]
                    (body, i) = try readBlock(from: j)
                    rules.append(AwkRule(pattern: .expr(cond), actions: body))
                } else { i = program.index(after: i) }
            }
        }
        _ = exitEarly
        return AwkProgram(begin: begin.isEmpty ? nil : begin, rules: rules,
                          end: end.isEmpty ? nil : end, exitEarly: false)
    }

    private func word(at i: String.Index) -> String {
        let chars = Array(program)
        let offset = program.distance(from: program.startIndex, to: i)
        guard offset < chars.count else { return "" }
        if chars[offset] == "B" || chars[offset] == "E" {
            let s = program.suffix(from: i).prefix(5)
            return String(s)
        }
        return ""
    }

    private func peekChar(at i: String.Index) -> Character? {
        let offset = program.distance(from: program.startIndex, to: i)
        let chars = Array(program)
        return offset < chars.count ? chars[offset] : nil
    }

    private func skip(to target: Character, from i: String.Index) -> String.Index {
        var idx = i
        while idx < program.endIndex && peekChar(at: idx) != target {
            idx = program.index(after: idx)
        }
        return idx
    }

    private func skipWs(from i: String.Index) -> String.Index {
        var idx = i
        while idx < program.endIndex, let c = peekChar(at: idx), c == " " || c == "\t" || c == "\n" {
            idx = program.index(after: idx)
        }
        return idx
    }

    private func readRegex(from i: String.Index) -> (pattern: String, end: String.Index)? {
        var idx = program.index(after: i)
        var buf = ""
        while idx < program.endIndex, let c = peekChar(at: idx), c != "/" {
            buf.append(c)
            idx = program.index(after: idx)
        }
        guard idx < program.endIndex else { return nil }
        return (buf, program.index(after: idx))
    }

    private func readBlock(from brace: String.Index) throws -> ([AwkStmt], String.Index) {
        let start = skipWs(from: brace)
        guard let c = peekChar(at: start) else { throw AwkError(message: "expected block") }
        var idx = start
        if c == "{" { idx = program.index(after: start) }
        return try readStatements(from: idx)
    }

    private func readStatements(from start: String.Index) throws -> ([AwkStmt], String.Index) {
        var stmts: [AwkStmt] = []
        var idx = start
        while idx < program.endIndex {
            idx = skipWs(from: idx)
            guard let c = peekChar(at: idx) else { break }
            if c == "}" { return (stmts, program.index(after: idx)) }
            if c == "\n" || c == ";" { idx = program.index(after: idx); continue }
            // parse one statement
            idx = skipWs(from: idx)
            if program.suffix(from: idx).hasPrefix("print") && !program.suffix(from: idx).hasPrefix("printf") {
                idx = program.index(idx, offsetBy: 5)
                var exprs: [AwkExpr] = []
                while true {
                    idx = skipWs(from: idx)
                    if let c2 = peekChar(at: idx), c2 == ";" || c2 == "}" || c2 == "\n" { break }
                    if let (e, j) = try parseExpr(from: idx) {
                        exprs.append(e)
                        idx = j
                    } else { break }
                    idx = skipWs(from: idx)
                    if let c2 = peekChar(at: idx), c2 == "," { idx = program.index(after: idx) }
                }
                if exprs.isEmpty { exprs = [.field(0)] }
                stmts.append(.print(exprs))
                continue
            }
            if program.suffix(from: idx).hasPrefix("printf") {
                idx = program.index(idx, offsetBy: 6)
                idx = skipWs(from: idx)
                let fmt = try parseExpr(from: idx)!
                idx = fmt.1
                var args: [AwkExpr] = []
                while true {
                    idx = skipWs(from: idx)
                    if let c = peekChar(at: idx), c == "," {
                        idx = program.index(after: idx)
                        idx = skipWs(from: idx)
                        if let (e, j) = try parseExpr(from: idx) { args.append(e); idx = j }
                    } else { break }
                }
                stmts.append(.printf(fmt.0, args))
                continue
            }
            if program.suffix(from: idx).hasPrefix("if") {
                idx = program.index(idx, offsetBy: 2)
                idx = skipWs(from: idx)
                idx = skip(to: "(", from: idx)
                let cond = try parseExpr(from: idx)!
                idx = cond.1
                if let c = peekChar(at: idx), c == ")" { idx = program.index(after: idx) }
                idx = skipWs(from: idx)
                let thenStmt: [AwkStmt]
                if let c = peekChar(at: idx), c == "{" {
                    (thenStmt, idx) = try readBlock(from: idx)
                } else {
                    let (single, j) = try readSingleStatement(from: idx)
                    thenStmt = single
                    idx = j
                }
                var elseStmt: [AwkStmt]? = nil
                let after = skipWs(from: idx)
                if program.suffix(from: after).hasPrefix("else") {
                    idx = program.index(after, offsetBy: 4)
                    idx = skipWs(from: idx)
                    let el: [AwkStmt]
                    if let c = peekChar(at: idx), c == "{" {
                        (el, idx) = try readBlock(from: idx)
                    } else {
                        let (single, j) = try readSingleStatement(from: idx)
                        el = single
                        idx = j
                    }
                    elseStmt = el
                }
                stmts.append(.ifStmt(cond.0, thenStmt, elseStmt))
                continue
            }
            if program.suffix(from: idx).hasPrefix("while") {
                idx = program.index(idx, offsetBy: 5)
                idx = skipWs(from: idx)
                idx = skip(to: "(", from: idx)
                let cond = try parseExpr(from: idx)!
                idx = cond.1
                if let c = peekChar(at: idx), c == ")" { idx = program.index(after: idx) }
                idx = skipWs(from: idx)
                let body: [AwkStmt]
                if let c = peekChar(at: idx), c == "{" { (body, idx) = try readBlock(from: idx) }
                else { let (single, j) = try readSingleStatement(from: idx); body = single; idx = j }
                stmts.append(.whileStmt(cond.0, body))
                continue
            }
            if program.suffix(from: idx).hasPrefix("next") {
                idx = program.index(idx, offsetBy: 4)
                stmts.append(.next)
                continue
            }
            if program.suffix(from: idx).hasPrefix("exit") {
                idx = program.index(idx, offsetBy: 4)
                stmts.append(.exit)
                continue
            }
            // assignment expression
            let (e, j) = try parseExpr(from: idx)!
            if case .assign(let name, _) = e { stmts.append(.assign(name, e)) }
            idx = j
        }
        return (stmts, idx)
    }

    private func readSingleStatement(from idx: String.Index) throws -> ([AwkStmt], String.Index) {
        // read until ; or } for a simple statement
        var parts: [AwkExpr] = []
        var idx = skipWs(from: idx)
        _ = parts
        if let (e, j) = try parseExpr(from: idx) {
            return ([.ifStmt(e, [], nil)], j)
        }
        return ([], idx)
    }

    // MARK: expression parsing (PEG-lite)

    private func parseExpr(from i: String.Index) throws -> (AwkExpr, String.Index)? {
        var idx = skipWs(from: i)
        guard let prim = try parsePrimary(from: idx) else { return nil }
        var left = prim.0
        idx = prim.1

        while idx < program.endIndex {
            idx = skipWs(from: idx)
            guard let c = peekChar(at: idx) else { break }
            if c == ">" || c == "<" || c == "=" || c == "!" {
                if let cmp = try parseOp(from: idx) {
                    idx = cmp.1
                    idx = skipWs(from: idx)
                    guard let rhs = try parsePrimary(from: idx) else { break }
                    left = .binary(cmp.0, left, rhs.0)
                    idx = rhs.1
                    continue
                } else {
                    break
                }
            }
            if c == "+" || c == "-" || c == "*" || c == "/" || c == "%" {
                if let op = try parseOp(from: idx) {
                    idx = op.1
                    idx = skipWs(from: idx)
                    guard let rhs = try parsePrimary(from: idx) else { break }
                    left = .binary(op.0, left, rhs.0)
                    idx = rhs.1
                    continue
                } else {
                    break
                }
            }
            break
        }
        return (left, idx)
    }

    private func parseOp(from i: String.Index) throws -> (String, String.Index)? {
        let chars = Array(program)
        let offset = program.distance(from: program.startIndex, to: i)
        guard offset < chars.count else { return nil }
        let two = offset + 1 < chars.count ? String(chars[offset]) + String(chars[offset + 1]) : ""
        let one = String(chars[offset])
        for op in ["==", "!=", "<=", ">=", "&&", "||", "**"] {
            if two == op { return (op, program.index(i, offsetBy: 2)) }
        }
        if ["+", "-", "*", "/", "%", ">", "<", "="].contains(one) { return (one, program.index(after: i)) }
        return nil
    }

    private func parsePrimary(from i: String.Index) throws -> (AwkExpr, String.Index)? {
        var idx = skipWs(from: i)
        guard let c = peekChar(at: idx) else { return nil }
        let chars = Array(program)
        let offset = program.distance(from: program.startIndex, to: idx)

        if c.isNumber {
            var buf = ""
            var j = idx
            while j < program.endIndex, let d = peekChar(at: j), d.isNumber || d == "." {
                buf.append(d)
                j = program.index(after: j)
            }
            return (.number(Double(buf) ?? 0), j)
        }
        if c == "\"" {
            var buf = ""
            var j = program.index(after: idx)
            while j < program.endIndex, let d = peekChar(at: j), d != "\"" {
                buf.append(d)
                j = program.index(after: j)
            }
            return (.string(buf), program.index(after: j))
        }
        if c == "$" {
            // `$0` => whole record; `$NF` => last field's value; `$n` => field n.
            let chars2 = program.suffix(from: program.index(after: idx))
            if chars2.hasPrefix("0") {
                return (.field(0), program.index(after: idx))
            }
            if chars2.hasPrefix("NF") {
                return (.field(-1), program.index(idx, offsetBy: 3)) // "$NF" = $ + NF
            }
            var digitCount = 0
            for ch in chars2 { if ch.isNumber { digitCount += 1 } else { break } }
            if digitCount > 0, let n = Int(chars2.prefix(digitCount)) {
                return (.field(n), program.index(idx, offsetBy: 1 + digitCount))
            }
            return (.field(0), program.index(after: idx))
        }
        if c.isLetter || c == "_" {
            // The name includes the character at `idx`; scanning must start with it.
            var name = String(c)
            var j = program.index(after: idx)
            while j < program.endIndex, let d = peekChar(at: j), d.isLetter || d.isNumber || d == "_" {
                name.append(d)
                j = program.index(after: j)
            }
            // function call?
            let after = skipWs(from: j)
            if let p = peekChar(at: after), p == "(" {
                // parse args
                var args: [AwkExpr] = []
                var k = program.index(after: after)
                while k < program.endIndex, let d = peekChar(at: k), d != ")" {
                    if d == "," { k = program.index(after: k); continue }
                    if let (arg, k2) = try parseExpr(from: k) {
                        args.append(arg)
                        k = k2
                    } else { k = program.index(after: k) }
                    k = skipWs(from: k)
                }
                let afterParen = k < program.endIndex ? program.index(after: k) : k
                return (.call(name, args), afterParen)
            }
            // could be a field reference $var? just variable
            // check if followed by '=' for assignment
            let after2 = skipWs(from: j)
            if let eq = peekChar(at: after2), eq == "=" {
                let rhs = try parseExpr(from: program.index(after: after2))
                if let rhs = rhs {
                    return (.assign(name, rhs.0), rhs.1)
                }
            }
            return (.variable(name), j)
        }
        return nil
    }
}
