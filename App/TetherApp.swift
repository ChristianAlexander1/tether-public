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
    lazy var engine: CoreEngineAdapter = CoreEngineAdapter(core: integration.makePrimaryEngine())
    @Published var selected: Workspace?
    @Published var theme: TerminalTheme = .midnight
    @Published var errorMessage: String?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #if DEBUG
        // A test workspace must never become a user's remembered workspace.
        // Remove records left by older builds before creating a transient one.
        workspaces.removeLocalWorkspaceRegistrations(rootURL: docs)
        let testEnvironment = ProcessInfo.processInfo.environment
        let isUITest = (testEnvironment["TETHER_UI_TEST_MODE"]
            ?? testEnvironment["TERMX_UI_TEST_MODE"]) == "1"
        if isUITest,
           (testEnvironment["TETHER_AUTOWORKSPACE"]
            ?? testEnvironment["TERMX_AUTOWORKSPACE"]) == "1" {
            let ws = Workspace(name: "Documents", mountPath: "/workspaces/Documents")
            if (try? workspaces.registerLocalWorkspaceForTesting(
                ws, rootURL: docs, persisted: false
            )) != nil {
                selected = ws
                return
            }
        }
        #else
        // Migrate away any DEBUG automation bookmark that reached a release
        // container through a restored Simulator backup.
        workspaces.removeLocalWorkspaceRegistrations(rootURL: docs)
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

    func forgetWorkspace(_ workspace: Workspace) {
        workspaces.removeWorkspace(workspace)
        if selected?.id == workspace.id { selected = nil }
    }
}

