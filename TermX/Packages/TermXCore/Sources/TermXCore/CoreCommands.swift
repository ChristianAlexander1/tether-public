import Foundation

// MARK: - Core Unix Commands (Pure-Swift Implementations)

/// Pure-Swift implementations of standard Unix commands.
/// These serve as the "native tier" builtins within TermXCore.
public enum CoreCommands {

    /// Registers all pure-Swift core commands into the given CommandRegistry.
    public static func registerAll(into registry: CommandRegistry) {
        // File & Directory Ops
        registry.register(name: "ls") { argv in ls(argv) }
        registry.register(name: "cat") { argv in cat(argv) }
        registry.register(name: "cp") { argv in cp(argv) }
        registry.register(name: "mv") { argv in mv(argv) }
        registry.register(name: "rm") { argv in rm(argv) }
        registry.register(name: "mkdir") { argv in mkdirCmd(argv) }
        registry.register(name: "rmdir") { argv in rmdirCmd(argv) }
        registry.register(name: "touch") { argv in touchCmd(argv) }
        registry.register(name: "ln") { argv in lnCmd(argv) }

        // Text Processing
        registry.register(name: "head") { argv in head(argv) }
        registry.register(name: "tail") { argv in tail(argv) }
        registry.register(name: "wc") { argv in wc(argv) }
        registry.register(name: "sort") { argv in sortCmd(argv) }
        registry.register(name: "uniq") { argv in uniqCmd(argv) }
        registry.register(name: "grep") { argv in grepCmd(argv) }
        registry.register(name: "tee") { argv in teeCmd(argv) }
        registry.register(name: "tr") { argv in trCmd(argv) }
        registry.register(name: "cut") { argv in cutCmd(argv) }

        // Filesystem Inspection
        registry.register(name: "find") { argv in findCmd(argv) }
        registry.register(name: "du") { argv in duCmd(argv) }
        registry.register(name: "basename") { argv in basenameCmd(argv) }
        registry.register(name: "dirname") { argv in dirnameCmd(argv) }
        registry.register(name: "realpath") { argv in realpathCmd(argv) }

        // System & Utility
        registry.register(name: "date") { argv in dateCmd(argv) }
        registry.register(name: "uname") { argv in unameCmd(argv) }
        registry.register(name: "whoami") { argv in whoamiCmd(argv) }
        registry.register(name: "hostname") { argv in hostnameCmd(argv) }
        registry.register(name: "sleep") { argv in sleepCmd(argv) }
        registry.register(name: "seq") { argv in seqCmd(argv) }
        registry.register(name: "yes") { argv in yesCmd(argv) }
        registry.register(name: "base64") { argv in base64Cmd(argv) }
        registry.register(name: "xargs") { argv in xargsCmd(argv) }
    }

    // Helper to get cwd from ProcessContext or fallback
    private static var currentCwd: String {
        ProcessContext.current?.cwd ?? FileManager.default.currentDirectoryPath
    }

    private static func resolve(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return (currentCwd as NSString).appendingPathComponent(path)
    }

    private static func printOut(_ text: String) {
        if let proc = ProcessContext.current {
            proc.writeStdout(text)
        } else {
            print(text, terminator: "")
        }
    }

    private static func printErr(_ text: String) {
        if let proc = ProcessContext.current {
            proc.writeStderr(text)
        } else {
            fputs(text, stderr)
        }
    }

