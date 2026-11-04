import Foundation
import Observation

@MainActor @Observable
final class ModelLibrary {
    private(set) var models: [LocalModel] = []
    private(set) var issues: [ModelLibraryIssue] = []
    private(set) var isRefreshing = false
    private(set) var isImporting = false
    private(set) var isProcessing = false
    private(set) var processingStatus = ""
    private(set) var processingProgress = 0.0
    private(set) var importingName: String?
    private(set) var isReady = false
    private(set) var download: ModelDownload?
    var errorMessage: String?
    @ObservationIgnored private var files: ModelFiles?
    @ObservationIgnored private var isOpening = false
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var processingCancelled = false
    @ObservationIgnored private var processingTask: Task<LocalModel, Error>?

    var totalBytes: Int64 { models.reduce(0) { $0 + $1.byteCount } }
    var isWriting: Bool { isImporting || isProcessing || isRefreshing || download?.transfer?.phase == .importing }

    func open() async {
        guard !isOpening, !isReady || download == nil else { return }
        isOpening = true
        defer { isOpening = false }
        do {
            let directory = try ModelFiles.defaultDirectory()
            let files: ModelFiles
            if let existing = self.files {
                files = existing
            } else {
                files = try ModelFiles(directory: directory)
                let inventory = try await files.list()
                try Task.checkCancellation()
                models = inventory.models
                issues = inventory.issues
                self.files = files
                isReady = true
            }
            // Download recovery errors must not block already imported models.
            download = try ModelDownload(
                directory: directory.deletingLastPathComponent().appendingPathComponent("Downloads"),
                files: files,
                didImport: { [weak self] model in self?.models.insert(model, at: 0) }
            )
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    func retryInvalidEntries() async {
        guard let files, !isWriting else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let inventory = try await files.list()
            try Task.checkCancellation()
            models = inventory.models
            issues = inventory.issues
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    func deleteInvalidEntry(_ issue: ModelLibraryIssue) async {
        guard let files, !isWriting else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await files.deleteInvalidEntry(issue)
            issues.removeAll { $0.id == issue.id }
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
            var completed = 0
            for (index, url) in urls.enumerated() {
                do {
                    try Task.checkCancellation()
                    self?.importingName = url.lastPathComponent
                    let model: LocalModel
                    if copies { model = try await files.importPickerCopy(from: url) }
                    else { model = try await files.importFile(from: url) }
                    self?.models.insert(model, at: 0)
                    completed = index + 1
                } catch is CancellationError {
                    break
                } catch {
                    self?.errorMessage = "\(url.lastPathComponent)：\(error.localizedDescription)"
                    break
                }
            }
            // Reclaim only unprocessed copies. Successful imports have already moved.
            if copies && completed < urls.count {
                do { try await files.discardPickerCopies(Array(urls.dropFirst(completed))) }
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

    func rename(_ model: LocalModel, displayName: String) async {
        guard let files, !isWriting else { return }
        do {
            let updated = try await files.rename(model, displayName: displayName)
            if let index = models.firstIndex(where: { $0.id == updated.id }) { models[index] = updated }
        } catch { errorMessage = error.localizedDescription }
    }

    func configureImage(_ model: LocalModel, configuration: ImageModelConfiguration) async -> Bool {
        guard let files, !isWriting else { return false }
        do {
            let updated = try await files.configureImage(model, configuration: configuration)
            if let index = models.firstIndex(where: { $0.id == updated.id }) { models[index] = updated }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func imageComponents(for model: LocalModel) throws -> [String: URL] {
        try (model.imageConfiguration?.components ?? [:]).mapValues { id in
            guard let component = models.first(where: { $0.id == id }), component.format == .checkpoint else {
                throw ModelFileError.invalid("已配置的配套组件已被删除，请重新选择。")
            }
            return try fileURL(for: component)
        }
    }

    func reinspect(_ model: LocalModel) async {
        guard let files, !isWriting else { return }
        do {
            let result = try await files.reinspect(model)
            if let index = models.firstIndex(where: { $0.id == result.id }) { models[index] = result }
        } catch { errorMessage = error.localizedDescription }
    }

    func process(_ model: LocalModel, operation: ImageModelOperation,
                 prepare: @MainActor () async -> Void) async {
        guard let files, !isWriting else { return }
        isProcessing = true
        processingCancelled = false
        processingStatus = "正在准备模型处理…"
        processingProgress = 0
        defer { isProcessing = false; processingTask = nil }
        await prepare()
        guard !Task.isCancelled, !processingCancelled else { return }
        processingStatus = "正在处理 \(model.title)"
        let job = Task { [weak self] in
            try await files.process(model, operation: operation) { [weak self] fraction in
                Task { @MainActor in self?.processingProgress = min(1, max(0, fraction)) }
            }
        }
        processingTask = job
        do {
            let result = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            models.insert(result, at: 0)
        } catch is CancellationError {
            processingStatus = "已取消"
        } catch { errorMessage = error.localizedDescription }
    }

    func cancelProcessing() {
        processingCancelled = true
        processingTask?.cancel()
        if isProcessing { processingStatus = "取消中，等待当前转换步骤结束…" }
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
