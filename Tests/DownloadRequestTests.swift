import XCTest
@testable import LocalAIStudio

final class DownloadRequestTests: XCTestCase {
    func testHTTPSDirectLinkPreservesQueryAndDerivesFilename() throws {
        let request = try DownloadRequest(
            address: "  https://huggingface.co/example/model/resolve/main/model.safetensors?download=true  ", name: ""
        )
        XCTAssertEqual(request.name, "model.safetensors")
        XCTAssertEqual(request.url.query, "download=true")
    }

    func testExplicitFilenameWorksForDownloadEndpoints() throws {
        let request = try DownloadRequest(address: "https://example.com/download/42", name: " Model.LITERTLM ")
        XCTAssertEqual(request.name, "Model.LITERTLM")
    }

    func testOnlyHTTPSURLsWithoutEmbeddedCredentialsAreAccepted() {
        for address in [
            "http://example.com/model.gguf", "file:///model.gguf", "ftp://example.com/model.gguf",
            "/model.gguf", "https:///", "https://user@example.com/model.gguf",
            "https://user:password@example.com/model.gguf"
        ] {
            XCTAssertThrowsError(try DownloadRequest(address: address, name: "model.gguf"), address)
        }
    }

    func testFilenameCannotEscapeStorageOrHideControlCharacters() {
        for name in [
            "../model.gguf", "/tmp/model.gguf", "folder/model.gguf", "folder\\model.gguf",
            "bad\u{0000}.gguf", "bad\nname.gguf", "model.zip", "model"
        ] {
            XCTAssertThrowsError(try DownloadRequest(address: "https://example.com/download", name: name), name)
        }
    }

    func testRepositoryPageNeedsAnExplicitModelFilename() {
        XCTAssertThrowsError(try DownloadRequest(address: "https://huggingface.co/example/model", name: ""))
    }

    func testBinarySuccessAndResumedResponsesAreAccepted() throws {
        for status in [200, 206] {
            let response = try response(status: status, type: "application/octet-stream")
            XCTAssertNoThrow(try DownloadRequest.validate(response))
        }
    }

    func testHTMLJSONAndXMLAreNotImportedAsModels() throws {
        for type in ["text/html; charset=utf-8", "application/json", "application/problem+json", "application/xml"] {
            let response = try response(status: 200, type: type)
            XCTAssertThrowsError(try DownloadRequest.validate(response), type)
        }
    }

    func testErrorAndRedirectResponsesAreRejected() throws {
        for status in [204, 301, 302, 401, 403, 404, 416, 500] {
            let response = try response(status: status, type: "application/octet-stream")
            XCTAssertThrowsError(try DownloadRequest.validate(response), String(status))
        }
        XCTAssertThrowsError(try DownloadRequest.validate(nil))
    }

    @MainActor
    func testRedirectAllowsHTTPSCDNButRejectsHTTPDowngrade() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try ModelFiles(directory: directory.appendingPathComponent("Models"))
        let download = try ModelDownload(directory: directory.appendingPathComponent("Downloads"), files: files) { _ in }
        let source = try XCTUnwrap(URL(string: "https://example.com/model.gguf"))
        let task = URLSession.shared.downloadTask(with: source)
        defer { task.cancel() }
        let redirect = try response(status: 302, type: "application/octet-stream")
        for address in ["https://cdn.example.com/model.gguf", "http://cdn.example.com/model.gguf"] {
            let request = URLRequest(url: try XCTUnwrap(URL(string: address)))
            var followed: URLRequest?
            download.urlSession(.shared, task: task, willPerformHTTPRedirection: redirect,
                                newRequest: request) { followed = $0 }
            XCTAssertEqual(followed?.url, address.hasPrefix("https:") ? request.url : nil)
        }
        // The suspended task is never resumed; this test makes no network request.
    }

    @MainActor
    func testFailedCompletedImportPreservesFileForRetryAndCancelCleansIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = directory.appendingPathComponent("Downloads", isDirectory: true)
        let files = try ModelFiles(directory: directory.appendingPathComponent("Models"))
        let request = try DownloadRequest(address: "https://example.com/model.gguf", name: "")
        let transfer = ModelTransfer(id: UUID(), request: request, phase: .importing)
        let completed = try saveCompleted(transfer, data: Data("<!doctype html>not a model".utf8), at: downloads)
        var imported: [LocalModel] = []
        let download = try ModelDownload(directory: downloads, files: files) { imported.append($0) }

        XCTAssertEqual(download.transfer?.phase, .paused)
        await download.resume()
        XCTAssertEqual(download.transfer?.phase, .failed)
        XCTAssertNotNil(download.errorMessage)
        XCTAssertTrue(imported.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completed.path))

        download.cancel()
        XCTAssertNil(download.transfer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: completed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("transfer.json").path))
        let models = try await files.list()
        XCTAssertTrue(models.isEmpty)
    }

    @MainActor
    func testCompletedDownloadImportsOnResumeWithoutDownloadingAgain() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = directory.appendingPathComponent("Downloads", isDirectory: true)
        let files = try ModelFiles(directory: directory.appendingPathComponent("Models"))
        let request = try DownloadRequest(address: "https://example.com/model.safetensors", name: "")
        let transfer = ModelTransfer(id: UUID(), request: request, phase: .importing)
        let header = Data(#"{"weight":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}"#.utf8)
        var length = UInt64(header.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(header)
        data.append(Data(repeating: 0, count: 4))
        let completed = try saveCompleted(transfer, data: data, at: downloads)
        var imported: [LocalModel] = []
        let download = try ModelDownload(directory: downloads, files: files) { imported.append($0) }

        await download.resume()
        XCTAssertNil(download.transfer)
        XCTAssertNil(download.errorMessage)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.format, .safetensors)
        XCTAssertFalse(FileManager.default.fileExists(atPath: completed.path))
        let models = try await files.list()
        XCTAssertEqual(models, imported)
    }

    private func response(status: Int, type: String) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.com/model.gguf")!,
                                     statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type]))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func saveCompleted(_ transfer: ModelTransfer, data: Data, at directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(transfer).write(to: directory.appendingPathComponent("transfer.json"))
        let url = directory.appendingPathComponent(transfer.id.uuidString + ".download")
        try data.write(to: url)
        return url
    }
}
