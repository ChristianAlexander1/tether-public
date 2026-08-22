#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import SwiftTerm

public struct TerminalSessionView: View {
    @ObservedObject private var session: TerminalSession
    @Binding private var theme: TerminalTheme
    @State private var ctrlIsSticky = false
    @State private var fontSize: CGFloat = 14
    @State private var selectedFont: TerminalFont = .jetBrainsMono

    public init(session: TerminalSession, theme: Binding<TerminalTheme> = .constant(.midnight)) {
        self.session = session
        self._theme = theme
    }

    public var body: some View {
        VStack(spacing: 0) {
            SwiftTermTerminalView(
                session: session,
                theme: theme,
                palette: theme.palette,
                font: selectedFont,
                fontSize: fontSize,
                ctrlIsSticky: $ctrlIsSticky
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            KeyboardAccessoryView(ctrlIsSticky: $ctrlIsSticky) { key in
                session.send(key.bytes)
            } onControl: { isSticky in
                ctrlIsSticky = isSticky
            } onCtrlC: {
                session.send(TerminalKey.ctrlC)
                ctrlIsSticky = false
            }
        }
        .background(theme.palette.background)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(URL(fileURLWithPath: session.cwd).lastPathComponent)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(theme.palette.foreground)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Theme", selection: $theme) {
                        ForEach(TerminalTheme.allCases) { item in Text(item.rawValue.capitalized).tag(item) }
                    }
                    Picker("Font", selection: $selectedFont) {
                        ForEach(TerminalFont.allCases) { item in Text(item.displayName).tag(item) }
                    }
                    Divider()
                    Stepper("Font \(Int(fontSize)) pt", value: $fontSize, in: 10...24)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }
}

private struct SwiftTermTerminalView: UIViewRepresentable {
    let session: TerminalSession
    let theme: TerminalTheme
    let palette: TerminalPalette
    let font: TerminalFont
    let fontSize: CGFloat
    @Binding var ctrlIsSticky: Bool

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: font.uiFont(size: fontSize))
        view.terminalDelegate = context.coordinator
        view.backgroundColor = UIColor(palette.background)
        view.linkReporting = .implicit
        view.clipsToBounds = true
        theme.apply(to: view, palette: palette, font: font, fontSize: fontSize)
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        view.backgroundColor = UIColor(palette.background)
        context.coordinator.session = session
        context.coordinator.ctrlIsSticky = ctrlIsSticky
        view.controlModifier = ctrlIsSticky
        theme.apply(to: view, palette: palette, font: font, fontSize: fontSize)
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var session: TerminalSession
        var ctrlIsSticky = false
        private var outputPump: TerminalOutputPump?

        init(session: TerminalSession) { self.session = session }

        func attach(to view: TerminalView) {
            let pump = TerminalOutputPump(terminalView: view)
            pump.start()
            outputPump = pump
            session.attachOutputHandler { [weak pump] data in
                pump?.enqueue(data)
            }
        }

        func detach() {
            outputPump?.stop()
            outputPump = nil
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.send(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session.resize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            DispatchQueue.main.async { UIApplication.shared.open(url) }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }

        func clipboardRead(source: TerminalView) -> Data? {
            UIPasteboard.general.string?.data(using: .utf8)
        }
    }
}

public struct KeyboardAccessoryView: View {
    @Binding private var ctrlIsSticky: Bool
    private let onKey: (TerminalKey) -> Void
    private let onControl: (Bool) -> Void
    private let onCtrlC: () -> Void

    public init(
        ctrlIsSticky: Binding<Bool>,
        onKey: @escaping (TerminalKey) -> Void,
        onControl: @escaping (Bool) -> Void,
        onCtrlC: @escaping () -> Void = {}
    ) {
        self._ctrlIsSticky = ctrlIsSticky
        self.onKey = onKey
        self.onControl = onControl
        self.onCtrlC = onCtrlC
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                accessoryButton("Esc") { onKey(.escape) }
                accessoryButton("Tab") { onKey(.tab) }
                accessoryButton("Ctrl", active: ctrlIsSticky) {
                    ctrlIsSticky.toggle()
                    onControl(ctrlIsSticky)
                }
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                    onCtrlC()
                    ctrlIsSticky = false
                    onControl(false)
                })
                accessoryButton("^C") { onCtrlC() }
                accessoryButton("⌥") {}
                ForEach([TerminalKey.left, .up, .down, .right], id: \.rawValue) { key in
                    accessoryButton(arrowTitle(key)) { onKey(key) }
                }
                accessoryButton("~") { onKey(.tilde) }
                accessoryButton("/") { onKey(.slash) }
                accessoryButton("-") { onKey(.dash) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    private func accessoryButton(_ title: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(.subheadline, design: .monospaced).weight(.semibold)).frame(minWidth: 38, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .tint(active ? .accentColor : .secondary)
    }

    private func arrowTitle(_ key: TerminalKey) -> String {
        switch key { case .left: return "←"; case .up: return "↑"; case .down: return "↓"; case .right: return "→"; default: return key.rawValue }
    }
}
#endif
