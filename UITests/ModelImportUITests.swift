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
    func testSelectLiteRTLMFileClosesPickerAndImports() {
        let app = launchApp()
        openPicker(app)
        selectFixture("UI-Import-Test.litertlm", in: app)
        XCTAssertTrue(cancelButton(app).waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["模型"].exists)
        XCTAssertTrue(app.staticTexts["UI-Import-Test.litertlm"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
        snapshot(app, "Import-completed")

        app.staticTexts["UI-Import-Test.litertlm"].firstMatch.tap()
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
        XCTAssertTrue(cancelButton(app).waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    private func selectFixture(_ name: String, in app: XCUIApplication) {
        // CI seeds these small files in Documents; selection still goes through the real Files picker.
        let file = text(app, [name, (name as NSString).deletingPathExtension])
        if !file.exists {
            let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
            if browse.exists { browse.tap() }

            let local = text(app, ["On My iPhone", "我的 iPhone", "在我的 iPhone 上"])
            if local.waitForExistence(timeout: 5) {
                local.tap()
                let folder = text(app, ["Local AI Studio", "LocalAIStudio"])
                XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
                folder.tap()
            }
        }
        if !file.waitForExistence(timeout: 15) {
            snapshot(app, "Import-file-not-found")
            XCTFail("The seeded file is not visible in Files.\n\(app.debugDescription)")
            return
        }
        snapshot(app, "Import-file-selection")
        let document = app.cells.containing(.staticText, identifier: file.label).firstMatch
        XCTAssertTrue(document.exists, app.debugDescription)
        // Activate the document thumbnail instead of the separate file-name caption.
        document.images.firstMatch.tap()
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
        if open.waitForExistence(timeout: 2), open.isHittable { open.tap() }
    }

    @MainActor
    private func text(_ app: XCUIApplication, _ labels: [String]) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
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
