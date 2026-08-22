import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
@MainActor
public final class DocumentWorkspaceProvider: NSObject, WorkspaceProviding, UIDocumentPickerDelegate {
    private let store: WorkspaceStore
    private var continuation: CheckedContinuation<Workspace, Error>?
    public init(store: WorkspaceStore = WorkspaceStore()) { self.store = store }
    public func addWorkspace() async throws -> Workspace {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.allowsMultipleSelection = false; picker.delegate = self
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let presenter = scene.keyWindow?.rootViewController else { continuation.resume(throwing: CocoaError(.userCancelled)); return }
            presenter.present(picker, animated: true)
        }
    }
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { continuation?.resume(throwing: CocoaError(.userCancelled)); continuation = nil; return }
        let name = url.lastPathComponent.isEmpty ? "Workspace" : url.lastPathComponent
        let workspace = Workspace(name: name, mountPath: "/workspaces/\(name)")
        let accessed = url.startAccessingSecurityScopedResource(); defer { if !accessed { } }
        do { let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil); store.register(workspace, realPath: url.path); UserDefaults.standard.set(bookmark, forKey: "termx.bookmark.\(workspace.id.uuidString)"); continuation?.resume(returning: workspace) } catch { continuation?.resume(throwing: error) }
        continuation = nil
    }
    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { continuation?.resume(throwing: CocoaError(.userCancelled)); continuation = nil }
    public func restoreAll() -> [Workspace] { store.restoreAll() }
    public func beginAccess(_ workspace: Workspace) throws -> String { try store.beginAccess(workspace) }
    public func endAccess(_ workspace: Workspace) { store.endAccess(workspace) }
    public func resolve(virtualPath: String) -> String? { store.resolve(virtualPath: virtualPath) }
}
#endif
