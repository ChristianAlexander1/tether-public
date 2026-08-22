import SwiftUI
import TermXCore

@MainActor
public final class TerminalSession: ObservableObject {
    @Published public private(set) var lines: [String] = ["TermX — workspace terminal ready.", "Type `help` for available commands."]
    @Published public var input = ""
    @Published public private(set) var cwd: String
    private let engine: TermXCommandEngine
    private var commandHistory: [String] = []
    private var historyIndex: Int?
    public init(cwd: String, engine: TermXCommandEngine = .shared) { self.cwd = cwd; self.engine = engine }
    public func submit() {
        let command = input; input = ""; guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        commandHistory.append(command); historyIndex = nil; lines.append("\u{001B}[32m\(prompt)\u{001B}[0m \(command)")
        Task {
            do {
                let result = try await engine.execute(command, cwd: cwd, environment: TermXCommandEngine.defaultEnvironment(home: NSHomeDirectory()))
                if !result.output.isEmpty { lines.append(contentsOf: result.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)) }
                if command.hasPrefix("cd ") { let destination = command.dropFirst(3).trimmingCharacters(in: .whitespaces); let candidate = URL(fileURLWithPath: destination.hasPrefix("/") ? String(destination) : cwd).appendingPathComponent(destination.hasPrefix("/") ? "" : String(destination)).standardizedFileURL.path; var isDir: ObjCBool = false; if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue { cwd = candidate } }
                if result.exitCode != 0 { lines.append("[exit \(result.exitCode)]") }
            } catch { lines.append("termx: \(error.localizedDescription)") }
        }
    }
    public func historyUp() { guard !commandHistory.isEmpty else { return }; let i = max(0, (historyIndex ?? commandHistory.count) - 1); historyIndex = i; input = commandHistory[i] }
    public func historyDown() { guard let i = historyIndex else { return }; if i + 1 < commandHistory.count { historyIndex = i + 1; input = commandHistory[i + 1] } else { historyIndex = nil; input = "" } }
    public func sendControl(_ value: String) { input.append(value) }
    private var prompt: String { "termx:\(URL(fileURLWithPath: cwd).lastPathComponent)$" }
}

public struct TerminalView: View {
    @StateObject private var session: TerminalSession
    public init(cwd: String) { _session = StateObject(wrappedValue: TerminalSession(cwd: cwd)) }
    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView { LazyVStack(alignment: .leading, spacing: 3) { ForEach(Array(session.lines.enumerated()), id: \.offset) { index, line in Text(line).id(index) } }.frame(maxWidth: .infinity, alignment: .leading).padding(12) }.onChange(of: session.lines.count) { _ in if let last = session.lines.indices.last { proxy.scrollTo(last, anchor: .bottom) } }
            }
            Divider()
            HStack(spacing: 8) { Text("termx:").foregroundStyle(.green); TextField("command", text: $session.input).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.go).onSubmit { session.submit() } }
                .font(.system(.body, design: .monospaced)).padding(12).background(Color.black)
            HStack { Button("Esc") { session.sendControl("\u{001B}") }; Button("Ctrl-C") { session.sendControl("^C") }; Button("Tab") { session.sendControl("\t") }; Button("↑") { session.historyUp() }; Button("↓") { session.historyDown() }; Spacer() }.font(.caption.monospaced()).buttonStyle(.bordered).padding(8).background(Color(.secondarySystemBackground))
        }.font(.system(.body, design: .monospaced)).foregroundStyle(.green).background(Color.black.ignoresSafeArea()).preferredColorScheme(.dark)
    }
}
