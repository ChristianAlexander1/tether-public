import XCTest

/// Opens the Files and Storage screens from the terminal and captures them.
/// Element queries are avoided: snapshotting the terminal canvas is slow enough
/// to time out XCUITest's UI-query interface.
final class ScreensTests: XCTestCase {
    private func openMenuItem(_ name: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TETHER_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TETHER_AUTOWORKSPACE"] = "1"
        app.launchEnvironment["TETHER_AUTOCOMMANDS"] = ""
        app.launchEnvironment["TERMX_AUTOCOMMANDS"] = ""
        app.launch()
        sleep(5)
        app.buttons["workspaceMenu"].firstMatch.tap()
        sleep(2)
        app.buttons[name].firstMatch.tap()
        sleep(5)
        return app
    }

    func testStorageScreenOpens() {
        _ = openMenuItem("Storage")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "storage"; shot.lifetime = .keepAlways; add(shot)
    }

    func testFilesScreenOpens() {
        _ = openMenuItem("Files")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "files"; shot.lifetime = .keepAlways; add(shot)
    }

    func testCloseWorkspaceReturnsToPickerWithoutCrashing() {
        let app = XCUIApplication()
        app.launchEnvironment["TETHER_UI_TEST_MODE"] = "1"
        app.launchEnvironment["TETHER_AUTOWORKSPACE"] = "1"
        app.launchEnvironment["TETHER_AUTOCOMMANDS"] = ""
        app.launchEnvironment["TERMX_AUTOCOMMANDS"] = ""
        app.launch()

        XCTAssertTrue(app.buttons["workspaceMenu"].waitForExistence(timeout: 10))
        app.buttons["workspaceMenu"].tap()
        XCTAssertTrue(app.buttons["Close workspace"].waitForExistence(timeout: 3))
        app.buttons["Close workspace"].tap()

        XCTAssertTrue(app.buttons["Add Folder"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
    }
}
