import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Loads a complete local MLX model directory, including config and tokenizer assets.
actor MLXTextRuntime {
    struct Metrics: Sendable {
        let firstTokenSeconds: Double?
        let tokensPerSecond: Double?
        let outputTokens: Int?
    }

    private var container: ModelContainer?
    private var generation: Task<Void, Never>?
    private var lastMetrics: Metrics?
    private var options = ChatPreferences()
    private(set) var backendName = "MLX Metal"

    func load(directory: URL, options: ChatPreferences) async throws -> Double {
        await unload()
        let start = ContinuousClock.now
        self.options = options
        container = try await LLMModelFactory.shared.loadContainer(
            from: directory, using: #huggingFaceTokenizerLoader()
        )
        return elapsed(start)
    }

    func stream(prompt: String, history: [ChatMessage], maxOutputTokens: Int)
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
                    if !options.systemPrompt.isEmpty {
                        chat.append(.system(options.systemPrompt))
                    }
                    for message in history where !message.isInterrupted && !message.text.isEmpty {
                        chat.append(message.role == .user ? .user(message.text) : .assistant(message.text))
                    }
                    chat.append(.user(prompt))
                    let input = try await model.prepare(input: UserInput(chat: chat))
                    let start = ContinuousClock.now
                    let stream = try await model.generate(
                        input: input,
                        parameters: GenerateParameters(
                            maxTokens: maxOutputTokens,
                            temperature: Float(options.temperature),
                            topP: Float(options.topP),
                            topK: options.topK
                        )
                    )
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
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            generation = task
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func cancel() {
        generation?.cancel()
    }

    func metrics() -> Metrics? { lastMetrics }

    func unload() async {
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
