import Foundation
import LiteRTLM
import MLXBackend
import Observation
import os

struct ChatMessage: Identifiable, Codable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }

    var id = UUID()
    let role: Role
    var text: String
    var date = Date()
    var isInterrupted = false
    var webSources: [WebSource]? = nil
    var webActivity: [String]? = nil
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

struct ChatPreferences: Codable, Equatable, Sendable {
    var maxOutputTokens = 512
    var topK = 40
    var topP = 0.95
    var temperature = 0.7
    var backend = "auto"
    var enableThinking = false
    var enableSpeculativeDecoding = false
    var systemPrompt = ""
    var autoSpeak = false
    var speechLanguage = "zh-CN"
    var voiceIdentifier = ""
    // Optional so older saved preferences decode without a migration.
    var webEnabled: Bool? = nil
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
    private(set) var preferences = ChatPreferences()
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
    @ObservationIgnored private let webTools = WebTools()
    @ObservationIgnored private var webOperation: Task<WebToolResult, Error>?
    @ObservationIgnored private let archiveURL: URL
    @ObservationIgnored private let preferencesURL: URL
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var unloadOperation: Task<Void, Never>?
    @ObservationIgnored private var cancellationRequested = false
    @ObservationIgnored private var clearRequested = false
    @ObservationIgnored private var pendingPrompt: String?
    @ObservationIgnored private var pendingMessageID: UUID?
    @ObservationIgnored private var archiveIsReadable = true

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("Chat", isDirectory: true)) {
        archiveURL = directory.appendingPathComponent("conversation.json")
        preferencesURL = directory.appendingPathComponent("preferences.json")
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
        if FileManager.default.fileExists(atPath: preferencesURL.path) {
            do { preferences = try JSONDecoder().decode(ChatPreferences.self, from: Data(contentsOf: preferencesURL)) }
            catch { errorMessage = "无法读取推理配置：\(error.localizedDescription)" }
        }
    }

    func applyPreferences(_ newValue: ChatPreferences) async {
        guard !isBusy else { return }
        do {
            try JSONEncoder().encode(newValue).write(to: preferencesURL, options: .atomic)
            if preferences != newValue {
                preferences = newValue
                if loadedModelID != nil { await unload() }
            }
        } catch { errorMessage = "无法保存推理配置：\(error.localizedDescription)" }
    }

    func send(model: LocalModel, fileURL: URL) async {
        guard !isBusy else { return }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard model.supportsTextGeneration else {
            errorMessage = "目前没有可运行 \(model.format.rawValue) 文件的文本引擎。"
            return
        }
        let history = messages.filter { !$0.isInterrupted && !$0.text.isEmpty }
        let options = preferences
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
            await self.generate(model: model, fileURL: fileURL, prompt: prompt, userID: user.id, history: history, options: options)
        }
        operation = task
        await task.value
    }

    func cancel() {
        guard operation != nil, let messageID = pendingMessageID else { return }
        cancellationRequested = true
        webOperation?.cancel()
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

    private func generate(model: LocalModel, fileURL: URL, prompt: String, userID: UUID, history: [ChatMessage], options: ChatPreferences) async {
        let assistantID = UUID()
        defer {
            operation = nil
            webOperation = nil
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
                loadSeconds = try await runtime.load(fileURL: fileURL, format: model.format, history: history, options: options)
                loadedModelID = model.id
            }
            if cancellationRequested { throw CancellationError() }
            status = "正在生成"
            messages.append(ChatMessage(id: assistantID, role: .assistant, text: ""))
            let effectivePrompt: String
            if options.webEnabled == true {
                effectivePrompt = try await prepareWebAnswer(prompt: prompt, userID: userID, assistantID: assistantID,
                                                           history: history)
                status = "正在整理联网结果…"
            } else { effectivePrompt = prompt }
            if cancellationRequested { throw CancellationError() }
            let stream = try await runtime.stream(prompt: effectivePrompt, messageID: userID, history: history,
                                                  maxOutputTokens: options.maxOutputTokens,
                                                  reset: options.webEnabled == true)
            if cancellationRequested { try await runtime.cancel(messageID: userID) }
            for try await chunk in stream {
                if !cancellationRequested, let index = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[index].text += chunk
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

    private func prepareWebAnswer(prompt: String, userID: UUID, assistantID: UUID,
                                  history: [ChatMessage]) async throws -> String {
        var results: [WebToolResult] = []
        var calls: [WebToolCall] = []
        for _ in 0..<WebAgent.maxCalls {
            if cancellationRequested { throw CancellationError() }
            status = "正在选择联网工具…"
            let planning = try WebAgent.prompt(request: prompt, results: results, planning: true)
            let stream = try await runtime.stream(prompt: planning, messageID: userID, history: history,
                                                  maxOutputTokens: 512, reset: true, planning: true)
            if cancellationRequested { try await runtime.cancel(messageID: userID) }
            var output = ""
            for try await chunk in stream {
                if !cancellationRequested { output += chunk }
            }
            if cancellationRequested { throw CancellationError() }
            let call = try WebToolCall.parse(output)
            if call.tool == .answer { break }
            if calls.contains(call) { break }
            calls.append(call)
            let label = call.tool == .web_search ? "搜索：\(call.query!)" : "读取：\(call.url!)"
            status = label
            if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                messages[index].webActivity = (messages[index].webActivity ?? []) + [label]
            }
            let job = Task { try await webTools.execute(call) }
            webOperation = job
            let result = try await job.value
            webOperation = nil
            if cancellationRequested { throw CancellationError() }
            results.append(result)
            if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                var sources = messages[index].webSources ?? []
                for source in result.sources where !sources.contains(where: { $0.url == source.url }) { sources.append(source) }
                messages[index].webSources = sources
                if let error = result.error { messages[index].webActivity?.append(error) }
            }
        }
        return try WebAgent.prompt(request: prompt, results: results, planning: false)
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
    private let gguf = GGUFTextRuntime()
    private let mlx = MLXTextRuntime()
    private var options = ChatPreferences()
    private var currentFormat: ModelFormat?
    private var activeMessageID: UUID?
    private(set) var backendName = ""

    func load(fileURL: URL, format: ModelFormat, history: [ChatMessage], options: ChatPreferences) async throws -> Double {
        await unload()
        var options = options
        if options.webEnabled == true {
            options.systemPrompt += "\n\n" + WebAgent.systemInstruction
        }
        self.options = options
        if format == .mlxBundle {
            guard options.backend != "cpu" else { throw ChatError.unsupportedMLXCPU }
            guard !options.enableSpeculativeDecoding else { throw ChatError.unsupportedSpeculativeDecoding }
            guard !options.enableThinking else { throw ChatError.unsupportedMLXThinking }
            let elapsed = try await mlx.load(directory: fileURL, systemPrompt: options.systemPrompt,
                temperature: Float(options.temperature), topP: Float(options.topP), topK: options.topK)
            currentFormat = .mlxBundle
            backendName = "MLX Metal"
            return elapsed
        }
        if format == .gguf {
            if options.enableSpeculativeDecoding { throw ChatError.unsupportedSpeculativeDecoding }
            let elapsed = try await gguf.load(fileURL: fileURL, history: history, options: options)
            currentFormat = .gguf
            backendName = await gguf.backendName
            return elapsed
        }
        let start = ContinuousClock.now
        let configuration = try configuration(fileURL: fileURL, backendPreference: options.backend, maxOutputTokens: options.maxOutputTokens)
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableBenchmark = true
        let loadedEngine = Engine(engineConfig: configuration)
        engine = loadedEngine
        try await loadedEngine.initialize()
        try await resetConversation(history: history)
        currentFormat = .litertLM
        backendName = configuration.backend == .gpu ? "Metal" : "CPU"
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    private func resetConversation(history: [ChatMessage], planning: Bool = false) async throws {
        let thinking = options.enableThinking && !planning
        let initialMessages = history.map {
            Message($0.text, role: $0.role == .user ? .user : .model)
        }
        let instruction = options.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation = try await engine!.createConversation(with: ConversationConfig(
            systemMessage: instruction.isEmpty ? nil : Message(instruction, role: .system),
            initialMessages: initialMessages,
            samplerConfig: try SamplerConfig(
                topK: options.topK, topP: Float(options.topP), temperature: planning ? 0.1 : Float(options.temperature)
            ),
            thinkingConfig: ThinkingConfig(enableThinking: thinking,
                                           thinkingTokenBudget: thinking ? min(options.maxOutputTokens / 2, 512) : 0),
            automaticToolCalling: false,
            enableSpeculativeDecoding: options.enableSpeculativeDecoding
        ))
    }

    func stream(prompt: String, messageID: UUID, history: [ChatMessage], maxOutputTokens: Int, reset: Bool = false, planning: Bool = false) async throws -> AsyncThrowingStream<String, Error> {
        activeMessageID = messageID
        if currentFormat == .gguf {
            return await gguf.stream(prompt: prompt, history: history, maxOutputTokens: maxOutputTokens)
        }
        if currentFormat == .mlxBundle {
            let messages = history.filter { !$0.isInterrupted && !$0.text.isEmpty }
                .map { (isUser: $0.role == .user, text: $0.text) }
            return await mlx.stream(prompt: prompt, history: messages, maxOutputTokens: maxOutputTokens)
        }
        if reset { try await resetConversation(history: history, planning: planning) }
        let conversation = conversation!
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await chunk in conversation.sendMessageStream(Message(prompt), maxOutputTokens: maxOutputTokens) {
                        continuation.yield(chunk.toString)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }

    func cancel(messageID: UUID) async throws {
        guard activeMessageID == messageID else { return }
        if currentFormat == .gguf { gguf.cancel() }
        else if currentFormat == .mlxBundle { await mlx.cancel() }
        else { try conversation?.cancel() }
    }

    func unload() async {
        await gguf.unload()
        await mlx.unload()
        conversation = nil
        engine = nil
        currentFormat = nil
        backendName = ""
        activeMessageID = nil
    }

    func metrics() async throws -> Metrics {
        defer { activeMessageID = nil }
        if currentFormat == .mlxBundle {
            let values = await mlx.metrics()
            return Metrics(firstTokenSeconds: values?.firstTokenSeconds,
                           tokensPerSecond: values?.tokensPerSecond,
                           outputTokens: values?.outputTokens)
        }
        if currentFormat == .gguf {
            let values = await gguf.metrics()
            return Metrics(firstTokenSeconds: values?.firstTokenSeconds,
                           tokensPerSecond: values?.tokensPerSecond,
                           outputTokens: values?.outputTokens)
        }
        let info = try conversation!.getBenchmarkInfo()
        return Metrics(
            firstTokenSeconds: info.timeToFirstTokenInSecond > 0 ? info.timeToFirstTokenInSecond : nil,
            tokensPerSecond: info.lastDecodeTokensPerSecond > 0 ? info.lastDecodeTokensPerSecond : nil,
            outputTokens: info.lastDecodeTokenCount > 0 ? info.lastDecodeTokenCount : nil
        )
    }

    private func configuration(fileURL: URL, backendPreference: String, maxOutputTokens: Int) throws -> EngineConfig {
        let info = try ModelInfo(throwingModelPath: fileURL.path)
        guard info.isLlmModel(), info.inputModalities.text else { throw ChatError.notTextModel }
        let supported = info.supportedBackends(for: .text)
        let backend: Backend
        switch backendPreference {
        case "gpu":
            guard supported.contains(.gpu) else { throw ChatError.unsupportedBackend }
            backend = .gpu
        case "cpu":
            guard supported.contains(.cpu) else { throw ChatError.unsupportedBackend }
            backend = .cpu(threadCount: 4)
        default:
            if supported.contains(.gpu) { backend = .gpu }
            else if supported.contains(.cpu) { backend = .cpu(threadCount: 4) }
            else { throw ChatError.unsupportedBackend }
        }
        let maximum = info.maxContextTokens()
        // Reserve space for input as output limits increase, within the model's advertised maximum.
        let preferredContext = max(options.webEnabled == true ? 8192 : 2048, maxOutputTokens + 512)
        let context = info.isDynamicContext() && maximum > 0 ? min(preferredContext, maximum) : nil
        let cache = URL.cachesDirectory.appendingPathComponent("LiteRT-LM", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return try EngineConfig(
            modelPath: fileURL.path, backend: backend,
            maxNumTokens: context, cacheDir: cache.path
        )
    }
}

private enum ChatError: LocalizedError {
    case noMemoryBudget, unreadableArchive, notTextModel, unsupportedBackend, unsupportedSpeculativeDecoding, unsupportedMLXCPU, unsupportedMLXThinking

    var errorDescription: String? {
        switch self {
        case .noMemoryBudget: "系统当前未提供可分配内存预算，请关闭其他任务后重试。"
        case .unreadableArchive: "原对话文件无法读取。为避免覆盖，请先确认清空对话。"
        case .notTextModel: "该 LiteRT-LM 文件不是支持文本输入的语言模型。"
        case .unsupportedBackend: "该模型未提供可在此 App 使用的 CPU 或 Metal 后端。"
        case .unsupportedSpeculativeDecoding: "当前模型后端未接入推测解码，请关闭该选项后重试。"
        case .unsupportedMLXCPU: "MLX 后端使用 Apple Metal，不支持强制 CPU，请将加速器设为自动或 GPU。"
        case .unsupportedMLXThinking: "当前 MLX 后端使用模型自带的推理模式，不能通过此开关强制开启思考。请关闭后重试。"
        }
    }
}
