import Foundation

/// Handles standardized terminal protocols not yet understood by the renderer,
/// while passing every unrelated byte through unchanged.
final class TerminalProtocolAdapter {
    private var pending = Data()
    private(set) var reportsColorSchemeChanges = false
    private var isDark: Bool
    var sendReply: ((Data) -> Void)?

    init(isDark: Bool, sendReply: ((Data) -> Void)? = nil) {
        self.isDark = isDark
        self.sendReply = sendReply
    }

    func updateColorScheme(isDark: Bool) {
        guard self.isDark != isDark else { return }
        self.isDark = isDark
        if reportsColorSchemeChanges { sendColorSchemeReport() }
    }

    func process(_ input: Data) -> Data {
        pending.append(input)
        var output = Data()
        var index = pending.startIndex
        while index < pending.endIndex {
            guard pending[index] == 0x1B else {
                output.append(pending[index])
                index = pending.index(after: index)
                continue
            }
            let bracket = pending.index(after: index)
            guard bracket < pending.endIndex else { break }
            guard pending[bracket] == 0x5B else {
                output.append(pending[index])
                index = bracket
                continue
            }
            var end = pending.index(after: bracket)
            while end < pending.endIndex, !(0x40...0x7E).contains(pending[end]) {
                end = pending.index(after: end)
            }
            guard end < pending.endIndex else { break }
            let afterEnd = pending.index(after: end)
            let sequence = Data(pending[index..<afterEnd])
            if !handle(sequence) { output.append(sequence) }
            index = afterEnd
        }
        pending = index < pending.endIndex ? Data(pending[index...]) : Data()
        return output
    }

    private func handle(_ data: Data) -> Bool {
        guard let sequence = String(data: data, encoding: .ascii) else { return false }
        switch sequence {
        case "\u{1B}[?2031h":
            reportsColorSchemeChanges = true
            return true
        case "\u{1B}[?2031l":
            reportsColorSchemeChanges = false
            return true
        case "\u{1B}[?996n":
            sendColorSchemeReport()
            return true
        case "\u{1B}[?2031$p":
            let state = reportsColorSchemeChanges ? 1 : 2
            sendReply?(Data("\u{1B}[?2031;\(state)$y".utf8))
            return true
        default:
            return false
        }
    }

    private func sendColorSchemeReport() {
        let value = isDark ? 1 : 2
        sendReply?(Data("\u{1B}[?997;\(value)n".utf8))
    }
}
