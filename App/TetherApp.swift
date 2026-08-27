import SwiftUI
import TermXCore
import TermXFiles
import TermXUI
import TetherSessionCore

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
    /// Scrollback snapshots persisted per workspace, so a force-quit does not
    /// lose the last screen of output.
    let scrollback = ScrollbackStore()
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
    /// One lifecycle state machine per session, plus the services it drives.
    @State private var lifecycle: SessionCommandRunner?
    @State private var lifecycleServices: WorkspaceSessionServices?
    @State private var lifecycleFailure: SessionFailure?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let session {
                TerminalSessionView(session: session, theme: $model.theme)
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
        .onChange(of: scenePhase) { phase in
            // Backgrounding is only meaningful once the shell is live; the
            // machine documents that suspending earlier would misplace state.
            switch phase {
            case .background:
                if lifecycle?.phase == .active { lifecycle?.send(.appBackgrounded) }
            case .active:
                if lifecycle?.phase == .suspended {
                    lifecycle?.send(.appForegrounded)
                    // Re-check the workspace here: a bookmark can go stale while
                    // suspended, and the machine defers that event until now.
                    if resolvedPath != nil, !model.workspaces.isStillAvailable(workspace) {
                        lifecycle?.send(.workspaceBecameUnavailable)
                    }
                }
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tetherLinuxRootfsRemoved)) { _ in
            lifecycle?.send(.rootfsRemovedExternally)
        }
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

        // One lifecycle machine per session. It owns bootstrap -> shell ->
        // teardown ordering; this view only supplies the services and events.
        let services = WorkspaceSessionServices(
            workspaceID: workspace.id.uuidString,
            integration: model.integration,
            scrollback: model.scrollback,
            startShell: { completion in completion(.success(())) },
            releaseScope: { [workspace, model] in model.workspaces.endAccess(workspace) },
            presentFailure: { failure in
                lifecycleFailure = failure
                startFailed = true
                startError = Self.describe(failure)
            }
        )
        let runner = SessionCommandRunner(services: services)
        lifecycleServices = services
        lifecycle = runner

        let newSession = TerminalSession(cwd: path, engine: model.engine)
        do {
            try newSession.start()
        } catch {
            lifecycle = nil
            lifecycleServices = nil
            model.workspaces.endAccess(workspace)
            resolvedPath = nil
            startFailed = true
            startError = error.localizedDescription
            return
        }
        services.session = newSession
        // A snapshot taken mid-TUI must end with the sequence that returns the
        // terminal to a sane state, or a restore would replay into a dead
        // alternate screen.
        services.modeStateProvider = { [weak newSession] in
            newSession?.terminalRestoreProvider?() ?? Data()
        }
        newSession.onShellExited = { [weak runner] code in
            runner?.send(.shellExited(code: code))
        }
        // The shell is already running by the time the machine is driven, so
        // walk it to `.active` with the outcomes that actually happened rather
        // than re-running the work.
        runner.send(.workspaceOpened)
        runner.send(.bootstrapSucceeded)
        runner.send(.shellStarted)
        guard !Task.isCancelled, model.selected?.id == workspace.id else {
            newSession.terminate()
            model.workspaces.endAccess(workspace)
            resolvedPath = nil
            return
        }
        // A host-proxied job that dies mid-TUI leaves the terminal wedged;
        // route its completion to the session so the view layer repairs it.
        model.integration.onHostJobFinished = { [weak newSession] code in
            newSession?.hostJobFinished(code: code)
        }
        // Host-run jobs live outside the guest's controlling terminal, so the
        // kernel never signals them on resize. Push the size down explicitly.
        newSession.onResize = { [weak model] cols, rows in
            model?.integration.resizeActiveRuntimes(cols: cols, rows: rows)
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
        model.integration.onHostJobFinished = nil
        let stopping = session
        session = nil

        if let lifecycle {
            // The machine emits the ordered sequence: signal the shell, wait
            // for the engine, stop the reader, close the PTY, release the
            // scope. Executing it in that order is what keeps the PTY from
            // being closed under a thread still blocked reading it.
            lifecycle.send(.userRequestedClose)
            lifecycle.send(.teardownFinished)
            self.lifecycle = nil
            lifecycleServices = nil
        } else {
            stopping?.terminate()
            if resolvedPath != nil {
                model.workspaces.endAccess(workspace)
            }
        }
        resolvedPath = nil
    }

    private static func describe(_ failure: SessionFailure) -> String {
        switch failure {
        case .bootstrapFailed(let message):
            return "Linux setup failed: \(message)"
        case .engineCrashed(let code):
            return "The shell exited unexpectedly (code \(code))."
        case .ptyError(let message):
            return "The terminal could not be opened: \(message)"
        case .workspaceUnavailable:
            return "This folder is no longer available. Pick it again with Add Folder."
        case .rootfsRemoved:
            return "Linux data was deleted while this session was open. Reopen to set it up again."
        }
    }
}
