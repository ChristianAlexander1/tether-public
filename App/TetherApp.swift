import SwiftUI
import TermXCore
import TermXFiles
import TermXUI

@main
struct TetherApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(model) }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let workspaces = WorkspaceStore()
    let integration = TermXIntegration()
    lazy var engine: CoreEngineAdapter = CoreEngineAdapter(core: integration.makeShellEngine())
    @Published var selected: Workspace?
    @Published var theme: TerminalTheme = .midnight
    @Published var errorMessage: String?

    init() {
        #if DEBUG
        // Simulator/UI-test hook only: TERMX_AUTOWORKSPACE=1 opens a Documents workspace
        // without the picker. Compiled out of release builds; users always pick a folder.
        if ProcessInfo.processInfo.environment["TERMX_AUTOWORKSPACE"] == "1" {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let ws = Workspace(name: "Documents", mountPath: "/workspaces/Documents")
            if (try? workspaces.registerLocalWorkspaceForTesting(ws, rootURL: docs)) != nil {
                selected = ws
            }
        }
        #endif
    }

    func addWorkspace() async {
        do { selected = try await workspaces.addWorkspace() }
        catch { errorMessage = error.localizedDescription }
    }
}

/// Bridges TermXCore's shell engine to TermXUI's frozen TerminalEngine seam.
final class CoreEngineAdapter: TermXUI.TerminalEngine {
    private let core: TermXShellEngine
    init(core: TermXShellEngine) { self.core = core }
    func startShell(cwd: String, env: [String: String], ptySlave: Int32, onExit: @escaping (Int32) -> Void) throws -> Int32 {
        try core.startShell(cwd: cwd, env: env, ptySlave: ptySlave, onExit: onExit)
    }
    func signal(pid: Int32, _ sig: Int32) { core.signal(pid: pid, sig) }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    // A NavigationLink inside a Menu pushes outside the stack's normal flow and
    // arrives without a back button, trapping the user. Menu items set these
    // instead and navigationDestination does the push.
    @State private var showStorage = false
    @State private var showLicenses = false
    var body: some View {
        NavigationStack {
            if let workspace = model.selected {
                WorkspaceView(workspace: workspace)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("Choose a workspace").font(.title2.bold())
                    Text("Tether runs commands only inside a folder you explicitly select.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Menu {
                            Button { showStorage = true } label: {
                                Label("Storage", systemImage: "internaldrive")
                            }
                            Button { showLicenses = true } label: {
                                Label("Licenses", systemImage: "doc.text")
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add Folder") { Task { await model.addWorkspace() } }
                    }
                }
                .navigationDestination(isPresented: $showStorage) { StorageView() }
                .navigationDestination(isPresented: $showLicenses) { LicensesView() }
            }
        }
        .alert("Unable to open workspace", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(model.errorMessage ?? "Unknown error") }
    }
}

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    let workspace: Workspace
    @State private var session: TerminalSession?
    @State private var resolvedPath: String?
    @State private var showFiles = false
    @State private var showStorage = false
    @State private var showLicenses = false
    var body: some View {
        Group {
            if let session { TerminalSessionView(session: session, theme: $model.theme) }
            else { ProgressView("Opening workspace…") }
        }
        .navigationTitle(workspace.name)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    if resolvedPath != nil {
                        Button { showFiles = true } label: {
                            Label("Files", systemImage: "folder")
                        }
                    }
                    Button { showStorage = true } label: {
                        Label("Storage", systemImage: "internaldrive")
                    }
                    Button { showLicenses = true } label: {
                        Label("Licenses", systemImage: "doc.text")
                    }
                } label: { Image(systemName: "sidebar.leading") }
                .accessibilityIdentifier("workspaceMenu")
            }
        }
        .navigationDestination(isPresented: $showFiles) {
            if let resolvedPath {
                WorkspaceFilesView(rootPath: resolvedPath, title: workspace.name)
            }
        }
        .navigationDestination(isPresented: $showStorage) { StorageView() }
        .navigationDestination(isPresented: $showLicenses) { LicensesView() }
        .task {
            if session == nil {
                let path: String?
                #if DEBUG
                path = (try? model.workspaces.beginAccess(workspace))
                    ?? (try? model.workspaces.beginLocalAccessForTesting(workspace))
                #else
                path = try? model.workspaces.beginAccess(workspace)
                #endif
                if let path {
                    resolvedPath = path
                    let newSession = TerminalSession(cwd: path, engine: model.engine)
                    session = newSession
                    try? newSession.start()
                    #if DEBUG
                    // Simulator harness: TERMX_AUTOCOMMANDS holds \n-separated commands
                    // fed into the session exactly as if typed. Compiled out of release.
                    if let script = ProcessInfo.processInfo.environment["TERMX_AUTOCOMMANDS"], !script.isEmpty {
                        Task.detached {
                            // Give embedded runtimes (Node/Python) time to finish first launch.
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
                                newSession.send(String(line) + "\n")
                                try? await Task.sleep(nanoseconds: 2_500_000_000)
                            }
                        }
                    }
                    #endif
                }
            }
        }
        .onDisappear { model.workspaces.endAccess(workspace); session?.terminate() }
    }
}
