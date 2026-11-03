import Foundation

enum ModelFormat: String, Codable, Sendable, CaseIterable {
    case litertLM = "LiteRT-LM"
    case mediaPipe = "MediaPipe task"
    case tflite = "TFLite"
    case gguf = "GGUF"
    case safetensors = "Safetensors"
    case mlxBundle = "MLX model folder"
    case checkpoint = "Checkpoint"
    case binary = "Binary"

    var supportsTextGeneration: Bool { self == .litertLM || self == .gguf || self == .mlxBundle }
    var supportsImageGeneration: Bool { self == .checkpoint }

    var fileExtension: String {
        switch self {
        case .litertLM: "litertlm"
        case .mediaPipe: "task"
        case .tflite: "tflite"
        case .gguf: "gguf"
        case .safetensors: "safetensors"
        case .mlxBundle: "mlx"
        case .checkpoint: "ckpt"
        case .binary: "bin"
        }
    }
}

struct LocalModel: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    let byteCount: Int64
    let importedAt: Date
    let format: ModelFormat
    let architecture: String?
    let quantization: String?
    let adapter: String?
    let validationNote: String

    var compatibilityDescription: String {
        if format == .litertLM {
            return "可尝试用 LiteRT-LM 加载；架构、量化与内存占用需实际验证。"
        }
        if format == .gguf {
            return "可尝试用 llama.cpp 加载单文件 GGUF 文本模型；架构、聊天模板及内存需求需实际验证。"
        }
        if format == .mlxBundle {
            return "可尝试用 MLX Swift LM 加载本地模型目录；需完整的 config、tokenizer 与 Safetensors 权重，模型架构须受 MLX 支持。"
        }
        if format == .checkpoint {
            return "可尝试通过 MediaGenerationKit 使用支持的生图 Checkpoint；仅凭 .ckpt 扩展名不代表模型兼容。"
        }
        if format == .safetensors {
            return "独立 Safetensors 只是权重。语言模型需连同配置、分词器作为模型文件夹导入；生图权重需兼容转换。"
        }
        return "当前未接入此格式的推理引擎，仅可存储与管理。适配器还需匹配的基础模型."
    }
}

struct ModelInspection: Sendable {
    let format: ModelFormat
    var architecture: String?
    var quantization: String?
    var adapter: String?
    var note: String
}

enum ModelFileError: LocalizedError {
    case unsupportedFile
    case invalid(String)
    case headerTooLarge
    case notEnoughSpace
    case invalidLibraryEntry(String)
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            "请选择模型文件（litertlm、gguf、safetensors、ckpt 等），或使用“导入 MLX 文件夹”选择包含配置和权重的目录。"
        case .invalid(let detail): "模型文件无效：\(detail)"
        case .headerTooLarge: "模型元数据超过 8 MiB 检查上限，未导入。请使用受支持的模型文件。"
        case .notEnoughSpace: "可用存储空间不足，无法导入此模型。"
        case .invalidLibraryEntry(let name): "模型库记录损坏或文件缺失：\(name)。现有文件已保留。"
        case .cleanupFailed(let detail): "导入未完成，临时文件清理失败：\(detail)"
        }
    }
}

enum ModelFile {
    static let supportedExtensions: Set<String> = ["litertlm", "task", "tflite", "gguf", "safetensors", "ckpt", "bin"]
    static let headerLimit = 8 * 1_024 * 1_024

