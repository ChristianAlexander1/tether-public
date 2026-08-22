import Foundation

// MARK: - Shell Builtins

/// All shell builtins as defined in the C2 spec.
/// These run in the shell's own process context (not spawned as VirtualProcesses).
public final class Builtins {
    public weak var executor: PipelineExecutor?

    public init() {}

    /// Install all builtins into the command registry.
    public func install(into registry: CommandRegistry) {
        registry.register(name: "cd") { [weak self] argv in self?.builtinCd(argv) ?? 1 }
        registry.register(name: "export") { [weak self] argv in self?.builtinExport(argv) ?? 1 }
        registry.register(name: "unset") { [weak self] argv in self?.builtinUnset(argv) ?? 1 }
        registry.register(name: "env") { [weak self] argv in self?.builtinEnv(argv) ?? 0 }
        registry.register(name: "set") { [weak self] argv in self?.builtinSet(argv) ?? 0 }
        registry.register(name: "alias") { [weak self] argv in self?.builtinAlias(argv) ?? 0 }
        registry.register(name: "unalias") { [weak self] argv in self?.builtinUnalias(argv) ?? 0 }
        registry.register(name: "history") { [weak self] argv in self?.builtinHistory(argv) ?? 0 }
        registry.register(name: "source") { [weak self] argv in self?.builtinSource(argv) ?? 1 }
        registry.register(name: ".") { [weak self] argv in self?.builtinSource(argv) ?? 1 }
        registry.register(name: "type") { [weak self] argv in self?.builtinType(argv) ?? 1 }
        registry.register(name: "which") { [weak self] argv in self?.builtinWhich(argv) ?? 1 }
        registry.register(name: "exit") { [weak self] argv in self?.builtinExit(argv) ?? 0 }
        registry.register(name: "read") { [weak self] argv in self?.builtinRead(argv) ?? 1 }
        registry.register(name: "test") { argv in Builtins.builtinTest(argv) }
        registry.register(name: "[") { argv in Builtins.builtinTest(argv) }
        registry.register(name: "printf") { argv in Builtins.builtinPrintf(argv) }
        registry.register(name: "kill") { [weak self] argv in self?.builtinKill(argv) ?? 1 }
        registry.register(name: "fg") { [weak self] argv in self?.builtinFg(argv) ?? 1 }
        registry.register(name: "bg") { [weak self] argv in self?.builtinBg(argv) ?? 1 }
        registry.register(name: "clear") { [weak self] argv in self?.builtinClear(argv) ?? 0 }
    }

    // MARK: - cd

