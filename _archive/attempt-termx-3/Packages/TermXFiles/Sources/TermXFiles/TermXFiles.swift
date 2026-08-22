import Foundation

public struct Workspace: Codable, Identifiable, Hashable {
 public let id: UUID; public let name: String; public let mountPath: String
 public init(id: UUID=UUID(), name: String, mountPath: String) { self.id=id; self.name=name; self.mountPath=mountPath }
}
public protocol WorkspaceProviding {
 func addWorkspace() async throws -> Workspace
 func restoreAll() -> [Workspace]
 func beginAccess(_ w: Workspace) throws -> String
 func endAccess(_ w: Workspace)
 func resolve(virtualPath: String) -> String?
}
public final class WorkspaceStore: WorkspaceProviding {
 private var urls:[UUID:URL]=[:]; private var scopes:[UUID:Int]=[:]; private let key="termx.workspaces"
 public init() { restorePersisted() }
 public func addWorkspace() async throws -> Workspace {
  #if os(iOS)
  let picker=UIDocumentPickerViewController(forOpeningContentTypes: [.folder]); throw NSError(domain:"TermXFiles",code:2,userInfo:[NSLocalizedDescriptionKey:"Present UIDocumentPickerViewController from the app coordinator."])
  #else
  throw NSError(domain:"TermXFiles",code:2,userInfo:[NSLocalizedDescriptionKey:"Folder picking is available on iOS through UIDocumentPickerViewController."])
  #endif
 }
 public func restoreAll() -> [Workspace] { urls.map { Workspace(id:$0.key,name:$0.value.lastPathComponent,mountPath:"/workspaces/\($0.value.lastPathComponent)") } }
 public func beginAccess(_ w: Workspace) throws -> String { guard let u=urls[w.id] else { throw NSError(domain:"TermXFiles",code:3) }; let ok=u.startAccessingSecurityScopedResource(); if !ok && !FileManager.default.fileExists(atPath:u.path) { throw NSError(domain:"TermXFiles",code:4) }; scopes[w.id,default:0]+=1; return u.path }
 public func endAccess(_ w: Workspace) { guard let n=scopes[w.id] else{return}; if n<=1 { urls[w.id]?.stopAccessingSecurityScopedResource(); scopes.removeValue(forKey:w.id) } else { scopes[w.id]=n-1 } }
 public func resolve(virtualPath:String)->String? { let comps=virtualPath.split(separator:"/").map(String.init); guard comps.count>=2, comps[0]=="workspaces" else{return nil}; guard let w=restoreAll().first(where:{$0.name==comps[1]}), let u=urls[w.id] else{return nil}; return u.appendingPathComponent(comps.dropFirst(2).joined(separator:"/")).path }
 private func restorePersisted(){ }
}
