import CryptoKit
import Foundation
import Observation

@MainActor @Observable
final class SpeechModels {
    private(set) var models: [SpeechModel] = []
    private(set) var isInstalling = false
    private(set) var status = ""
    var errorMessage: String?
    var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: "ttsModelID") }
    }
    var speaker: Int {
        didSet { UserDefaults.standard.set(speaker, forKey: "ttsSpeaker") }
    }
    var speed: Double {
        didSet { UserDefaults.standard.set(speed, forKey: "ttsSpeed") }
    }
    @ObservationIgnored private var installTask: Task<Void, Never>?

    var selected: SpeechModel? { models.first { $0.id.uuidString == selectedID } }
    nonisolated static func root() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true).appendingPathComponent("SpeechModels")
    }
    func directory(for model: SpeechModel) throws -> URL {
        try Self.root().appendingPathComponent(model.id.uuidString)
    }

    init() {
        selectedID = UserDefaults.standard.string(forKey: "ttsModelID") ?? ""
        speaker = UserDefaults.standard.integer(forKey: "ttsSpeaker")
        let savedSpeed = UserDefaults.standard.double(forKey: "ttsSpeed")
        speed = (0.5...2).contains(savedSpeed) ? savedSpeed : 1
        do {
            let root = try Self.root()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var url = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                if folder.lastPathComponent.hasPrefix(".import-") {
                    try FileManager.default.removeItem(at: folder)
                } else if UUID(uuidString: folder.lastPathComponent) != nil {
                    let model = try JSONDecoder().decode(SpeechModel.self, from: Data(contentsOf: folder.appendingPathComponent("speech.json")))
                    guard model.id.uuidString == folder.lastPathComponent else {
                        throw SpeechModelError.invalid("语音模型记录损坏。")
                    }
                    models.append(model)
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func install(from source: URL? = nil) {
        guard !isInstalling else { return }
        isInstalling = true
        status = source == nil ? "正在下载 Kokoro…" : "正在导入 Kokoro…"
        installTask = Task {
            defer { isInstalling = false; installTask = nil }
            let job = Task.detached(priority: .utility) {
                try await Self.installFiles(source: source) { name in
                    await MainActor.run { self.status = name }
                }
            }
            do {
                let model = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                models.append(model)
                // Do not change the active voice while another model is speaking.
                status = "已添加 \(model.name)"
            } catch is CancellationError { status = "已取消" }
            catch let error as URLError where error.code == .cancelled { status = "已取消" }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func cancelInstall() { installTask?.cancel() }

    func delete(_ model: SpeechModel) {
        do {
            try FileManager.default.removeItem(at: directory(for: model))
            models.removeAll { $0.id == model.id }
            if selectedID == model.id.uuidString { selectedID = "" }
        } catch { errorMessage = error.localizedDescription }
    }

    nonisolated private static func installFiles(source: URL?, progress: @Sendable (String) async -> Void) async throws -> SpeechModel {
        let fm = FileManager.default
        let root = try root()
        let id = UUID()
        let staging = root.appendingPathComponent(".import-\(id)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            if let source {
                let accessed = source.startAccessingSecurityScopedResource()
                defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                var copyResult: Result<Void, Error>?
                var coordinationError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
                    copyResult = Result {
                        let inspection = try SpeechModelFiles.inspect(coordinated)
                        for name in inspection.files {
                            try Task.checkCancellation()
                            let input = try FileHandle(forReadingFrom: coordinated.appendingPathComponent(name))
                            defer { input.closeFile() }
                            let target = staging.appendingPathComponent(name)
                            guard fm.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                            let output = try FileHandle(forWritingTo: target)
                            defer { output.closeFile() }
                            while let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty {
                                try Task.checkCancellation()
                                try output.write(contentsOf: data)
                            }
                        }
                    }
                }
                if let coordinationError { throw coordinationError }
                guard let copyResult else { throw CocoaError(.fileReadUnknown) }
                try copyResult.get()
            } else {
                // Pinned upstream snapshot. No model weights are bundled with the app.
                let base = "https://huggingface.co/csukuangfj/kokoro-int8-multi-lang-v1_0/resolve/57adb37fc0e8d4bd430cfc1b8f8c2294945b9af2/"
                let hashes = [
                    "tokens.txt": "6ebb6bb288f20f3ae8d004d3c2ca27697da27c037d75e81a60e2a6a663f95425",
                    "date-zh.fst": "eb8aa079ae3cb81d8f4404992f39d61a0cb990947512b5b8d1e54d1f6980e718",
                    "number-zh.fst": "743f402181fcfebf76cc2f0546b71fa26476e626fbe4e460fb7b4c3a7a8bd5bd",
                    "phone-zh.fst": "1ac2b6fa56b1442320c4de7db08353bab8963a2b57f365eebcdd3a2d3562f8d7",
                    "LICENSE": "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30",
                    "model.int8.onnx": "75635ea3b85a32d00094dcdd61a258aba87c160f7c264c304a7b3ae9d734195e",
                    "voices.bin": "1c5a5b983d3d50d8586d437a51f3faa2da7919ce76a013c081e65671a3447c29",
                    "lexicon-us-en.txt": "7daaab53a181be9885b853a8582bf1838186317e5dadacbcef9c426d6fa0da14",
                    "lexicon-zh.txt": "902bc2d20ac7c449c5ecbbbb23c89d12119c03ed5b8ed27f114f0260c9e35229"
                ]
                let names = ["model.int8.onnx"] + SpeechModelFiles.required + SpeechModelFiles.optional
                for (index, name) in names.enumerated() {
                    try Task.checkCancellation()
                    await progress("下载 \(index + 1)/\(names.count)：\(name)")
                    let (temporary, response) = try await URLSession.shared.download(from: URL(string: base + name)!)
                    defer { try? fm.removeItem(at: temporary) }
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw SpeechModelError.invalid("下载失败：\(name)，请稍后重试。")
                    }
                    if let expected = hashes[name] {
                        let handle = try FileHandle(forReadingFrom: temporary)
                        defer { handle.closeFile() }
                        var hash = SHA256()
                        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
                            try Task.checkCancellation()
                            hash.update(data: data)
                        }
                        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
                            throw SpeechModelError.invalid("下载校验失败：\(name)")
                        }
                    }
                    try fm.moveItem(at: temporary, to: staging.appendingPathComponent(name))
                }
            }
            let inspected = try SpeechModelFiles.inspect(staging)
            let model = SpeechModel(id: id, name: source?.lastPathComponent ?? "Kokoro v1.0 · INT8", speakers: inspected.speakers, byteCount: inspected.bytes)
            try JSONEncoder().encode(model).write(to: staging.appendingPathComponent("speech.json"), options: .atomic)
            try Task.checkCancellation()
            try fm.moveItem(at: staging, to: root.appendingPathComponent(id.uuidString))
            return model
        } catch {
            do { try fm.removeItem(at: staging) }
            catch { throw SpeechModelError.invalid("清理语音模型临时文件失败：\(error.localizedDescription)") }
            throw error
        }
    }
}
