import Foundation
import XCTest
@testable import ModelValidation

final class SpeechModelTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        for name in ["model.onnx"] + SpeechModelFiles.required {
            try Data([1, 2, 3]).write(to: root.appendingPathComponent(name))
        }
        try Data(count: SpeechModelFiles.styleBytes * 2).write(to: root.appendingPathComponent("voices.bin"))
        return root
    }

    func testCompletePackageCountsSpeakersAndIgnoresUnrelatedFiles() throws {
        let root = try fixture()
        try Data([9]).write(to: root.appendingPathComponent("unrelated.bin"))
        let result = try SpeechModelFiles.inspect(root)
        XCTAssertEqual(result.speakers, 2)
        XCTAssertEqual(result.files.count, 5)
        XCTAssertFalse(result.files.contains("unrelated.bin"))
    }

    func testMissingLexiconIsRejected() throws {
        let root = try fixture()
        try FileManager.default.removeItem(at: root.appendingPathComponent("lexicon-zh.txt"))
        XCTAssertThrowsError(try SpeechModelFiles.inspect(root))
    }

    func testSymlinkIsRejected() throws {
        let root = try fixture()
        let tokens = root.appendingPathComponent("tokens.txt")
        try FileManager.default.removeItem(at: tokens)
        try FileManager.default.createSymbolicLink(at: tokens, withDestinationURL: root.appendingPathComponent("lexicon-zh.txt"))
        XCTAssertThrowsError(try SpeechModelFiles.inspect(root))
    }

    func testTruncatedVoiceTableIsRejected() throws {
        let root = try fixture()
        try Data(count: SpeechModelFiles.styleBytes - 1).write(to: root.appendingPathComponent("voices.bin"))
        XCTAssertThrowsError(try SpeechModelFiles.inspect(root))
    }

    func testLFSAndHTMLWeightsAreRejected() throws {
        let root = try fixture()
        for placeholder in ["version https://git-lfs.github.com/spec/v1\n", "<!DOCTYPE html><html>"] {
            try Data(placeholder.utf8).write(to: root.appendingPathComponent("model.onnx"))
            XCTAssertThrowsError(try SpeechModelFiles.inspect(root))
        }
    }

    func testSpeechChunksPreserveContentAndBoundMemory() {
        let text = "你好。Hello!" + String(repeating: "测试", count: 400) + "结束"
        let chunks = SpeechModelFiles.chunks(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 180 })
        XCTAssertEqual(SpeechModelFiles.chunks(" \n "), [])
    }
}
