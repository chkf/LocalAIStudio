import Foundation
import MediaGenerationKit
import Observation
import ModelZoo
import DataModels
import UniformTypeIdentifiers

@MainActor @Observable
final class ImageGenerationSession {
    private(set) var isGenerating = false
    private(set) var status = ""
    private(set) var resultURL: URL?
    var errorMessage: String?

    @ObservationIgnored private var job: Task<Void, Never>?

    func generate(model: LocalModel, sourceURL: URL, prompt: String,
                  negativePrompt: String, size: Int, steps: Int,
                  lora: (model: LocalModel, url: URL, weight: Double)? = nil) async {
        guard !isGenerating, model.supportsImageGeneration else { return }
        isGenerating = true
        status = "准备生图模型…"
        errorMessage = nil
        resultURL = nil
        let task = Task {
            do {
                try Task.checkCancellation()
                let directory = URL.applicationSupportDirectory.appendingPathComponent("ImageRuntime", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                // All studio_* files are owned transient hard links; recover interrupted sessions.
                for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    where url.lastPathComponent.hasPrefix("studio_") {
                    try FileManager.default.removeItem(at: url)
                }
                var aliases: [URL] = []
                let oldModels = ModelZoo.overrideMapping
                let oldLoRAs = LoRAZoo.overrideMapping
                defer {
                    ModelZoo.overrideMapping = oldModels
                    LoRAZoo.overrideMapping = oldLoRAs
                    for url in aliases { try? FileManager.default.removeItem(at: url) }
                }
                func link(_ source: URL, name: String) throws {
                    let target = directory.appendingPathComponent(name)
                    // Resource downloads are cached here, outside immutable model bundles.
                    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                    try FileManager.default.linkItem(at: source, to: target)
                    aliases.append(target)
                }
                var modelFile = model.name
                var template: String?
                if model.format == .drawThingsBundle {
                    let bundle = try ImageModelBundle.read(sourceURL)
                    guard let spec = bundle.model else { throw ModelFileError.invalid("LoRA 不能单独作为生图主模型。") }
                    ModelZoo.overrideMapping[spec.file] = spec
                    modelFile = bundle.file
                    template = bundle.template
                    for url in try FileManager.default.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil)
                        where url.lastPathComponent != "bundle.json" {
                        try link(url, name: url.lastPathComponent)
                    }
                } else {
                    try link(sourceURL, name: model.name)
                }
                var pipeline = try await MediaGenerationPipeline.fromPretrained(
                    modelFile, backend: .local(directory: directory.path)
                )
                if let template {
                    let reference = try await MediaGenerationPipeline.fromPretrained(template, backend: .local(directory: directory.path))
                    // The model binding is read-only. Transfer sampling defaults without replacing it.
                    let defaults = reference.configuration
                    pipeline.configuration.steps = defaults.steps
                    pipeline.configuration.sampler = defaults.sampler
                    pipeline.configuration.seedMode = defaults.seedMode
                    pipeline.configuration.guidanceScale = defaults.guidanceScale
                    pipeline.configuration.strength = defaults.strength
                    pipeline.configuration.clipSkip = defaults.clipSkip
                    pipeline.configuration.shift = defaults.shift
                    pipeline.configuration.resolutionDependentShift = defaults.resolutionDependentShift
                    pipeline.configuration.guidanceEmbed = defaults.guidanceEmbed
                    pipeline.configuration.speedUpWithGuidanceEmbed = defaults.speedUpWithGuidanceEmbed
                    pipeline.configuration.t5TextEncoder = defaults.t5TextEncoder
                    pipeline.configuration.zeroNegativePrompt = defaults.zeroNegativePrompt
                    pipeline.configuration.aestheticScore = defaults.aestheticScore
                    pipeline.configuration.negativeAestheticScore = defaults.negativeAestheticScore
                }
                pipeline.configuration.loras = []
                if let lora {
                    let bundle = try ImageModelBundle.read(lora.url)
                    guard let spec = bundle.lora,
                          let base = ModelZoo.specificationForModel(modelFile), spec.version == base.version else {
                        throw ModelFileError.invalid("LoRA 与生图模型的架构不匹配。")
                    }
                    LoRAZoo.overrideMapping[spec.file] = spec
                    try link(lora.url.appendingPathComponent(spec.file), name: spec.file)
                    pipeline.configuration.loras = [LoRA(file: spec.file, weight: Float(lora.weight))]
                }
                pipeline.configuration.width = size
                pipeline.configuration.height = size
                if steps > 0 { pipeline.configuration.steps = steps }
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
