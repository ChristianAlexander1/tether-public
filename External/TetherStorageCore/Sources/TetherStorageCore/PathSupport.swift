import Foundation

/// Small, lexical-only path helpers shared by the catalog, fake file system,
/// and resolver. No helper in this type touches the host file system.
internal enum PathSupport {
    static func rawComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func canonicalComponents(_ path: String) -> [String]? {
        guard !path.utf8.contains(0) else {
            return nil
        }

        var result: [String] = []
        for component in rawComponents(path) {
            switch component {
            case ".":
                continue
            case "..":
                guard !result.isEmpty else {
                    return nil
                }
                result.removeLast()
            default:
                result.append(component)
            }
        }
        return result
    }

    /// Canonicalizes a path in the in-memory file system's virtual namespace.
    /// A leading slash is accepted as a convenience and still refers to that
    /// virtual root. Attempts to climb above it are rejected.
    static func canonicalVirtualPath(_ path: String) -> String? {
        guard let components = canonicalComponents(path) else {
            return nil
        }
        return join(components)
    }

    /// A catalog path is intentionally stricter than a general virtual path:
    /// it must already be a nonempty, canonical relative path and may not
    /// contain traversal components.
    static func safeManagedRelativePath(_ path: String) -> String? {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.utf8.contains(0) else {
            return nil
        }

        let components = rawComponents(path)
        guard !components.isEmpty else {
            return nil
        }
        guard components.allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".." && !component.utf8.contains(0)
        }) else {
            return nil
        }

        let canonical = join(components)
        guard canonical == path else {
            return nil
        }
        return canonical
    }

    /// Normalizes a root supplied to the resolver. Roots may be written with
    /// or without a leading slash, but cannot lexically climb above virtual
    /// root.
    static func normalizedRootComponents(_ root: String) -> [String]? {
        canonicalComponents(root)
    }

    static func canonicalPathComponents(_ path: String) -> [String] {
        guard !path.isEmpty else {
            return []
        }
        return rawComponents(path)
    }

    static func join(_ components: [String]) -> String {
        components.joined(separator: "/")
    }

    static func isPrefix(_ prefix: [String], of path: [String]) -> Bool {
        guard prefix.count <= path.count else {
            return false
        }
        for index in prefix.indices where prefix[index] != path[index] {
            return false
        }
        return true
    }

    static func isInsideOrEqual(_ path: [String], root: [String]) -> Bool {
        isPrefix(root, of: path)
    }

    static func isStrictlyInside(_ path: [String], root: [String]) -> Bool {
        path.count > root.count && isPrefix(root, of: path)
    }

    /// True when a path is either an ancestor of the root or is inside it.
    /// This is useful while walking an absolute path from virtual root toward
    /// a deeper confinement root.
    static func isOnRouteOrInside(_ path: [String], root: [String]) -> Bool {
        isPrefix(path, of: root) || isPrefix(root, of: path)
    }

    static func simpleEntry(_ entry: String) -> String? {
        guard !entry.isEmpty,
              entry != ".",
              entry != "..",
              !entry.contains("/"),
              !entry.utf8.contains(0) else {
            return nil
        }
        return entry
    }

    static func path(_ child: String, isContainedIn area: String) -> Bool {
        guard let childPath = safeManagedRelativePath(child),
              let areaPath = safeManagedRelativePath(area) else {
            return false
        }
        return isPrefix(canonicalPathComponents(areaPath), of: canonicalPathComponents(childPath))
    }

    static func relativePath(_ child: String, below base: String) -> String? {
        let childComponents = canonicalPathComponents(child)
        let baseComponents = canonicalPathComponents(base)
        guard isPrefix(baseComponents, of: childComponents) else {
            return nil
        }
        return join(Array(childComponents.dropFirst(baseComponents.count)))
    }
}