    private func builtinCd(_ argv: [String]) -> Int32 {
        guard let state = executor?.shellState else { return 1 }
        let target: String
        if argv.count > 1 {
            target = argv[1]
        } else {
            target = state.environ["HOME"] ?? "/"
        }

        let resolved: String
        if target == "-" {
            resolved = state.environ["OLDPWD"] ?? state.cwd
        } else if target.hasPrefix("/") {
            resolved = target
        } else if target == "~" || target.hasPrefix("~/") {
            let home = state.environ["HOME"] ?? "/"
            resolved = target.replacingOccurrences(of: "~", with: home, options: [], range: target.startIndex..<target.index(target.startIndex, offsetBy: 1))
        } else {
            resolved = (state.cwd as NSString).appendingPathComponent(target)
        }

        // Normalize
        let normalized = (resolved as NSString).standardizingPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: normalized, isDirectory: &isDir), isDir.boolValue {
            state.environ["OLDPWD"] = state.cwd
            state.cwd = normalized
            state.environ["PWD"] = normalized
            return 0
        } else {
            return 1
        }
    }

    // MARK: - export

    private func builtinExport(_ argv: [String]) -> Int32 {
        guard let state = executor?.shellState else { return 1 }
        for arg in argv.dropFirst() {
            if let eqIdx = arg.firstIndex(of: "=") {
                let name = String(arg[arg.startIndex..<eqIdx])
                let value = String(arg[arg.index(after: eqIdx)...])
                state.environ[name] = value
            }
            // `export VAR` without = just marks existing var for export (no-op in our model)
        }
        return 0
    }

    // MARK: - unset

    private func builtinUnset(_ argv: [String]) -> Int32 {
        guard let state = executor?.shellState else { return 1 }
        for name in argv.dropFirst() {
            state.environ.removeValue(forKey: name)
        }
        return 0
    }

    // MARK: - env

    private func builtinEnv(_ argv: [String]) -> Int32 {
        guard let state = executor?.shellState else { return 1 }
        for (key, value) in state.environ.sorted(by: { $0.key < $1.key }) {
            _ = executor?.registry.run(SpawnRequest(cmdline: "echo \(key)=\(value)", stdinFD: -1, stdoutFD: -1, stderrFD: -1, cwd: state.cwd, environment: state.environ, interactive: false), write: { _ in })
        }
        return 0
    }

    // MARK: - set

    private func builtinSet(_ argv: [String]) -> Int32 {
        // Display all variables (same as env for our model)
        return builtinEnv(argv)
    }

    // MARK: - alias

    private func builtinAlias(_ argv: [String]) -> Int32 {
        guard let state = executor?.shellState else { return 1 }
        if argv.count <= 1 {
            // List all aliases
            return 0
        }
        for arg in argv.dropFirst() {
            if let eqIdx = arg.firstIndex(of: "=") {
                let name = String(arg[arg.startIndex..<eqIdx])
                let value = String(arg[arg.index(after: eqIdx)...])
                state.aliases[name] = value
            }
        }
        return 0
    }

    // MARK: - unalias

    private func builtinUnalias(_ argv: [String]) -> Int32 {
        guard let state = executor?.shellState else { return 1 }
        for name in argv.dropFirst() {
            if name == "-a" { state.aliases.removeAll(); return 0 }
            state.aliases.removeValue(forKey: name)
        }
        return 0
    }

    // MARK: - history

    private func builtinHistory(_ argv: [String]) -> Int32 {
        guard let state = executor?.shellState else { return 1 }
        if argv.count > 1, let count = Int(argv[1]) {
            let start = max(0, state.history.count - count)
            for (i, line) in state.history[start...].enumerated() {
                _ = "\(start + i + 1)  \(line)\n"
            }
        }
        return 0
    }

    // MARK: - source / .

    private func builtinSource(_ argv: [String]) -> Int32 {
        guard argv.count > 1, let executor else { return 1 }
        let path: String
        if argv[1].hasPrefix("/") {
            path = argv[1]
        } else {
            path = (executor.shellState.cwd as NSString).appendingPathComponent(argv[1])
        }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return 1 }
        let lines = content.components(separatedBy: "\n")
        var lastCode: Int32 = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if let ast = ShellParser.parse(trimmed) {
                lastCode = executor.execute(ast)
            }
        }
        return lastCode
    }

    // MARK: - type

    private func builtinType(_ argv: [String]) -> Int32 {
        guard argv.count > 1, let executor else { return 1 }
        let name = argv[1]
        let builtinNames = ["cd", "export", "unset", "env", "set", "alias", "unalias",
                           "history", "source", ".", "type", "which", "exit", "read",
                           "test", "[", "printf", "kill", "fg", "bg", "clear",
                           "echo", "pwd", "jobs", "true", "false"]
        if builtinNames.contains(name) {
            return 0
        }
        if executor.registry.entry(for: name) != nil {
            return 0
        }
        return 1
    }

    // MARK: - which

    private func builtinWhich(_ argv: [String]) -> Int32 {
        return builtinType(argv)
    }

    // MARK: - exit

    private func builtinExit(_ argv: [String]) -> Int32 {
        if argv.count > 1, let code = Int32(argv[1]) { return code }
        return 0
    }

    // MARK: - read

    private func builtinRead(_ argv: [String]) -> Int32 {
        guard let state = executor?.shellState else { return 1 }
        let varName = argv.count > 1 ? argv[1] : "REPLY"
        // Read one line from stdin (simplified — real impl would read from stdinFD)
        guard let line = readLine(strippingNewline: true) else { return 1 }
        state.environ[varName] = line
        return 0
    }

    // MARK: - test / [

    static func builtinTest(_ argv: [String]) -> Int32 {
        var args = Array(argv.dropFirst())
        // Remove trailing ] if [ was the command
        if argv.first == "[" {
            if args.last == "]" { args.removeLast() }
        }

        guard !args.isEmpty else { return 1 } // empty test is false

        func resolve(_ path: String) -> String {
            if path.hasPrefix("/") { return path }
            let cwd = ProcessContext.current?.cwd ?? FileManager.default.currentDirectoryPath
            return (cwd as NSString).appendingPathComponent(path)
        }

        // Unary tests
        if args.count == 1 { return args[0].isEmpty ? 1 : 0 } // -n implied

        if args.count == 2 {
            let op = args[0]
            let operand = resolve(args[1])
            switch op {
            case "-z": return args[1].isEmpty ? 0 : 1
            case "-n": return args[1].isEmpty ? 1 : 0
            case "-f": return FileManager.default.fileExists(atPath: operand) ? 0 : 1
            case "-d":
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: operand, isDirectory: &isDir) && isDir.boolValue ? 0 : 1
            case "-e": return FileManager.default.fileExists(atPath: operand) ? 0 : 1
            case "-r": return FileManager.default.isReadableFile(atPath: operand) ? 0 : 1
            case "-w": return FileManager.default.isWritableFile(atPath: operand) ? 0 : 1
            case "-x": return FileManager.default.isExecutableFile(atPath: operand) ? 0 : 1
            case "-s":
                let attrs = try? FileManager.default.attributesOfItem(atPath: operand)
                let size = attrs?[.size] as? Int ?? 0
                return size > 0 ? 0 : 1
            case "!": return args[1].isEmpty ? 0 : 1
            default: break
            }
        }

        // Binary tests
        if args.count == 3 {
            let left = args[0], op = args[1], right = args[2]
            switch op {
            case "=", "==": return left == right ? 0 : 1
            case "!=": return left != right ? 0 : 1
            case "-eq": return (Int(left) ?? 0) == (Int(right) ?? 0) ? 0 : 1
            case "-ne": return (Int(left) ?? 0) != (Int(right) ?? 0) ? 0 : 1
            case "-lt": return (Int(left) ?? 0) < (Int(right) ?? 0) ? 0 : 1
            case "-le": return (Int(left) ?? 0) <= (Int(right) ?? 0) ? 0 : 1
            case "-gt": return (Int(left) ?? 0) > (Int(right) ?? 0) ? 0 : 1
            case "-ge": return (Int(left) ?? 0) >= (Int(right) ?? 0) ? 0 : 1
            default: break
            }
        }

        return 1
    }

    // MARK: - printf

    static func builtinPrintf(_ argv: [String]) -> Int32 {
        guard argv.count > 1 else { return 1 }
        let format = argv[1]
        let args = Array(argv.dropFirst(2))
        var result = ""
        var argIdx = 0
        let chars = Array(format)
        var i = 0

        while i < chars.count {
            if chars[i] == "\\" && i + 1 < chars.count {
                i += 1
                switch chars[i] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                default: result.append("\\"); result.append(chars[i])
                }
                i += 1
                continue
            }

            if chars[i] == "%" && i + 1 < chars.count {
                i += 1
                switch chars[i] {
                case "s":
                    result.append(argIdx < args.count ? args[argIdx] : "")
                    argIdx += 1
                case "d":
                    result.append(argIdx < args.count ? String(Int(args[argIdx]) ?? 0) : "0")
                    argIdx += 1
                case "%":
                    result.append("%")
                default:
                    result.append("%"); result.append(chars[i])
                }
                i += 1
                continue
            }

            result.append(chars[i])
            i += 1
        }

        // Emit the formatted text: nothing else writes it.
        if let proc = ProcessContext.current {
            proc.writeStdout(result)
        } else {
            print(result, terminator: "")
        }
        return 0
    }

    // MARK: - kill

    private func builtinKill(_ argv: [String]) -> Int32 {
        guard let executor else { return 1 }
        var sig: Int32 = 15 // SIGTERM default
        var targets: [String] = []

        var i = 1
        while i < argv.count {
            if argv[i].hasPrefix("-") && argv[i].count > 1 {
                let sigStr = String(argv[i].dropFirst())
                if let sigNum = Int32(sigStr) { sig = sigNum }
                else if sigStr == "INT" { sig = 2 }
                else if sigStr == "TERM" { sig = 15 }
                else if sigStr == "KILL" { sig = 9 }
                else if sigStr == "WINCH" { sig = 28 }
            } else {
                targets.append(argv[i])
            }
            i += 1
        }

        for target in targets {
            if target.hasPrefix("%"), let jobID = Int(target.dropFirst()) {
                // Job-based kill
                if let job = executor.jobs.all().first(where: { $0.id == jobID }) {
                    _ = executor.processTable.signal(job.pid, sig)
                }
            } else if let pid = TermXPID(target) {
                _ = executor.processTable.signal(pid, sig)
            }
        }
        return 0
    }

    // MARK: - fg / bg

    private func builtinFg(_ argv: [String]) -> Int32 {
        // Simplified: just report the job
        guard let executor else { return 1 }
        let runningJobs = executor.jobs.all().filter(\.running)
        guard !runningJobs.isEmpty else { return 1 }
        return 0
    }

    private func builtinBg(_ argv: [String]) -> Int32 {
        return builtinFg(argv) // Simplified
    }

    // MARK: - clear

    private func builtinClear(_ argv: [String]) -> Int32 {
        return 0 // The \e[2J\e[H sequence is sent by the write callback
    }
}
