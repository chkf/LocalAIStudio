import Foundation
import XCTest
@testable import ModelValidation

final class SpeechModelTests: XCTestCase {
    private var metadata: [String: String] {
        ["model_type": "kokoro", "sample_rate": "24000", "n_speakers": "2",
         "style_dim": "510,1,256", "version": "1", "has_espeak": "1"]
    }

    private func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes = Data()
        repeat {
            let byte = UInt8(value & 127)
            value >>= 7
            bytes.append(byte | (value > 0 ? 128 : 0))
        } while value > 0
        return bytes
    }

    private func field(_ number: UInt64, _ bytes: Data) -> Data {
        varint(number << 3 | 2) + varint(UInt64(bytes.count)) + bytes
    }

    private func model(_ metadata: [String: String]) -> Data {
        // Only the header is exercised here; this fixture is never sent to ONNX Runtime.
        var result = field(7, field(2, Data("fixture".utf8)))
        for key in metadata.keys.sorted() {
            result += field(14, field(1, Data(key.utf8)) + field(2, Data(metadata[key]!.utf8)))
        }
        return result
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        for name in SpeechModelFiles.required {
            try Data([1, 2, 3]).write(to: root.appendingPathComponent(name))
        }
        try model(metadata).write(to: root.appendingPathComponent("model.onnx"))
        try Data("_ 0\n 1\na 2\n你 3\n".utf8).write(to: root.appendingPathComponent("tokens.txt"))
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

    func testMissingRequiredMetadataIsRejectedBeforeNativeLoad() throws {
        let root = try fixture()
        for key in ["sample_rate", "n_speakers", "style_dim"] {
            var values = metadata
            values.removeValue(forKey: key)
            try model(values).write(to: root.appendingPathComponent("model.onnx"))
            XCTAssertThrowsError(try SpeechModelFiles.inspect(root), key)
        }
    }

    func testVoiceShapeCountAndInvalidNativeIntegersAreRejected() throws {
        let root = try fixture()
        for (key, value) in [("n_speakers", "3"), ("n_speakers", "-2"),
                             ("n_speakers", "\u{00a0}2"), ("n_speakers", "2garbage"),
                             ("style_dim", "510,2,256"), ("style_dim", "510,1"),
                             ("style_dim", "510,1,-256"), ("style_dim", "510,1,256,"),
                             ("sample_rate", "0"), ("sample_rate", "2147483648"),
                             ("version", "-1"), ("has_espeak", "-1"),
                             ("model_type", "vits")] {
            var values = metadata
            values[key] = value
            try model(values).write(to: root.appendingPathComponent("model.onnx"))
            XCTAssertThrowsError(try SpeechModelFiles.inspect(root), "\(key)=\(value)")
        }
    }

    func testLegacyOptionalMetadataCanBeAbsent() throws {
        let root = try fixture()
        var values = metadata
        for key in ["version", "has_espeak", "model_type"] { values.removeValue(forKey: key) }
        try model(values).write(to: root.appendingPathComponent("model.onnx"))
        XCTAssertNoThrow(try SpeechModelFiles.inspect(root))
    }

    func testMalformedAndTruncatedONNXHeadersAreRejected() throws {
        let root = try fixture()
        for bytes in [Data([0x72, 0x80]), Data([0x72, 0x7f, 1, 2]),
                      Data([0x3a, 0x7f, 1]), Data(repeating: 0xff, count: 11),
                      Data([0]), Data([0x3b]),
                      field(14, Data([0x08, 1])), field(14, field(1, Data([0xff]))),
                      model(metadata) + field(14, field(1, Data("n_speakers".utf8)) + field(2, Data("2".utf8)))] {
            try bytes.write(to: root.appendingPathComponent("model.onnx"))
            XCTAssertThrowsError(try SpeechModelFiles.inspect(root))
        }
    }

    func testOversizedMetadataIsRejected() throws {
        let root = try fixture()
        var values = metadata
        values["description"] = String(repeating: "x", count: 65_537)
        try model(values).write(to: root.appendingPathComponent("model.onnx"))
        XCTAssertThrowsError(try SpeechModelFiles.inspect(root))
    }

    func testLargeGraphIsSkippedToReadTrailingMetadata() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("model.onnx")
        let handle = try FileHandle(forWritingTo: file)
        defer { handle.closeFile() }
        try handle.truncate(atOffset: 0)
        let graphBytes: UInt64 = 300 * 1_024 * 1_024
        let header = varint(7 << 3 | 2) + varint(graphBytes)
        try handle.write(contentsOf: header)
        try handle.seek(toOffset: UInt64(header.count) + graphBytes)
        // Remove the small fixture graph, leaving only its metadata fields.
        try handle.write(contentsOf: model(metadata).dropFirst(field(7, field(2, Data("fixture".utf8))).count))
        XCTAssertEqual(try SpeechModelFiles.inspect(root).speakers, 2)
    }

    func testMalformedTokenRowsAreRejectedBeforeNativeReadTokens() throws {
        let root = try fixture()
        for bytes in [Data("a nope\n".utf8), Data("a 1 extra\n".utf8),
                      Data("a -1\n".utf8), Data("a 2147483648\n".utf8),
                      Data("\n\n".utf8), Data([0xff, 0x20, 0x31]), Data([0])] {
            try bytes.write(to: root.appendingPathComponent("tokens.txt"))
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
