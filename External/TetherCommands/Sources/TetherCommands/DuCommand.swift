import Foundation

public enum DuCommand: TetherCommand {
    public static let name = "du"

    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name)
        var summarize = false
        var human = false
        var bytes = false

        while let option = args.first, option.hasPrefix("-") && option != "-" {
            if option == "--" { args.removeFirst(); break }
            for flag in option.dropFirst() {
                switch flag {
                case "s": summarize = true
                case "h": human = true
                case "b": bytes = true
                case "k": bytes = false
                default: return CommandSupport.error(name, "invalid option -- \(flag)", usage: true)
                }
            }
            args.removeFirst()
        }
        if args.isEmpty { args = ["."] }

        var output: [String] = []
        var errors: [String] = []
        for operand in args {
            let root = CommandSupport.path(operand, cwd: io.cwd)
            do {
                let rootAttributes = try FileManager.default.attributesOfItem(atPath: root)
                if !summarize, rootAttributes[.type] as? FileAttributeType == .typeDirectory {
                    let directories = try descendantDirectories(root).sorted {
                        let leftDepth = $0.split(separator: "/").count
                        let rightDepth = $1.split(separator: "/").count
                        return leftDepth == rightDepth ? $0 < $1 : leftDepth > rightDepth
                    }
                    for relative in directories {
                        let path = (root as NSString).appendingPathComponent(relative)
                        output.append(line(size: try size(path), display: displayPath(operand, relative), human: human, bytes: bytes))
                    }
                }
                output.append(line(size: try size(root), display: operand, human: human, bytes: bytes))
            } catch {
                errors.append("du: \(operand): \(error.localizedDescription)")
            }
        }
        return CommandResult(
            stdout: output.isEmpty ? "" : output.joined(separator: "\n") + "\n",
            stderr: errors.isEmpty ? "" : errors.joined(separator: "\n") + "\n",
            exitCode: errors.isEmpty ? 0 : 1
        )
    }

    private static func descendantDirectories(_ root: String) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
        var result: [String] = []
        for case let relative as String in enumerator {
            let path = (root as NSString).appendingPathComponent(relative)
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if attributes[.type] as? FileAttributeType == .typeDirectory { result.append(relative) }
        }
        return result
    }

    private static func size(_ path: String) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        }
        var total = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if let enumerator = FileManager.default.enumerator(atPath: path) {
            for case let child as String in enumerator {
                let childPath = (path as NSString).appendingPathComponent(child)
                let childAttributes = try FileManager.default.attributesOfItem(atPath: childPath)
                total += (childAttributes[.size] as? NSNumber)?.uint64Value ?? 0
            }
        }
        return total
    }

    private static func displayPath(_ root: String, _ relative: String) -> String {
        if root == "." { return "./" + relative }
        if root.hasSuffix("/") { return root + relative }
        return root + "/" + relative
    }

    private static func line(size: UInt64, display: String, human: Bool, bytes: Bool) -> String {
        let amount = human ? humanSize(size) : String(bytes ? size : (size + 1023) / 1024)
        return "\(amount)\t\(display)"
    }

    private static func humanSize(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return String(format: "%.1fK", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1fM", Double(bytes) / 1_048_576) }
        return String(format: "%.1fG", Double(bytes) / 1_073_741_824)
    }
}
