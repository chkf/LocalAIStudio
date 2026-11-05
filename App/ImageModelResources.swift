import Foundation
import ModelZoo
import NNC

enum ImageModelResources {
    static func specification(for model: LocalModel, url: URL,
                              configuration: ImageModelConfiguration? = nil) throws -> ModelZoo.Specification {
        let configuration = configuration ?? model.imageConfiguration
        let spec: ModelZoo.Specification
        if model.format == .drawThingsBundle {
            guard let bundled = try ImageModelBundle.read(url).model else {
                throw ModelFileError.invalid("LoRA 不能单独作为生图主模型。")
            }
            spec = bundled
        } else if model.format == .checkpoint {
            if let template = configuration?.template {
                guard let profile = ImageModelTools.profiles.first(where: { $0.file == template }) else {
                    throw ModelFileError.invalid("生图基础配置已不可用，请重新选择。")
                }
                spec = profile
            } else if let known = ModelZoo.specificationForModel(model.name)
                ?? ImageModelTools.profiles.first(where: { $0.file == model.name }) {
                spec = known
            } else {
                throw ModelFileError.invalid("此 Checkpoint 没有匹配的生图配置。请先选择与模型一致的基础配置和配套组件。")
            }
        } else {
            throw ModelFileError.invalid("原始 Safetensors 请先转换；只有 Draw Things 格式的 Checkpoint 可以直接加载。")
        }
        guard spec.remoteApiModelConfig == nil,
              ImageModelTools.profiles.contains(where: { $0.version == spec.version }),
              spec.modifier == nil || spec.modifier == .some(.none) else {
            throw ModelFileError.invalid("此模型需要当前生图页尚未支持的架构或编辑输入。")
        }
        try validateFilenames(in: spec)
        return spec
    }

    /// Editable, direct dependencies. Refiner dependencies are resolved by the engine.
    static func components(for spec: ModelZoo.Specification) -> [(role: String, file: String)] {
        var result: [(role: String, file: String)] = [
            ("VAE", spec.autoencoder ?? "vae_ft_mse_840000_f16.ckpt"),
            ("文本编码器", spec.textEncoder ?? (spec.version == .v1 ? "clip_vit_l14_f16.ckpt" : "open_clip_vit_h14_f16.ckpt"))
        ]
        if let file = spec.clipEncoder { result.append(("CLIP", file)) }
        for (index, file) in (spec.additionalClipEncoders ?? []).enumerated() {
            result.append(("CLIP \(index + 2)", file))
        }
        if let file = spec.t5Encoder { result.append(("T5", file)) }
        if let file = spec.imageEncoder { result.append(("图像编码器", file)) }
        if let file = spec.diffusionMapping { result.append(("扩散映射", file)) }
        var seen = Set<String>()
        return result.filter { seen.insert($0.file).inserted }
    }

    static func replacingComponent(_ original: String, with replacement: String,
                                   in spec: inout ModelZoo.Specification) {
        if original == (spec.autoencoder ?? "vae_ft_mse_840000_f16.ckpt") { spec.autoencoder = replacement }
        if original == (spec.textEncoder ?? (spec.version == .v1 ? "clip_vit_l14_f16.ckpt" : "open_clip_vit_h14_f16.ckpt")) {
            spec.textEncoder = replacement
        }
        if spec.clipEncoder == original { spec.clipEncoder = replacement }
        spec.additionalClipEncoders = spec.additionalClipEncoders?.map { $0 == original ? replacement : $0 }
        if spec.t5Encoder == original { spec.t5Encoder = replacement }
        if spec.imageEncoder == original { spec.imageEncoder = replacement }
        if spec.diffusionMapping == original { spec.diffusionMapping = replacement }
    }

    static func validateFilenames(in spec: ModelZoo.Specification) throws {
        let files = [spec.file] + components(for: spec).map(\.file) + (spec.stageModels ?? [])
            + (spec.latentsUpscalers ?? []).map(\.file) + [spec.defaultRefiner].compactMap { $0 }
        guard files.count <= 64, files.allSatisfy({ file in
            !file.isEmpty && file.utf8.count <= 255 && file.hasSuffix(".ckpt")
                && file == URL(fileURLWithPath: file).lastPathComponent
                && !file.contains("/") && !file.contains("\\") && !file.contains("\0")
        }) else {
            throw ModelFileError.invalid("生图配套文件清单无效，文件名必须是单个 .ckpt 文件名。")
        }
    }

    /// Checks the container and tensor index without allocating model tensors.
    static func validateCheckpoint(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ModelFileError.invalid("请选择普通 Draw Things Checkpoint 文件。")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        guard try handle.read(upToCount: 16) == Data("SQLite format 3\0".utf8) else {
            throw ModelFileError.invalid("这个 .ckpt 不是 Draw Things 权重容器。原始 PyTorch Checkpoint 不能直接加载，请使用 Safetensors 转换或 Draw Things 导出的文件。")
        }
        let graph = DynamicGraph()
        try graph.openStore(url.path, flags: .readOnly) { store in
            let keys = store.keys
            guard !keys.isEmpty else {
                throw ModelFileError.invalid("Checkpoint 没有可读取的张量索引。")
            }
            // The pinned NNC version has no single-file trailer-store reader.
            if keys.contains(where: { store.codec(for: $0)?.contains(.externalData) == true }) {
                throw ModelFileError.invalid("这个 Checkpoint 依赖单独的外部张量文件。请从 Draw Things 导出包含完整权重的单文件，再导入使用。")
            }
        }.get()
    }
}
