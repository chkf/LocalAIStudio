import Foundation
import Observation

@MainActor @Observable
final class ModelLibrary {
    private(set) var models: [LocalModel] = []
    private(set) var isImporting = false
    private(set) var isReady = false
    private(set) var download: ModelDownload?
    var errorMessage: String?
    @ObservationIgnored private var files: ModelFiles?
    @ObservationIgnored private var isOpening = false
    @ObservationIgnored private var importTask: Task<Void, Never>?

    var totalBytes: Int64 { models.reduce(0) { $0 + $1.byteCount } }
    var isWriting: Bool { isImporting || download?.transfer?.phase == .importing }

    func open() async {
        guard !isReady, !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        do {
            let directory = try ModelFiles.defaultDirectory()
            let files = try ModelFiles(directory: directory)
            models = try await files.list()
            download = try ModelDownload(
                directory: directory.deletingLastPathComponent().appendingPathComponent("Downloads"),
                files: files,
                didImport: { [weak self] model in self?.models.insert(model, at: 0) }
            )
            self.files = files
            isReady = true
        } catch { errorMessage = error.localizedDescription }
    }

    func importFiles(_ urls: [URL]) async {
        guard let files, !isWriting else { return }
        isImporting = true
        defer {
            isImporting = false
            importTask = nil
        }
        let job = Task { [weak self] in
            for url in urls {
                do {
                    try Task.checkCancellation()
                    let model = try await files.importFile(from: url)
                    self?.models.insert(model, at: 0)
                } catch is CancellationError {
                    return
                } catch {
                    self?.errorMessage = "\(url.lastPathComponent)：\(error.localizedDescription)"
                    return
                }
            }
        }
        importTask = job
        await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            job.cancel()
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    func delete(_ model: LocalModel) async {
        guard let files else { return }
        do {
            try await files.delete(model)
            models.removeAll { $0.id == model.id }
        } catch { errorMessage = error.localizedDescription }
    }

    func fileURL(for model: LocalModel) async throws -> URL {
        guard let files else { throw CocoaError(.fileReadNoSuchFile) }
        return await files.fileURL(for: model)
    }
}