    /// Recognition does not verify tensor contents or certify engine compatibility.
    static func inspect(_ url: URL, name: String) throws -> ModelInspection {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard size >= 8 else { throw ModelFileError.invalid("文件为空或文件头不完整。") }
        let prefix = try handle.read(upToCount: 32) ?? Data()
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()

        if prefix.starts(with: Data("LITERTLM".utf8)) {
            guard prefix.count == 32 else { throw ModelFileError.invalid("LiteRT-LM 文件头不完整。") }
            let headerEnd = integer(prefix, offset: 24, bytes: 8)
            guard headerEnd >= 36, headerEnd <= size else {
                throw ModelFileError.invalid("LiteRT-LM 元数据范围超出文件。")
            }
            let major = integer(prefix, offset: 8, bytes: 4)
            let minor = integer(prefix, offset: 12, bytes: 4)
            return ModelInspection(format: .litertLM, note: "已识别 LiteRT-LM \(major).\(minor) 文件头；内部模型、分词器与权重尚未验证。")
        }
        if prefix.starts(with: Data("GGUF".utf8)) {
            try handle.seek(toOffset: 0)
            let data = try handle.read(upToCount: headerLimit) ?? Data()
            return try inspectGGUF(data, fileSize: size)
        }
        if prefix.count >= 8, prefix[4..<8] == Data("TFL3".utf8) {
            let root = integer(prefix, offset: 0, bytes: 4)
            guard root >= 8, root <= size - 4 else { throw ModelFileError.invalid("TFLite 根表偏移无效。") }
            return ModelInspection(format: .tflite, note: "已识别 TFLite 文件头；算子、架构与权重尚未验证。")
        }
        if ext == "safetensors" || (prefix.count > 8 && prefix[8] == 0x7b && integer(prefix, offset: 0, bytes: 8) <= size - 8) {
            try handle.seek(toOffset: 0)
            return try inspectSafetensors(handle, fileSize: size)
        }
        guard supportedExtensions.contains(ext) else { throw ModelFileError.unsupportedFile }
        if ["litertlm", "tflite", "gguf"].contains(ext) {
            throw ModelFileError.invalid("文件内容与 .\(ext) 格式不符，请确认下载的是权重文件而非网页。")
        }
        let text = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.hasPrefix("<!doctype"), !text.hasPrefix("<html"), !text.hasPrefix("version https://git-lfs") else {
            throw ModelFileError.invalid("收到的是网页或 Git LFS 指针，不是模型权重。")
        }
        let format: ModelFormat = ext == "task" ? .mediaPipe : (ext == "ckpt" ? .checkpoint : .binary)
        return ModelInspection(format: format, note: "仅按扩展名登记，内部格式、架构与量化尚未验证；不会执行或反序列化文件内容。")
    }

    private struct Tensor: Decodable {
        let dtype: String
        let shape: [UInt64]
        let data_offsets: [UInt64]
    }

