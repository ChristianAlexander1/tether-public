import Foundation

// MARK: - Control flow

/// Non-local control flow implemented with Swift errors.
enum ShellFlow: Error {
    case exitShell(Int32)
    /// Fatal shell error (`${x:?}`, arithmetic errors, execution limit).
    case abort(Int32, message: String?)
    case returnFromFunction(Int32)
    case breakLoop(Int)
    case continueLoop(Int)
}

// MARK: - I/O plumbing

/// Standard input as a cursor so `read` consumes one line at a time while
/// `cat` drains the rest.
final class StdinBuffer {
    private let text: String
    private var offset: String.Index

    init(_ text: String = "") {
        self.text = text
        self.offset = text.startIndex
    }

    var isAtEnd: Bool { offset >= text.endIndex }

    /// Reads one line. Returns (line, hitNewline), or nil at EOF with no data.
    func readLine() -> (line: String, hitNewline: Bool)? {
        guard !isAtEnd else { return nil }
        if let nl = text[offset...].firstIndex(of: "\n") {
            let line = String(text[offset..<nl])
            offset = text.index(after: nl)
            return (line, true)
        }
        let line = String(text[offset...])
        offset = text.endIndex
        return (line, false)
    }

    func readRest() -> String {
        let rest = String(text[offset...])
        offset = text.endIndex
        return rest
    }

    /// Copy of the remaining input without consuming it (for `$( )`).
    func remaining() -> String { String(text[offset...]) }
}

/// The standard streams a command executes against. Redirects swap the sinks.
final class ExecContext {
    var stdin: StdinBuffer
    var stdout: (String) -> Void
    var stderr: (String) -> Void

    init(stdin: StdinBuffer,
         stdout: @escaping (String) -> Void,
         stderr: @escaping (String) -> Void) {
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }

    func copy() -> ExecContext {
        ExecContext(stdin: stdin, stdout: stdout, stderr: stderr)
    }
}

/// Host wrapper used by subshells and command substitutions: env mutations
/// (`export`, `unset`) are captured in an overlay instead of leaking into the
/// parent's environment.
final class OverlayHost: ShellHost {
    let base: ShellHost
    private var overlay: [String: String] = [:]
    private var removed: Set<String> = []

    init(base: ShellHost) { self.base = base }

    func run(commandLine: String) -> Int32 { base.run(commandLine: commandLine) }
    func write(_ text: String) { base.write(text) }
    func writeError(_ text: String) { base.writeError(text) }

    func value(for name: String) -> String? {
        if removed.contains(name) { return nil }
        if let value = overlay[name] { return value }
        return base.value(for: name)
    }

    func setValue(_ value: String?, for name: String) {
        if let value {
            overlay[name] = value
            removed.remove(name)
        } else {
            overlay.removeValue(forKey: name)
            removed.insert(name)
        }
    }
}

// MARK: - The shell

/// A reusable POSIX shell session: parser + evaluator state (variables,
/// functions, positional parameters, virtual file system) bound to one
/// `ShellHost`. Create one instance and feed it scripts with `run`.
///
/// The shell never spawns processes; external commands are delegated to the
/// host. It keeps an in-memory file system so redirections, `.` (sourcing),
/// and file test operators work the same in every environment.
public final class TetherShell {

    // MARK: Public surface

    public let host: ShellHost

    /// In-memory file system keyed by absolute path. Redirects write here;
    /// `cat`, `[ -e ... ]`, `. file` and pathname globbing read from it.
    public var fileSystem: [String: String] = [:]

    /// Working directory for relative file names (fixed to `/` — no `cd`).
    public var cwd = "/"

    /// Value of `$0`.
    public var scriptName = "tethersh"

    /// Value of `$$`.
    public var pid = 4242

    /// Script arguments; become the outer positional parameters.
    public var arguments: [String] = [] {
        didSet { positionalStack = [arguments] }
    }

    /// Safety net: maximum number of command executions per `run` call
    /// before the shell aborts (protects hosts from `while true` scripts).
    public var maxCommandExecutions = 250_000

    /// Exit status of the most recent command (`$?`).
    public internal(set) var lastStatus: Int32 = 0

    public init(host: ShellHost) {
        self.host = host
    }

    /// Seeds the virtual file system, applying path normalization.
    public func setVirtualFile(_ path: String, contents: String) {
        fileSystem[normalizePath(path)] = contents
    }

