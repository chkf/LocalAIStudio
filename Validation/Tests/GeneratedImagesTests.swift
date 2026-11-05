import Foundation
import XCTest
@testable import ModelValidation

final class GeneratedImagesTests: XCTestCase {
    private var root: URL!
    private var store: GeneratedImages!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = GeneratedImages(directory: root.appendingPathComponent("Generated"))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testSaveSurvivesRelaunchAndKeepsEarlierResults() throws {
        let first = try store.save { try Data([1, 2, 3]).write(to: $0) }
        let second = try store.save { try Data([4, 5]).write(to: $0) }
        let reopened = GeneratedImages(directory: store.directory)
        let images = try reopened.list()
        XCTAssertEqual(Set(images.map(\.url)), Set([first, second]))
        XCTAssertEqual(images.reduce(0) { $0 + $1.byteCount }, 5)
        XCTAssertEqual(images.map(\.date), images.map(\.date).sorted(by: >))
    }

    func testLegacyUUIDFilesRemainAccessibleAndSelectedDeletionPreservesOthers() throws {
        let legacy = store.directory.appendingPathComponent(UUID().uuidString.lowercased() + ".png")
        let other = store.directory.appendingPathComponent(UUID().uuidString + ".png")
        let unrelated = store.directory.appendingPathComponent("keep.txt")
        for url in [legacy, other, unrelated] { try Data([1]).write(to: url) }
        let image = try XCTUnwrap(store.list().first { $0.url == legacy })
        try store.delete(image)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(try store.list().count, 1)
    }

    func testFailedAndInterruptedWritesNeverBecomeHistoryEntries() throws {
        XCTAssertThrowsError(try store.save { url in
            try Data([1]).write(to: url)
            throw CocoaError(.fileWriteUnknown)
        })
        XCTAssertTrue(try store.list().isEmpty)
        let interrupted = store.directory.appendingPathComponent(".pending-\(UUID().uuidString).png")
        let unrelated = store.directory.appendingPathComponent(".pending-unrelated.png")
        try Data([1]).write(to: interrupted)
        try Data([1]).write(to: unrelated)
        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testListRejectsSymlinksAndDeletionStaysInsideOwnedDirectory() throws {
        let id = UUID()
        let outside = root.appendingPathComponent(id.uuidString + ".png")
        let owned = store.directory.appendingPathComponent(id.uuidString + ".png")
        try Data([1]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: owned, withDestinationURL: outside)
        XCTAssertTrue(try store.list().isEmpty)
        let forged = GeneratedImage(id: id, url: outside, date: .now, byteCount: 1)
        try store.delete(forged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertThrowsError(try store.delete(GeneratedImage(id: id,
            url: root.appendingPathComponent("keep.txt"), date: .now, byteCount: 1)))
    }
}
