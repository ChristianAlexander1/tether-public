import Foundation

public struct Workspace: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let mountPath: String
    public init(id: UUID = UUID(), name: String, mountPath: String) { self.id = id; self.name = name; self.mountPath = mountPath }
}

public protocol WorkspaceProviding: AnyObject {
    func addWorkspace() async throws -> Workspace
    func restoreAll() -> [Workspace]
    func beginAccess(_ workspace: Workspace) throws -> String
    func endAccess(_ workspace: Workspace)
    func resolve(virtualPath: String) -> String?
}

public final class WorkspaceStore: WorkspaceProviding {
    private let defaults: UserDefaults
    private var workspaces: [Workspace] = []
    private var realPaths: [UUID: String] = [:]
    private var accessCounts: [UUID: Int] = [:]
    private let lock = NSLock()
    private let key = "termx.workspaces"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults; workspaces = (try? JSONDecoder().decode([Workspace].self, from: defaults.data(forKey: key) ?? Data())) ?? [] }
    public func addWorkspace() async throws -> Workspace { throw CocoaError(.userCancelled) }
    public func restoreAll() -> [Workspace] { lock.lock(); defer { lock.unlock() }; return workspaces }
    public func register(_ workspace: Workspace, realPath: String) {
        lock.lock(); defer { lock.unlock() }; if !workspaces.contains(workspace) { workspaces.append(workspace) }; realPaths[workspace.id] = realPath; persist()
    }
    public func beginAccess(_ workspace: Workspace) throws -> String {
        lock.lock(); defer { lock.unlock() }; guard let path = realPaths[workspace.id] else { throw CocoaError(.fileNoSuchFile) }
        accessCounts[workspace.id, default: 0] += 1
        #if os(iOS)
        _ = URL(fileURLWithPath: path).startAccessingSecurityScopedResource()
        #endif
        return path
    }
    public func endAccess(_ workspace: Workspace) {
        lock.lock(); defer { lock.unlock() }; let count = max(0, (accessCounts[workspace.id] ?? 1) - 1); accessCounts[workspace.id] = count
        if count == 0 {
            #if os(iOS)
            _ = URL(fileURLWithPath: realPaths[workspace.id] ?? "").stopAccessingSecurityScopedResource()
            #endif
        }
    }
    public func resolve(virtualPath: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let match = workspaces.first(where: { virtualPath == $0.mountPath || virtualPath.hasPrefix($0.mountPath + "/") }), let root = realPaths[match.id] else { return nil }
        let suffix = String(virtualPath.dropFirst(match.mountPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidate = URL(fileURLWithPath: root).appendingPathComponent(suffix).standardizedFileURL.path
        guard candidate == root || candidate.hasPrefix(root + "/") else { return nil }
        return candidate
    }
    private func persist() { defaults.set(try? JSONEncoder().encode(workspaces), forKey: key) }
}
