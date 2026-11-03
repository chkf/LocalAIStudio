import XCTest

final class StudioUITests: XCTestCase {
    @MainActor
    func testChatKeyboardDismissesWithDownwardSwipeOnShortConversation() {
        let app = XCUIApplication()
        app.launch()
        let input = app.descendants(matching: .any)["chatInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.56))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testChatOptionsAndGlobalSettings() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["chatMicrophone"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["chatStatus"].exists)
        app.buttons["对话选项"].tap()
        app.buttons["模型配置"].tap()
        XCTAssertTrue(app.navigationBars["对话设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["systemPromptEditor"].exists)
        XCTAssertTrue(app.buttons["applyChatSettings"].exists)
        app.buttons["取消"].tap()
        app.tabBars.buttons["模型"].tap()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["languagePicker"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["themeColorPicker"].exists)
    }

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

        app.tabBars.buttons["System"].tap()
        XCTAssertTrue(app.navigationBars["System"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["deviceMemoryValue"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["systemRAMGauge"].exists)
        XCTAssertFalse(app.buttons["settingsButton"].exists)
        XCTAssertFalse(app.staticTexts["系统等级，非摄氏温度"].exists)
        snapshot(app, "System-light")

        app.buttons["deviceDetailsButton"].tap()
        XCTAssertTrue(app.navigationBars["设备信息"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["系统等级，非摄氏温度"].exists)
        snapshot(app, "System-details")
        app.buttons["closeDeviceDetails"].tap()
        app.otherElements["systemMemoryCard"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["内存"].waitForExistence(timeout: 5))
        snapshot(app, "System-memory-details")
        app.buttons["closeDeviceDetails"].tap()
        app.otherElements["systemStorageCard"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["存储"].waitForExistence(timeout: 5))
        app.buttons["closeDeviceDetails"].tap()
    }

    @MainActor
    func testDeviceSamplingContinuesAcrossTabsAndResumesAfterBackground() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["System"].tap()
        let cpu = app.staticTexts["deviceCPUValue"]
        XCTAssertTrue(app.buttons["deviceDetailsButton"].waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            cpu.exists && cpu.label.contains("%")
        }, object: nil)
        wait(for: [ready], timeout: 10)
        let beforeSwitch = try sampleCount(app)

        app.tabBars.buttons["AI"].tap()
        // Observe another tab without Device view lifecycle callbacks.
        Thread.sleep(forTimeInterval: 15)
        app.tabBars.buttons["System"].tap()
        XCTAssertTrue(cpu.label.contains("%"), "Switching tabs must not discard the last valid CPU value.")
        XCTAssertGreaterThanOrEqual(try sampleCount(app), beforeSwitch + 6)
        snapshot(app, "System-after-tab-switch")

        let beforeBackground = try sampleCount(app)
        XCUIDevice.shared.press(.home)
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: nil)
        wait(for: [backgrounded], timeout: 5)
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(cpu.label.contains("%"), "Resume must retain the last CPU value while rebuilding its baseline.")
        app.buttons["deviceDetailsButton"].tap()
        let count = app.staticTexts["deviceSampleCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 10), app.debugDescription)
        let afterResume = try countValue(count)
        XCTAssertGreaterThanOrEqual(afterResume, beforeBackground)
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            // Re-query the live text instead of retaining a resolved accessibility snapshot.
            let latest = app.staticTexts["deviceSampleCount"]
            guard latest.exists, let number = self.sampleNumber(latest.label) else { return false }
            return number > afterResume + 1
        }, object: nil)
        wait(for: [resumed], timeout: 30)
        app.buttons["closeDeviceDetails"].tap()
        snapshot(app, "System-after-background")
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
        app.tabBars.buttons["System"].tap()
        XCTAssertTrue(app.staticTexts["deviceMemoryValue"].waitForExistence(timeout: 5))
        snapshot(app, "System-dark")
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
    func testSystemSupportsAccessibilityTextSize() {
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        app.tabBars.buttons["System"].tap()
        XCTAssertTrue(app.navigationBars["System"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["systemRAMGauge"].waitForExistence(timeout: 5))
        snapshot(app, "System-accessibility-text")
        app.buttons["deviceDetailsButton"].tap()
        XCTAssertTrue(app.navigationBars["设备信息"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["closeDeviceDetails"].isHittable)
        app.buttons["closeDeviceDetails"].tap()
    }

    @MainActor
    private func sampleCount(_ app: XCUIApplication) throws -> Int {
        // Read the real counter in details, not a toolbar button's system-owned value.
        app.buttons["deviceDetailsButton"].tap()
        defer { app.buttons["closeDeviceDetails"].tap() }
        let counter = app.staticTexts["deviceSampleCount"]
        XCTAssertTrue(counter.waitForExistence(timeout: 10), app.debugDescription)
        return try countValue(counter)
    }

    @MainActor
    private func countValue(_ element: XCUIElement) throws -> Int {
        let text = element.label
        return try XCTUnwrap(sampleNumber(text), "Unexpected sample counter: \(text)")
    }

    private func sampleNumber(_ label: String) -> Int? {
        // LabeledContent exposes its title and value together: "最近样本, 5".
        label.split(separator: ",").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
