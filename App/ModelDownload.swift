import Foundation
import Observation

struct DownloadRequest: Codable, Equatable {
    let url: URL
    let name: String

    init(address: String, name: String) throws {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              Self.isSecure(url) else {
            throw DownloadError.insecureURL
        }
        let proposedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = proposedName.isEmpty ? url.lastPathComponent : proposedName
        guard !filename.isEmpty, !filename.hasPrefix("."), filename == (filename as NSString).lastPathComponent,
              !filename.contains("\\"),
              filename.rangeOfCharacter(from: .controlCharacters) == nil,
              ModelFile.supportedExtensions.contains((filename as NSString).pathExtension.lowercased()) else {
            throw DownloadError.filename
        }
        self.url = url
        self.name = filename
    }

    static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
            && url.user == nil && url.password == nil
    }

    static func validate(_ response: URLResponse?) throws {
        guard let response = response as? HTTPURLResponse,
              let url = response.url, isSecure(url) else { throw DownloadError.insecureURL }
        guard response.statusCode == 200 || response.statusCode == 206 else {
            throw DownloadError.http(response.statusCode)
        }
        if let type = response.mimeType?.lowercased(),
           type.contains("html") || type.contains("json") || type.contains("xml") {
            throw DownloadError.webPage
        }
    }
}

enum DownloadError: LocalizedError {
    case insecureURL, filename, webPage, http(Int), occupied, diskSpace

    var errorDescription: String? {
        switch self {
        case .insecureURL: "请输入不含账号密码的 HTTPS 文件直链；不允许跳转到 HTTP。"
        case .filename: "请填写受支持的模型文件名，例如 model.litertlm 或 model.safetensors。"
        case .webPage: "下载地址返回了网页或接口数据，请使用模型文件的直接下载链接。"
        case .http(let code): "服务器返回 HTTP \(code)。请检查文件链接及访问权限。"
        case .occupied: "请先完成或取消当前下载。"
        case .diskSpace: "剩余存储空间不足，下载已停止。请释放空间后继续。"
        }
    }
}

struct ModelTransfer: Codable, Identifiable {
    enum Phase: String, Codable { case downloading, pausing, paused, importing, failed }
    let id: UUID
    let request: DownloadRequest
    var phase: Phase = .downloading
    var received: Int64 = 0
    var expected: Int64 = -1
    var note: String?
    var canResume = false

    var progress: Double? {
        expected > 0 ? min(1, Double(received) / Double(expected)) : nil
    }
    var isBusy: Bool { phase == .downloading || phase == .pausing || phase == .importing }
}