    private enum HeaderEntry: Decodable {
        case metadata([String: String])
        case tensor(Tensor)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if decoder.codingPath.last?.stringValue == "__metadata__" {
                self = .metadata(try container.decode([String: String].self))
            } else {
                self = .tensor(try container.decode(Tensor.self))
            }
        }
    }

    private static func inspectSafetensors(_ handle: FileHandle, fileSize: UInt64) throws -> ModelInspection {
        let lengthData = try handle.read(upToCount: 8) ?? Data()
        guard lengthData.count == 8 else { throw ModelFileError.invalid("Safetensors 文件头不完整。") }
        let length = integer(lengthData, offset: 0, bytes: 8)
        guard length > 0, length <= fileSize - 8 else { throw ModelFileError.invalid("Safetensors 文件头长度无效。") }
        guard length <= UInt64(headerLimit) else { throw ModelFileError.headerTooLarge }
        let headerData = try handle.read(upToCount: Int(length)) ?? Data()
        guard headerData.count == Int(length), headerData.first == 0x7b else {
            throw ModelFileError.invalid("Safetensors JSON 文件头不完整。")
        }
        let entries: [String: HeaderEntry]
        do {
            entries = try JSONDecoder().decode([String: HeaderEntry].self, from: headerData)
        } catch {
            throw ModelFileError.invalid("Safetensors 元数据无法解析：\(error.localizedDescription)")
        }
        var metadata: [String: String] = [:]
        var offsets: [(UInt64, UInt64)] = []
        var dtypes = Set<String>()
        let bitsPerElement: [String: UInt64] = ["BOOL": 8, "U8": 8, "I8": 8, "F8_E4M3": 8, "F8_E5M2": 8, "I16": 16, "U16": 16, "F16": 16, "BF16": 16, "I32": 32, "U32": 32, "F32": 32, "I64": 64, "U64": 64, "F64": 64]
        let dataSize = fileSize - 8 - length
        for entry in entries.values {
            switch entry {
            case .metadata(let values): metadata = values
            case .tensor(let tensor):
                guard tensor.data_offsets.count == 2,
                      tensor.data_offsets[0] <= tensor.data_offsets[1], tensor.data_offsets[1] <= dataSize else {
                    throw ModelFileError.invalid("Safetensors 张量范围超出文件。")
                }
                if let bits = bitsPerElement[tensor.dtype] {
                    var elements: UInt64 = tensor.shape.contains(0) ? 0 : 1
                    for dimension in tensor.shape {
                        let product = elements.multipliedReportingOverflow(by: dimension)
                        guard !product.overflow else { throw ModelFileError.invalid("Safetensors 张量形状溢出。") }
                        elements = product.partialValue
                    }
                    let bytes = elements.multipliedReportingOverflow(by: bits / 8)
                    guard !bytes.overflow, bytes.partialValue == tensor.data_offsets[1] - tensor.data_offsets[0] else {
                        throw ModelFileError.invalid("Safetensors 张量形状与数据长度不一致。")
                    }
                }
                offsets.append((tensor.data_offsets[0], tensor.data_offsets[1]))
                dtypes.insert(tensor.dtype)
            }
        }
        guard !offsets.isEmpty else { throw ModelFileError.invalid("Safetensors 未包含张量。") }
        offsets.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var end: UInt64 = 0
        for range in offsets {
            guard range.0 == end else { throw ModelFileError.invalid("Safetensors 张量范围重叠或存在空洞。") }
            end = range.1
        }
        guard end == dataSize else { throw ModelFileError.invalid("Safetensors 文件大小与张量范围不一致。") }
        let keys = entries.keys.map { $0.lowercased() }
        let adapter: String?
        if keys.contains(where: { $0.contains("lokr_w") }) {
            adapter = "LoKr（张量键识别，兼容性未验证）"
        } else if keys.contains(where: { $0.contains("lora_up.") || $0.contains("lora_down.") || $0.contains("lora_a.") || $0.contains("lora_b.") }) {
            adapter = "LoRA（张量键识别，兼容性未验证）"
        } else {
            adapter = nil
        }
        return ModelInspection(
            format: .safetensors,
            architecture: metadata["modelspec.architecture"] ?? metadata["ss_base_model_version"] ?? metadata["architecture"],
            quantization: metadata["quantization"] ?? dtypes.sorted().joined(separator: " / ") + "（张量类型）",
            adapter: adapter,
            note: "已检查元数据和张量文件范围；未验证权重数值、模型完整依赖或推理兼容性。"
        )
    }

    private static func inspectGGUF(_ data: Data, fileSize: UInt64) throws -> ModelInspection {
        var reader = PrefixReader(data: data, fileSize: fileSize, offset: 4)
        let version = try reader.number(4)
        guard version == 2 || version == 3 else { throw ModelFileError.invalid("仅识别小端序 GGUF v2/v3 文件。") }
        let tensorCount = try reader.number(8)
        let fieldCount = try reader.number(8)
        var result = ModelInspection(format: .gguf, note: "已检查 GGUF v\(version) 元数据与张量起始范围；未验证完整权重和引擎兼容性。")
        var alignment: UInt64 = 32
        do {
            for _ in 0..<fieldCount {
                let key = try reader.string()
                let type = try reader.number(4)
                if ["general.architecture", "adapter.type"].contains(key), type != 8 {
                    throw ModelFileError.invalid("GGUF 的 \(key) 应为字符串。")
                }
                if ["general.file_type", "general.alignment"].contains(key), type != 4, type != 10 {
                    throw ModelFileError.invalid("GGUF 的 \(key) 应为无符号整数。")
                }
                let value = try reader.value(type: type, retain: ["general.architecture", "general.file_type", "general.alignment", "adapter.type"].contains(key))
                switch key {
                case "general.architecture": result.architecture = value
                case "general.file_type":
                    let types = ["F32", "F16", "Q4_0", "Q4_1", "Q4_1 / F16", "Q4_2", "Q4_3", "Q8_0", "Q5_0", "Q5_1", "Q2_K", "Q3_K_S", "Q3_K_M", "Q3_K_L", "Q4_K_S", "Q4_K_M", "Q5_K_S", "Q5_K_M", "Q6_K"]
                    if let value, let index = Int(value), types.indices.contains(index) {
                        result.quantization = types[index]
                    } else if let value {
                        result.quantization = "GGUF file_type \(value)（未识别）"
                    }
                case "general.alignment":
                    guard let value, let parsed = UInt64(value), parsed > 0, parsed <= 65_536, parsed % 8 == 0 else {
                        throw ModelFileError.invalid("GGUF 对齐参数无效。")
                    }
                    alignment = parsed
                case "adapter.type": result.adapter = value.map { "\($0)（元数据声明，兼容性未验证）" }
                default: break
                }
            }
            var largestOffset: UInt64 = 0
            for _ in 0..<tensorCount {
                _ = try reader.string()
                let dimensions = try reader.number(4)
                guard dimensions <= 4 else { throw ModelFileError.invalid("GGUF 张量维数无效。") }
                try reader.skip(dimensions * 8)
                _ = try reader.number(4)
                let tensorOffset = try reader.number(8)
                guard tensorOffset % alignment == 0 else { throw ModelFileError.invalid("GGUF 张量对齐无效。") }
                largestOffset = max(largestOffset, tensorOffset)
            }
            let dataStart = (UInt64(reader.offset) + alignment - 1) / alignment * alignment
            if tensorCount > 0 {
                guard dataStart < fileSize, largestOffset < fileSize - dataStart else {
                    throw ModelFileError.invalid("GGUF 张量起始位置超出文件。")
                }
            }
        } catch PrefixReader.Limit.reached {
            result.note = "已识别 GGUF 文件头；元数据超过 8 MiB 检查范围，未完成结构验证。"
        }
        return result
    }

    private static func integer(_ data: Data, offset: Int, bytes: Int) -> UInt64 {
        (0..<bytes).reduce(UInt64(0)) { $0 | (UInt64(data[offset + $1]) << (8 * $1)) }
    }

    private struct PrefixReader {
        enum Limit: Error { case reached }
        let data: Data
        let fileSize: UInt64
        var offset: Int

        mutating func skip(_ count: UInt64) throws {
            guard count <= fileSize - UInt64(offset) else { throw ModelFileError.invalid("GGUF 文件被截断。") }
            guard count <= UInt64(data.count - offset) else { throw Limit.reached }
            offset += Int(count)
        }

        mutating func number(_ bytes: Int) throws -> UInt64 {
            let start = offset
            try skip(UInt64(bytes))
            return ModelFile.integer(data, offset: start, bytes: bytes)
        }

        mutating func string() throws -> String {
            let count = try number(8)
            let start = offset
            try skip(count)
            guard let value = String(data: data[start..<offset], encoding: .utf8) else { throw ModelFileError.invalid("GGUF 字符串不是 UTF-8。") }
            return value
        }

        mutating func value(type: UInt64, retain: Bool, depth: Int = 0) throws -> String? {
            let widths: [UInt64: Int] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
            if let width = widths[type] {
                let raw = try number(width)
                if type == 7, raw > 1 { throw ModelFileError.invalid("GGUF 布尔值无效。") }
                return retain ? String(raw) : nil
            }
            if type == 8 {
                if retain { return try string() }
                let length = try number(8)
                try skip(length)
                return nil
            }
            guard type == 9, depth < 4 else { throw ModelFileError.invalid("GGUF 元数据类型无效或嵌套过深。") }
            let elementType = try number(4)
            let count = try number(8)
            if let width = widths[elementType] {
                guard count <= UInt64.max / UInt64(width) else { throw ModelFileError.invalid("GGUF 数组长度无效。") }
                try skip(count * UInt64(width))
            } else {
                for _ in 0..<count { _ = try value(type: elementType, retain: false, depth: depth + 1) }
            }
            return nil
        }
    }
}
