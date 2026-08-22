import SwiftUI
import TermXCore
import TermXFiles
import TermXUI

@main
struct TermXApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene { WindowGroup { ContentView().environmentObject(model) } }
}

final class AppModel: ObservableObject {
    @Published var workspaces:[Workspace] = []; @Published var selected:Workspace?
    let store=WorkspaceStore()
    init(){workspaces=store.restoreAll();selected=workspaces.first}
    func add(url:URL){ if let w=try? store.addWorkspace(url:url){workspaces.append(w);selected=w} }
}

struct ContentView: View {
    @EnvironmentObject var model:AppModel; @State private var showingSettings=false; @State private var showingImporter=false
    var body: some View { NavigationSplitView { List(selection:$model.selected){ Section("Workspaces"){ ForEach(model.workspaces){ w in Label(w.name,systemImage:"folder").tag(w as Workspace?) } } } .navigationTitle("TermX").toolbar { ToolbarItem(placement:.primaryAction){Button {showingImporter=true} label:{Image(systemName:"folder.badge.plus")}}; ToolbarItem {Button {showingSettings=true} label:{Image(systemName:"gear")}} } } detail: { if let w=model.selected { let path=(try? model.store.beginAccess(w)) ?? w.realPath; TerminalView(cwd:path,env:TermXEnvironment.defaults(sandbox:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first!.deletingLastPathComponent().path)) } else { ContentUnavailableView("Choose a workspace",systemImage:"terminal",description:Text("Add a folder to start a local terminal session.")) } } .fileImporter(isPresented:$showingImporter,allowedContentTypes:[.folder]) { result in if case .success(let url)=result { model.add(url:url) } } .sheet(isPresented:$showingSettings){SettingsView()} }
}
struct SettingsView: View { var body: some View { NavigationStack { List { Section("Appearance"){Text("Dark terminal theme");Text("JetBrains Mono compatible fallback")}; Section("Capabilities"){Label("Native command engine",systemImage:"checkmark.circle");Label("Python and Node launchers",systemImage:"checkmark.circle");Label("Claude Code launcher",systemImage:"checkmark.circle");Label("Linux compatibility lane",systemImage:"info.circle")}; Section("Licenses"){Text("TermX uses permissive open-source components. See NOTICES in the distribution for full copyright texts.").font(.footnote)} }.navigationTitle("Settings") } }
