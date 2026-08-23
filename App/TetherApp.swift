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
                return
            }
        }
        #endif
        // Reopen the last folder the user picked. If the bookmark is stale,
        // WorkspaceView shows an error and returns them to the picker.
        selected = workspaces.restoreAll().first
    }

    func addWorkspace() async {
        do { selected = try await workspaces.addWorkspace() }
        catch { errorMessage = error.localizedDescription }
    }

    func closeWorkspace() {
        selected = nil
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            }
        }
        // Sheets always have a dismiss path — NavigationLink/Menu pushes were
        // trapping users on Storage with no back button.
        .sheet(isPresented: $showStorage) {
            NavigationStack {
                StorageView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showStorage = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showLicenses) {
            NavigationStack {
                LicensesView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showLicenses = false }
                        }
                    }
            }
        }
        .alert("Unable to open workspace", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }
}

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    let workspace: Workspace
    @State private var session: TerminalSession?
    @State private var resolvedPath: String?
    @State private var openFailed = false
    @State private var showFiles = false
    @State private var showStorage = false
    @State private var showLicenses = false

    var body: some View {
        Group {
            if let session {
                TerminalSessionView(session: session, theme: $model.theme)
            } else if openFailed {
                VStack(spacing: 14) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("Can't reopen this folder").font(.title3.bold())
                    Text("Pick it again with Add Folder. iOS sometimes needs a fresh permission after the app is closed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Choose another folder") {
                        model.closeWorkspace()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ProgressView("Opening workspace…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(model.theme.palette.background)
        .navigationTitle(workspace.name)
        .navigationBarTitleDisplayMode(.inline)
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
                    Divider()
                    Button("Close workspace", role: .destructive) {
                        teardownSession()
                        model.closeWorkspace()
                    }
                } label: { Image(systemName: "sidebar.leading") }
                .accessibilityIdentifier("workspaceMenu")
            }
        }
        .sheet(isPresented: $showFiles) {
            NavigationStack {
                if let resolvedPath {
                    WorkspaceFilesView(rootPath: resolvedPath, title: workspace.name)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showFiles = false }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showStorage) {
            NavigationStack {
                StorageView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showStorage = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showLicenses) {
            NavigationStack {
                LicensesView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showLicenses = false }
                        }
                    }
            }
        }
        .task { await openIfNeeded() }
        .onDisappear {
            // Only tear down when leaving the workspace entirely — not when a
            // sheet (Storage / Files / Licenses) covers this view. Tearing down
            // on every disappear left a dead/white terminal after dismissing.
            if model.selected?.id != workspace.id {
                teardownSession()
            }
        }
    }

    @MainActor
    private func openIfNeeded() async {
        guard session == nil, !openFailed else { return }
        let path: String?
        #if DEBUG
        path = (try? model.workspaces.beginAccess(workspace))
            ?? (try? model.workspaces.beginLocalAccessForTesting(workspace))
        #else
        path = try? model.workspaces.beginAccess(workspace)
        #endif
        guard let path else {
            openFailed = true
            return
        }
        resolvedPath = path
        let newSession = TerminalSession(cwd: path, engine: model.engine)
        session = newSession
        try? newSession.start()
        #if DEBUG
        // Simulator harness: TERMX_AUTOCOMMANDS holds newline-separated
        // commands. Join with `;` and send once so the shell runs them
        // in order to completion.
        if let script = ProcessInfo.processInfo.environment["TERMX_AUTOCOMMANDS"], !script.isEmpty {
            let joined = script
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .joined(separator: " ; ")
            Task.detached {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                newSession.send(joined + "\n")
            }
        }
        #endif
    }

    private func teardownSession() {
        if let session {
            session.terminate()
            self.session = nil
        }
        model.workspaces.endAccess(workspace)
        resolvedPath = nil
    }
}