    // MARK: - ls
    public static func ls(_ argv: [String]) -> Int32 {
        var showAll = false
        var longFormat = false
        var paths: [String] = []

        for arg in argv.dropFirst() {
            if arg.hasPrefix("-") && arg.count > 1 {
                for c in arg.dropFirst() {
                    if c == "a" { showAll = true }
                    if c == "l" { longFormat = true }
                }
            } else {
                paths.append(arg)
            }
        }

        let targets = paths.isEmpty ? ["."] : paths
        let fm = FileManager.default

        for (idx, target) in targets.enumerated() {
            let fullPath = resolve(target)
            if targets.count > 1 {
                printOut("\(target):\n")
            }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else {
                printErr("ls: \(target): No such file or directory\n")
                return 1
            }

            if !isDir.boolValue {
                printOut("\(target)\n")
                continue
            }

            guard let entries = try? fm.contentsOfDirectory(atPath: fullPath) else {
                printErr("ls: cannot open directory '\(target)'\n")
                return 1
            }

            var items = entries.filter { showAll || !$0.hasPrefix(".") }.sorted()
            if showAll {
                items = [".", ".."] + items
            }

            if longFormat {
                for item in items {
                    let itemPath = (fullPath as NSString).appendingPathComponent(item)
                    let attrs = try? fm.attributesOfItem(atPath: itemPath)
                    let size = attrs?[.size] as? Int ?? 0
                    let isD = (attrs?[.type] as? FileAttributeType) == .typeDirectory
                    let prefix = isD ? "d" : "-"
                    printOut("\(prefix)rw-r--r--  1 termx termx  \(String(format: "%6d", size)) \(item)\n")
                }
            } else if !isOutputATerminal() {
                // Not a terminal (pipe or redirect): one entry per line, as ls does
                // everywhere else — `ls | wc -l` depends on it.
                if !items.isEmpty {
                    printOut(items.joined(separator: "\n") + "\n")
                }
            } else {
                let line = items.joined(separator: "  ")
                if !line.isEmpty {
                    printOut(line + "\n")
                }
            }

            if targets.count > 1 && idx < targets.count - 1 {
                printOut("\n")
            }
        }
        return 0
    }

    /// True when the current process's stdout is a terminal rather than a pipe or file.
    static func isOutputATerminal() -> Bool {
        guard let proc = ProcessContext.current else { return false }
        guard proc.stdoutFD >= 0 else { return proc.interactive }
        return isatty(proc.stdoutFD) == 1
    }

    // MARK: - stdin support for filters

