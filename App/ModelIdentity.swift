import Foundation

enum ModelKind: String, Codable, Sendable {
    case text = "聊天模型"
    case image = "生图主模型"
    case lora = "LoRA"
    case lokr = "LoKr"
    case vae = "VAE"
    case textEncoder = "文本编码器"
    case visionEncoder = "视觉编码器"
    case unknown = "尚未确认"
}

/// Header-only identification. Similar language-model families remain ambiguous without config.json.
enum ModelIdentity {
    static let version = 1

    struct Result {
        var architecture: String?
        var kind: ModelKind
        var source: String
    }

    static func identify(metadata: [String: String], tensors: [String: [UInt64]]) -> Result {
        let keys = Set(tensors.keys.map { $0.lowercased() })
        func contains(_ fragment: String) -> Bool { keys.contains { $0.contains(fragment) } }
        let lora = contains("lora_down") || contains("lora_up") || contains("lora_a") || contains("lora_b")
        let lokr = contains("lokr_w")
        let declared = ["modelspec.architecture", "ss_base_model_version", "architecture"]
            .compactMap { metadata[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let adapterKind: ModelKind? = lokr ? .lokr : (lora ? .lora : nil)
        var architecture: String?
        if contains("single_blocks.39.linear1") || contains("single_transformer_blocks.39.attn.to_qkv_mlp_proj") {
            architecture = "flux2"
        } else if contains("single_blocks.23.linear1") || contains("single_transformer_blocks.23.attn.to_qkv_mlp_proj") {
            architecture = "flux2_9b"
        } else if contains("single_blocks.19.linear1") || contains("single_transformer_blocks.19.attn.to_qkv_mlp_proj") {
            architecture = "flux2_4b"
        } else if contains("double_blocks.18.img_attn.qkv") || contains("single_transformer_blocks.37.proj_mlp") {
            architecture = "flux1"
        } else if contains("transformer_blocks.59.txt_mlp") {
            architecture = "qwen_image"
        } else if contains("layers.29.feed_forward.w3") && contains("x_embedder") {
            architecture = "z_image"
        } else if let shape = tensors.first(where: {
            $0.key.hasSuffix("input_blocks.4.1.transformer_blocks.0.attn2.to_k.weight") ||
            $0.key.hasSuffix("down_blocks.1.attentions.0.transformer_blocks.0.attn2.to_k.weight")
        })?.value, shape.count == 2 {
            switch shape.last {
            case 768: architecture = "v1"
            case 1024: architecture = "v2"
            case 2048: architecture = "sdxl_base_v0.9"
            case 1280: architecture = "sdxl_refiner_v0.9"
            default: break
            }
        }
        if let architecture {
            let conflict = declared.map { canonicalArchitecture($0) != architecture && kind(for: $0) == .image } ?? false
            return Result(architecture: architecture, kind: adapterKind ?? .image,
                          source: conflict ? "张量结构与元数据声明不同，按结构识别；转换时由引擎确认" : "根据张量结构推断，转换时由引擎确认")
        }
        if let adapterKind {
            return Result(architecture: declared.map(canonicalArchitecture), kind: adapterKind,
                          source: declared == nil ? "根据适配器张量键识别；底模尚未确认" : "文件元数据声明；适配器张量确认角色")
        }
        // A full checkpoint can also contain VAE and CLIP tensors; do not mistake it for a component.
        if keys.contains(where: { $0.hasPrefix("model.diffusion_model.") || $0.hasPrefix("diffusion_model.") || $0.hasPrefix("unet.") })
            || contains("down_blocks.") && contains("time_embedding.") {
            return Result(architecture: declared.flatMap { kind(for: $0) == .image ? canonicalArchitecture($0) : nil },
                          kind: .image, source: "已识别去噪网络；确切架构由转换器确认")
        }
        // A component may declare the architecture of its parent pipeline. Its role must come from the weights.
        if contains("encoder.conv_in.") && contains("decoder.conv_out.") && !contains("diffusion_model") {
            return Result(architecture: declared.map(canonicalArchitecture), kind: .vae, source: "根据编码器／解码器张量结构推断")
        }
        if contains("vision_model.encoder.") && !contains("text_model.encoder.") {
            return Result(architecture: declared.map(canonicalArchitecture), kind: .visionEncoder, source: "根据视觉编码器张量结构推断")
        }
        if contains("text_model.encoder.") || contains("shared.weight") && contains("encoder.block.") {
            return Result(architecture: declared.map(canonicalArchitecture), kind: .textEncoder, source: "根据文本编码器张量结构推断")
        }
        if let declared, kind(for: declared) != .unknown {
            return Result(architecture: canonicalArchitecture(declared), kind: kind(for: declared), source: "文件元数据声明")
        }
        if contains("self_attn.q_proj") || contains("self_attn.qkv_proj") || contains("attention.wq.") {
            // Llama, Qwen and Gemma can share these names; never guess an exact architecture.
            return Result(kind: .text, source: "语言模型张量结构；确切架构需要 config.json")
        }
        return Result(architecture: declared, kind: .unknown, source: declared == nil ? "缺少可确认的架构信息" : "元数据声明未识别，不能确认模型用途")
    }

    /// Match known metadata names to the pinned image importer's model versions.
    static func canonicalArchitecture(_ architecture: String) -> String {
        let value = architecture.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let compact = value.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "")
        if compact.contains("stablediffusionxl") || compact.hasPrefix("sdxl") {
            return compact.contains("refiner") ? "sdxl_refiner_v0.9" : "sdxl_base_v0.9"
        }
        if compact.hasPrefix("stablediffusionv1") || ["sd1", "sd15", "sdv1", "v1"].contains(compact) { return "v1" }
        if compact.hasPrefix("stablediffusionv2") || ["sd2", "sd20", "sd21", "sdv2", "v2"].contains(compact) { return "v2" }
        if compact.hasPrefix("flux2") {
            if compact.contains("4b") { return "flux2_4b" }
            if compact.contains("9b") { return "flux2_9b" }
            return "flux2"
        }
        if compact.hasPrefix("flux1") || compact == "flux" { return "flux1" }
        if compact.hasPrefix("qwenimage") { return "qwen_image" }
        if compact.hasPrefix("zimage") { return "z_image" }
        return architecture.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func kind(for architecture: String) -> ModelKind {
        let value = architecture.lowercased()
        let compact = value.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        if compact.contains("vae") || compact.contains("autoencoder") { return .vae }
        if compact == "vision" || compact.hasPrefix("clipvision") || compact.hasPrefix("siglip") { return .visionEncoder }
        if compact.contains("textencoder") || compact.hasPrefix("clip") || compact.hasPrefix("openclip") || compact.hasPrefix("t5") { return .textEncoder }
        if compact.contains("qwenimage") || compact.contains("zimage") { return .image }
        if ["stable-diffusion", "sdxl", "flux", "z_image", "z-image", "qwen_image", "qwen-image", "sd3"].contains(where: value.contains)
            || ["v1", "v2"].contains(canonicalArchitecture(architecture)) { return .image }
        if ["llama", "qwen", "gemma", "mistral", "deepseek", "phi", "gpt", "falcon", "olmo", "granite", "internlm", "baichuan", "bloom", "command-r", "dbrx", "mamba", "rwkv", "starcoder"].contains(where: value.contains) { return .text }
        return .unknown
    }
}
