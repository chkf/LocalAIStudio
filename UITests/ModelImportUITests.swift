import XCTest

final class ModelImportUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testFilePickerCanCancelAndOpenAgain() {
        let app = launchApp()
        openPicker(app)
        snapshot(app, "Import-picker")
        cancelButton(app).tap()
        XCTAssertTrue(cancelButton(app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["模型"].exists)
        openPicker(app)
        cancelButton(app).tap()
        XCTAssertTrue(cancelButton(app).waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }

    @MainActor
    func testSelectionCanBeCancelledBeforeOpenWithoutImporting() {
        let app = launchApp()
        let before = app.staticTexts.matching(identifier: "UI-Import-Test.litertlm").count
        openPicker(app)
        selectFixture("UI-Import-Test.litertlm", in: app, confirm: false)
        cancelButton(app).tap()
        XCTAssertTrue(cancelButton(app).waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "UI-Import-Test.litertlm").count, before)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }

    @MainActor
    func testSelectLiteRTLMFileClosesPickerAndImports() {
        let app = launchApp()
        let imported = app.staticTexts.matching(identifier: "UI-Import-Test.litertlm")
        let before = imported.count
        openPicker(app)
        selectFixture("UI-Import-Test.litertlm", in: app)
        XCTAssertTrue(cancelButton(app).waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars["模型"].exists)
        let added = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in imported.count > before }, object: nil)
        wait(for: [added], timeout: 15)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
        snapshot(app, "Import-completed")
        imported.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["模型详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "权重尚未验证")).firstMatch.exists)
    }

    @MainActor
    func testUnsupportedFileShowsErrorAfterPickerCloses() {
        let app = launchApp()
        openPicker(app)
        selectFixture("UI-Unsupported-File.txt", in: app)
        let alert = app.alerts["操作未完成"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(cancelButton(app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "请选择单个模型文件")).firstMatch.exists)
        snapshot(app, "Import-unsupported")
        alert.buttons["好"].tap()
        XCTAssertTrue(app.navigationBars["模型"].exists)
        XCTAssertFalse(app.staticTexts["UI-Unsupported-File.txt"].exists)
        let imported = app.staticTexts.matching(identifier: "UI-Import-Test.litertlm")
        let beforeRetry = imported.count
        openPicker(app)
        selectFixture("UI-Import-Test.litertlm", in: app)
        XCTAssertTrue(cancelButton(app).waitForNonExistence(timeout: 15))
        let added = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in imported.count > beforeRetry }, object: nil)
        wait(for: [added], timeout: 15)
        XCTAssertFalse(alert.exists)
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.tabBars.buttons["模型"].tap()
        XCTAssertTrue(app.buttons["addModel"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func openPicker(_ app: XCUIApplication) {
        let directImport = app.buttons["importModel"].firstMatch
        if directImport.exists && directImport.isHittable {
            directImport.tap()
        } else {
            app.buttons["addModel"].tap()
            XCTAssertTrue(directImport.waitForExistence(timeout: 5))
            directImport.tap()
        }
        XCTAssertTrue(cancelButton(app).waitForExistence(timeout: 30), app.debugDescription)
    }

    @MainActor
    private func selectFixture(_ name: String, in app: XCUIApplication, confirm: Bool = true) {
        let picker = app.otherElements["Browse View (Picker)"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        let file = text(picker, [name, (name as NSString).deletingPathExtension])
        if !file.exists {
            let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
            if browse.exists { browse.tap() }
            let local = text(picker, ["On My iPhone", "我的 iPhone", "在我的 iPhone 上"])
            if local.waitForExistence(timeout: 5) {
                local.tap()
                let folder = text(picker, ["AI Studio"])
                XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
                folder.tap()
            }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 15), app.debugDescription)
        let document = picker.cells.containing(.staticText, identifier: file.label).firstMatch
        XCTAssertTrue(document.exists, app.debugDescription)
        document.tap()
        // A tap must select, not import. Confirmation is mandatory, not optional.
        XCTAssertTrue(picker.exists, "The picker closed before Open was confirmed")
        XCTAssertFalse(app.otherElements["importStatus"].exists)
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(open.isEnabled && open.isHittable, app.debugDescription)
        snapshot(app, "Import-selected-before-open")
        if confirm { open.tap() }
    }

    @MainActor
    private func text(_ root: XCUIElement, _ labels: [String]) -> XCUIElement {
        root.staticTexts.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    @MainActor
    private func cancelButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
