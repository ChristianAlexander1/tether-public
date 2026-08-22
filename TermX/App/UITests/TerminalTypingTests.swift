import XCTest

/// End-to-end proof that the interactive shell executes real commands: types into the
/// terminal like a user and leaves artifacts in the workspace that the host verifies.
final class TerminalTypingTests: XCTestCase {
    func testShellExecutesTypedCommands() {
        let app = XCUIApplication()
        app.launchEnvironment["TERMX_AUTOWORKSPACE"] = "1"
        app.launch()
        sleep(4)

        // Tap once to focus the terminal, then send every line in one event batch —
        // repeated accessibility snapshots of the terminal canvas time out in XCUITest.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(2)
        app.typeText(
            "echo proof-of-execution-42 > proof.txt\n" +
            "mkdir made-by-shell\n" +
            "echo hello | grep hell > piped.txt\n" +
            "echo $((6*7)) > math.txt\n" +
            "ls\n"
        )
        sleep(4)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "terminal-after-commands"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
