import XCTest

final class StudioUITests: XCTestCase {
    @MainActor
    func testNavigationAndUnsupportedGeneration() throws {
        let app = XCUIApplication()
        app.launch()
        let input = app.descendants(matching: .any)["chatInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["sendMessage"].isEnabled)
        XCTAssertFalse(app.buttons["settingsButton"].exists)
        snapshot(app, "AI-light")

        app.tabBars.buttons["生图"].tap()
        XCTAssertTrue(app.staticTexts["本地生图尚未接入"].exists)
        XCTAssertFalse(app.buttons["settingsButton"].exists)
        app.buttons["管理模型"].tap()
        XCTAssertTrue(app.navigationBars["模型"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settingsButton"].exists)
        snapshot(app, "Models-light")

        app.tabBars.buttons["设备"].tap()
        XCTAssertTrue(app.navigationBars["设备"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["deviceMemoryValue"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settingsButton"].exists)
        XCTAssertTrue(app.staticTexts["系统等级，非摄氏温度"].isHittable)
        snapshot(app, "Device-light")
    }

    @MainActor
    func testDeviceSamplingContinuesAcrossTabsAndResumesAfterBackground() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["设备"].tap()
        let cpu = app.staticTexts["deviceCPUValue"]
        let count = app.staticTexts["deviceSampleCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            cpu.exists && cpu.label.contains("%")
        }, object: nil)
        wait(for: [ready], timeout: 10)
        let beforeSwitch = try sampleCount(count)

        app.tabBars.buttons["AI"].tap()
        // The acceptance case observes 15 seconds on another tab, with no Device view callbacks.
        Thread.sleep(forTimeInterval: 15)
        app.tabBars.buttons["设备"].tap()
        XCTAssertTrue(cpu.label.contains("%"), "Switching tabs must not discard the last valid CPU value.")
        XCTAssertGreaterThanOrEqual(try sampleCount(count), beforeSwitch + 6)
        snapshot(app, "Device-after-tab-switch")

        let beforeBackground = try sampleCount(count)
        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: nil)
        wait(for: [backgrounded], timeout: 5)
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(cpu.label.contains("%"), "Resume must retain the last CPU value while rebuilding its baseline.")
        XCTAssertGreaterThanOrEqual(try sampleCount(count), beforeBackground)
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = count.value as? String, let number = Int(value) else { return false }
            return number > beforeBackground + 1
        }, object: nil)
        wait(for: [resumed], timeout: 10)
        snapshot(app, "Device-after-background")
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
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        snapshot(app, "Download-validation")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["模型"].exists)
    }

    @MainActor
    func testAppearancePersistsAcrossLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["模型"].tap()
        app.buttons["settingsButton"].tap()
        let appearance = app.segmentedControls["appearancePicker"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.buttons["深色"].tap()
        XCTAssertTrue(appearance.buttons["深色"].isSelected)
        app.buttons["closeSettings"].tap()
        app.tabBars.buttons["设备"].tap()
        XCTAssertTrue(app.staticTexts["deviceMemoryValue"].waitForExistence(timeout: 5))
        snapshot(app, "Device-dark")
        app.tabBars.buttons["AI"].tap()
        snapshot(app, "AI-dark")
        app.terminate()
        app.launch()
        app.tabBars.buttons["模型"].tap()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        XCTAssertTrue(appearance.buttons["深色"].isSelected)
        appearance.buttons["跟随系统"].tap()
        app.buttons["closeSettings"].tap()
    }

    @MainActor
    private func sampleCount(_ element: XCUIElement) throws -> Int {
        let value = try XCTUnwrap(element.value as? String)
        return try XCTUnwrap(Int(value))
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
