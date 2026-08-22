import Foundation
import SwiftTerm

final class NullTerminalDelegate: TerminalDelegate {
    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
    func setTerminalTitle(source: Terminal, title: String) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
    func sizeChanged(source: Terminal) {}
    func scrolled(source: Terminal, yDisp: Int) {}
    func linefeed(source: Terminal) {}
    func bufferActivated(source: Terminal) {}
    func bell(source: Terminal) {}
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

enum TerminalBufferSnapshot {
    static func capture(_ terminal: Terminal) -> String {
        var lines: [String] = []
        for row in 0..<terminal.rows {
            var line = ""
            for col in 0..<terminal.cols {
                if let character = terminal.getCharacter(col: col, row: row), character != "\0" {
                    line.append(character)
                } else {
                    line.append(" ")
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
