import Foundation

// MARK: - rg / jq / fd Pure-Swift Fallbacks
//
// Native Rust/C ports (ios_system xcframework) are deferred to integrator cross-compilation.
// These implementations satisfy C2 acceptance tests and docs/07-appstore-licensing.md (MIT).

public enum ToolCommands {

    public static func registerAll(into registry: CommandRegistry) {
        registry.register(name: "rg") { argv in rgCmd(argv) }
        registry.register(name: "jq") { argv in jqCmd(argv) }
        registry.register(name: "fd") { argv in fdCmd(argv) }
    }

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

    private static func readStdinLines() -> [String] {
        guard let proc = ProcessContext.current, proc.stdinFD >= 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let count = read(proc.stdinFD, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: "\n")
    }

    // MARK: - rg (ripgrep-style recursive grep)

    public static func rgCmd(_ argv: [String]) -> Int32 {
        var ignoreCase = false
        var filesOnly = false
        var pattern: String? = nil
        var roots: [String] = ["."]

        var i = 1
        while i < argv.count {
            let arg = argv[i]
            if arg == "--" {
                i += 1
                if i < argv.count { roots = Array(argv[i...]) }
                break
            } else if arg.hasPrefix("-") && arg.count > 1 {
                for c in arg.dropFirst() {
                    if c == "i" { ignoreCase = true }
                    if c == "l" { filesOnly = true }
                }
            } else if pattern == nil {
                pattern = arg
            } else {
                roots = [arg]
                if i + 1 < argv.count { roots.append(contentsOf: argv[(i + 1)...]) }
                break
            }
            i += 1
        }

        guard let pat = pattern else {
            printErr("rg: missing pattern\n")
            return 2
        }

        let options: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pat, options: options) else {
            printErr("rg: invalid regex: \(pat)\n")
            return 2
        }

