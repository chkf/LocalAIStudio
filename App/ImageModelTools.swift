import Foundation
import MediaGenerationKit
import ModelOp
import ModelZoo
import Diffusion
import NNC

struct ImageModelBundle: Codable {
    var file: String
    var version: String
    var template: String?
    var model: ModelZoo.Specification?
    var lora: LoRAZoo.Specification?
    var quantization: String

    static func read(_ directory: URL) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("bundle.json")))
        guard result.file == URL(fileURLWithPath: result.file).lastPathComponent,
              result.file.hasSuffix(".ckpt"), result.model != nil || result.lora != nil else {
            throw ModelFileError.invalid("生图模型清单无效。")
        }
        let payload = directory.appendingPathComponent(result.file)
        let values = try payload.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0,
              (result.model?.file ?? result.lora?.file) == result.file,
              (result.model?.version.rawValue ?? result.lora?.version.rawValue) == result.version else {
            throw ModelFileError.invalid("生图模型清单与权重不一致。")
        }
        return result
    }

    func write(_ directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("bundle.json"), options: .atomic)
    }
}

enum ImageModelOperation: Sendable {
    case convert(template: String, vae: URL?, textEncoder: URL? = nil, textEncoder2: URL? = nil)
    case lora(version: String?)
    case quantize
}

/// Uses the same pinned ModelOp/NNC implementation as MediaGenerationKit.
/// Called only by ModelFiles while the app has stopped both inference runtimes.
enum ImageModelTools {
    static var profiles: [ModelZoo.Specification] {
        let files: Set<String> = [
            "sd_v1.5_f16.ckpt", "sd_v2.1_f16.ckpt", "sd_v2.1_768_v_f16.ckpt",
            "sd_xl_base_1.0_f16.ckpt", "sd_xl_refiner_1.0_f16.ckpt",
            "flux_1_schnell_q8p.ckpt", "z_image_turbo_1.0_q8p.ckpt", "z_image_1.0_q8p.ckpt",
            "qwen_image_1.0_q8p.ckpt", "qwen_image_2512_q8p.ckpt",
            "flux_2_klein_4b_q8p.ckpt", "flux_2_klein_base_4b_q8p.ckpt"
        ]
        var result = ModelZoo.builtinSpecifications.filter { files.contains($0.file) }
        // Parameters from the pinned MediaGenerationKit bundled model catalog.
        for (name, file) in [("FLUX.1 [dev]", "flux_1_dev_q8p.ckpt"), ("FLUX.1 Krea [dev]", "flux_1_krea_dev_q8p.ckpt")] {
            result.append(ModelZoo.Specification(name: name, file: file, prefix: "", version: .flux1,
                defaultScale: 16, textEncoder: "t5_xxl_encoder_q6p.ckpt", autoencoder: "flux_1_vae_f16.ckpt",
                clipEncoder: "clip_vit_l14_f16.ckpt", highPrecisionAutoencoder: true,
                objective: .u(conditionScale: 1000), guidanceEmbed: true, paddedTextEncodingLength: 512,
                hiresFixScale: 24))
        }
        return result
    }

