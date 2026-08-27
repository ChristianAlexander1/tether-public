import Foundation
import TetherStorageCore

/// `StorageFileSystem` over `FileManager`, rooted at one app-container URL.
///
/// This adapter is the security boundary. `StorageCatalog` already validates
/// the paths it passes, but every call revalidates before touching
/// `FileManager`: a deletion bug here removes user data, so one check is not
/// enough. Validation compares path *components* rather than string prefixes,
/// because `"linux-old"` has the prefix `"linux"` but is a different directory.
public final class AppContainerFileSystem: StorageFileSystem {
    public enum AdapterError: Error, LocalizedError, Equatable {
        case invalidRelativePath(String)

        public var errorDescription: String? {
            switch self {
            case .invalidRelativePath(let path):
                return "refusing to operate on a path outside the app container: \(path)"
            }
        }
    }

    private let root: URL
    private let fileManager: FileManager

    public init(containerURL: URL, fileManager: FileManager = .default) {
        self.root = containerURL.standardizedFileURL
        self.fileManager = fileManager
    }

    /// Resolve a core-supplied relative path into a URL under `root`, or throw.
    /// Empty, absolute, and traversal-containing paths are all rejected.
    private func resolve(_ relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw AdapterError.invalidRelativePath(relativePath)
        }
        var components: [String] = []
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            let name = String(component)
            if name == "." { continue }
            // `..` is rejected outright rather than popped: the core never
            // emits one, so its presence means something upstream is wrong.
            if name == ".." { throw AdapterError.invalidRelativePath(relativePath) }
            components.append(name)
        }
        guard !components.isEmpty else { throw AdapterError.invalidRelativePath(relativePath) }

        var url = root
        for component in components { url.appendPathComponent(component) }
        let resolved = url.standardizedFileURL
        guard Self.isDescendant(resolved, of: root) else {
            throw AdapterError.invalidRelativePath(relativePath)
        }
        return resolved
    }

    /// Component-wise containment test. `/a/b` contains `/a/b/c` but not
    /// `/a/bc`, which a `hasPrefix` check would get wrong.
    static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootParts = root.standardizedFileURL.pathComponents
        let urlParts = url.standardizedFileURL.pathComponents
        guard urlParts.count >= rootParts.count else { return false }
        return Array(urlParts.prefix(rootParts.count)) == rootParts
    }

    // MARK: - StorageFileSystem

    public func exists(_ relativePath: String) -> Bool {
        guard let url = try? resolve(relativePath) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    public func isDirectory(_ relativePath: String) -> Bool {
        guard let url = try? resolve(relativePath) else { return false }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    public func sizeOfTree(_ relativePath: String) throws -> Int64 {
        let url = try resolve(relativePath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        // Symlinks are not followed: a link into another area would otherwise
        // be counted twice, and a link out of the container would inflate the
        // total with files this screen does not manage.
        guard let walker = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in walker {
            let values = try? child.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    public func removeTree(_ relativePath: String) throws {
        let url = try resolve(relativePath)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    public func list(_ relativePath: String) throws -> [String] {
        let url = try resolve(relativePath)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try fileManager.contentsOfDirectory(atPath: url.path).sorted()
    }

    public func destinationOfSymlink(_ relativePath: String) throws -> String? {
        let url = try resolve(relativePath)
        // A missing path and an ordinary file both answer "not a symlink";
        // confinement checks walk paths that may not exist yet.
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
            return nil
        }
        return try fileManager.destinationOfSymbolicLink(atPath: url.path)
    }
}
