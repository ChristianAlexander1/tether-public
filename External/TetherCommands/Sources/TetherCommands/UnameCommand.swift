import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum UnameCommand: TetherCommand {
    public static let name = "uname"

    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name)
        var flags: Set<Character> = []
        if args.first == "--" { args.removeFirst() }
        if args.isEmpty { flags.insert("s") }

        for argument in args {
            guard argument.hasPrefix("-"), argument.count > 1 else {
                return CommandSupport.error(name, "extra operand '\(argument)'", usage: true)
            }
            for flag in argument.dropFirst() {
                guard "asnrvmpio".contains(flag) else {
                    return CommandSupport.error(name, "invalid option -- \(flag)", usage: true)
                }
                flags.insert(flag)
            }
        }
        if flags.contains("a") { flags.formUnion(["s", "n", "r", "v", "m", "p", "i", "o"]) }

        var information = utsname()
        #if canImport(Glibc)
        guard Glibc.uname(&information) == 0 else { return CommandSupport.error(name, "unable to read system information") }
        #elseif canImport(Darwin)
        guard Darwin.uname(&information) == 0 else { return CommandSupport.error(name, "unable to read system information") }
        #else
        return CommandSupport.error(name, "unsupported platform")
        #endif

        let system = cString(&information.sysname)
        let node = cString(&information.nodename)
        let release = cString(&information.release)
        let version = cString(&information.version)
        let machine = cString(&information.machine)
        var values: [String] = []
        for flag: Character in ["s", "n", "r", "v", "m", "p", "i", "o"] where flags.contains(flag) {
            switch flag {
            case "s": values.append(system)
            case "n": values.append(node)
            case "r": values.append(release)
            case "v": values.append(version)
            case "m", "p", "i": values.append(machine)
            case "o": values.append(system)
            default: break
            }
        }
        return CommandResult(stdout: values.joined(separator: " ") + "\n")
    }

    private static func cString<T>(_ value: inout T) -> String {
        withUnsafePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }
}
