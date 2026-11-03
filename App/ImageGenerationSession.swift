import Foundation
import MediaGenerationKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class ImageGenerationSession {
    private(set) var isGenerating = false
    private(set) var status = ""
    private(set) var resultURL: URL?
    var errorMessage: String?

    @ObservationIgnored private var job: Task<Void, Never>?

    func generate(model: LocalModel, sourceURL: URL, prompt: String,
                  negativePrompt: String, size: Int, steps: Int) async {
        guard !isGenerating, model.format == .checkpoint else { return }
        isGenerating = true
        status = "准备生图模型…"
        errorMessage = nil
        resultURL = nil
        let task = Task {
            do {
                try Task.checkCancellation()
                // The library stores the weight under a normalized name. A hard link lets the
                // kit resolve it by its catalog filename without copying multi-GB weights.
                let directory = sourceURL.deletingLastPathComponent()
                let alias = directory.appendingPathComponent(model.name)
                let needsAlias = alias.standardizedFileURL != sourceURL.standardizedFileURL
                if needsAlias { try FileManager.default.linkItem(at: sourceURL, to: alias) }
                defer {
                    if needsAlias { try? FileManager.default.removeItem(at: alias) }
                }
                var pipeline = try await MediaGenerationPipeline.fromPretrained(
                    model.name, backend: .local(directory: directory.path)
                )
                pipeline.configuration.width = size
                pipeline.configuration.height = size
                pipeline.configuration.steps = steps
                let results = try await pipeline.generate(
                    prompt: prompt, negativePrompt: negativePrompt,
                    stateHandler: { state in
                        Task { @MainActor in
                            switch state {
                            case .preparing, .ensuringResources: self.status = "准备模型资源…"
                            case .generating(let step, let count): self.status = "生成中 · \(step)/\(count)"
                            case .decoding, .postprocessing: self.status = "解码图片…"
                            default: break
                            }
                        }
                    }
                )
                try Task.checkCancellation()
                guard let first = results.first else {
                    throw ImageGenerationError.noImage
                }
                let outputDirectory = URL.applicationSupportDirectory
                    .appendingPathComponent("Generated", isDirectory: true)
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                let output = outputDirectory.appendingPathComponent(UUID().uuidString + ".png")
                try first.write(to: output, type: .png)
                resultURL = output
                status = "生成完成"
            } catch is CancellationError {
                status = "已取消"
            } catch {
                errorMessage = "无法使用这个 Checkpoint 生图：\(error.localizedDescription)"
                status = "生成失败"
            }
        }
        job = task
        await task.value
        job = nil
        isGenerating = false
    }

    func cancel() { job?.cancel() }

    func stop() async {
        let current = job
        current?.cancel()
        await current?.value
    }
}

private enum ImageGenerationError: LocalizedError {
    case noImage
    var errorDescription: String? { "推理引擎没有返回图片。" }
}
