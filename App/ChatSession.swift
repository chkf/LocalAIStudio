import Foundation
import LiteRTLM
import Observation
import os

struct ChatMessage: Identifiable, Codable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }

    var id = UUID()
    let role: Role
    var text: String
    var date = Date()
    var isInterrupted = false
}

struct InferenceRecord: Identifiable, Codable, Sendable {
    var id = UUID()
    let modelID: UUID
    let modelName: String
    let quantization: String?
    let backend: String
    let date: Date
    let loadSeconds: Double?
    let firstTokenSeconds: Double?
    let tokensPerSecond: Double?
    let outputTokens: Int?
}

private struct ChatArchive: Codable {
    var messages: [ChatMessage] = []
    var draft = ""
    var pendingPrompt: String?
    var pendingMessageID: UUID?
    var lastModelID: UUID?
    var performanceRecords: [InferenceRecord] = []
}

@MainActor
@Observable
final class ChatSession {
    private(set) var messages: [ChatMessage] = []
    var draft = ""
    private(set) var isBusy = false
    private(set) var loadedModelID: UUID?
    private(set) var lastModelID: UUID?
    private(set) var status = "选择本地 LiteRT-LM 模型开始对话"
    var errorMessage: String?
    private(set) var loadSeconds: Double?
    private(set) var firstTokenSeconds: Double?
    private(set) var tokensPerSecond: Double?
    private(set) var metricsNote: String?
    private(set) var availableMemoryBytes: UInt64?
    private(set) var performanceRecords: [InferenceRecord] = []

