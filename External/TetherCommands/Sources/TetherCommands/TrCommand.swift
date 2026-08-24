public enum TrCommand: TetherCommand {
    public static let name = "tr"

    public static func run(_ io: CommandIO) -> CommandResult {
        var args = CommandSupport.args(io, command: name)
        var delete = false
        var squeeze = false

        while let first = args.first, first.hasPrefix("-") && first != "-" {
            if first == "--" { args.removeFirst(); break }
            let flags = first.dropFirst()
            guard !flags.isEmpty, flags.allSatisfy({ $0 == "d" || $0 == "s" }) else {
                return CommandSupport.error(name, "invalid option \(first)", usage: true)
            }
            delete = delete || flags.contains("d")
            squeeze = squeeze || flags.contains("s")
            args.removeFirst()
        }

        if delete {
            guard args.count == 1 || (squeeze && args.count == 2) else {
                return CommandSupport.error(name, "missing or extra operand", usage: true)
            }
        } else if squeeze {
            guard args.count == 1 || args.count == 2 else {
                return CommandSupport.error(name, "missing or extra operand", usage: true)
            }
        } else if args.count != 2 {
            return CommandSupport.error(name, "missing or extra operand", usage: true)
        }

        let set1 = CommandSupport.expandCharacterSet(args[0])
        let set2 = args.count > 1 ? CommandSupport.expandCharacterSet(args[1]) : []
        let deletion = Set(set1)
        let squeezeCharacters = Set(args.count > 1 ? set2 : set1)
        var mapping: [Character: Character] = [:]

        if !delete, args.count == 2, !set2.isEmpty {
            for (index, character) in set1.enumerated() {
                mapping[character] = set2[min(index, set2.count - 1)]
            }
        }

        var output = ""
        var previous: Character?
        for character in io.stdin {
            if delete && deletion.contains(character) { continue }
            let transformed = mapping[character] ?? character
            if squeeze && previous == transformed && squeezeCharacters.contains(transformed) { continue }
            output.append(transformed)
            previous = transformed
        }
        return CommandResult(stdout: output)
    }
}
