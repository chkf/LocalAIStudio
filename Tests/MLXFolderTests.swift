import XCTest
@testable import LocalAIStudio

final class MLXFolderTests: XCTestCase {
    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeFolder(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(#"{"model_type":"qwen2"}"#.utf8)
            .write(to: url.appendingPathComponent("config.json"))
        try Data(#"{"version":"1.0"}"#.utf8)
            .write(to: url.appendingPathComponent("tokenizer.json"))
        try Data(repeating: 0, count: 40)
            .write(to: url.appendingPathComponent("model.safetensors"))
    }

    func testImportPreservesACompleteMLXModelDirectoryAndRejectsMissingFiles() async throws {
        let root = try makeWorkspace()
        let original = root.appendingPathComponent("original")
        let copy = root.appendingPathComponent("imported")
        try makeFolder(at: original)
        try FileManager.default.copyItem(at: original, to: copy)
        let files = try ModelFiles(directory: root.appendingPathComponent("Models"))
        let model = try await files.importPickerCopy(from: copy)
        XCTAssertEqual(model.format, .mlxBundle)
        XCTAssertEqual(model.architecture, "qwen2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent("config.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.fileURL(for: model)
            .appendingPathComponent("model.safetensors").path))
        let reopened = try ModelFiles(directory: root.appendingPathComponent("Models"))
        let library = (try await reopened.list()).models
        XCTAssertEqual(library, [model])
        try await reopened.delete(model)
        let afterDeletion = (try await reopened.list()).models
        XCTAssertTrue(afterDeletion.isEmpty)

        let incomplete = root.appendingPathComponent("incomplete")
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try Data(#"{"model_type":"qwen2"}"#.utf8)
            .write(to: incomplete.appendingPathComponent("config.json"))
        do {
            _ = try await files.importPickerCopy(from: incomplete)
            XCTFail("A folder without tokenizer and weights must not enter the library")
        } catch ModelFileError.invalid(_) { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: incomplete.path))
    }

    func testSymbolicLinkInsideImportedModelDirectoryIsRejected() async throws {
        let root = try makeWorkspace()
        let folder = root.appendingPathComponent("linked")
        try makeFolder(at: folder)
        let external = root.appendingPathComponent("secret.bin")
        try Data("do not read".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("extra.bin"), withDestinationURL: external)
        let files = try ModelFiles(directory: root.appendingPathComponent("Models"))
        do {
            _ = try await files.importPickerCopy(from: folder)
            XCTFail("Symbolic links must be rejected")
        } catch ModelFileError.invalid(_) { }
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "do not read")
    }

    func testModelRoutingKeepsSingleSafetensorsFileSeparateFromMLXModelFolder() {
        XCTAssertTrue(ModelFormat.mlxBundle.supportsTextGeneration)
        XCTAssertFalse(ModelFormat.safetensors.supportsTextGeneration)
        XCTAssertTrue(ModelFormat.checkpoint.supportsImageGeneration)
        XCTAssertFalse(ModelFormat.safetensors.supportsImageGeneration)
    }
}
