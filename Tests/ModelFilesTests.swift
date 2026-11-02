import XCTest
@testable import LocalAIStudio

final class ModelFilesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testImportPreservesSourceAndDuplicateNamesHaveIndependentFiles() async throws {
        let store = try ModelFiles(directory: directory.appendingPathComponent("Models"))
        let source = try write("test.safetensors", data: safetensors())
        let first = try await store.importFile(from: source)
        let second = try await store.importFile(from: source)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.name, second.name)
        XCTAssertEqual(first.format, .safetensors)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let saved = store.fileURL(for: first)
        XCTAssertEqual(try Data(contentsOf: saved), try Data(contentsOf: source))
        let models = try await store.list()
        XCTAssertEqual(models.count, 2)
        try await store.delete(first)
        let remaining = try await store.list()
        XCTAssertEqual(remaining.map(\.id), [second.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
    }

    func testLibrarySurvivesReloadAndIsExcludedFromBackup() async throws {
        let root = directory.appendingPathComponent("Models")
        let store = try ModelFiles(directory: root)
        let source = try write("model.bin", data: safetensors())
        let imported = try await store.importFile(from: source)
        let reloaded = try ModelFiles(directory: root)
        let models = try await reloaded.list()
        XCTAssertEqual(models, [imported])
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testLinkedDownloadSurvivesUntilCallerCleanupAndInvalidImportPreservesIt() async throws {
        let root = directory.appendingPathComponent("Models")
        let store = try ModelFiles(directory: root)
        let valid = try write("download.tmp", data: safetensors())
        let imported = try await store.importFile(from: valid, name: "model.safetensors", link: true)
        let saved = store.fileURL(for: imported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: valid.path))
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: valid.path)
        let modelAttributes = try FileManager.default.attributesOfItem(atPath: saved.path)
        let sourceNumber = try XCTUnwrap(sourceAttributes[.systemFileNumber] as? NSNumber)
        let modelNumber = try XCTUnwrap(modelAttributes[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(sourceNumber, modelNumber)
        try FileManager.default.removeItem(at: valid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: valid.path))
        XCTAssertEqual(try Data(contentsOf: saved), try safetensors())

        let invalid = try write("invalid.tmp", data: Data("<!doctype html>not a model".utf8))
        do {
            _ = try await store.importFile(from: invalid, name: "model.gguf", link: true)
            XCTFail("A web response must not become a model.")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path))
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".import-") })
    }

    func testCancelledImportPreservesSourceAndDoesNotAppearInLibrary() async throws {
        let store = try ModelFiles(directory: directory.appendingPathComponent("Models"))
        let source = try write("model.safetensors", data: safetensors())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.importFile(from: source)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled import unexpectedly succeeded.")
        } catch is CancellationError {
            let models = try await store.list()
            XCTAssertTrue(models.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testInterruptedStagingIsReclaimedWithoutDeletingFinishedModels() async throws {
        let root = directory.appendingPathComponent("Models")
        let store = try ModelFiles(directory: root)
        let source = try write("model.safetensors", data: safetensors())
        let imported = try await store.importFile(from: source)
        let staging = root.appendingPathComponent(".import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: staging.appendingPathComponent("payload"))
        let reloaded = try ModelFiles(directory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let models = try await reloaded.list()
        XCTAssertEqual(models, [imported])
    }

    func testInterruptedLinkedImportPreservesCompletedDownload() async throws {
        let root = directory.appendingPathComponent("Models")
        let source = try write("completed.download", data: safetensors())
        let staging = root.appendingPathComponent(".import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: source, to: staging.appendingPathComponent("payload"))

        // Reopening the library models termination after linking and before committing the directory.
        let reloaded = try ModelFiles(directory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try Data(contentsOf: source), try safetensors())
        let models = try await reloaded.list()
        XCTAssertTrue(models.isEmpty)
        let recovered = try await reloaded.importFile(from: source, name: "model.safetensors", link: true)
        XCTAssertEqual(recovered.format, .safetensors)
    }

    func testCorruptLibraryMetadataIsReportedWithoutDeletingFile() async throws {
        let root = directory.appendingPathComponent("Models")
        let store = try ModelFiles(directory: root)
        let source = try write("model.safetensors", data: safetensors())
        let imported = try await store.importFile(from: source)
        let saved = store.fileURL(for: imported)
        try Data("broken json".utf8).write(to: saved.deletingLastPathComponent().appendingPathComponent("metadata.json"))
        do {
            _ = try await store.list()
            XCTFail("Damaged metadata must not be silently ignored.")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        }
    }

    func testSafetensorsRecognizesActualAdapterKeysAndMetadata() throws {
        let data = try safetensors(key: "unet.layer.lora_down.weight", metadata: ["modelspec.architecture": "stable-diffusion-xl-v1-base"])
        let url = try write("unrelated-name.bin", data: data)
        let info = try ModelFile.inspect(url, name: url.lastPathComponent)
        XCTAssertEqual(info.format, .safetensors)
        XCTAssertEqual(info.architecture, "stable-diffusion-xl-v1-base")
        XCTAssertTrue(info.adapter?.hasPrefix("LoRA") == true)
        XCTAssertTrue(info.quantization?.contains("F32") == true)

        let plain = try write("lora-in-filename.safetensors", data: safetensors())
        XCTAssertNil(try ModelFile.inspect(plain, name: plain.lastPathComponent).adapter)
        let lokr = try write("adapter.safetensors", data: safetensors(key: "layer.lokr_w1"))
        XCTAssertTrue(try ModelFile.inspect(lokr, name: lokr.lastPathComponent).adapter?.hasPrefix("LoKr") == true)
    }

    func testSafetensorsRejectsTruncationOverlappingOffsetsAndWrongShape() throws {
        var truncated = try safetensors()
        truncated.removeLast()
        let url = try write("truncated.safetensors", data: truncated)
        XCTAssertThrowsError(try ModelFile.inspect(url, name: url.lastPathComponent))

        let overlapping = try tensorFile([
            "a": ["dtype": "F32", "shape": [1], "data_offsets": [0, 4]],
            "b": ["dtype": "F32", "shape": [1], "data_offsets": [0, 4]]
        ])
        let overlapURL = try write("overlap.safetensors", data: overlapping)
        XCTAssertThrowsError(try ModelFile.inspect(overlapURL, name: overlapURL.lastPathComponent))

        let badShape = try tensorFile(["a": ["dtype": "F32", "shape": [2], "data_offsets": [0, 4]]])
        let badShapeURL = try write("shape.safetensors", data: badShape)
        XCTAssertThrowsError(try ModelFile.inspect(badShapeURL, name: badShapeURL.lastPathComponent))
    }

    func testSafetensorsHeaderLimitIsCheckedBeforeAllocation() throws {
        let length = UInt64(ModelFile.headerLimit + 1)
        let url = try write("large-header.safetensors", data: number(length))
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: length + 8)
        try file.close()
        XCTAssertThrowsError(try ModelFile.inspect(url, name: url.lastPathComponent)) { error in
            guard case ModelFileError.headerTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testGGUFReadsMetadataFromContentAndRejectsTruncatedTensorTable() throws {
        let source = try write("renamed.bin", data: gguf())
        let info = try ModelFile.inspect(source, name: source.lastPathComponent)
        XCTAssertEqual(info.format, .gguf)
        XCTAssertEqual(info.architecture, "llama")
        XCTAssertEqual(info.quantization, "Q4_K_M")
        let truncated = try write("bad.gguf", data: Data("GGUF".utf8) + number(3, bytes: 4) + number(1) + number(0))
        XCTAssertThrowsError(try ModelFile.inspect(truncated, name: truncated.lastPathComponent))
    }

    func testLiteRTLMBoundsAndOpaqueCheckpointAreNotMarkedVerified() throws {
        var data = Data("LITERTLM".utf8) + number(1, bytes: 4) + number(9, bytes: 4)
        data += number(0, bytes: 4) + number(0, bytes: 4) + number(36)
        data += Data(repeating: 0, count: 4)
        let source = try write("tiny.litertlm", data: data)
        XCTAssertEqual(try ModelFile.inspect(source, name: source.lastPathComponent).format, .litertLM)
        data.replaceSubrange(24..<32, with: number(1_000_000))
        let bad = try write("broken.litertlm", data: data)
        XCTAssertThrowsError(try ModelFile.inspect(bad, name: bad.lastPathComponent))
        let opaque = try write("model.ckpt", data: Data(repeating: 0x80, count: 32))
        let info = try ModelFile.inspect(opaque, name: opaque.lastPathComponent)
        XCTAssertNil(info.architecture)
        XCTAssertNil(info.quantization)
        XCTAssertTrue(info.note.contains("仅按扩展名"))
    }

    func testDirectoriesAndSymbolicLinksAreRejected() async throws {
        let store = try ModelFiles(directory: directory.appendingPathComponent("Models"))
        let source = try write("model.safetensors", data: safetensors())
        let link = directory.appendingPathComponent("link.safetensors")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        for candidate in [directory!, link] {
            do {
                _ = try await store.importFile(from: candidate)
                XCTFail("Directories and symbolic links must not be imported.")
            } catch { }
        }
        let models = try await store.list()
        XCTAssertTrue(models.isEmpty)
    }

    private func write(_ name: String, data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func safetensors(key: String = "weight", metadata: [String: String] = [:]) throws -> Data {
        try tensorFile([
            "__metadata__": metadata,
            key: ["dtype": "F32", "shape": [1], "data_offsets": [0, 4]]
        ])
    }

    private func tensorFile(_ header: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: header, options: .sortedKeys)
        return number(UInt64(json.count)) + json + Data(repeating: 0, count: 4)
    }

    private func gguf() -> Data {
        var data = Data("GGUF".utf8) + number(3, bytes: 4) + number(1) + number(2)
        data += string("general.architecture") + number(8, bytes: 4) + string("llama")
        data += string("general.file_type") + number(4, bytes: 4) + number(15, bytes: 4)
        data += string("weight") + number(1, bytes: 4) + number(1) + number(0, bytes: 4) + number(0)
        data += Data(repeating: 0, count: (32 - data.count % 32) % 32)
        return data + Data(repeating: 0, count: 4)
    }

    private func string(_ value: String) -> Data {
        number(UInt64(value.utf8.count)) + Data(value.utf8)
    }

    private func number(_ value: UInt64, bytes: Int = 8) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
}