    @ObservationIgnored private let runtime = TextRuntime()
    @ObservationIgnored private let archiveURL: URL
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var unloadOperation: Task<Void, Never>?
    @ObservationIgnored private var cancellationRequested = false
    @ObservationIgnored private var clearRequested = false
    @ObservationIgnored private var pendingPrompt: String?
    @ObservationIgnored private var pendingMessageID: UUID?
    @ObservationIgnored private var archiveIsReadable = true

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("Chat", isDirectory: true)) {
        archiveURL = directory.appendingPathComponent("conversation.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                let archive = try JSONDecoder().decode(ChatArchive.self, from: Data(contentsOf: archiveURL))
                messages = archive.messages
                draft = archive.draft
                lastModelID = archive.lastModelID
                performanceRecords = archive.performanceRecords
                if let prompt = archive.pendingPrompt {
                    if draft.isEmpty { draft = prompt }
                    if let index = messages.firstIndex(where: { $0.id == archive.pendingMessageID }) {
                        // A saved stream may already include a partial assistant reply after this prompt.
                        for messageIndex in index..<messages.endIndex {
                            messages[messageIndex].isInterrupted = true
                        }
                    }
                    status = "上次任务已中断，输入已恢复；需要重新生成"
                }
            }
        } catch {
            archiveIsReadable = false
            errorMessage = "无法读取对话记录，原文件已保留。清空对话后可重新开始。\n\(error.localizedDescription)"
        }
    }

    func send(model: LocalModel, fileURL: URL) async {
        guard !isBusy else { return }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard model.format == .litertLM else {
            errorMessage = "文本推理目前只支持 LiteRT-LM 文件，不能运行 \(model.format.rawValue)。"
            return
        }
        let history = messages.filter { !$0.isInterrupted && !$0.text.isEmpty }
        let user = ChatMessage(role: .user, text: prompt)
        messages.append(user)
        pendingPrompt = prompt
        pendingMessageID = user.id
        lastModelID = model.id
        draft = ""
        errorMessage = nil
        do {
            try persist()
        } catch {
            messages.removeLast()
            pendingPrompt = nil
            pendingMessageID = nil
            draft = prompt
            errorMessage = "未能保存任务输入，生成尚未开始。\n\(error.localizedDescription)"
            return
        }
        isBusy = true
        cancellationRequested = false
        firstTokenSeconds = nil
        tokensPerSecond = nil
        metricsNote = nil
        let task = Task {
            await self.generate(model: model, fileURL: fileURL, prompt: prompt, userID: user.id, history: history)
        }
        operation = task
        await task.value
    }

    func cancel() {
        guard operation != nil, let messageID = pendingMessageID else { return }
        cancellationRequested = true
        status = "正在停止；模型加载期间需等待加载结束"
        // Drain the native stream to its terminal callback before releasing the engine.
        // Cancelling the Swift task would end iteration before native inference has stopped.
        Task {
            do { try await runtime.cancel(messageID: messageID) }
            catch { errorMessage = "停止请求失败：\(error.localizedDescription)" }
        }
    }

    func unload() async {
        if let unloadOperation {
            await unloadOperation.value
            return
        }
        isBusy = true
        cancel()
        let task = Task {
            if let operation { await operation.value }
            await runtime.unload()
            loadedModelID = nil
            status = "模型已卸载"
            if clearRequested {
                messages = []
                draft = ""
                pendingPrompt = nil
                pendingMessageID = nil
                lastModelID = nil
                archiveIsReadable = true
                clearRequested = false
                errorMessage = nil
                saveDraft()
            }
            unloadOperation = nil
            isBusy = false
        }
        unloadOperation = task
        await task.value
    }

    func clear() async {
        clearRequested = true
        await unload()
    }

    func saveDraft() {
        do { try persist() }
        catch { errorMessage = "未能保存对话：\(error.localizedDescription)" }
    }

    private func generate(model: LocalModel, fileURL: URL, prompt: String, userID: UUID, history: [ChatMessage]) async {
        let assistantID = UUID()
        defer {
            operation = nil
            if unloadOperation == nil { isBusy = false }
        }
        do {
            if cancellationRequested { throw CancellationError() }
            availableMemoryBytes = UInt64(os_proc_available_memory())
            // This is headroom reported by iOS, not an estimate of model peak memory.
            if availableMemoryBytes == 0 { throw ChatError.noMemoryBudget }
            if loadedModelID != model.id {
                status = "正在加载 \(model.name)"
                loadedModelID = nil
                loadSeconds = nil
                loadSeconds = try await runtime.load(fileURL: fileURL, history: history)
                loadedModelID = model.id
            }
            if cancellationRequested { throw CancellationError() }
            status = "正在生成"
            messages.append(ChatMessage(id: assistantID, role: .assistant, text: ""))
            let stream = await runtime.stream(prompt: prompt, messageID: userID)
            if cancellationRequested { try await runtime.cancel(messageID: userID) }
            for try await chunk in stream {
                if !cancellationRequested, let index = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[index].text += chunk.toString
                }
            }
            if cancellationRequested { throw CancellationError() }
            let metrics: TextRuntime.Metrics?
            do {
                metrics = try await runtime.metrics()
                firstTokenSeconds = metrics?.firstTokenSeconds
                tokensPerSecond = metrics?.tokensPerSecond
            } catch {
                metrics = nil
                metricsNote = "本次引擎未返回性能统计：\(error.localizedDescription)"
            }
            performanceRecords.append(InferenceRecord(
                modelID: model.id, modelName: model.name, quantization: model.quantization,
                backend: await runtime.backendName, date: .now, loadSeconds: loadSeconds,
                firstTokenSeconds: firstTokenSeconds, tokensPerSecond: tokensPerSecond,
                outputTokens: metrics?.outputTokens
            ))
            pendingPrompt = nil
            pendingMessageID = nil
            status = "生成完成"
        } catch {
            if let index = messages.firstIndex(where: { $0.id == pendingMessageID }) {
                messages[index].isInterrupted = true
            }
            if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                if messages[index].text.isEmpty { messages.remove(at: index) }
                else { messages[index].isInterrupted = true }
            }
            if draft.isEmpty { draft = prompt }
            pendingPrompt = nil
            pendingMessageID = nil
            await runtime.unload()
            loadedModelID = nil
            status = cancellationRequested ? "已停止，输入与已有文字已保留" : "生成失败"
            if !cancellationRequested { errorMessage = error.localizedDescription }
        }
        saveDraft()
    }

    private func persist() throws {
        guard archiveIsReadable else { throw ChatError.unreadableArchive }
        let archive = ChatArchive(
            messages: messages, draft: draft, pendingPrompt: pendingPrompt,
            pendingMessageID: pendingMessageID, lastModelID: lastModelID,
            performanceRecords: performanceRecords
        )
        try JSONEncoder().encode(archive).write(to: archiveURL, options: .atomic)
    }
}