/// One foreground transfer. URLSession owns the partial file; its opaque resume data is persisted.
@MainActor @Observable
final class ModelDownload: NSObject, URLSessionDownloadDelegate {
    private(set) var transfer: ModelTransfer?
    var errorMessage: String?
    @ObservationIgnored private let files: ModelFiles
    @ObservationIgnored private let didImport: (LocalModel) -> Void
    nonisolated private let directory: URL
    @ObservationIgnored private var task: URLSessionDownloadTask?
    @ObservationIgnored private var checkedDiskForTask: Int?
    nonisolated private let progressLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var lastProgress: (taskID: Int, time: ContinuousClock.Instant)?
    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(directory: URL, files: ModelFiles, didImport: @escaping (LocalModel) -> Void) throws {
        self.directory = directory
        self.files = files
        self.didImport = didImport
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        super.init()
        if FileManager.default.fileExists(atPath: recordURL.path) {
            transfer = try JSONDecoder().decode(ModelTransfer.self, from: Data(contentsOf: recordURL))
            if let transfer {
                _ = try DownloadRequest(address: transfer.request.url.absoluteString, name: transfer.request.name)
            }
            transfer?.phase = .paused
            transfer?.canResume = FileManager.default.fileExists(atPath: resumeURL.path)
            transfer?.note = "上次下载已中断。继续时会尝试续传；无法续传时可重新下载。"
        }
        for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if entry.pathExtension == "download", let id = UUID(uuidString: entry.deletingPathExtension().lastPathComponent),
               id != transfer?.id {
                try FileManager.default.removeItem(at: entry)
            }
        }
        if let transfer, FileManager.default.fileExists(atPath: completedURL(transfer.id).path) {
            self.transfer?.note = "文件已下载，尚未完成导入。继续可重试导入；重新下载会丢弃此文件。"
        }
    }

    private var recordURL: URL { directory.appendingPathComponent("transfer.json") }
    private var resumeURL: URL { directory.appendingPathComponent("resume.data") }
    private func completedURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".download") }

    func start(_ request: DownloadRequest) throws {
        guard transfer == nil else { throw DownloadError.occupied }
        transfer = ModelTransfer(id: UUID(), request: request)
        do {
            try save()
            begin(resumeData: nil)
        } catch {
            transfer = nil
            throw error
        }
    }

    func resume(restart: Bool = false) async {
        guard let current = transfer, !current.isBusy else { return }
        do {
            if !restart, FileManager.default.fileExists(atPath: completedURL(current.id).path) {
                await finish(id: current.id, at: completedURL(current.id))
                return
            }
            let data = !restart && current.canResume ? try Data(contentsOf: resumeURL) : nil
            if restart {
                try removeIfPresent(completedURL(current.id))
                discardResumeData(try savedResumeData())
                try removeIfPresent(resumeURL)
            }
            // A new identity keeps late callbacks from a cancelled attempt out of the next one.
            transfer = ModelTransfer(id: UUID(), request: current.request)
            if data != nil {
                transfer?.received = current.received
                transfer?.expected = current.expected
                transfer?.canResume = true
            }
            transfer?.note = data == nil ? "正在下载。切换到后台时会暂停。" : "正在尝试续传，具体进度由服务器确认。"
            try save()
            begin(resumeData: data)
        } catch { fail(error) }
    }

    private func begin(resumeData: Data?) {
        guard let current = transfer else { return }
        let newTask = resumeData.map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: current.request.url)
        newTask.taskDescription = current.id.uuidString
        task = newTask
        checkedDiskForTask = nil
        newTask.resume()
    }

    func pause() async {
        guard let task, let id = transfer?.id, transfer?.phase == .downloading else { return }
        transfer?.phase = .pausing
        let resumeData = await task.cancelByProducingResumeData()
        guard transfer?.id == id, transfer?.phase == .pausing else {
            discardResumeData(resumeData)
            return
        }
        self.task = nil
        do {
            try storeResumeData(resumeData)
            transfer?.phase = .paused
            transfer?.note = resumeData == nil
                ? "已暂停；服务器未提供续传数据，下次将重新下载。"
                : "已暂停。继续时会尝试从断点下载。"
            try save()
        } catch { fail(error) }
    }

    func cancel() {
        guard let current = transfer, current.phase != .importing else { return }
        task?.cancel()
        task = nil
        do {
            discardResumeData(try savedResumeData())
            try removeIfPresent(completedURL(current.id))
            try removeIfPresent(resumeURL)
            try removeIfPresent(recordURL)
            transfer = nil
        } catch { fail(error) }
    }

    private func save() throws {
        try JSONEncoder().encode(transfer).write(to: recordURL, options: .atomic)
    }

    private func storeResumeData(_ data: Data?) throws {
        if let data { try data.write(to: resumeURL, options: .atomic) }
        else { try removeIfPresent(resumeURL) }
        transfer?.canResume = data != nil
    }

    private func savedResumeData() throws -> Data? {
        FileManager.default.fileExists(atPath: resumeURL.path) ? try Data(contentsOf: resumeURL) : nil
    }

    private func discardResumeData(_ data: Data?) {
        if let data {
            // URLSession owns the partial file; do not interpret its private resume-data keys.
            session.downloadTask(withResumeData: data).cancel()
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func fail(_ error: Error) {
        transfer?.phase = .failed
        transfer?.note = error.localizedDescription
        errorMessage = error.localizedDescription
        do { try save() }
        catch { errorMessage = "\(errorMessage ?? "")\n下载状态未能保存：\(error.localizedDescription)" }
    }

    private func update(taskID: Int, received: Int64, expected: Int64, response: URLResponse?) {
        guard task?.taskIdentifier == taskID, transfer?.phase == .downloading else { return }
        transfer?.received = received
        transfer?.expected = expected
        if let response, checkedDiskForTask != taskID {
            checkedDiskForTask = taskID
            do {
                try DownloadRequest.validate(response)
                let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage
                if let capacity, expected > 0, expected - received > capacity { throw DownloadError.diskSpace }
            } catch {
                task?.cancel()
                task = nil
                fail(error)
            }
        }
    }

    private func finish(id: UUID, at location: URL, taskID: Int? = nil) async {
        guard let current = transfer, current.id == id else {
            do { try removeIfPresent(location) }
            catch { errorMessage = error.localizedDescription }
            return
        }
        guard current.phase != .importing else { return }
        if let taskID, task?.taskIdentifier != taskID, current.phase != .paused {
            do { try removeIfPresent(location) }
            catch { errorMessage = error.localizedDescription }
            return
        }
        task = nil
        transfer?.phase = .importing
        do {
            try save()
            let model = try await files.importFile(from: location, name: current.request.name, link: true)
            didImport(model)
            transfer = nil
            do {
                try removeIfPresent(location)
                try removeIfPresent(resumeURL)
                try removeIfPresent(recordURL)
            } catch {
                errorMessage = "模型已导入，但下载记录清理失败：\(error.localizedDescription)"
            }
        } catch { fail(error) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                               totalBytesExpectedToWrite: Int64) {
        let shouldUpdate = progressLock.withLock {
            let now = ContinuousClock.now
            if let lastProgress, lastProgress.taskID == downloadTask.taskIdentifier,
               lastProgress.time.duration(to: now) < .milliseconds(250),
               totalBytesWritten != totalBytesExpectedToWrite { return false }
            lastProgress = (downloadTask.taskIdentifier, now)
            return true
        }
        guard shouldUpdate else { return }
        Task { @MainActor in
            update(taskID: downloadTask.taskIdentifier, received: totalBytesWritten,
                   expected: totalBytesExpectedToWrite, response: downloadTask.response)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        Task { @MainActor in
            update(taskID: downloadTask.taskIdentifier, received: fileOffset,
                   expected: expectedTotalBytes, response: downloadTask.response)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        guard let description = downloadTask.taskDescription, let id = UUID(uuidString: description) else { return }
        do {
            try DownloadRequest.validate(downloadTask.response)
            let destination = directory.appendingPathComponent(id.uuidString + ".download")
            // URLSession removes its temporary file when this callback returns; move it now, inspect off-main later.
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in await finish(id: id, at: destination, taskID: downloadTask.taskIdentifier) }
        } catch {
            Task { @MainActor in
                guard transfer?.id == id, transfer?.phase != .importing else { return }
                task = nil
                fail(error)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            guard self.task?.taskIdentifier == task.taskIdentifier, transfer?.phase != .pausing else { return }
            self.task = nil
            do { try storeResumeData((error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data) }
            catch {
                fail(error)
                return
            }
            fail(error)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = request.url.map(DownloadRequest.isSecure) == true
        completionHandler(allowed ? request : nil)
        if !allowed {
            task.cancel()
            Task { @MainActor in
                guard self.task?.taskIdentifier == task.taskIdentifier else { return }
                self.task = nil
                fail(DownloadError.insecureURL)
            }
        }
    }
}
