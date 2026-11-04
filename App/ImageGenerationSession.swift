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

    func prepareResources(model: LocalModel, sourceURL: URL, components: [String: URL]) async {
        await run(model: model, sourceURL: sourceURL, prompt: "", negativePrompt: "", size: 512, steps: 0,
                  components: components, prepareOnly: true)
    }

    func generate(model: LocalModel, sourceURL: URL, prompt: String,
                  negativePrompt: String, size: Int, steps: Int,
                  lora: (model: LocalModel, url: URL, weight: Double)? = nil,
                  components: [String: URL] = [:]) async {
        await run(model: model, sourceURL: sourceURL, prompt: prompt, negativePrompt: negativePrompt,
                  size: size, steps: steps, lora: lora, components: components, prepareOnly: false)
    }

    private func run(model: LocalModel, sourceURL: URL, prompt: String,
                     negativePrompt: String, size: Int, steps: Int,
                     lora: (model: LocalModel, url: URL, weight: Double)? = nil,
                     components: [String: URL], prepareOnly: Bool) async {
        guard !isGenerating, model.supportsImageGeneration else { return }
        isGenerating = true
        status = "准备生图模型…"
        errorMessage = nil
        if !prepareOnly { resultURL = nil }
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
                let environment = MediaGenerationEnvironment.default
                let oldEnvironmentURLs = environment.externalUrls
                let oldExternalURLs = ModelZoo.externalUrls
                let oldPreference = ModelZoo.isExternalUrlsPreferred
                environment.externalUrls = [directory]
                ModelZoo.isExternalUrlsPreferred = true
                let oldModels = ModelZoo.overrideMapping
                let oldLoRAs = LoRAZoo.overrideMapping
                defer {
                    environment.externalUrls = oldEnvironmentURLs
                    ModelZoo.externalUrls = oldExternalURLs
                    ModelZoo.isExternalUrlsPreferred = oldPreference
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
                var spec = try ImageModelResources.specification(for: model, url: sourceURL)
                var template = model.imageConfiguration?.template
                if model.format == .drawThingsBundle {
                    let bundle = try ImageModelBundle.read(sourceURL)
                    template = bundle.template
                    // Only declared components become runtime files; never link arbitrary bundle entries.
                    let filenames = Set(ModelZoo.filesToDownload(spec).map(\.file))
                    for filename in filenames {
                        if components[filename] != nil { continue }
                        let url = sourceURL.appendingPathComponent(filename)
                        if FileManager.default.fileExists(atPath: url.path) {
                            try ImageModelResources.validateCheckpoint(url)
                            try link(url, name: filename)
                        } else if filename.hasPrefix("studio_") {
                            throw ModelFileError.invalid("转换模型缺少组件：\(filename)。请重新转换或指定组件。")
                        }
                    }
                } else {
                    try ImageModelResources.validateCheckpoint(sourceURL)
                    template = template ?? spec.file
                    // Keep user weights under an owned alias so catalog hash checks cannot replace them.
                    spec.file = "studio_\(model.id.uuidString)_main.ckpt"
                    try link(sourceURL, name: spec.file)
                }
                let required = Set(ImageModelResources.components(for: spec).map(\.file))
                for (original, source) in components {
                    guard required.contains(original) else {
                        throw ModelFileError.invalid("配套组件配置已变化，请重新保存模型配置。")
                    }
                    try ImageModelResources.validateCheckpoint(source)
                    let alias = "studio_\(UUID().uuidString)_component.ckpt"
                    try link(source, name: alias)
                    ImageModelResources.replacingComponent(original, with: alias, in: &spec)
                }
                let modelFile = spec.file
                ModelZoo.overrideMapping[modelFile] = spec
                _ = try await environment.ensure(modelFile, offline: true) { state in
                    Task { @MainActor in
                        switch state {
                        case .resolving: self.status = "检查配套资源…"
                        case .verifying(let file, let index, let total):
                            self.status = "检查 \(index)/\(total) · \(file)"
                        case .downloading(let file, let index, let total, let written, let expected):
                            let received = ByteCountFormatter.string(fromByteCount: written, countStyle: .file)
                            let size = expected > 0 ? " / " + ByteCountFormatter.string(fromByteCount: expected, countStyle: .file) : ""
                            self.status = "下载 \(index)/\(total) · \(file)\n\(received)\(size)"
                        }
                    }
                }
                try Task.checkCancellation()
                if prepareOnly {
                    status = "配套资源已就绪"
                    return
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
                errorMessage = "生图模型或配套资源加载失败：\(error.localizedDescription)"
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
