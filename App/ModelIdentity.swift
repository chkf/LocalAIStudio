import Foundation

enum ModelKind: String, Codable, Sendable {
    case text = "聊天模型"
    case image = "生图主模型"
    case lora = "LoRA"
    case lokr = "LoKr"
    case vae = "VAE"
    case textEncoder = "文本编码器"
    case unknown = "尚未确认"
}

/// Header-only identification. Similar language-model families remain ambiguous without config.json.
enum ModelIdentity {
    struct Result {
        var architecture: String?
        var kind: ModelKind
        var source: String
    }

    static func identify(metadata: [String: String], tensors: [String: [UInt64]]) -> Result {
        let keys = Set(tensors.keys.map { $0.lowercased() })
        let lora = keys.contains { $0.contains("lora_down") || $0.contains("lora_up") || $0.contains("lora_a") || $0.contains("lora_b") }
        let lokr = keys.contains { $0.contains("lokr_w") }
        let declared = ["modelspec.architecture", "ss_base_model_version", "architecture"]
            .compactMap { metadata[$0] }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let adapterKind: ModelKind? = lokr ? .lokr : (lora ? .lora : nil)
        if let declared {
            return Result(architecture: declared, kind: adapterKind ?? kind(for: declared), source: "文件元数据声明")
        }
        func contains(_ fragment: String) -> Bool { keys.contains { $0.contains(fragment) } }
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
        } else if let shape = tensors["model.diffusion_model.input_blocks.4.1.transformer_blocks.0.attn2.to_k.weight"]
                    ?? tensors["down_blocks.1.attentions.0.transformer_blocks.0.attn2.to_k.weight"], shape.count == 2 {
            switch shape.last {
            case 768: architecture = "v1"
            case 1024: architecture = "v2"
            case 2048: architecture = "sdxl_base_v0.9"
            case 1280: architecture = "sdxl_refiner_v0.9"
            default: break
            }
        }
        if let architecture {
            return Result(architecture: architecture, kind: adapterKind ?? .image, source: "根据张量结构推断，转换时由引擎确认")
        }
        if let adapterKind { return Result(kind: adapterKind, source: "根据适配器张量键识别；底模尚未确认") }
        if contains("self_attn.q_proj") || contains("self_attn.qkv_proj") || contains("attention.wq.") {
            // Llama, Qwen and Gemma can share these names; never guess an exact architecture.
            return Result(kind: .text, source: "语言模型张量结构；确切架构需要 config.json")
        }
        if contains("encoder.conv_in.") && contains("decoder.conv_out.") && !contains("diffusion_model") {
            return Result(kind: .vae, source: "根据编码器／解码器张量结构推断")
        }
        if contains("text_model.encoder.") || contains("shared.weight") && contains("encoder.block.") {
            return Result(kind: .textEncoder, source: "根据文本编码器张量结构推断")
        }
        return Result(kind: .unknown, source: "缺少可确认的架构信息")
    }

    static func kind(for architecture: String) -> ModelKind {
        let value = architecture.lowercased()
        let compact = value.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        if compact.contains("qwenimage") || compact.contains("zimage") { return .image }
        if ["stable-diffusion", "sdxl", "flux", "z_image", "z-image", "qwen_image", "qwen-image", "sd3"].contains(where: value.contains)
            || ["v1", "v2"].contains(value) { return .image }
        if ["llama", "qwen", "gemma", "mistral", "deepseek", "phi", "gpt", "falcon", "olmo"].contains(where: value.contains) { return .text }
        return .unknown
    }
}
