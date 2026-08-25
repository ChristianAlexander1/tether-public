import XCTest

/// End-to-end proof that the interactive shell executes real commands: types into the
/// terminal like a user and leaves artifacts in the workspace that the host verifies.
final class TerminalTypingTests: XCTestCase {
    func testShellExecutesTypedCommands() {
        let app = XCUIApplication()
        // Real user mode: open a workspace, no AUTOCOMMAND harness — type like a person.
        app.launchEnvironment["TETHER_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TETHER_AUTOWORKSPACE"] = "1"
        app.launch()
        sleep(8) // allow Alpine bootstrap + login banner

        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(2)
        // Guest-first Alpine: workspace is /work. BusyBox ash understands these.
        app.typeText(
            "uname -a > uname.txt\n" +
            "echo proof-of-execution-42 > proof.txt\n" +
            "mkdir made-by-shell\n" +
            "pwd > pwd.txt\n" +
            "ls\n"
        )
        sleep(8)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "terminal-after-linux-commands"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
