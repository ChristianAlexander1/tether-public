#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Launcher screen: recent workspaces grid + "Open Folder…" button.
/// Implements the C3 deliverable requirement from docs/03-filesystem-folders.md.
public struct WorkspaceLauncherView: View {
    @ObservedObject private var viewModel: WorkspaceLauncherViewModel

    public init(store: WorkspaceStore, onSelect: @escaping (Workspace) -> Void) {
        self.viewModel = WorkspaceLauncherViewModel(store: store, onSelect: onSelect)
    }

    public var body: some View {
        NavigationStack {
            Group {
                if viewModel.workspaces.isEmpty {
                    emptyState
                } else {
                    workspaceGrid
                }
            }
            .navigationTitle("Workspaces")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await viewModel.addWorkspace() }
                    } label: {
                        Label("Open Folder", systemImage: "folder.badge.plus")
                    }
                }
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "Unknown error")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No Workspaces")
                .font(.title2.bold())
            Text("TermX runs commands inside a folder you pick.\nTap \"Open Folder\" to choose one from Files, iCloud Drive, or any storage provider.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await viewModel.addWorkspace() }
            } label: {
                Text("Open Folder…")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var workspaceGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                ForEach(viewModel.workspaces) { workspace in
                    WorkspaceCard(workspace: workspace) {
                        viewModel.onSelect(workspace)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            viewModel.remove(workspace)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - Workspace Card

private struct WorkspaceCard: View {
    let workspace: Workspace
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)

                VStack(spacing: 4) {
                    Text(workspace.name)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)

                    Text(workspace.mountPath)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .padding(.horizontal, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ViewModel

@MainActor
public final class WorkspaceLauncherViewModel: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var showError = false
    @Published var errorMessage: String?

    let store: WorkspaceStore
    let onSelect: (Workspace) -> Void

    init(store: WorkspaceStore, onSelect: @escaping (Workspace) -> Void) {
        self.store = store
        self.onSelect = onSelect
        refresh()
    }

    func refresh() {
        workspaces = store.recentWorkspaces()
    }

    func addWorkspace() async {
        do {
            let workspace = try await store.addWorkspace()
            refresh()
            onSelect(workspace)
        } catch is CancellationError {
            // User cancelled picker — not an error
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func remove(_ workspace: Workspace) {
        store.removeWorkspace(workspace)
        refresh()
    }
}
#endif
