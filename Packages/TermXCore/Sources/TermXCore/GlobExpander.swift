import Foundation

// MARK: - Glob Expander

/// POSIX-style glob expansion using FileManager.
/// Supports: *, ?, [abc], [!abc], ** (recursive).
public enum GlobExpander {

    /// Expand a glob pattern into matching file paths.
    /// Returns the original pattern as-is if no matches found (POSIX behavior).
    public static func expand(_ pattern: String, in directory: String) -> [String] {
        // If pattern contains no glob characters, return as-is
        guard containsGlobChars(pattern) else { return [pattern] }

        let isAbsolute = pattern.hasPrefix("/")
        let baseDir: String
        let globPattern: String

        if isAbsolute {
            // Split absolute path into base directory + pattern components
            let parts = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            var base: [String] = []
            var patternParts: [String] = []
            var foundGlob = false
            for part in parts {
                if !foundGlob && !containsGlobChars(part) {
                    base.append(part)
                } else {
                    foundGlob = true
                    patternParts.append(part)
                }
            }
            baseDir = "/" + base.joined(separator: "/")
            globPattern = patternParts.joined(separator: "/")
        } else {
            baseDir = directory
            globPattern = pattern
        }

        let parts = globPattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var matches = expandRecursive(basePath: baseDir, patternParts: parts)

        // POSIX: if no matches, return the original pattern
        if matches.isEmpty { return [pattern] }

        // Return relative paths if input was relative
        if !isAbsolute {
            let prefix = baseDir.hasSuffix("/") ? baseDir : baseDir + "/"
            matches = matches.map { path in
                if path.hasPrefix(prefix) {
                    return String(path.dropFirst(prefix.count))
                }
                return path
            }
        }

        return matches.sorted()
    }

    /// Check if a string contains glob metacharacters.
    public static func containsGlobChars(_ s: String) -> Bool {
        s.contains("*") || s.contains("?") || s.contains("[")
    }

    // MARK: - Internal

    private static func expandRecursive(basePath: String, patternParts: [String]) -> [String] {
        guard !patternParts.isEmpty else { return [basePath] }

        let part = patternParts[0]
        let remaining = Array(patternParts.dropFirst())
        let fm = FileManager.default

        // ** recursive glob
        if part == "**" {
            var results: [String] = []
            // Match zero directories (skip **)
            results.append(contentsOf: expandRecursive(basePath: basePath, patternParts: remaining))
            // Match one or more directories
            if let entries = try? fm.contentsOfDirectory(atPath: basePath) {
                for entry in entries {
                    let fullPath = (basePath as NSString).appendingPathComponent(entry)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                        // Continue matching ** in subdirectory
                        results.append(contentsOf: expandRecursive(basePath: fullPath, patternParts: patternParts))
                    }
                }
            }
            return results
        }

        // Regular glob pattern for this directory level
        guard let entries = try? fm.contentsOfDirectory(atPath: basePath) else { return [] }

        var results: [String] = []
        for entry in entries {
            // Skip hidden files unless pattern starts with .
            if entry.hasPrefix(".") && !part.hasPrefix(".") { continue }

            if matchesGlob(entry, pattern: part) {
                let fullPath = (basePath as NSString).appendingPathComponent(entry)
                if remaining.isEmpty {
                    results.append(fullPath)
                } else {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                        results.append(contentsOf: expandRecursive(basePath: fullPath, patternParts: remaining))
                    }
                }
            }
        }

        return results
    }

    /// Match a filename against a glob pattern (single component, no path separators).
    /// Supports: * (any chars), ? (one char), [abc] (char class), [!abc] (negated class).
    public static func matchesGlob(_ name: String, pattern: String) -> Bool {
        let nameChars = Array(name)
        let patChars = Array(pattern)
        return matchGlob(nameChars, 0, patChars, 0)
    }

    private static func matchGlob(_ name: [Character], _ ni: Int,
                                    _ pattern: [Character], _ pi: Int) -> Bool {
        var ni = ni, pi = pi

        while pi < pattern.count {
            if ni < name.count && pattern[pi] == "?" {
                ni += 1; pi += 1; continue
            }

            if pattern[pi] == "*" {
                pi += 1
                // * at end matches everything
                if pi >= pattern.count { return true }
                // Try matching * with 0, 1, 2, ... characters
                for skip in ni...name.count {
                    if matchGlob(name, skip, pattern, pi) { return true }
                }
                return false
            }

            if pattern[pi] == "[" {
                pi += 1
                guard ni < name.count else { return false }
                let negated = pi < pattern.count && pattern[pi] == "!"
                if negated { pi += 1 }
                var matched = false
                while pi < pattern.count && pattern[pi] != "]" {
                    // Range: [a-z]
                    if pi + 2 < pattern.count && pattern[pi + 1] == "-" {
                        let lo = pattern[pi], hi = pattern[pi + 2]
                        if name[ni] >= lo && name[ni] <= hi { matched = true }
                        pi += 3
                    } else {
                        if name[ni] == pattern[pi] { matched = true }
                        pi += 1
                    }
                }
                if pi < pattern.count { pi += 1 } // skip ]
                if matched == negated { return false } // negated XOR matched
                ni += 1
                continue
            }

            // Literal character match
            guard ni < name.count, name[ni] == pattern[pi] else { return false }
            ni += 1; pi += 1
        }

        return ni == name.count
    }
}
