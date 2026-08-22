import SwiftUI
import TermXFiles

@main struct TermXApp: App {
 @State private var showingPicker=false
 var body: some Scene { WindowGroup { NavigationStack { VStack(spacing:20) { Text("TermX").font(.largeTitle.bold()); Text("A local developer terminal").foregroundStyle(.secondary); Button("Choose Workspace") { showingPicker=true }.buttonStyle(.borderedProminent()) }.padding().navigationTitle("TermX") } } }
}
