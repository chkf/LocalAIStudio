import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import LocalAIStudio

final class ModelDocumentPickerTests: XCTestCase {
    @MainActor
    func testSelectionForwardsURLWithoutReadingOrCopyingIt() {
        let url = URL(fileURLWithPath: "/unavailable-provider/模型.litertlm")
        var selections: [URL?] = []
        let view = ModelDocumentPicker { selections.append($0) }
        let coordinator = view.makeCoordinator()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)

        coordinator.documentPicker(picker, didPickDocumentsAt: [url])

        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(selections.first ?? nil, url)
    }

    @MainActor
    func testCancellationReturnsNoSelection() {
        var selections: [URL?] = []
        let view = ModelDocumentPicker { selections.append($0) }
        let coordinator = view.makeCoordinator()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)

        coordinator.documentPickerWasCancelled(picker)

        XCTAssertEqual(selections.count, 1)
        XCTAssertNil(selections.first ?? nil)
    }
}