/// Bridges TermXCore's TerminalEngine to TermXUI's frozen TerminalEngine seam.
final class CoreEngineAdapter: TermXUI.TerminalEngine {
    private let core: any TermXCore.TerminalEngine
    init(core: any TermXCore.TerminalEngine) { self.core = core }
    func startShell(cwd: String, env: [String: String], ptySlave: Int32, onExit: @escaping (Int32) -> Void) throws -> Int32 {
        // Pass the host workspace path so Linux login can mount it at /work and
        // host-backed tools (claude/node) can resolve files correctly.
        var env = env
        env["TETHER_HOST_CWD"] = cwd
        env["TERMX_HOST_CWD"] = cwd
        return try core.startShell(cwd: cwd, env: env, ptySlave: ptySlave, onExit: onExit)
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
                    Text("Choose a folder from Files. Tether keeps Linux and global tools separately in app storage.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .background(Color(uiColor: .systemGroupedBackground))
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
    @State private var startFailed = false
    @State private var startError: String?
    /// Bumped only for explicit retry; must not change during close/teardown.
    @State private var openAttempt = 0
    @State private var showFiles = false
    @State private var showStorage = false
    @State private var showLicenses = false
    @State private var didTearDown = false

    var body: some View {
        Group {
            if let session {
                TerminalSessionView(session: session, theme: $model.theme) { force in
                    model.integration.interruptActiveRuntimes(forceNodeSignal: force)
                }
            } else if openFailed {
                workspaceErrorView(
                    title: "Can't reopen this folder",
                    message: "Pick it again with Add Folder. iOS sometimes needs a fresh permission after the app is closed.",
                    actionTitle: "Choose another folder"
                ) {
                    model.forgetWorkspace(workspace)
                }
            } else if startFailed {
                workspaceErrorView(
                    title: "Terminal failed to start",
                    message: startError ?? "The shell could not open a PTY session.",
                    actionTitle: "Try again"
                ) {
                    startFailed = false
                    startError = nil
                    openAttempt += 1
                }
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
                        model.closeWorkspace()
                    }
                    .accessibilityIdentifier("closeWorkspace")
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
        .task(id: openAttempt) { await openIfNeeded() }
        .onDisappear {
            // Only tear down when leaving the workspace entirely — not when a
            // sheet (Storage / Files / Licenses) covers this view. Tearing down
            // on every disappear left a dead/white terminal after dismissing.
            if model.selected?.id != workspace.id {
                teardownSession()
            }
        }
    }

    @ViewBuilder
    private func workspaceErrorView(
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @MainActor
    private func openIfNeeded() async {
        guard model.selected?.id == workspace.id else { return }
        guard session == nil, !openFailed, !startFailed else { return }
        let path: String?
        #if DEBUG
        path = (try? model.workspaces.beginAccess(workspace))
            ?? (try? model.workspaces.beginLocalAccessForTesting(workspace))
        #else
        path = try? model.workspaces.beginAccess(workspace)
        #endif
        guard !Task.isCancelled, model.selected?.id == workspace.id else {
            if path != nil { model.workspaces.endAccess(workspace) }
            return
        }
        guard let path else {
            openFailed = true
            return
        }
        resolvedPath = path
        didTearDown = false
        let newSession = TerminalSession(cwd: path, engine: model.engine)
        do {
            try newSession.start()
        } catch {
            model.workspaces.endAccess(workspace)
            resolvedPath = nil
            startFailed = true
            startError = error.localizedDescription
            return
        }
        guard !Task.isCancelled, model.selected?.id == workspace.id else {
            newSession.terminate()
            model.workspaces.endAccess(workspace)
            resolvedPath = nil
            return
        }
        session = newSession
        #if DEBUG
        // Simulator harness: TETHER_AUTOCOMMANDS holds newline-separated
        // commands, or TETHER_AUTOCOMMAND_FILE points at a script in the
        // workspace. Join with `;` and send once so the shell runs them
        // in order to completion. A file avoids SIMCTL_CHILD env size /
        // newline limits for longer acceptance batches.
        let script: String? = {
            let environment = ProcessInfo.processInfo.environment
            guard (environment["TETHER_UI_TEST_MODE"]
                ?? environment["TERMX_UI_TEST_MODE"]) == "1" else { return nil }
            if let path = environment["TETHER_AUTOCOMMAND_FILE"] ?? environment["TERMX_AUTOCOMMAND_FILE"],
               !path.isEmpty,
               let fromFile = try? String(contentsOfFile: path, encoding: .utf8) {
                return fromFile
            }
            return environment["TETHER_AUTOCOMMANDS"] ?? environment["TERMX_AUTOCOMMANDS"]
        }()
        if let script, !script.isEmpty {
            // Line-oriented harness. Special lines (testing only):
            //   #delay N   — wait N seconds before the next send
            //   #enter     — send a lone newline (confirm menus / theme pickers)
            //   #raw:TEXT  — send TEXT without appending newline
            // Everything else is sent as `line\n` (a shell or TUI command).
            let lines = script
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("# ") && $0 != "#" }
            Task.detached {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                for line in lines {
                    if line.hasPrefix("#delay ") {
                        let n = Double(line.dropFirst("#delay ".count).trimmingCharacters(in: .whitespaces)) ?? 1
                        try? await Task.sleep(nanoseconds: UInt64(max(0.1, n) * 1_000_000_000))
                        continue
                    }
                    if line == "#enter" {
                        newSession.send("\n")
                        continue
                    }
                    if line.hasPrefix("#raw:") {
                        newSession.send(String(line.dropFirst(5)))
                        continue
                    }
                    if line.hasPrefix("#") { continue }
                    newSession.send(line + "\n")
                }
            }
        }
        #endif
    }

    private func teardownSession() {
        guard !didTearDown else { return }
        didTearDown = true
        model.integration.interruptActiveRuntimes()
        let stopping = session
        session = nil
        // terminate() only requests guest shutdown and schedules PTY closing; it
        // never waits on the main thread. Request it before releasing the iOS
        // security scope so the guest cannot race a revoked workspace mount.
        stopping?.terminate()
        if resolvedPath != nil {
            model.workspaces.endAccess(workspace)
        }
        resolvedPath = nil
    }
}
