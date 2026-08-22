import XCTest

/// Exercises the real workspace flow: tapping "Add Folder" must present the system
/// document picker (the path a user actually takes, as opposed to the DEBUG
/// auto-workspace hook used by the scripted terminal tests).
final class FolderPickerTests: XCTestCase {
    func testAddFolderPresentsSystemDocumentPicker() {
        let app = XCUIApplication()
        app.launch()

        let addFolder = app.buttons["Add Folder"]
        XCTAssertTrue(addFolder.waitForExistence(timeout: 15), "launcher did not show Add Folder")
        addFolder.tap()

        // The picker is hosted out-of-process; look for its recognisable chrome.
        let cancel = app.buttons["Cancel"]
        let browse = app.buttons["Browse"]
        let open = app.buttons["Open"]
        let appeared = cancel.waitForExistence(timeout: 15)
            || browse.waitForExistence(timeout: 3)
            || open.waitForExistence(timeout: 3)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "document-picker"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertTrue(appeared, "tapping Add Folder did not present the document picker")
    }

    /// The complete user path: pick a folder in the system picker, and get a live
    /// terminal bound to it via a security-scoped bookmark.
    func testPickingFolderOpensTerminalInThatFolder() {
        let app = XCUIApplication()
        app.launch()

        let addFolder = app.buttons["Add Folder"]
        XCTAssertTrue(addFolder.waitForExistence(timeout: 15))
        addFolder.tap()

        // In folder-picking mode "Open" selects the folder currently being browsed.
        let open = app.buttons["Open"]
        XCTAssertTrue(open.waitForExistence(timeout: 15), "picker never offered Open")
        open.tap()

        // The terminal screen is identifiable by its keyboard accessory bar.
        let esc = app.buttons["Esc"]
        XCTAssertTrue(esc.waitForExistence(timeout: 20),
                      "picking a folder did not open a terminal session")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "terminal-in-picked-folder"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
