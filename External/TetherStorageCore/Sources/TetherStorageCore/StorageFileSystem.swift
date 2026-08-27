import Foundation

/// The only file-system boundary used by the core package.
///
/// Every argument is a path relative to an integrator-selected app-container
/// root. Implementations should make a missing or non-symlink path return
/// `nil` from `destinationOfSymlink(_:)`; that lets confinement checks inspect
/// ordinary and not-yet-created path components without treating them as I/O
/// failures.
public protocol StorageFileSystem: AnyObject {
    func exists(_ relativePath: String) -> Bool
    func isDirectory(_ relativePath: String) -> Bool
    func sizeOfTree(_ relativePath: String) throws -> Int64
    func removeTree(_ relativePath: String) throws
    func list(_ relativePath: String) throws -> [String]
    func destinationOfSymlink(_ relativePath: String) throws -> String?
}

/// Errors emitted by the deterministic in-memory implementation.
public enum InMemoryStorageFileSystemError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidPath(String)
    case notFound(String)
    case notDirectory(String)
    case cannotRemoveVirtualRoot
    case scriptedRemoveFailure(String)

    public var description: String {
        switch self {
        case .invalidPath(let path):
            return "invalid path: \(path)"
        case .notFound(let path):
            return "not found: \(path)"
        case .notDirectory(let path):
            return "not a directory: \(path)"
        case .cannotRemoveVirtualRoot:
            return "cannot remove the virtual root"
        case .scriptedRemoveFailure(let message):
            return message
        }
    }
}

/// A deterministic, non-disk-backed implementation for tests and previews.
/// Directories are created for missing parents when using the seeding helpers.
/// Symlinks are stored as links, never followed by tree sizing or deletion.
public final class InMemoryStorageFileSystem: StorageFileSystem {
    private enum Node {
        case directory
        case file(Int64)
        case symlink(String)
    }

    private let lock = NSLock()
    private var nodes: [String: Node] = [:]
    private var removeFailures: [Int: String] = [:]
    private var removalInvocationCount = 0

    public init() {}

    /// Adds a file, creating absent parent directories. Invalid paths and
    /// attempts to replace a directory are harmless no-ops.
    public func addFile(_ relativePath: String, size: Int64) {
        guard let path = PathSupport.canonicalVirtualPath(relativePath), !path.isEmpty else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        guard ensureParentDirectories(for: path) else {
            return
        }
        if let existing = nodes[path], case .directory = existing {
            return
        }
        nodes[path] = .file(max(0, size))
    }

    /// Adds a directory and all absent ancestors. Invalid paths and attempts
    /// to replace a file or symlink are harmless no-ops.
    public func addDirectory(_ relativePath: String) {
        guard let path = PathSupport.canonicalVirtualPath(relativePath) else {
            return
        }
        guard !path.isEmpty else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        _ = ensureDirectories(PathSupport.canonicalPathComponents(path))
    }

    /// Adds a symlink with its destination kept verbatim. Missing parent
    /// directories are created; a directory at the final path is preserved.
    public func addSymlink(_ relativePath: String, destination: String) {
        guard let path = PathSupport.canonicalVirtualPath(relativePath), !path.isEmpty else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        guard ensureParentDirectories(for: path) else {
            return
        }
        if let existing = nodes[path], case .directory = existing {
            return
        }
        nodes[path] = .symlink(destination)
    }

    /// Makes the specified invocation of `removeTree(_:)` fail before it
    /// changes any node. This is useful for deterministic partial-plan tests.
    public func failRemoveTree(onCall call: Int, message: String) {
        guard call > 0 else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        removeFailures[call] = message
    }

    public func clearRemoveTreeFailures() {
        lock.lock()
        defer { lock.unlock() }
        removeFailures.removeAll()
    }