    static func process(source: URL, name: String, operation: ImageModelOperation, destination: URL,
                        progress: @escaping @Sendable (Double) -> Void) throws -> ImageModelBundle {
        try Task.checkCancellation()
        switch operation {
        case .lora(let requestedVersion):
            let inspection = try ModelFile.inspect(source, name: name)
            guard inspection.format == .safetensors, inspection.kind == .lora,
                  inspection.architecture.map({ ModelIdentity.kind(for: $0) != .text }) ?? true else {
                throw ModelFileError.invalid("请选择 Safetensors LoRA；LoKr 和聊天模型适配器暂不转换。")
            }
            let forced = requestedVersion.flatMap(ModelVersion.init(rawValue:))
            if requestedVersion != nil && forced == nil { throw ModelFileError.invalid("不支持这个底模架构。") }
            let filename = "studio_\(UUID().uuidString)_lora_f16.ckpt"
            var importer = MediaGenerationKit.LoRAImporter(file: source, version: forced)
            try importer.import(to: destination.appendingPathComponent(filename), progressHandler: progress)
            try Task.checkCancellation()
            guard let version = importer.version else { throw ModelFileError.invalid("无法确认 LoRA 的底模架构。") }
            let spec = LoRAZoo.Specification(name: name, file: filename, prefix: "", version: version)
            return ImageModelBundle(file: filename, version: version.rawValue, lora: spec, quantization: "FP16")
        case .convert(let template, let vae, let textEncoder, let textEncoder2):
            let inspection = try ModelFile.inspect(source, name: name)
            guard inspection.format == .safetensors, inspection.adapter == nil,
                  inspection.kind == .image || inspection.kind == .unknown else {
                throw ModelFileError.invalid("请选择生图主模型 Safetensors 文件。")
            }
            guard var spec = profiles.first(where: { $0.file == template }) else {
                throw ModelFileError.invalid("请选择受支持的基础配置。")
            }
            if let vae {
                guard try ModelFile.inspect(vae, name: "vae.safetensors").format == .safetensors else {
                    throw ModelFileError.invalid("VAE 必须为 Safetensors 文件。")
                }
            }
            let stem = "studio_\(UUID().uuidString)"
            let probe = ModelOp.ModelImporter(filePath: source.path, modelName: stem,
                isTextEncoderCustomized: false, autoencoderFilePath: nil,
                textEncoderFilePath: nil, textEncoder2FilePath: nil)
            let detected = try probe.inspect()
            guard detected.version == spec.version else {
                throw ModelFileError.invalid("识别为 \(detected.version.rawValue)，与所选基础配置 \(spec.version.rawValue) 不匹配。")
            }
            if detected.version == .flux1 && detected.hasGuidanceEmbed != (spec.guidanceEmbed ?? false) {
                throw ModelFileError.invalid("FLUX 的 guidance 结构与基础配置不匹配，请核对 dev／schnell 版本。")
            }
            guard detected.modifier == .none else {
                throw ModelFileError.invalid("当前生图页尚未接入此模型需要的编辑／修补输入。")
            }
            // These profiles have complete importer branches at the pinned revision.
            let sdFamily: Set<ModelVersion> = [.v1, .v2, .sdxlBase, .sdxlRefiner]
            let embeddedText = sdFamily.contains(detected.version) && detected.stateDict.keys.contains {
                $0.hasPrefix("cond_stage_model.") || $0.hasPrefix("conditioner.embedders.")
            }
            let embeddedVAE = sdFamily.contains(detected.version) && detected.stateDict.keys.contains {
                $0.hasPrefix("first_stage_model.encoder.")
            }
            if vae != nil && !sdFamily.contains(detected.version) {
                throw ModelFileError.invalid("此架构请使用基础配置指定的 VAE；独立 VAE 转换目前支持 SD1／SD2／SDXL。")
            }
            let customText = textEncoder != nil || textEncoder2 != nil
            if customText {
                guard sdFamily.contains(detected.version) else {
                    throw ModelFileError.invalid("此架构的原始文本编码器暂不支持转换，请使用配套的 Draw Things 组件。")
                }
                if detected.version == .sdxlBase {
                    let hasFirst = textEncoder != nil || detected.stateDict.keys.contains { $0.hasPrefix("conditioner.embedders.0.") }
                    let hasSecond = textEncoder2 != nil || detected.stateDict.keys.contains { $0.hasPrefix("conditioner.embedders.1.") }
                    guard hasFirst && hasSecond else {
                        throw ModelFileError.invalid("SDXL 需要 CLIP-L 和 OpenCLIP bigG 两个文本编码器，请补齐缺少的组件，或都使用标准组件。")
                    }
                }
                if textEncoder2 != nil && detected.version != .sdxlBase {
                    throw ModelFileError.invalid("只有 SDXL Base 使用第二个文本编码器。")
                }
                for file in [textEncoder, textEncoder2].compactMap({ $0 }) {
                    let component = try ModelFile.inspect(file, name: "encoder.safetensors")
                    guard component.format == .safetensors, component.kind == .textEncoder else {
                        throw ModelFileError.invalid("请选择兼容的 Safetensors 文本编码器。")
                    }
                }
            }
            let importer = ModelOp.ModelImporter(filePath: source.path, modelName: stem,
                isTextEncoderCustomized: embeddedText || customText,
                autoencoderFilePath: vae?.path ?? (embeddedVAE ? source.path : nil),
                textEncoderFilePath: textEncoder?.path, textEncoder2FilePath: textEncoder2?.path)
            let originalPaths = ModelZoo.externalUrls
            let originalPreference = ModelZoo.isExternalUrlsPreferred
            ModelZoo.externalUrls = [destination]
            ModelZoo.isExternalUrlsPreferred = true
            defer {
                ModelZoo.externalUrls = originalPaths
                ModelZoo.isExternalUrlsPreferred = originalPreference
            }
            let (paths, version, modifier, result) = try importer.import(versionCheck: { _ in }, progress: { progress(Double($0)) })
            try Task.checkCancellation()
            let filenames = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
            let filename = stem + "_f16.ckpt"
            guard filenames.contains(filename) else { throw ModelFileError.invalid("转换器没有输出生图主模型。") }
            spec.name = name
            spec.file = filename
            spec.modifier = modifier
            spec.guidanceEmbed = result.hasGuidanceEmbed
            // Preserve profile-specific prediction / normalization; replace only converted components.
            if let file = filenames.first(where: { $0.hasSuffix("_vae_f16.ckpt") }) { spec.autoencoder = file }
            if let file = filenames.first(where: { $0.hasSuffix("_open_clip_vit_bigg14_f16.ckpt") }) { spec.textEncoder = file }
            if let file = filenames.first(where: { $0.hasSuffix("_open_clip_vit_h14_f16.ckpt") }) { spec.textEncoder = file }
            if let file = filenames.first(where: { $0.hasSuffix("_clip_vit_l14_f16.ckpt") }) {
                if version == .v1 { spec.textEncoder = file } else { spec.clipEncoder = file }
            }
            spec.huggingFaceLink = nil
            spec.note = "由用户导入转换；基础配置：\(template)"
            return ImageModelBundle(file: filename, version: version.rawValue, template: template,
                                    model: spec, quantization: "FP16")
        case .quantize:
            var bundle = try ImageModelBundle.read(source)
            guard var spec = bundle.model, bundle.quantization == "FP16" else {
                throw ModelFileError.invalid("请选择尚未量化的已转换生图主模型。")
            }
            let newFile = "studio_\(UUID().uuidString)_q8p.ckpt"
            for entry in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                if entry.lastPathComponent == "bundle.json" || entry.lastPathComponent == bundle.file { continue }
                // Companions are immutable; hard links avoid copying them just to quantize the main model.
                try FileManager.default.linkItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
            }
            try quantize(source.appendingPathComponent(bundle.file), to: destination.appendingPathComponent(newFile), progress: progress)
            spec.file = newFile
            bundle.file = newFile
            bundle.model = spec
            bundle.quantization = "8-bit Q8P（主模型矩阵；其余保留原精度）"
            return bundle
        }
    }

    static func quantize(_ source: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) throws {
        let graph = DynamicGraph()
        try graph.openStore(source.path, flags: .readOnly) { input in
            let keys = input.keys
            guard !keys.isEmpty else { throw ModelFileError.invalid("模型没有可读取的权重。") }
            try graph.openStore(destination.path) { output in
                for (index, key) in keys.enumerated() {
                    try Task.checkCancellation()
                    try autoreleasepool {
                        guard let tensor = input.read(key, codec: [.ezm7, .q8p, .q6p, .q4p]) else {
                            throw ModelFileError.invalid("无法读取权重：\(key)")
                        }
                        let fp16 = Tensor<Float16>(from: tensor)
                        let matrix = fp16.shape.filter { $0 > 1 }.count > 1
                        let preserve = ["norm", "embed", "bias", "scale", "shift"].contains { key.contains($0) }
                        try output.write(key, tensor: fp16, strict: true, codec: matrix && !preserve ? [.q8p, .ezm7] : [.ezm7])
                    }
                    progress(Double(index + 1) / Double(keys.count))
                }
            }.get()
        }.get()
    }
}
