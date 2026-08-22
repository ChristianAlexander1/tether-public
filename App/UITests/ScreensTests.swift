import XCTest

/// Opens the Files and Storage screens from the terminal and captures them.
/// Element queries are avoided: snapshotting the terminal canvas is slow enough
/// to time out XCUITest's UI-query interface.
final class ScreensTests: XCTestCase {
    private func openMenuItem(_ name: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TERMX_AUTOWORKSPACE"] = "1"
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
}
