import Foundation
import Observation

@MainActor @Observable
final class ModelLibrary {
    private(set) var models: [LocalModel] = []
    private(set) var isImporting = false
    private(set) var importingName: String?
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

    func importFiles(_ urls: [URL], copies: Bool = false) async {
        // A download can finish while Files is open. ModelFiles serializes both saves.
        guard let files, !isImporting else { return }
        isImporting = true
        defer {
            isImporting = false
            importingName = nil
            importTask = nil
        }
        let job = Task { [weak self] in
            for url in urls {
                do {
                    try Task.checkCancellation()
                    self?.importingName = url.lastPathComponent
                    let model: LocalModel
                    if copies { model = try await files.importPickerCopy(from: url) }
                    else { model = try await files.importFile(from: url) }
                    self?.models.insert(model, at: 0)
                } catch is CancellationError {
                    break
                } catch {
                    self?.errorMessage = "\(url.lastPathComponent)：\(error.localizedDescription)"
                    break
                }
            }
            // On failure/cancellation, also release copies not yet processed in the batch.
            if copies {
                do { try await files.discardPickerCopies(urls) }
                catch {
                    let previous = self?.errorMessage.map { "\($0)\n" } ?? ""
                    self?.errorMessage = previous + "清理导入副本失败：\(error.localizedDescription)"
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

    func fileURL(for model: LocalModel) throws -> URL {
        guard let files else { throw CocoaError(.fileReadNoSuchFile) }
        return files.fileURL(for: model)
    }
}
