import Foundation

public struct Workspace: Codable, Identifiable, Hashable {
    public let id: UUID; public let name: String; public let mountPath: String; public let realPath: String
    public init(id: UUID = UUID(), name: String, mountPath: String, realPath: String) { self.id=id; self.name=name; self.mountPath=mountPath; self.realPath=realPath }
}

public protocol WorkspaceProviding {
    func addWorkspace() async throws -> Workspace
    func restoreAll() -> [Workspace]
    func beginAccess(_ workspace: Workspace) throws -> String
    func endAccess(_ workspace: Workspace)
    func resolve(virtualPath: String) -> String?
}

public final class WorkspaceStore: WorkspaceProviding {
    private var workspaces: [Workspace] = []; private var scopes: [UUID:Int] = [:]; private let fileURL: URL; private let lock = NSLock()
    public init(storageDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())) { fileURL = storageDirectory.appendingPathComponent("workspaces.json"); load() }
    public func addWorkspace() async throws -> Workspace { throw WorkspaceError.pickerRequired }
    public func addWorkspace(url: URL) throws -> Workspace { let name = url.lastPathComponent.isEmpty ? "Workspace" : url.lastPathComponent; let clean = name.replacingOccurrences(of: "/", with: "-"); let w = Workspace(name: clean, mountPath: "/workspaces/\(clean)", realPath: url.standardizedFileURL.path); lock.lock(); workspaces.append(w); persist(); lock.unlock(); return w }
    public func restoreAll() -> [Workspace] { lock.lock(); defer { lock.unlock() }; return workspaces }
    public func beginAccess(_ workspace: Workspace) throws -> String { let url=URL(fileURLWithPath: workspace.realPath); guard FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceError.missingPath(url.path) }; #if os(iOS) || os(macOS) _ = url.startAccessingSecurityScopedResource() #endif; lock.lock(); scopes[workspace.id, default:0] += 1; lock.unlock(); return url.path }
    public func endAccess(_ workspace: Workspace) { #if os(iOS) || os(macOS) _ = URL(fileURLWithPath: workspace.realPath).stopAccessingSecurityScopedResource() #endif; lock.lock(); if let c=scopes[workspace.id], c>1 { scopes[workspace.id]=c-1 } else { scopes.removeValue(forKey: workspace.id) }; lock.unlock() }
    public func resolve(virtualPath: String) -> String? { guard virtualPath.hasPrefix("/workspaces/") else { return nil }; let rest=String(virtualPath.dropFirst("/workspaces/".count)); let parts=rest.split(separator:"/",omittingEmptySubsequences:true); guard let first=parts.first else { return nil }; guard let w=workspaces.first(where: {$0.name==String(first)}) else { return nil }; let candidate=parts.dropFirst().reduce(URL(fileURLWithPath:w.realPath)) { $0.appendingPathComponent(String($1)) }.standardizedFileURL.path; guard candidate == w.realPath || candidate.hasPrefix(w.realPath + "/") else { return nil }; return candidate }
    private func load() { guard let data=try? Data(contentsOf:fileURL), let value=try? JSONDecoder().decode([Workspace].self,from:data) else { return }; workspaces=value }
    private func persist() { try? FileManager.default.createDirectory(at:fileURL.deletingLastPathComponent(),withIntermediateDirectories:true); if let data=try? JSONEncoder().encode(workspaces) { try? data.write(to:fileURL,options:.atomic) } }
}
public enum WorkspaceError: Error, LocalizedError { case pickerRequired, missingPath(String); public var errorDescription:String? { switch self { case .pickerRequired:return "A document picker URL is required to add a workspace."; case .missingPath(let p):return "Workspace path does not exist: \(p)" } } }
