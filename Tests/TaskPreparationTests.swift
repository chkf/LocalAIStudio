import XCTest
@testable import LocalAIStudio

@MainActor
final class TaskPreparationTests: XCTestCase {
    func testCancelledPreparationCannotStartAfterItsWaitFinishes() async throws {
        let preparation = TaskPreparation()
        let waitingForUnload = try XCTUnwrap(preparation.begin("Preparing image"))
        // A stop/background event arrives while the previous native runtime is draining.
        preparation.cancel()
        XCTAssertFalse(preparation.isCurrent(waitingForUnload))
        XCTAssertFalse(preparation.isPreparing)
    }

    func testOldCompletionCannotClearANewerPreparation() async throws {
        let preparation = TaskPreparation()
        let old = try XCTUnwrap(preparation.begin("Old"))
        preparation.cancel()
        let current = try XCTUnwrap(preparation.begin("New"))
        preparation.finish(old)
        XCTAssertTrue(preparation.isCurrent(current))
        XCTAssertEqual(preparation.title, "New")
    }

    func testTwoPagesCannotReserveConcurrentModelStarts() async throws {
        let preparation = TaskPreparation()
        let chat = try XCTUnwrap(preparation.begin("Chat"))
        XCTAssertNil(preparation.begin("Image"))
        XCTAssertTrue(preparation.isCurrent(chat))
        preparation.finish(chat)
        XCTAssertNotNil(preparation.begin("Image"))
    }
}
