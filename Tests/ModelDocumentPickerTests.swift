import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import LocalAIStudio

final class ModelDocumentPickerTests: XCTestCase {
    func testAppDisplayName() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "AI Studio")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "AI Studio")
    }

    func testProductionAppDoesNotExposeFixtureDocuments() {
        XCTAssertNotEqual(Bundle.main.object(forInfoDictionaryKey: "UIFileSharingEnabled") as? Bool, true)
    }

    @MainActor
    func testProductionPickerUsesCopyAndExplicitConfirmation() {
        let coordinator = ModelDocumentPicker { _ in }.makeCoordinator()
        // Exercise the actual factory used by makeUIViewController, not a lookalike picker.
        let picker = ModelDocumentPicker.makePicker(delegate: coordinator)
        XCTAssertEqual(picker.documentPickerMode, .import)
        XCTAssertTrue(picker.allowsMultipleSelection)
        XCTAssertTrue(picker.shouldShowFileExtensions)
        XCTAssertTrue(picker.delegate === coordinator)
    }

    @MainActor
    func testSelectionForwardsEveryConfirmedCopy() {
        let urls = [URL(fileURLWithPath: "/tmp/first.litertlm"), URL(fileURLWithPath: "/tmp/second.gguf")]
        var selections: [[URL]] = []
        let coordinator = ModelDocumentPicker { selections.append($0) }.makeCoordinator()
        let picker = ModelDocumentPicker.makePicker(delegate: coordinator)
        XCTAssertTrue(selections.isEmpty)
        coordinator.documentPicker(picker, didPickDocumentsAt: urls)
        XCTAssertEqual(selections, [urls])
    }

    @MainActor
    func testCancellationReturnsNoSelection() {
        var selections: [[URL]] = []
        let coordinator = ModelDocumentPicker { selections.append($0) }.makeCoordinator()
        let picker = ModelDocumentPicker.makePicker(delegate: coordinator)
        coordinator.documentPickerWasCancelled(picker)
        XCTAssertEqual(selections, [[]])
    }
}