    /// Reads a virtual file (normalized); `/dev/null` reads as empty.
    public func virtualFile(_ path: String) -> String? {
        let key = normalizePath(path)
        if key == "/dev/null" { return "" }
        return fileSystem[key]
    }

    /// Parses source into an AST without running it.
    public func parse(_ source: String) throws -> TetherProgram {
        try TetherShellParser.parse(source)
    }

    /// Parses and runs source, returning the exit status.
    @discardableResult
    public func run(_ source: String) throws -> Int32 {
        run(try parse(source))
    }

    /// Runs a parsed program, returning the exit status.
    @discardableResult
    public func run(_ program: TetherProgram) -> Int32 {
        execute(program, ctx: rootContext())
    }

    // MARK: State

    var globals: [String: String] = [:]
    var localScopes: [[String: String]] = []
    var localExported: [Set<String>] = []
    var exportedVars: Set<String> = []
    var functions: [String: TetherCommand] = [:]
    var positionalStack: [[String]] = [[]]

    var cmdSubHappened = false
    private var executionCount = 0

    // MARK: Entry plumbing

    private func rootContext() -> ExecContext {
        ExecContext(stdin: StdinBuffer(),
                    stdout: { text in self.host.write(text) },
                    stderr: { text in self.host.writeError(text) })
    }

    /// Execution boundary: catches control flow, producing a status.
    @discardableResult
    func execute(_ program: TetherProgram, ctx: ExecContext) -> Int32 {
        var status = lastStatus
        do {
            status = try runItems(program.items, ctx: ctx)
        } catch ShellFlow.exitShell(let code) {
            status = code
        } catch ShellFlow.abort(let code, let message) {
            if let message {
                ctx.stderr(message.hasSuffix("\n") ? message : message + "\n")
            }
            status = code
        } catch ShellFlow.returnFromFunction(let code) {
            status = code
        } catch ShellFlow.breakLoop(_) {
            ctx.stderr("tethersh: break: not in a loop\n")
            status = 1
        } catch ShellFlow.continueLoop(_) {
            ctx.stderr("tethersh: continue: not in a loop\n")
            status = 1
        } catch {
            ctx.stderr("tethersh: internal error: \(error)\n")
            status = 2
        }
        lastStatus = status
        return status
    }

    func makeSubshell() -> TetherShell {
        let sub = TetherShell(host: OverlayHost(base: host))
        sub.fileSystem = fileSystem
        sub.globals = globals
        sub.localScopes = localScopes
        sub.localExported = localExported
        sub.exportedVars = exportedVars
        sub.functions = functions
        sub.positionalStack = positionalStack
        sub.scriptName = scriptName
        sub.pid = pid
        sub.cwd = cwd
        sub.lastStatus = lastStatus
        sub.maxCommandExecutions = maxCommandExecutions
        return sub
    }

    private func bumpExecution() throws {
        executionCount += 1
        if executionCount > maxCommandExecutions {
            throw ShellFlow.abort(2, message: "tethersh: execution limit exceeded\n")
        }
    }

    // MARK: - Variables

    func lookup(_ name: String) -> String? {
        for scope in localScopes.reversed() {
            if let value = scope[name] { return value }
        }
        if let value = globals[name] { return value }
        return host.value(for: name)
    }

    func setVar(_ name: String, _ value: String) {
        for index in localScopes.indices.reversed() where localScopes[index][name] != nil {
            localScopes[index][name] = value
            return
        }
        globals[name] = value
        if exportedVars.contains(name) {
            host.setValue(value, for: name)
        }
    }

    func exportVar(_ name: String) {
        exportedVars.insert(name)
        if let top = localScopes.indices.last, localScopes[top][name] != nil {
            localExported[top].insert(name)
        }
        host.setValue(lookup(name), for: name)
    }

    func unsetVar(_ name: String) {
        for index in localScopes.indices.reversed() where localScopes[index][name] != nil {
            localScopes[index].removeValue(forKey: name)
            localExported[index].remove(name)
            return
        }
        globals.removeValue(forKey: name)
        exportedVars.remove(name)
        host.setValue(nil, for: name)
    }

    var positional: [String] { positionalStack.last ?? [] }

    /// Field-splitting characters (`$IFS`, default " \t\n").
    var ifs: String { lookup("IFS") ?? " \t\n" }
    var ifsFirst: String { String(ifs.first ?? " ") }