    public var removeTreeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return removalInvocationCount
    }

    public func exists(_ relativePath: String) -> Bool {
        guard let path = PathSupport.canonicalVirtualPath(relativePath) else {
            return false
        }
        if path.isEmpty {
            return true
        }

        lock.lock()
        defer { lock.unlock() }
        return nodes[path] != nil
    }

    public func isDirectory(_ relativePath: String) -> Bool {
        guard let path = PathSupport.canonicalVirtualPath(relativePath) else {
            return false
        }
        if path.isEmpty {
            return true
        }

        lock.lock()
        defer { lock.unlock() }
        if let node = nodes[path], case .directory = node {
            return true
        }
        return false
    }

    public func sizeOfTree(_ relativePath: String) throws -> Int64 {
        guard let path = PathSupport.canonicalVirtualPath(relativePath) else {
            throw InMemoryStorageFileSystemError.invalidPath(relativePath)
        }

        lock.lock()
        defer { lock.unlock() }

        if path.isEmpty {
            return saturatedSize(ofDescendantsOf: path)
        }
        guard let node = nodes[path] else {
            throw InMemoryStorageFileSystemError.notFound(path)
        }

        switch node {
        case .file(let size):
            return size
        case .symlink:
            return 0
        case .directory:
            return saturatedSize(ofDescendantsOf: path)
        }
    }

    public func removeTree(_ relativePath: String) throws {
        guard let path = PathSupport.canonicalVirtualPath(relativePath) else {
            throw InMemoryStorageFileSystemError.invalidPath(relativePath)
        }

        lock.lock()
        defer { lock.unlock() }

        removalInvocationCount += 1
        if let message = removeFailures[removalInvocationCount] {
            throw InMemoryStorageFileSystemError.scriptedRemoveFailure(message)
        }
        guard !path.isEmpty else {
            throw InMemoryStorageFileSystemError.cannotRemoveVirtualRoot
        }
        guard nodes[path] != nil else {
            throw InMemoryStorageFileSystemError.notFound(path)
        }

        let pathComponents = PathSupport.canonicalPathComponents(path)
        let keysToRemove = nodes.keys.filter { key in
            let candidate = PathSupport.canonicalPathComponents(key)
            return PathSupport.isPrefix(pathComponents, of: candidate)
        }
        for key in keysToRemove {
            nodes.removeValue(forKey: key)
        }
    }

    public func list(_ relativePath: String) throws -> [String] {
        guard let path = PathSupport.canonicalVirtualPath(relativePath) else {
            throw InMemoryStorageFileSystemError.invalidPath(relativePath)
        }

        lock.lock()
        defer { lock.unlock() }

        if !path.isEmpty {
            guard let node = nodes[path] else {
                throw InMemoryStorageFileSystemError.notFound(path)
            }
            guard case .directory = node else {
                throw InMemoryStorageFileSystemError.notDirectory(path)
            }
        }

        let parentComponents = PathSupport.canonicalPathComponents(path)
        var entries = Set<String>()
        for key in nodes.keys {
            let components = PathSupport.canonicalPathComponents(key)
            guard components.count > parentComponents.count,
                  PathSupport.isPrefix(parentComponents, of: components) else {
                continue
            }
            entries.insert(components[parentComponents.count])
        }
        return entries.sorted()
    }

    public func destinationOfSymlink(_ relativePath: String) throws -> String? {
        guard let path = PathSupport.canonicalVirtualPath(relativePath) else {
            throw InMemoryStorageFileSystemError.invalidPath(relativePath)
        }

        lock.lock()
        defer { lock.unlock() }
        guard let node = nodes[path] else {
            return nil
        }
        if case .symlink(let destination) = node {
            return destination
        }
        return nil
    }

    private func ensureParentDirectories(for path: String) -> Bool {
        let components = PathSupport.canonicalPathComponents(path)
        guard !components.isEmpty else {
            return false
        }
        return ensureDirectories(Array(components.dropLast()))
    }

    private func ensureDirectories(_ components: [String]) -> Bool {
        var current: [String] = []
        for component in components {
            current.append(component)
            let path = PathSupport.join(current)
            if let node = nodes[path] {
                guard case .directory = node else {
                    return false
                }
            } else {
                nodes[path] = .directory
            }
        }
        return true
    }

    private func saturatedSize(ofDescendantsOf path: String) -> Int64 {
        let rootComponents = PathSupport.canonicalPathComponents(path)
        var total: Int64 = 0
        for (key, node) in nodes {
            let candidate = PathSupport.canonicalPathComponents(key)
            guard PathSupport.isPrefix(rootComponents, of: candidate) else {
                continue
            }
            guard case .file(let size) = node else {
                continue
            }
            let (next, overflow) = total.addingReportingOverflow(size)
            total = overflow ? Int64.max : next
        }
        return total
    }
}
