import XCTest

final class StudioUITests: XCTestCase {
    @MainActor
    func testNavigationAndUnsupportedGeneration() throws {
        let app = XCUIApplication()
        app.launch()
        let input = app.descendants(matching: .any)["chatInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["sendMessage"].isEnabled)
        snapshot(app, "AI-light")

        app.tabBars.buttons["生图"].tap()
        XCTAssertTrue(app.staticTexts["本地生图尚未接入"].exists)
        app.buttons["管理模型"].tap()
        XCTAssertTrue(app.navigationBars["模型"].waitForExistence(timeout: 5))
        snapshot(app, "Models-light")

        app.tabBars.buttons["设备"].tap()
        XCTAssertTrue(app.navigationBars["设备"].waitForExistence(timeout: 5))
        snapshot(app, "Device-light")
    }

    @MainActor
    func testDownloadRejectsInsecureURLBeforeNetwork() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["模型"].tap()
        XCTAssertTrue(app.buttons["addModel"].waitForExistence(timeout: 10))
        app.buttons["addModel"].tap()
        app.buttons["从 HTTPS 下载"].tap()
        let field = app.descendants(matching: .any)["downloadURL"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("http://example.com/model.litertlm")
        app.buttons["startDownload"].tap()
        XCTAssertTrue(app.staticTexts["downloadError"].waitForExistence(timeout: 5))
        snapshot(app, "Download-validation")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["模型"].exists)
    }

    @MainActor
    func testAppearancePersistsAcrossLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["settingsButton"].tap()
        let appearance = app.segmentedControls["appearancePicker"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.buttons["深色"].tap()
        XCTAssertTrue(appearance.buttons["深色"].isSelected)
        app.buttons["closeSettings"].tap()
        snapshot(app, "AI-dark")
        app.terminate()
        app.launch()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        XCTAssertTrue(appearance.buttons["深色"].isSelected)
        appearance.buttons["跟随系统"].tap()
        app.buttons["closeSettings"].tap()
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
