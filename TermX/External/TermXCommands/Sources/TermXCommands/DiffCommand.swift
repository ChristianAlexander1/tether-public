import Foundation

/// `diff` — compare files line by line. Supports `-u` (unified) and `-q`
/// (brief). Exit code 0 = same, 1 = different, 2 = error. `-` reads stdin.
struct DiffCommand: TermXCommand {
    static let name = "diff"

    static func run(_ io: CommandIO) -> CommandResult {
        var unified = false
        var brief = false
        var context = 3
        var files: [String] = []
        var i = 1
        var rest = false
        while i < io.argv.count {
            let a = io.argv[i]
            if !rest && a == "--" { rest = true }
            else if !rest && a == "-u" { unified = true }
            else if !rest && a == "-q" { brief = true }
            else if !rest && a.hasPrefix("-U") { context = Int(a.dropFirst(2)) ?? 3 }
            else if !rest && a.hasPrefix("-") && a.count > 1 {
                if a.hasPrefix("-u") { unified = true } else { brief = true }
            }
            else { files.append(a) }
            i += 1
        }
        guard files.count >= 2 else { return CommandSupport.usageError(io, "usage: diff [-u -q] file1 file2") }

        func load(_ f: String) throws -> String {
            if f == "-" { return io.stdin }
            return try String(contentsOfFile: CommandSupport.resolve(f, cwd: io.cwd), encoding: .utf8)
        }
        let a: String, b: String
        do { a = try load(files[0]); b = try load(files[1]) }
        catch { return CommandSupport.error(io, "\(files[0]): No such file or directory") }

        let linesA = CommandSupport.lines(a)
        let linesB = CommandSupport.lines(b)

        if linesA == linesB {
            return CommandResult()
        }
        if brief {
            return CommandResult(stdout: "Files \(files[0]) and \(files[1]) differ\n", exitCode: 1)
        }

        var ops: [Op] = []
        var iA = 0, iB = 0
        // LCS-based diff (O(n*min(n,m))), suitable for typical file sizes.
        let opsFromLCS = lcsOps(linesA, linesB)
        ops = opsFromLCS

        let out = renderUnified(ops: ops, linesA: linesA, linesB: linesB,
                                names: (files[0], files[1]), context: context)
        return CommandResult(stdout: out, exitCode: 1)
    }

    enum Op: Equatable { case equal(Int, Int); case delete(Int); case insert(Int) }

    private static func lcsOps(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        if n == 0 { return b.indices.map { .insert($0) } }
        if m == 0 { return a.indices.map { .delete($0) } }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i] == b[j] { dp[i][j] = dp[i + 1][j + 1] + 1 }
                else { dp[i][j] = max(dp[i + 1][j], dp[i][j + 1]) }
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { ops.append(.equal(i, j)); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { ops.append(.delete(i)); i += 1 }
            else { ops.append(.insert(j)); j += 1 }
        }
        while i < n { ops.append(.delete(i)); i += 1 }
        while j < m { ops.append(.insert(j)); j += 1 }
        return ops
    }

    private static func renderUnified(ops: [Op], linesA: [String], linesB: [String],
                                      names: (String, String), context: Int) -> String {
        var hunks: [[Op]] = []
        var current: [Op] = []
        var gap = 0
        for op in ops {
            if case .equal = op {
                gap += 1
                if gap > context * 2 {
                    if !current.isEmpty { hunks.append(current); current = [] }
                    gap = 0
                }
                current.append(op)
            } else {
                gap = 0
                current.append(op)
            }
        }
        if !current.isEmpty { hunks.append(current) }

        var out = "--- \(names.0)\n+++ \(names.1)\n"
        for hunk in hunks {
            // Compute start/end ranges for headers.
            let aStart = hunk.firstIndex(where: { !isEqual($0) }).map { _ in hunk[0] } ?? hunk[0]
            _ = aStart
            let firstEqual = hunk.firstIndex(where: { $0 == .equal(0, 0) })
            _ = firstEqual

            var aBeg = Int.max, aEnd = -1, bBeg = Int.max, bEnd = -1
            var aLen = 0, bLen = 0
            for op in hunk {
                switch op {
                case .equal(let ai, let bi):
                    aBeg = min(aBeg, ai); aEnd = max(aEnd, ai)
                    bBeg = min(bBeg, bi); bEnd = max(bEnd, bi)
                    aLen += 1; bLen += 1
                case .delete(let ai):
                    aBeg = min(aBeg, ai); aEnd = max(aEnd, ai)
                    aLen += 1
                case .insert(let bi):
                    bBeg = min(bBeg, bi); bEnd = max(bEnd, bi)
                    bLen += 1
                }
            }
            let aLine = aBeg == Int.max ? 0 : aBeg + 1
            let bLine = bBeg == Int.max ? 0 : bBeg + 1
            let aCount = aLen
            let bCount = bLen
            out += "@@ -\(aLine),\(aCount) +\(bLine),\(bCount) @@\n"

            var ai = 0, bi = 0
            for op in hunk {
                switch op {
                case .equal(let p, let q):
                    out += " " + linesA[p] + "\n"
                    ai = p + 1; bi = q + 1
                case .delete(let p):
                    out += "-" + linesA[p] + "\n"
                    ai = p + 1
                case .insert(let q):
                    out += "+" + linesB[q] + "\n"
                    bi = q + 1
                }
            }
            _ = ai; _ = bi
        }
        return out
    }

    private static func isEqual(_ op: Op) -> Bool {
        if case .equal = op { return true }
        return false
    }
}
