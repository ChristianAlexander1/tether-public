import SwiftUI
import TermXUI
import TermXFiles

@main
struct TermXApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene { WindowGroup { RootView().environmentObject(model) } }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedWorkspace: Workspace?
    @Published var selectedPath: String?
    let store: WorkspaceStore
    #if canImport(UIKit)
    let picker: DocumentWorkspaceProvider
    #endif
    init() {
        store = WorkspaceStore()
        #if canImport(UIKit)
        picker = DocumentWorkspaceProvider(store: store)
        #endif
        if let first = store.restoreAll().first, let path = try? store.beginAccess(first) { selectedWorkspace = first; selectedPath = path }
    }
    func openDocuments() {
        #if canImport(UIKit)
        Task {
            if let workspace = try? await picker.addWorkspace(), let path = try? picker.beginAccess(workspace) { selectedWorkspace = workspace; selectedPath = path }
        }
        #else
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let workspace = Workspace(name: "Documents", mountPath: "/workspaces/Documents")
        store.register(workspace, realPath: url.path); selectedWorkspace = workspace; selectedPath = url.path
        #endif
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationStack {
            if let workspace = model.selectedWorkspace, let path = model.selectedPath {
                TerminalView(cwd: path).navigationTitle(workspace.name).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink(destination: TermXSettingsView()) { Image(systemName: "gearshape") } } }
            } else {
                VStack(spacing: 20) { Image(systemName: "terminal").font(.system(size: 54)); Text("TermX").font(.largeTitle.bold()); Text("A native terminal for your workspaces.").foregroundStyle(.secondary); Button("Choose Workspace") { model.openDocuments() }.buttonStyle(.borderedProminent) }.padding()
            }
        }
    }
}
