import Foundation
import XCTest
@testable import LocalAIStudio

final class ChatPreferencesTests: XCTestCase {
    @MainActor
    func testPreferencesPersistWithoutErasingConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = ChatSession(directory: root)
        var options = chat.preferences
        options.maxOutputTokens = 1024
        options.topK = 32
        options.topP = 0.8
        options.temperature = 0.5
        options.backend = "cpu"
        options.systemPrompt = "Answer concisely."
        options.enableThinking = true
        options.autoSpeak = true
        options.speechLanguage = "en-US"
        await chat.applyPreferences(options)
        let reopened = ChatSession(directory: root)
        XCTAssertEqual(reopened.preferences, options)
        XCTAssertTrue(reopened.messages.isEmpty)
        XCTAssertNil(reopened.errorMessage)
    }

    @MainActor
    func testDefaultGenerationConfiguration() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = ChatSession(directory: root)
        XCTAssertEqual(chat.preferences.maxOutputTokens, 512)
        XCTAssertEqual(chat.preferences.backend, "auto")
        XCTAssertFalse(chat.preferences.enableThinking)
        XCTAssertFalse(chat.preferences.enableSpeculativeDecoding)
    }
}