    func positionalAt(_ index: Int) -> String? {
        guard index >= 1, index <= positional.count else { return nil }
        return positional[index - 1]
    }

    private func pushTempScope(_ scope: [String: String]) {
        localScopes.append(scope)
        localExported.append([])
    }

    private func popScope() {
        let locals = localScopes.removeLast()
        let exported = localExported.removeLast()
        for name in exported where locals[name] != nil {
            host.setValue(nil, for: name)
            exportedVars.remove(name)
        }
    }

    // MARK: - Files

    func normalizePath(_ path: String) -> String {
        var parts: [String] = path.hasPrefix("/")
            ? []
            : cwd.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(String(component))
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    private func openForWrite(_ path: String, append: Bool) -> ((String) -> Void)? {
        let key = normalizePath(path)
        if key == "/dev/null" { return { _ in } }
        let base = append ? (fileSystem[key] ?? "") : ""
        fileSystem[key] = base
        return { text in self.fileSystem[key, default: ""] += text }
    }

    // MARK: - Execution: lists

    @discardableResult
    func runItems(_ items: [TetherListItem], ctx: ExecContext) throws -> Int32 {
        var status = lastStatus
        for item in items {
            status = try runAndOr(item.andOr, ctx: ctx)
            if item.async { status = 0 }
            lastStatus = status
        }
        return status
    }

    func runAndOr(_ andOr: TetherAndOr, ctx: ExecContext) throws -> Int32 {
        var status = try runPipeline(andOr.first, ctx: ctx)
        for tail in andOr.rest {
            switch tail.op {
            case .and:
                if status == 0 { status = try runPipeline(tail.pipeline, ctx: ctx) }
            case .or:
                if status != 0 { status = try runPipeline(tail.pipeline, ctx: ctx) }
            }
        }
        return status
    }

    func runPipeline(_ pipeline: TetherPipeline, ctx: ExecContext) throws -> Int32 {
        var status: Int32 = 0
        if pipeline.commands.count == 1, let only = pipeline.commands.first {
            status = try runCommand(only, ctx: ctx)
        } else {
            // Stages run left to right; each stage's captured stdout becomes the
            // next stage's stdin. (External commands run via ShellHost can't
            // receive that stdin — a documented protocol limit.)
            var pipeText = ""
            for (index, command) in pipeline.commands.enumerated() {
                let isLast = index == pipeline.commands.count - 1
                let stageCtx = ctx.copy()
                stageCtx.stdin = index == 0 ? ctx.stdin : StdinBuffer(pipeText)
                var captured = ""
                if !isLast {
                    stageCtx.stdout = { captured += $0 }
                }
                status = try runCommand(command, ctx: stageCtx)
                pipeText = captured
            }
        }
        if pipeline.negated {
            status = status == 0 ? 1 : 0
        }
        return status
    }

    // MARK: - Execution: commands

    func runCommand(_ command: TetherCommand, ctx: ExecContext) throws -> Int32 {
        switch command {
        case .simple(let simple):
            return try runSimpleCommand(simple, ctx: ctx)

        case .functionDef(let def):
            functions[def.name] = def.body
            return 0

        case .arithmetic(let expr, let redirects):
            guard let _ = try applyRedirects(redirects, ctx: ctx) else { return 1 }
            let value = try runArithmetic(expr, ctx: ctx)
            return value != 0 ? 0 : 1

        case .braceGroup(let body, let redirects):
            guard let c = try applyRedirects(redirects, ctx: ctx) else { return 1 }
            return try runItems(body, ctx: c)

        case .subshell(let body, let redirects):
            guard let c = try applyRedirects(redirects, ctx: ctx) else { return 1 }
            return makeSubshell().execute(TetherProgram(items: body), ctx: c)

        case .ifClause(let clause, let redirects):
            guard let c = try applyRedirects(redirects, ctx: ctx) else { return 1 }
            if try runItems(clause.condition, ctx: c) == 0 {
                return try runItems(clause.thenBody, ctx: c)
            }
            for elif in clause.elifs {
                if try runItems(elif.condition, ctx: c) == 0 {
                    return try runItems(elif.body, ctx: c)
                }
            }
            if let elseBody = clause.elseBody {
                return try runItems(elseBody, ctx: c)
            }
            return 0

        case .loop(let condition, let body, let until, let redirects):
            guard let c = try applyRedirects(redirects, ctx: ctx) else { return 1 }
            var status: Int32 = 0
            while true {
                let condStatus = try runItems(condition, ctx: c)
                let proceed = until ? condStatus != 0 : condStatus == 0
                guard proceed else { break }
                guard try runLoopBody(body, ctx: c, status: &status) else { break }
            }
            return status

        case .forClause(let clause, let redirects):
            guard let c = try applyRedirects(redirects, ctx: ctx) else { return 1 }
            var status: Int32 = 0
            if let arith = clause.arithmetic {
                let start = arith.start.trimmingCharacters(in: .whitespaces)
                if !start.isEmpty { _ = try runArithmetic(start, ctx: c) }
                while true {
                    let cond = arith.condition.trimmingCharacters(in: .whitespaces)
                    if !cond.isEmpty {
                        guard try runArithmetic(cond, ctx: c) != 0 else { break }
                    }
                    guard try runLoopBody(clause.body, ctx: c, status: &status) else { break }
                    let step = arith.step.trimmingCharacters(in: .whitespaces)
                    if !step.isEmpty { _ = try runArithmetic(step, ctx: c) }
                }
            } else {
                let values: [String]
                if let words = clause.words {
                    var expanded: [String] = []
                    for word in words {
                        expanded.append(contentsOf: try expandFields(word, ctx: c))
                    }
                    values = expanded
                } else {
                    values = positional
                }
                for value in values {
                    setVar(clause.varName, value)
                    guard try runLoopBody(clause.body, ctx: c, status: &status) else { break }
                }
            }
            return status

        case .caseClause(let clause, let redirects):
            guard let c = try applyRedirects(redirects, ctx: ctx) else { return 1 }
            let subject = try expandScalar(clause.subject, ctx: c)
            var status: Int32 = 0
            var executeRest = false // after `;&`, bodies run unconditionally
            for item in clause.items {
                var matched = executeRest
                if !matched {
                    for patternWord in item.patterns {
                        let pattern = try expandPattern(patternWord, ctx: c)
                        if TetherGlob.match(pattern, subject) { matched = true; break }
                    }
                }
                if matched {
                    status = try runItems(item.body, ctx: c)
                    switch item.terminator {
                    case .stop: return status
                    case .fallThru: executeRest = true
                    case .retest: executeRest = false
                    }
                }
            }
            return status
        }
    }

    /// Runs a loop body; returns false on a level-1 `break`.
    private func runLoopBody(_ body: [TetherListItem], ctx: ExecContext,
                             status: inout Int32) throws -> Bool {
        try bumpExecution()
        do {
            status = try runItems(body, ctx: ctx)
            return true
        } catch ShellFlow.breakLoop(let levels) {
            if levels > 1 { throw ShellFlow.breakLoop(levels - 1) }
            return false
        } catch ShellFlow.continueLoop(let levels) {
            if levels > 1 { throw ShellFlow.continueLoop(levels - 1) }
            return true
        }
    }

    // MARK: - Execution: simple commands

    private static let assignmentBuiltins: Set<String> = [
        "local", "export", "readonly", "typeset", "declare",
    ]

    func runSimpleCommand(_ simple: TetherSimpleCommand, ctx: ExecContext) throws -> Int32 {
        try bumpExecution()
        cmdSubHappened = false

        // Expand words. TetherAssignment-looking arguments of `local`/`export`/etc
        // are expanded without field splitting (mksh behavior).
        var fields: [String] = []
        if let first = simple.words.first {
            let firstFields = try expandFields(first, ctx: ctx)
            fields = firstFields
            let assignmentContext = TetherShell.assignmentBuiltins
                .contains(firstFields.first ?? "")
            for word in simple.words.dropFirst() {
                if assignmentContext, parseAssignmentWord(word.raw) != nil {
                    fields.append(try expandScalar(word, ctx: ctx))
                } else {
                    fields.append(contentsOf: try expandFields(word, ctx: ctx))
                }
            }
        }

        var assignments: [(String, String)] = []
        for assignment in simple.assignments {
            assignments.append((assignment.name, try expandScalar(assignment.value, ctx: ctx)))
        }

        guard !fields.isEmpty else {
            // TetherAssignment-only simple command: values persist in the shell.
            for (name, value) in assignments { setVar(name, value) }
            guard try applyRedirects(simple.redirects, ctx: ctx) != nil else { return 1 }
            return cmdSubHappened ? lastStatus : 0
        }

        // `NAME=val cmd`: temporary environment for the command duration.
        if !assignments.isEmpty {
            pushTempScope(Dictionary(assignments, uniquingKeysWith: { _, new in new }))
        }
        defer {
            if !assignments.isEmpty { popScope() }
        }

        guard let effective = try applyRedirects(simple.redirects, ctx: ctx) else {
            return 1
        }

        let name = fields[0]
        let args = Array(fields.dropFirst())
        let status = try dispatchCommand(name: name, args: args, ctx: effective,
                                         bypassFunctions: false)
        lastStatus = status
        return status
    }

    func dispatchCommand(name: String, args: [String], ctx: ExecContext,
                         bypassFunctions: Bool) throws -> Int32 {
        if !bypassFunctions, let body = functions[name] {
            return try callFunction(body: body, args: args, ctx: ctx)
        }
        if let status = try runBuiltin(name: name, args: args, ctx: ctx) {
            return status
        }
        return host.run(commandLine: ([name] + args).joined(separator: " "))
    }

    private func callFunction(body: TetherCommand, args: [String], ctx: ExecContext) throws -> Int32 {
        positionalStack.append(args)
        pushTempScope([:])
        defer {
            popScope()
            positionalStack.removeLast()
        }
        do {
            return try runCommand(body, ctx: ctx)
        } catch ShellFlow.returnFromFunction(let code) {
            return code
        }
    }

    private func parseAssignmentWord(_ raw: String) -> (String, String)? {
        guard let eq = raw.firstIndex(of: "=") else { return nil }
        let name = String(raw[raw.startIndex..<eq])
        guard ScanUtil.isValidName(name) else { return nil }
        return (name, String(raw[raw.index(after: eq)...]))
    }

    // MARK: - Execution: redirects

    /// Applies redirects to a copy of `ctx`; nil means "redirection failed,
    /// do not run the command" after writing a diagnostic.
    func applyRedirects(_ redirects: [TetherRedirect], ctx: ExecContext) throws -> ExecContext? {
        guard !redirects.isEmpty else { return ctx }
        let c = ctx.copy()
        for redirect in redirects {
            let fd = redirect.fd ?? defaultFd(for: redirect.op)
            switch redirect.op {
            case .input, .readWrite:
                let path = try expandScalar(redirect.target, ctx: c)
                guard !path.isEmpty, let content = virtualFile(path) else {
                    c.stderr("tethersh: cannot open \(path) for reading\n")
                    return nil
                }
                if fd == 0 { c.stdin = StdinBuffer(content) }

            case .output, .append, .clobber:
                let path = try expandScalar(redirect.target, ctx: c)
                guard !path.isEmpty, let sink = openForWrite(path, append: redirect.op == .append) else {
                    c.stderr("tethersh: cannot open \(path) for writing\n")
                    return nil
                }
                if fd == 1 { c.stdout = sink }
                else if fd == 2 { c.stderr = sink }
                // fd >= 3: the file is created/truncated; nothing can write to it.

            case .heredoc, .heredocTabs:
                guard let hd = redirect.hereDoc else { return nil }
                let body = hd.expand ? try expandHereDocText(hd.body, ctx: c) : hd.body
                c.stdin = StdinBuffer(body)

            case .hereString:
                let text = try expandScalar(redirect.target, ctx: c)
                c.stdin = StdinBuffer(text + "\n")

            case .outputDup:
                let target = try expandScalar(redirect.target, ctx: c)
                switch target {
                case "-":
                    if fd == 2 { c.stderr = { _ in } } else { c.stdout = { _ in } }
                case "1":
                    if fd == 2 { c.stderr = c.stdout }
                case "2":
                    if fd == 1 { c.stdout = c.stderr }
                default:
                    c.stderr("tethersh: >&\(target): bad file descriptor\n")
                    return nil
                }

            case .inputDup:
                let target = try expandScalar(redirect.target, ctx: c)
                switch target {
                case "-": c.stdin = StdinBuffer("")
                case "0": break
                default:
                    c.stderr("tethersh: <&\(target): bad file descriptor\n")
                    return nil
                }
            }
        }
        return c
    }

    private func defaultFd(for op: TetherRedirOp) -> Int {
        switch op {
        case .input, .readWrite, .inputDup, .heredoc, .heredocTabs, .hereString:
            return 0
        default:
            return 1
        }
    }
}