        var matchedAny = false
        for root in roots {
            let fullRoot = resolve(root)
            walkFiles(at: fullRoot) { filePath in
                guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }
                var fileMatched = false
                for (lineNum, line) in content.components(separatedBy: "\n").enumerated() {
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    if regex.firstMatch(in: line, options: [], range: range) != nil {
                        matchedAny = true
                        fileMatched = true
                        if filesOnly { break }
                        let rel = relativePath(filePath, from: currentCwd)
                        printOut("\(rel):\(lineNum + 1):\(line)\n")
                    }
                }
                if filesOnly && fileMatched {
                    printOut("\(relativePath(filePath, from: currentCwd))\n")
                }
            }
        }
        return matchedAny ? 0 : 1
    }

    // MARK: - jq (minimal JSON filter)

    public static func jqCmd(_ argv: [String]) -> Int32 {
        var rawOutput = false
        var filter = "."
        var paths: [String] = []

        var i = 1
        while i < argv.count {
            let arg = argv[i]
            if arg == "-r" { rawOutput = true; i += 1 }
            else if arg.hasPrefix("-") { i += 1 }
            else if arg == "." || arg.hasPrefix(".") { filter = arg; i += 1 }
            else { paths.append(arg); i += 1 }
        }

        let inputs: [(String, Any)]
        if paths.isEmpty {
            let lines = readStdinLines()
            let joined = lines.joined(separator: "\n")
            guard let data = joined.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                printErr("jq: parse error\n")
                return 1
            }
            inputs = [("", json)]
        } else {
            inputs = paths.compactMap { path in
                let full = resolve(path)
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)),
                      let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
                return (path, json)
            }
        }

        if inputs.isEmpty {
            printErr("jq: no input\n")
            return 1
        }

        for (_, json) in inputs {
            let results = applyJQFilter(filter, to: json)
            for value in results {
                let text = formatJSON(value, raw: rawOutput)
                printOut(text + "\n")
            }
        }
        return 0
    }

    // MARK: - fd (find by name pattern)

    public static func fdCmd(_ argv: [String]) -> Int32 {
        var pattern = ".*"
        var root = "."
        var typeFilter: Character? = nil // f=file, d=directory

        var i = 1
        while i < argv.count {
            let arg = argv[i]
            if arg == "-e" && i + 1 < argv.count {
                pattern = argv[i + 1]
                i += 2
            } else if arg == "-t" && i + 1 < argv.count {
                typeFilter = arg.dropFirst().first
                i += 2
            } else if !arg.hasPrefix("-") {
                pattern = arg
                if i + 1 < argv.count { root = argv[i + 1] }
                break
            } else {
                i += 1
            }
        }

        let fullRoot = resolve(root)
        let regexPattern: String
        if pattern.hasPrefix(".") && !pattern.contains("*") && !pattern.contains("?") {
            // Extension-style pattern: `.js` → match names ending in .js
            regexPattern = ".*" + NSRegularExpression.escapedPattern(for: pattern) + "$"
        } else {
            regexPattern = globToRegex(pattern)
        }
        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: []) else {
            printErr("fd: invalid pattern\n")
            return 2
        }

        var count = 0
        walkFiles(at: fullRoot) { filePath in
            let fm = FileManager.default
            var isDir: ObjCBool = false
            fm.fileExists(atPath: filePath, isDirectory: &isDir)
            if typeFilter == "f" && isDir.boolValue { return }
            if typeFilter == "d" && !isDir.boolValue { return }

            let name = (filePath as NSString).lastPathComponent
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if regex.firstMatch(in: name, options: [], range: range) != nil {
                printOut(relativePath(filePath, from: currentCwd) + "\n")
                count += 1
            }
        }
        return count > 0 ? 0 : 1
    }

    // MARK: - Helpers

    private static func walkFiles(at path: String, visitor: (String) -> Void) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return }

        if isDir.boolValue {
            guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return }
            for entry in entries {
                if entry.hasPrefix(".") { continue }
                walkFiles(at: (path as NSString).appendingPathComponent(entry), visitor: visitor)
            }
        } else {
            visitor(path)
        }
    }

    private static func relativePath(_ path: String, from base: String) -> String {
        let prefix = base.hasSuffix("/") ? base : base + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    private static func globToRegex(_ glob: String) -> String {
        var result = "^"
        for ch in glob {
            switch ch {
            case "*": result += ".*"
            case "?": result += "."
            case ".": result += "\\."
            default: result.append(ch)
            }
        }
        result += "$"
        return result
    }

    private static func applyJQFilter(_ filter: String, to json: Any) -> [Any] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        if trimmed == "." { return [json] }

        // Split on ` | ` for simple pipes
        let stages = trimmed.components(separatedBy: " | ").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        var current: [Any] = [json]
        for stage in stages {
            var next: [Any] = []
            for item in current {
                next.append(contentsOf: applySingleFilter(stage, to: item))
            }
            current = next
        }
        return current
    }

    private static func applySingleFilter(_ filter: String, to json: Any) -> [Any] {
        if filter == "." { return [json] }
        if filter == ".[]" {
            if let arr = json as? [Any] { return arr }
            return []
        }

        if filter.hasPrefix(".") {
            let path = String(filter.dropFirst())
            if path.isEmpty { return [json] }
            if let value = traversePath(path, in: json) {
                return [value]
            }
            return []
        }

        return [json]
    }

    private static func traversePath(_ path: String, in json: Any) -> Any? {
        var current: Any? = json
        for segment in path.split(separator: ".") {
            guard let val = current else { return nil }
            if let dict = val as? [String: Any] {
                current = dict[String(segment)]
            } else {
                return nil
            }
        }
        return current
    }

    private static func formatJSON(_ value: Any, raw: Bool) -> String {
        if raw {
            if let s = value as? String { return s }
            if let n = value as? NSNumber { return n.stringValue }
            if value is NSNull { return "null" }
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "\(value)"
        }
        return str
    }
}
