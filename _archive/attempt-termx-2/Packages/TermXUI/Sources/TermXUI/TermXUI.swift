import SwiftUI
import TermXCore

public struct TerminalSession: Identifiable { public let id=UUID(); public var cwd:String; public var env:[String:String]; public var lines:[String]=[]; public var history:[String]=[]; public init(cwd:String, env:[String:String]) { self.cwd=cwd; self.env=env } }

public struct TerminalView: View {
    @State private var session: TerminalSession; @State private var command=""; @State private var engine=ShellCore(); @State private var historyIndex: Int?; @FocusState private var focused: Bool
    public init(cwd:String, env:[String:String]) { _session=State(initialValue:TerminalSession(cwd:cwd,env:env)) }
    public var body: some View { VStack(spacing:0) { ScrollViewReader { scroll in ScrollView { LazyVStack(alignment:.leading,spacing:4) { ForEach(Array(session.lines.enumerated()),id:\.offset) { i,line in Text(line).font(.system(.body,design:.monospaced)).foregroundStyle(.green).frame(maxWidth:.infinity,alignment:.leading).id(i) } } .padding(14) }.background(Color.black).onChange(of:session.lines.count) { _ in if let last=session.lines.indices.last { withAnimation { scroll.scrollTo(last) } } } }
            HStack(alignment:.top,spacing:8) { Text("\(session.cwd) $").foregroundStyle(.cyan).font(.system(.body,design:.monospaced)); TextField("command",text:$command,axis:.vertical).font(.system(.body,design:.monospaced)).foregroundStyle(.white).focused($focused).onSubmit { execute() }; Button("↑") { previous() }.buttonStyle(.bordered).accessibilityLabel("Previous command"); Button("↓") { next() }.buttonStyle(.bordered).accessibilityLabel("Next command"); Button("Run") { execute() }.buttonStyle(.borderedProminent) }.padding(12).background(Color(white:0.1)) }.background(Color.black).preferredColorScheme(.dark).task { focused=true } }
    private func execute() { let line=command.trimmingCharacters(in:.whitespacesAndNewlines); guard !line.isEmpty else { return }; session.lines.append("\(session.cwd) $ \(line)"); session.history.append(line); historyIndex=nil; let status=engine.run(line,cwd:&session.cwd,env:&session.env,output:{ session.lines.append(contentsOf:$0.split(separator:"\n",omittingEmptySubsequences:false).map(String.init)) },error:{ session.lines.append("\u{1b}[31m\($0)\u{1b}[0m") }); session.lines.append("[exit \(status)]"); command="" }
    private func previous() { guard !session.history.isEmpty else{return}; historyIndex=min((historyIndex ?? session.history.count)-1,session.history.count-1); command=session.history[historyIndex!] }
    private func next() { guard let i=historyIndex else{return}; if i+1<session.history.count { historyIndex=i+1; command=session.history[i+1] } else { historyIndex=nil; command="" } }
}
