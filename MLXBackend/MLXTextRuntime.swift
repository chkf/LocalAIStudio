import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Loads a complete local MLX model directory, including config and tokenizer assets.
public actor MLXTextRuntime {
    public struct Metrics: Sendable {
        public let firstTokenSeconds: Double?
        public let tokensPerSecond: Double?
        public let outputTokens: Int?
    }

    private var container: ModelContainer?
    private var generation: Task<Void, Never>?
    private var lastMetrics: Metrics?
    private var systemPrompt = ""
    private var temperature: Float = 0.7
    private var topP: Float = 0.9
    private var topK = 40

    public init() {}

    public func load(directory: URL, systemPrompt: String, temperature: Float, topP: Float, topK: Int) async throws -> Double {
        await unload()
        let start = ContinuousClock.now
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: directory, using: #huggingFaceTokenizerLoader()
        )
        try Task.checkCancellation()
        container = loaded
        return elapsed(start)
    }

    public func stream(prompt: String, history: [(isUser: Bool, text: String)], maxOutputTokens: Int)
        -> AsyncThrowingStream<String, Error>
    {
        let model = container
        lastMetrics = nil
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let model else {
                    continuation.finish(throwing: CocoaError(.fileReadNoSuchFile))
                    return
                }
                do {
                    var chat: [MLXLMCommon.Chat.Message] = []
                    if !systemPrompt.isEmpty {
                        chat.append(.system(systemPrompt))
                    }
                    for message in history {
                        chat.append(message.isUser ? .user(message.text) : .assistant(message.text))
                    }
                    chat.append(.user(prompt))
                    try Task.checkCancellation()
                    let input = try await model.prepare(input: UserInput(chat: chat))
                    try Task.checkCancellation()
                    let parameters = GenerateParameters(
                        maxTokens: maxOutputTokens,
                        temperature: temperature,
                        topP: topP,
                        topK: topK
                    )
                    let start = ContinuousClock.now
                    let (stream, computation) = try await model.perform(nonSendable: input) { context, input in
                        try Task.checkCancellation()
                        let iterator = try TokenIterator(input: input, model: context.model, parameters: parameters)
                        return MLXLMCommon.generateTask(
                            promptTokenCount: input.text.tokens.size,
                            modelConfiguration: context.configuration,
                            tokenizer: context.tokenizer,
                            iterator: iterator,
                            toolCallPolicy: parameters.toolCallPolicy
                        )
                    }
                    do {
                        try await withTaskCancellationHandler {
                            try Task.checkCancellation()
                            var first: Double?
                            for await result in stream {
                                try Task.checkCancellation()
                                switch result {
                                case .chunk(let text):
                                    if first == nil { first = elapsed(start) }
                                    continuation.yield(text)
                                case .info(let info):
                                    lastMetrics = Metrics(firstTokenSeconds: first,
                                                          tokensPerSecond: info.tokensPerSecond,
                                                          outputTokens: info.generationTokenCount)
                                default:
                                    break
                                }
                            }
                            await computation.value
                            try Task.checkCancellation()
                        } onCancel: {
                            computation.cancel()
                        }
                    } catch {
                        computation.cancel()
                        // Ending the output stream does not finish the GPU work. Drain the
                        // actual generation task before unload can release or replace its model.
                        await computation.value
                        throw error
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            generation = task
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func cancel() {
        generation?.cancel()
    }

    public func metrics() -> Metrics? { lastMetrics }

    public func unload() async {
        let current = generation
        current?.cancel()
        await current?.value
        generation = nil
        container = nil
        lastMetrics = nil
    }

    private func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) + Double(d.attoseconds) / 1e18
    }
}
