import XCTest
@testable import LocalAIStudio

@MainActor
final class ChatSessionTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testLegacyPreferencesKeepNetworkingOff() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ChatPreferences())) as! [String: Any]
        object.removeValue(forKey: "webEnabled")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(ChatPreferences.self, from: oldData)
        XCTAssertNotEqual(restored.webEnabled, true)
    }

    func testWebSourcesRoundTripWithoutChangingText() throws {
        var message = ChatMessage(role: .assistant, text: "A sourced answer")
        message.webSources = [WebSource(title: "Example", url: URL(string: "https://example.com")!, excerpt: "Evidence")]
        message.webActivity = ["Search completed"]
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(restored.webSources, message.webSources)
        XCTAssertEqual(restored.webActivity, message.webActivity)
        XCTAssertEqual(restored.text, message.text)
    }

    func testDraftSurvivesRelaunchAndClear() async throws {
        let folder = try directory()
        let session = ChatSession(directory: folder)
        session.draft = "A draft that has not been sent"
        session.saveDraft()
        XCTAssertNil(session.errorMessage)

        let restored = ChatSession(directory: folder)
        XCTAssertEqual(restored.draft, session.draft)
        await restored.clear()

        let cleared = ChatSession(directory: folder)
        XCTAssertEqual(cleared.draft, "")
        XCTAssertTrue(cleared.messages.isEmpty)
        XCTAssertFalse(cleared.isBusy)
    }

    func testInterruptedInputIsRestoredWithoutResumingInference() throws {
        let folder = try directory()
        let messageID = UUID()
        let modelID = UUID()
        let archive: [String: Any] = [
            "messages": [[
                "id": messageID.uuidString, "role": "user", "text": "Pending input",
                "date": 0, "isInterrupted": false
            ]],
            "draft": "", "pendingPrompt": "Pending input",
            "pendingMessageID": messageID.uuidString,
            "lastModelID": modelID.uuidString, "performanceRecords": []
        ]
        try JSONSerialization.data(withJSONObject: archive).write(to: folder.appendingPathComponent("conversation.json"))

        let session = ChatSession(directory: folder)
        XCTAssertEqual(session.draft, "Pending input")
        XCTAssertEqual(session.lastModelID, modelID)
        XCTAssertEqual(session.messages.count, 1)
        XCTAssertTrue(session.messages[0].isInterrupted)
        XCTAssertNil(session.loadedModelID)
        XCTAssertFalse(session.isBusy)
        XCTAssertNil(session.tokensPerSecond)
    }

    func testUnreadableArchiveIsNotOverwrittenByDraftSave() throws {
        let folder = try directory()
        let file = folder.appendingPathComponent("conversation.json")
        let damaged = Data("incomplete JSON".utf8)
        try damaged.write(to: file)

        let session = ChatSession(directory: folder)
        XCTAssertNotNil(session.errorMessage)
        session.draft = "New input"
        session.saveDraft()
        XCTAssertEqual(try Data(contentsOf: file), damaged)
        XCTAssertNotNil(session.errorMessage)
    }

    func testInterruptedPartialReplyIsPreservedAndMarkedWithItsPrompt() throws {
        let folder = try directory()
        let pendingID = UUID()
        let archive: [String: Any] = [
            "messages": [
                ["id": UUID().uuidString, "role": "user", "text": "Earlier question", "date": 0, "isInterrupted": false],
                ["id": UUID().uuidString, "role": "assistant", "text": "Completed answer", "date": 0, "isInterrupted": false],
                ["id": pendingID.uuidString, "role": "user", "text": "Pending question", "date": 0, "isInterrupted": false],
                ["id": UUID().uuidString, "role": "assistant", "text": "Partially generated answer", "date": 0, "isInterrupted": false]
            ],
            "draft": "", "pendingPrompt": "Pending question",
            "pendingMessageID": pendingID.uuidString, "performanceRecords": []
        ]
        try JSONSerialization.data(withJSONObject: archive).write(to: folder.appendingPathComponent("conversation.json"))

        let session = ChatSession(directory: folder)
        XCTAssertEqual(session.draft, "Pending question")
        XCTAssertEqual(session.messages.map(\.isInterrupted), [false, false, true, true])
        XCTAssertEqual(session.messages.last?.text, "Partially generated answer")
        XCTAssertFalse(session.isBusy)
        XCTAssertNil(session.loadedModelID)

        session.saveDraft()
        XCTAssertNil(session.errorMessage)
        let restoredAgain = ChatSession(directory: folder)
        XCTAssertEqual(restoredAgain.messages.map(\.isInterrupted), [false, false, true, true])
        XCTAssertEqual(restoredAgain.messages.last?.text, "Partially generated answer")
    }

    func testExistingUnsentDraftWinsOverInterruptedPrompt() throws {
        let folder = try directory()
        let archive: [String: Any] = [
            "messages": [], "draft": "A newer unsent draft",
            "pendingPrompt": "Older in-flight prompt", "performanceRecords": []
        ]
        try JSONSerialization.data(withJSONObject: archive).write(to: folder.appendingPathComponent("conversation.json"))
        let session = ChatSession(directory: folder)
        XCTAssertEqual(session.draft, "A newer unsent draft")
        XCTAssertFalse(session.isBusy)
    }
}
