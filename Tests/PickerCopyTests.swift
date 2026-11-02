import Foundation
import XCTest
@testable import LocalAIStudio

final class PickerCopyTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func testAdoptsLargeSystemCopyWithoutCopyingItsContentsAgain() async throws {
        let root = try workspace()
        let original = root.appendingPathComponent("original.bin")
        let copy = root.appendingPathComponent("picked.bin")
        let data = Data(repeating: 0, count: 32)
        try data.write(to: original)
        try data.write(to: copy)
        let handle = try FileHandle(forWritingTo: copy)
        let size: UInt64 = 4_000_000_000
        try handle.truncate(atOffset: size) // Sparse fixture; not 4 GB of weights.
        try handle.close()
        let inode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: copy.path)[.systemFileNumber] as? NSNumber)
        let files = try ModelFiles(directory: root.appendingPathComponent("Models"))
        let model = try await files.importPickerCopy(from: copy)
        let destination = files.fileURL(for: model)
        XCTAssertEqual(model.byteCount, Int64(size))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try Data(contentsOf: original), data)
        XCTAssertEqual(try XCTUnwrap(FileManager.default.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? NSNumber), inode)
        try await files.discardPickerCopies([copy])
        let models = try await files.list()
        XCTAssertEqual(models, [model])
    }

    func testInvalidCopyDoesNotLeaveAStagingFileOrDeleteOriginal() async throws {
        let root = try workspace()
        let original = root.appendingPathComponent("original.txt")
        let copy = root.appendingPathComponent("picked.txt")
        let data = Data("An ordinary file, not model weights.".utf8)
        try data.write(to: original)
        try data.write(to: copy)
        let directory = root.appendingPathComponent("Models")
        let files = try ModelFiles(directory: directory)
        do {
            _ = try await files.importPickerCopy(from: copy)
            XCTFail("Unsupported copy must not enter the library")
        } catch ModelFileError.unsupportedFile { }
        try await files.discardPickerCopies([copy])
        XCTAssertEqual(try Data(contentsOf: original), data)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCancellationReclaimsUnprocessedCopies() async throws {
        let root = try workspace()
        let copy = root.appendingPathComponent("picked.bin")
        try Data(repeating: 0, count: 32).write(to: copy)
        let files = try ModelFiles(directory: root.appendingPathComponent("Models"))
        let job = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await files.importPickerCopy(from: copy)
        }
        do { _ = try await job.value; XCTFail("Cancelled import must fail") }
        catch is CancellationError { }
        try await files.discardPickerCopies([copy])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        let models = try await files.list()
        XCTAssertTrue(models.isEmpty)
    }

    func testPickerCopyPathCannotConsumeAnOrdinaryDocument() async throws {
        let root = try workspace()
        let files = try ModelFiles(directory: root.appendingPathComponent("Models"))
        let source = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Never-delete-\(UUID().uuidString).bin")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(repeating: 0, count: 32)
        try data.write(to: source)
        addTeardownBlock { try FileManager.default.removeItem(at: source) }
        do { _ = try await files.importPickerCopy(from: source); XCTFail("Must reject a non-copy URL") }
        catch ModelFileError.invalid(_) { }
        do { try await files.discardPickerCopies([source]); XCTFail("Must not delete a non-copy URL") }
        catch ModelFileError.invalid(_) { }
        XCTAssertEqual(try Data(contentsOf: source), data)
    }
}