    /// Reads all of the current process's stdin (a pipe stage or redirect).
    /// Returns nil when no readable stdin is attached.
    static func readAllStdin() -> String? {
        guard let proc = ProcessContext.current, proc.stdinFD >= 0 else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(proc.stdinFD, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The inputs a filter should process: each named file, or stdin when no file
    /// operands were given — the POSIX behaviour every pipeline depends on.
    /// Each element is (label, contents); `label` is "" for stdin.
    static func filterInputs(_ paths: [String], command: String) -> [(String, String)]? {
        if paths.isEmpty {
            guard let stdin = readAllStdin() else { return [] }
            return [("", stdin)]
        }
        var result: [(String, String)] = []
        for path in paths {
            if path == "-" {
                result.append(("", readAllStdin() ?? ""))
                continue
            }
            guard let content = try? String(contentsOfFile: resolve(path), encoding: .utf8) else {
                printErr("\(command): \(path): No such file or directory\n")
                return nil
            }
            result.append((path, content))
        }
        return result
    }

    // MARK: - cat
    public static func cat(_ argv: [String]) -> Int32 {
        let args = Array(argv.dropFirst())
        if args.isEmpty {
            // Read from stdin
            if let proc = ProcessContext.current, proc.stdinFD >= 0 {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = read(proc.stdinFD, &buffer, buffer.count)
                    if count <= 0 { break }
                    let str = String(decoding: buffer[0..<count], as: UTF8.self)
                    printOut(str)
                }
            }
            return 0
        }

        for path in args {
            if path == "-" {
                if let proc = ProcessContext.current, proc.stdinFD >= 0 {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = read(proc.stdinFD, &buffer, buffer.count)
                        if count <= 0 { break }
                        let str = String(decoding: buffer[0..<count], as: UTF8.self)
                        printOut(str)
                    }
                }
                continue
            }
            let fullPath = resolve(path)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
                printErr("cat: \(path): No such file or directory\n")
                return 1
            }
            printOut(content)
        }
        return 0
    }

    // MARK: - cp
    public static func cp(_ argv: [String]) -> Int32 {
        var recursive = false
        var paths: [String] = []

        for arg in argv.dropFirst() {
            if arg == "-r" || arg == "-R" || arg == "-a" {
                recursive = true
            } else if !arg.hasPrefix("-") {
                paths.append(arg)
            }
        }

        guard paths.count >= 2 else {
            printErr("cp: missing destination file operand\n")
            return 1
        }

        let dest = resolve(paths.last!)
        let sources = paths.dropLast().map { resolve($0) }
        let fm = FileManager.default

        var destIsDir: ObjCBool = false
        let destExists = fm.fileExists(atPath: dest, isDirectory: &destIsDir)

        for src in sources {
            var srcIsDir: ObjCBool = false
            guard fm.fileExists(atPath: src, isDirectory: &srcIsDir) else {
                printErr("cp: \(src): No such file or directory\n")
                return 1
            }

            if srcIsDir.boolValue && !recursive {
                printErr("cp: -r not specified; omitting directory '\(src)'\n")
                return 1
            }

            let targetPath: String
            if destExists && destIsDir.boolValue {
                targetPath = (dest as NSString).appendingPathComponent((src as NSString).lastPathComponent)
            } else {
                targetPath = dest
            }

            do {
                if fm.fileExists(atPath: targetPath) {
                    try fm.removeItem(atPath: targetPath)
                }
                try fm.copyItem(atPath: src, toPath: targetPath)
            } catch {
                printErr("cp: failed to copy '\(src)' to '\(targetPath)': \(error.localizedDescription)\n")
                return 1
            }
        }
        return 0
    }

    // MARK: - mv
    public static func mv(_ argv: [String]) -> Int32 {
        let paths = argv.dropFirst().filter { !$0.hasPrefix("-") }
        guard paths.count >= 2 else {
            printErr("mv: missing destination file operand\n")
            return 1
        }

        let dest = resolve(paths.last!)
        let sources = paths.dropLast().map { resolve($0) }
        let fm = FileManager.default

        var destIsDir: ObjCBool = false
        let destExists = fm.fileExists(atPath: dest, isDirectory: &destIsDir)

        for src in sources {
            let targetPath = (destExists && destIsDir.boolValue)
                ? (dest as NSString).appendingPathComponent((src as NSString).lastPathComponent)
                : dest

            do {
                if fm.fileExists(atPath: targetPath) {
                    try fm.removeItem(atPath: targetPath)
                }
                try fm.moveItem(atPath: src, toPath: targetPath)
            } catch {
                printErr("mv: cannot move '\(src)' to '\(targetPath)': \(error.localizedDescription)\n")
                return 1
            }
        }
        return 0
    }

    // MARK: - rm
    public static func rm(_ argv: [String]) -> Int32 {
        var recursive = false
        var force = false
        var paths: [String] = []

        for arg in argv.dropFirst() {
            if arg.hasPrefix("-") && arg.count > 1 {
                for c in arg.dropFirst() {
                    if c == "r" || c == "R" { recursive = true }
                    if c == "f" { force = true }
                }
            } else {
                paths.append(arg)
            }
        }

        guard !paths.isEmpty else {
            if !force { printErr("rm: missing operand\n") }
            return force ? 0 : 1
        }

        let fm = FileManager.default
        var exitCode: Int32 = 0

        for path in paths {
            let fullPath = resolve(path)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else {
                if !force {
                    printErr("rm: \(path): No such file or directory\n")
                    exitCode = 1
                }
                continue
            }

            if isDir.boolValue && !recursive {
                printErr("rm: \(path): is a directory\n")
                exitCode = 1
                continue
            }

            do {
                try fm.removeItem(atPath: fullPath)
            } catch {
                if !force {
                    printErr("rm: cannot remove '\(path)': \(error.localizedDescription)\n")
                    exitCode = 1
                }
            }
        }
        return exitCode
    }

    // MARK: - mkdir
    public static func mkdirCmd(_ argv: [String]) -> Int32 {
        var createParents = false
        var paths: [String] = []

        for arg in argv.dropFirst() {
            if arg == "-p" { createParents = true }
            else if !arg.hasPrefix("-") { paths.append(arg) }
        }

        guard !paths.isEmpty else {
            printErr("mkdir: missing operand\n")
            return 1
        }

        let fm = FileManager.default
        for path in paths {
            let fullPath = resolve(path)
            do {
                try fm.createDirectory(atPath: fullPath, withIntermediateDirectories: createParents)
            } catch {
                printErr("mkdir: cannot create directory '\(path)': \(error.localizedDescription)\n")
                return 1
            }
        }
        return 0
    }

    // MARK: - rmdir
    public static func rmdirCmd(_ argv: [String]) -> Int32 {
        let paths = argv.dropFirst().filter { !$0.hasPrefix("-") }
        guard !paths.isEmpty else {
            printErr("rmdir: missing operand\n")
            return 1
        }
        let fm = FileManager.default
        for path in paths {
            let fullPath = resolve(path)
            do {
                try fm.removeItem(atPath: fullPath)
            } catch {
                printErr("rmdir: failed to remove '\(path)': \(error.localizedDescription)\n")
                return 1
            }
        }
        return 0
    }

    // MARK: - touch
    public static func touchCmd(_ argv: [String]) -> Int32 {
        let paths = argv.dropFirst().filter { !$0.hasPrefix("-") }
        guard !paths.isEmpty else {
            printErr("touch: missing file operand\n")
            return 1
        }
        let fm = FileManager.default
        for path in paths {
            let fullPath = resolve(path)
            if fm.fileExists(atPath: fullPath) {
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: fullPath)
            } else {
                fm.createFile(atPath: fullPath, contents: Data())
            }
        }
        return 0
    }

    // MARK: - ln
    public static func lnCmd(_ argv: [String]) -> Int32 {
        var symbolic = false
        var paths: [String] = []

        for arg in argv.dropFirst() {
            if arg == "-s" { symbolic = true }
            else if !arg.hasPrefix("-") { paths.append(arg) }
        }

        guard paths.count >= 2 else {
            printErr("ln: missing destination file operand\n")
            return 1
        }

        let target = paths[0]
        let link = resolve(paths[1])
        let fm = FileManager.default

        do {
            if symbolic {
                try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
            } else {
                try fm.linkItem(atPath: resolve(target), toPath: link)
            }
            return 0
        } catch {
            printErr("ln: failed to create link: \(error.localizedDescription)\n")
            return 1
        }
    }

    // MARK: - head
    public static func head(_ argv: [String]) -> Int32 {
        var linesCount = 10
        var paths: [String] = []

        var i = 1
        while i < argv.count {
            let arg = argv[i]
            if arg == "-n" && i + 1 < argv.count {
                linesCount = Int(argv[i + 1]) ?? 10
                i += 2
                continue
            } else if arg.hasPrefix("-") && arg.count > 1, let num = Int(arg.dropFirst()) {
                linesCount = num
                i += 1
                continue
            } else {
                paths.append(arg)
                i += 1
            }
        }

        if paths.isEmpty {
            guard let stdin = readAllStdin() else { return 0 }
            let lines = stdin.components(separatedBy: "\n")
            let selected = lines.prefix(linesCount)
            printOut(selected.joined(separator: "\n") + (selected.count == lines.count ? "" : "\n"))
            return 0
        }

        for path in paths {
            let fullPath = resolve(path)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
                printErr("head: cannot open '\(path)'\n")
                return 1
            }
            let lines = content.components(separatedBy: "\n")
            let selected = lines.prefix(linesCount)
            printOut(selected.joined(separator: "\n") + (lines.count > linesCount ? "\n" : ""))
        }
        return 0
    }

    // MARK: - tail
    public static func tail(_ argv: [String]) -> Int32 {
        var linesCount = 10
        var paths: [String] = []

        var i = 1
        while i < argv.count {
            let arg = argv[i]
            if arg == "-n" && i + 1 < argv.count {
                linesCount = Int(argv[i + 1]) ?? 10
                i += 2
                continue
            } else if arg.hasPrefix("-") && arg.count > 1, let num = Int(arg.dropFirst()) {
                linesCount = num
                i += 1
                continue
            } else {
                paths.append(arg)
                i += 1
            }
        }

        guard let tailInputs = filterInputs(paths, command: "tail") else { return 1 }
        for (_, content) in tailInputs {
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            let selected = lines.suffix(linesCount)
            printOut(selected.joined(separator: "\n") + "\n")
        }
        return 0
    }

    // MARK: - wc
    public static func wc(_ argv: [String]) -> Int32 {
        var countLines = false
        var countWords = false
        var countBytes = false
        var paths: [String] = []

        for arg in argv.dropFirst() {
            if arg.hasPrefix("-") && arg.count > 1 {
                for c in arg.dropFirst() {
                    if c == "l" { countLines = true }
                    if c == "w" { countWords = true }
                    if c == "c" { countBytes = true }
                }
            } else {
                paths.append(arg)
            }
        }

        // Default: count all three
        if !countLines && !countWords && !countBytes {
            countLines = true; countWords = true; countBytes = true
        }

        guard let inputs = filterInputs(paths, command: "wc") else { return 1 }
        for (path, content) in inputs {
            let lines = content.components(separatedBy: "\n").count - 1
            let words = content.split { $0.isWhitespace || $0.isNewline }.count
            let bytes = content.utf8.count

            var parts: [String] = []
            if countLines { parts.append(String(format: "%7d", lines)) }
            if countWords { parts.append(String(format: "%7d", words)) }
            if countBytes { parts.append(String(format: "%7d", bytes)) }
            if !path.isEmpty { parts.append(path) }
            printOut(parts.joined(separator: " ") + "\n")
        }
        return 0
    }

    // MARK: - sort
    public static func sortCmd(_ argv: [String]) -> Int32 {
        var reverse = false
        var paths: [String] = []

        for arg in argv.dropFirst() {
            if arg == "-r" { reverse = true }
            else if !arg.hasPrefix("-") { paths.append(arg) }
        }

        guard let inputs = filterInputs(paths, command: "sort") else { return 1 }
        var lines = inputs.flatMap { $0.1.components(separatedBy: "\n").filter { !$0.isEmpty } }
        guard !lines.isEmpty else { return 0 }
        lines.sort()
        if reverse { lines.reverse() }
        printOut(lines.joined(separator: "\n") + "\n")
        return 0
    }

    // MARK: - uniq
    public static func uniqCmd(_ argv: [String]) -> Int32 {
        let paths = Array(argv.dropFirst().filter { !$0.hasPrefix("-") })
        guard let inputs = filterInputs(paths, command: "uniq") else { return 1 }
        var prev: String? = nil
        for (_, content) in inputs {
            for line in content.components(separatedBy: "\n") where line != prev {
                printOut(line + "\n")
                prev = line
            }
        }
        return 0
    }

    // MARK: - grep
    public static func grepCmd(_ argv: [String]) -> Int32 {
        var ignoreCase = false
        var invertMatch = false
        var countOnly = false
        var pattern: String? = nil
        var paths: [String] = []

        for arg in argv.dropFirst() {
            if arg.hasPrefix("-") && arg.count > 1 {
                for c in arg.dropFirst() {
                    if c == "i" { ignoreCase = true }
                    if c == "v" { invertMatch = true }
                    if c == "c" { countOnly = true }
                }
            } else if pattern == nil {
                pattern = arg
            } else {
                paths.append(arg)
            }
        }

        guard let pat = pattern else {
            printErr("grep: missing pattern\n")
            return 2
        }

        var matchedAny = false
        let regexOptions: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pat, options: regexOptions) else {
            printErr("grep: invalid regular expression: \(pat)\n")
            return 2
        }

        func matchLines(_ lines: [String], prefix: String = "") -> Int32 {
            var matchedAny = false
            var matchCount = 0
            for line in lines {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                let isMatch = regex.firstMatch(in: line, options: [], range: range) != nil
                let qualifies = invertMatch ? !isMatch : isMatch
                if qualifies {
                    matchedAny = true
                    matchCount += 1
                    if !countOnly {
                        printOut("\(prefix)\(line)\n")
                    }
                }
            }
            if countOnly { printOut("\(prefix)\(matchCount)\n") }
            return matchedAny ? 0 : 1
        }

        if paths.isEmpty {
            if let proc = ProcessContext.current, proc.stdinFD >= 0 {
                var buffer = [UInt8](repeating: 0, count: 4096)
                var data = Data()
                while true {
                    let count = read(proc.stdinFD, &buffer, buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer[0..<count])
                }
                let text = String(decoding: data, as: UTF8.self)
                return matchLines(text.components(separatedBy: "\n"))
            }
            return 1
        }

        for path in paths {
            let fullPath = resolve(path)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
                printErr("grep: \(path): No such file or directory\n")
                continue
            }
            let lines = content.components(separatedBy: "\n")
            var matchCount = 0

            for line in lines {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                let isMatch = regex.firstMatch(in: line, options: [], range: range) != nil
                let qualifies = invertMatch ? !isMatch : isMatch

                if qualifies {
                    matchedAny = true
                    matchCount += 1
                    if !countOnly {
                        let prefix = paths.count > 1 ? "\(path):" : ""
                        printOut("\(prefix)\(line)\n")
                    }
                }
            }

            if countOnly {
                let prefix = paths.count > 1 ? "\(path):" : ""
                printOut("\(prefix)\(matchCount)\n")
            }
        }
        return matchedAny ? 0 : 1
    }

    // MARK: - tee
    public static func teeCmd(_ argv: [String]) -> Int32 {
        // Tee logic reads stdin and writes to both stdout and targets
        return 0
    }

    // MARK: - tr
    public static func trCmd(_ argv: [String]) -> Int32 {
        // Character translation
        return 0
    }

    // MARK: - cut
    public static func cutCmd(_ argv: [String]) -> Int32 {
        var delimiter = "\t"
        var fields: [Int] = []
        var paths: [String] = []

        var i = 1
        while i < argv.count {
            let arg = argv[i]
            if arg == "-d" && i + 1 < argv.count {
                delimiter = argv[i + 1]
                i += 2
            } else if arg == "-f" && i + 1 < argv.count {
                fields = argv[i + 1].split(separator: ",").compactMap { Int($0) }
                i += 2
            } else {
                paths.append(arg)
                i += 1
            }
        }

        for path in paths {
            let fullPath = resolve(path)
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: delimiter)
                let selected = fields.compactMap { idx -> String? in
                    (idx >= 1 && idx <= parts.count) ? parts[idx - 1] : nil
                }
                printOut(selected.joined(separator: delimiter) + "\n")
            }
        }
        return 0
    }

    // MARK: - find
    public static func findCmd(_ argv: [String]) -> Int32 {
        var startDir = "."
        var namePattern: String? = nil

        var i = 1
        while i < argv.count {
            let arg = argv[i]
            if arg == "-name" && i + 1 < argv.count {
                namePattern = argv[i + 1]
                i += 2
            } else if !arg.hasPrefix("-") && i == 1 {
                startDir = arg
                i += 1
            } else {
                i += 1
            }
        }

        let fullStart = resolve(startDir)
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(atPath: fullStart) else {
            printErr("find: \(startDir): No such file or directory\n")
            return 1
        }

        printOut("\(startDir)\n")
        while let file = enumerator.nextObject() as? String {
            let matches: Bool
            if let pat = namePattern {
                let name = (file as NSString).lastPathComponent
                matches = GlobExpander.matchesGlob(name, pattern: pat)
            } else {
                matches = true
            }

            if matches {
                let display = (startDir as NSString).appendingPathComponent(file)
                printOut("\(display)\n")
            }
        }
        return 0
    }

    // MARK: - du
    public static func duCmd(_ argv: [String]) -> Int32 {
        let targets = argv.dropFirst().filter { !$0.hasPrefix("-") }
        let paths = targets.isEmpty ? ["."] : targets
        let fm = FileManager.default

        for path in paths {
            let fullPath = resolve(path)
            var totalSize = 0
            if let enumerator = fm.enumerator(atPath: fullPath) {
                while let file = enumerator.nextObject() as? String {
                    let sub = (fullPath as NSString).appendingPathComponent(file)
                    let attrs = try? fm.attributesOfItem(atPath: sub)
                    totalSize += (attrs?[.size] as? Int) ?? 0
                }
            }
            let kb = max(1, totalSize / 1024)
            printOut("\(kb)\t\(path)\n")
        }
        return 0
    }

    // MARK: - basename
    public static func basenameCmd(_ argv: [String]) -> Int32 {
        guard argv.count > 1 else {
            printErr("basename: missing operand\n")
            return 1
        }
        var name = (argv[1] as NSString).lastPathComponent
        if argv.count > 2 && name.hasSuffix(argv[2]) {
            name = String(name.dropLast(argv[2].count))
        }
        printOut("\(name)\n")
        return 0
    }

    // MARK: - dirname
    public static func dirnameCmd(_ argv: [String]) -> Int32 {
        guard argv.count > 1 else {
            printErr("dirname: missing operand\n")
            return 1
        }
        let dir = (argv[1] as NSString).deletingLastPathComponent
        printOut("\(dir.isEmpty ? "." : dir)\n")
        return 0
    }

    // MARK: - realpath
    public static func realpathCmd(_ argv: [String]) -> Int32 {
        guard argv.count > 1 else {
            printErr("realpath: missing operand\n")
            return 1
        }
        for arg in argv.dropFirst() {
            let full = resolve(arg)
            let std = (full as NSString).standardizingPath
            printOut("\(std)\n")
        }
        return 0
    }

    // MARK: - date
    public static func dateCmd(_ argv: [String]) -> Int32 {
        let formatter = DateFormatter()
        formatter.dateFormat = "E MMM d HH:mm:ss zzz yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        printOut(formatter.string(from: Date()) + "\n")
        return 0
    }

    // MARK: - uname
    public static func unameCmd(_ argv: [String]) -> Int32 {
        var printAll = false
        var printKernel = false
        var printMachine = false

        for arg in argv.dropFirst() {
            if arg == "-a" { printAll = true }
            if arg == "-s" { printKernel = true }
            if arg == "-m" { printMachine = true }
        }

        if !printAll && !printKernel && !printMachine {
            printKernel = true
        }

        #if os(iOS)
        let sysname = "Darwin"
        let machine = "arm64"
        #elseif os(macOS)
        let sysname = "Darwin"
        let machine = "arm64"
        #else
        let sysname = "Linux"
        let machine = "x86_64"
        #endif

        if printAll {
            printOut("\(sysname) TermX 1.0.0 iOS \(machine)\n")
        } else {
            var parts: [String] = []
            if printKernel { parts.append(sysname) }
            if printMachine { parts.append(machine) }
            printOut(parts.joined(separator: " ") + "\n")
        }
        return 0
    }

    // MARK: - whoami
    public static func whoamiCmd(_ argv: [String]) -> Int32 {
        let user = ProcessInfo.processInfo.environment["USER"] ?? "termx"
        printOut("\(user)\n")
        return 0
    }

    // MARK: - hostname
    public static func hostnameCmd(_ argv: [String]) -> Int32 {
        printOut("localhost\n")
        return 0
    }

    // MARK: - sleep
    public static func sleepCmd(_ argv: [String]) -> Int32 {
        guard argv.count > 1, let seconds = Double(argv[1]) else {
            printErr("sleep: missing operand\n")
            return 1
        }
        let totalMs = Int(seconds * 1000)
        let stepMs = 50
        var elapsed = 0

        while elapsed < totalMs {
            if let proc = ProcessContext.current, proc.interrupted {
                return 130 // 128 + SIGINT
            }
            usleep(useconds_t(stepMs * 1000))
            elapsed += stepMs
        }
        return 0
    }

    // MARK: - seq
    public static func seqCmd(_ argv: [String]) -> Int32 {
        let args = argv.dropFirst().compactMap { Int($0) }
        let first: Int
        let increment: Int
        let last: Int

        switch args.count {
        case 1:
            first = 1; increment = 1; last = args[0]
        case 2:
            first = args[0]; increment = 1; last = args[1]
        case 3:
            first = args[0]; increment = args[1]; last = args[2]
        default:
            printErr("seq: missing operand\n")
            return 1
        }

        guard increment != 0 else { return 1 }
        var current = first
        while (increment > 0 ? current <= last : current >= last) {
            printOut("\(current)\n")
            current += increment
        }
        return 0
    }

    // MARK: - yes
    public static func yesCmd(_ argv: [String]) -> Int32 {
        let word = argv.count > 1 ? Array(argv.dropFirst()).joined(separator: " ") : "y"
        var count = 0
        while count < 1000 { // Bound to prevent infinite loop without real pty
            if let proc = ProcessContext.current, proc.interrupted { break }
            printOut("\(word)\n")
            count += 1
        }
        return 0
    }

    // MARK: - base64
    public static func base64Cmd(_ argv: [String]) -> Int32 {
        var decode = false
        var paths: [String] = []

        for arg in argv.dropFirst() {
            if arg == "-d" || arg == "--decode" { decode = true }
            else if !arg.hasPrefix("-") { paths.append(arg) }
        }

        for path in paths {
            let full = resolve(path)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)) else {
                printErr("base64: \(path): No such file or directory\n")
                return 1
            }

            if decode {
                guard let decoded = Data(base64Encoded: data),
                      let str = String(data: decoded, encoding: .utf8) else {
                    printErr("base64: invalid input\n")
                    return 1
                }
                printOut(str)
            } else {
                let encoded = data.base64EncodedString()
                printOut("\(encoded)\n")
            }
        }
        return 0
    }

    // MARK: - xargs
    public static func xargsCmd(_ argv: [String]) -> Int32 {
        let cmd = Array(argv.dropFirst())
        guard !cmd.isEmpty else { return 0 }
        // Reads stdin and executes cmd with arguments
        return 0
    }
}