// Native model inspection, stream setup and destruction can block; keep them off the UI actor.
private actor TextRuntime {
    struct Metrics: Sendable {
        let firstTokenSeconds: Double?
        let tokensPerSecond: Double?
        let outputTokens: Int?
    }

    private var engine: Engine?
    private var conversation: Conversation?
    private var activeMessageID: UUID?
    private(set) var backendName = ""

    func load(fileURL: URL, history: [ChatMessage]) async throws -> Double {
        unload()
        let start = ContinuousClock.now
        let configuration = try configuration(fileURL: fileURL)
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableBenchmark = true
        let loadedEngine = Engine(engineConfig: configuration)
        engine = loadedEngine
        try await loadedEngine.initialize()
        let initialMessages = history.map {
            Message($0.text, role: $0.role == .user ? .user : .model)
        }
        conversation = try await loadedEngine.createConversation(with: ConversationConfig(
            initialMessages: initialMessages,
            thinkingConfig: ThinkingConfig(enableThinking: false),
            automaticToolCalling: false
        ))
        backendName = configuration.backend == .gpu ? "Metal" : "CPU"
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    func stream(prompt: String, messageID: UUID) -> AsyncThrowingStream<Message, Error> {
        activeMessageID = messageID
        return conversation!.sendMessageStream(Message(prompt), maxOutputTokens: 512)
    }

    func cancel(messageID: UUID) throws {
        guard activeMessageID == messageID else { return }
        try conversation?.cancel()
    }

    func unload() {
        conversation = nil
        engine = nil
        activeMessageID = nil
    }

    func metrics() throws -> Metrics {
        defer { activeMessageID = nil }
        let info = try conversation!.getBenchmarkInfo()
        return Metrics(
            firstTokenSeconds: info.timeToFirstTokenInSecond > 0 ? info.timeToFirstTokenInSecond : nil,
            tokensPerSecond: info.lastDecodeTokensPerSecond > 0 ? info.lastDecodeTokensPerSecond : nil,
            outputTokens: info.lastDecodeTokenCount > 0 ? info.lastDecodeTokenCount : nil
        )
    }

    private func configuration(fileURL: URL) throws -> EngineConfig {
        let info = try ModelInfo(throwingModelPath: fileURL.path)
        guard info.isLlmModel(), info.inputModalities.text else { throw ChatError.notTextModel }
        let supported = info.supportedBackends(for: .text)
        let backend: Backend
        if supported.contains(.gpu) { backend = .gpu }
        else if supported.contains(.cpu) { backend = .cpu(threadCount: 4) }
        else { throw ChatError.unsupportedBackend }
        let maximum = info.maxContextTokens()
        let context = info.isDynamicContext() && maximum > 0 ? min(2048, maximum) : nil
        let cache = URL.cachesDirectory.appendingPathComponent("LiteRT-LM", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return try EngineConfig(
            modelPath: fileURL.path, backend: backend,
            maxNumTokens: context, cacheDir: cache.path
        )
    }
}

private enum ChatError: LocalizedError {
    case noMemoryBudget, unreadableArchive, notTextModel, unsupportedBackend

    var errorDescription: String? {
        switch self {
        case .noMemoryBudget: "系统当前未提供可分配内存预算，请关闭其他任务后重试。"
        case .unreadableArchive: "原对话文件无法读取。为避免覆盖，请先确认清空对话。"
        case .notTextModel: "该 LiteRT-LM 文件不是支持文本输入的语言模型。"
        case .unsupportedBackend: "该模型未提供可在此 App 使用的 CPU 或 Metal 后端。"
        }
    }
}
