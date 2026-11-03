import Foundation
import LlamaSwift

private final class GGUFStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func reset() { lock.lock(); stopped = false; lock.unlock() }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

/// A single, text-only GGUF session. C pointers stay on this actor; cancellation uses a lock.
actor GGUFTextRuntime {
    struct Metrics {
        let firstTokenSeconds: Double?
        let tokensPerSecond: Double?
        let outputTokens: Int?
    }

    enum RuntimeError: LocalizedError {
        case modelLoad, contextLoad, missingTemplate, unsupportedTemplate
        case invalidPrompt, contextOverflow, decodeFailed, tokenConversion

        var errorDescription: String? {
            switch self {
            case .modelLoad: "GGUF 模型加载失败，可能不兼容或内存不足。"
            case .contextLoad: "无法创建 GGUF 推理上下文，可能是内存不足。"
            case .missingTemplate: "该 GGUF 不包含聊天模板，无法安全构造对话输入。"
            case .unsupportedTemplate: "当前 llama.cpp 不支持该模型的聊天模板。"
            case .invalidPrompt: "无法对聊天输入进行分词。"
            case .contextOverflow: "对话超出模型上下文窗口，请清空对话或降低输出长度。"
            case .decodeFailed: "GGUF 推理失败。"
            case .tokenConversion: "无法解码模型输出。"
            }
        }
    }

    private static let initialized: Bool = {
        llama_backend_init()
        return true
    }()

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var history: [ChatMessage] = []
    private var options = ChatPreferences()
    private var mostRecentMetrics: Metrics?
    private(set) var backendName = ""
    private nonisolated let stopFlag = GGUFStopFlag()

    deinit {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    func load(fileURL: URL, history: [ChatMessage], options: ChatPreferences) throws -> Double {
        unload()
        _ = Self.initialized
        let started = ContinuousClock.now
        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = options.backend == "cpu" ? 0 : 99
        #endif
        guard let loaded = llama_model_load_from_file(fileURL.path, modelParams) else {
            throw RuntimeError.modelLoad
        }
        model = loaded
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(min(8192, max(2048, options.maxOutputTokens + 512)))
        contextParams.n_batch = 512
        contextParams.n_ubatch = 512
        let cores = max(1, min(6, ProcessInfo.processInfo.activeProcessorCount - 1))
        contextParams.n_threads = Int32(cores)
        contextParams.n_threads_batch = Int32(cores)
        guard let loadedContext = llama_init_from_model(loaded, contextParams) else {
            unload()
            throw RuntimeError.contextLoad
        }
        context = loadedContext
        vocab = llama_model_get_vocab(loaded)
        self.history = history
        self.options = options
        self.backendName = modelParams.n_gpu_layers > 0 ? "llama.cpp Metal" : "llama.cpp CPU"
        stopFlag.reset()
        return seconds(started.duration(to: .now))
    }

    func stream(prompt: String, history: [ChatMessage], maxOutputTokens: Int) -> AsyncThrowingStream<String, Error> {
        self.history = history
        stopFlag.reset()
        return AsyncThrowingStream { continuation in
            Task { await self.generate(prompt: prompt, limit: maxOutputTokens, continuation: continuation) }
        }
    }

    nonisolated func cancel() { stopFlag.stop() }

    func metrics() -> Metrics? { mostRecentMetrics }

    func unload() {
        stopFlag.stop()
        if let context { llama_free(context); self.context = nil }
        if let model { llama_model_free(model); self.model = nil }
        vocab = nil
        history = []
        mostRecentMetrics = nil
        backendName = ""
    }

    private func generate(prompt: String, limit: Int, continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        do {
            try await decode(prompt: prompt, limit: limit, continuation: continuation)
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func decode(prompt: String, limit: Int, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard let model, let context, let vocab else { throw RuntimeError.contextLoad }
        let fullPrompt = try formatChat(model: model, current: prompt)
        let tokens = try tokenize(fullPrompt, vocab: vocab)
        let available = Int(llama_n_ctx(context))
        guard !tokens.isEmpty, tokens.count + limit <= available else { throw RuntimeError.contextOverflow }

        // A fresh full chat prompt per turn keeps history correct without persistent KV bookkeeping.
        llama_memory_clear(llama_get_memory(context), true)
        let batchSize = 512
        var batch = llama_batch_init(Int32(batchSize), 0, 1)
        defer { llama_batch_free(batch) }
        let prefillStarted = ContinuousClock.now
        var position = 0
        while position < tokens.count {
            try checkCancellation()
            let size = min(batchSize, tokens.count - position)
            batch.n_tokens = Int32(size)
            for i in 0..<size {
                batch.token[i] = tokens[position + i]
                batch.pos[i] = Int32(position + i)
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = 0
                batch.logits[i] = position + i == tokens.count - 1 ? 1 : 0
            }
            guard llama_decode(context, batch) == 0 else { throw RuntimeError.decodeFailed }
            position += size
            await Task.yield()
        }

        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw RuntimeError.decodeFailed
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(Int32(options.topK)))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(Float(options.topP), 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(Float(options.temperature)))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.max))

        let generationStarted = ContinuousClock.now
        var first: Double?
        var total = 0
        var pendingBytes: [UInt8] = []
        for index in 0..<limit {
            try checkCancellation()
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            llama_sampler_accept(sampler, token)
            if first == nil { first = seconds(prefillStarted.duration(to: .now)) }
            total += 1
            pendingBytes.append(contentsOf: try tokenBytes(vocab: vocab, token: token))
            if let text = String(bytes: pendingBytes, encoding: .utf8) {
                if !text.isEmpty { continuation.yield(text) }
                pendingBytes.removeAll(keepingCapacity: true)
            }
            if index + 1 == limit { break }
            batch.n_tokens = 1
            batch.token[0] = token
            batch.pos[0] = Int32(tokens.count + index)
            batch.n_seq_id[0] = 1
            batch.seq_id[0]![0] = 0
            batch.logits[0] = 1
            guard llama_decode(context, batch) == 0 else { throw RuntimeError.decodeFailed }
            await Task.yield()
        }
        if !pendingBytes.isEmpty { continuation.yield(String(decoding: pendingBytes, as: UTF8.self)) }
        let elapsed = seconds(generationStarted.duration(to: .now))
        mostRecentMetrics = Metrics(firstTokenSeconds: first,
                                    tokensPerSecond: elapsed > 0 ? Double(total) / elapsed : nil,
                                    outputTokens: total)
    }

    private func checkCancellation() throws {
        if stopFlag.isStopped || Task.isCancelled { throw CancellationError() }
    }

    private func formatChat(model: OpaquePointer, current: String) throws -> String {
        guard let template = llama_model_chat_template(model, nil) else { throw RuntimeError.missingTemplate }
        var pairs: [(String, String)] = []
        if !options.systemPrompt.isEmpty { pairs.append(("system", options.systemPrompt)) }
        for message in history where !message.isInterrupted && !message.text.isEmpty {
            pairs.append((message.role == .user ? "user" : "assistant", message.text))
        }
        pairs.append(("user", current))
        var messages: [llama_chat_message] = []
        defer {
            for message in messages {
                free(UnsafeMutableRawPointer(mutating: message.role))
                free(UnsafeMutableRawPointer(mutating: message.content))
            }
        }
        for (role, text) in pairs {
            guard let rolePointer = strdup(role) else { throw RuntimeError.invalidPrompt }
            guard let textPointer = strdup(text) else {
                free(rolePointer)
                throw RuntimeError.invalidPrompt
            }
            messages.append(llama_chat_message(role: rolePointer, content: textPointer))
        }
        var output = [CChar](repeating: 0, count: max(256, pairs.reduce(0) { $0 + $1.0.utf8.count + $1.1.utf8.count } * 3))
        func apply(_ output: inout [CChar]) -> Int32 {
            messages.withUnsafeBufferPointer { messages in
                llama_chat_apply_template(template, messages.baseAddress, messages.count,
                                          true, &output, Int32(output.count))
            }
        }
        var length = apply(&output)
        if length > Int32(output.count) {
            output = [CChar](repeating: 0, count: Int(length) + 1)
            length = apply(&output)
        }
        guard length > 0, Int(length) <= output.count else { throw RuntimeError.unsupportedTemplate }
        return String(decoding: output.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func tokenize(_ text: String, vocab: OpaquePointer) throws -> [llama_token] {
        let utf8 = text.utf8.count
        guard utf8 < Int(Int32.max) else { throw RuntimeError.invalidPrompt }
        var tokens = [llama_token](repeating: 0, count: max(32, utf8 + 32))
        var count = text.withCString { chars in
            llama_tokenize(vocab, chars, Int32(utf8), &tokens, Int32(tokens.count), true, true)
        }
        if count < 0 && count != Int32.min {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = text.withCString { chars in
                llama_tokenize(vocab, chars, Int32(utf8), &tokens, Int32(tokens.count), true, true)
            }
        }
        guard count > 0 else { throw RuntimeError.invalidPrompt }
        return Array(tokens.prefix(Int(count)))
    }

    private func tokenBytes(vocab: OpaquePointer, token: llama_token) throws -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 128)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard count >= 0 else { throw RuntimeError.tokenConversion }
        return buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
