import Foundation

struct SpeechModel: Identifiable, Codable, Sendable {
    let id: UUID
    let name: String
    let speakers: Int
    let byteCount: Int64
}

enum SpeechModelError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

/// Only the self-contained sherpa-onnx Kokoro lexicon format is accepted.
/// Original PyTorch / MLX weights and standalone ONNX files are not interchangeable.
enum SpeechModelFiles {
    static let required = ["voices.bin", "tokens.txt", "lexicon-us-en.txt", "lexicon-zh.txt"]
    static let optional = ["phone-zh.fst", "date-zh.fst", "number-zh.fst", "LICENSE"]
    static let styleBytes = 510 * 256 * 4

    static func inspect(_ directory: URL) throws -> (files: [String], speakers: Int, bytes: Int64) {
        let fm = FileManager.default
        let root = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard root.isDirectory == true, root.isSymbolicLink != true else {
            throw SpeechModelError.invalid("请选择解压后的 Kokoro 模型文件夹。")
        }
        let weights = ["model.int8.onnx", "model.onnx"].filter {
            fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        guard let weight = weights.first else {
            throw SpeechModelError.invalid("缺少 model.onnx 或 model.int8.onnx；仅支持 sherpa-onnx Kokoro 模型包。")
        }
        let names = [weight] + required + optional.filter {
            fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        var total: Int64 = 0
        var speakers = 0
        for name in names {
            let file = directory.appendingPathComponent(name)
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  let size = info.fileSize, size > 0, size <= 600 * 1_024 * 1_024 else {
                throw SpeechModelError.invalid("模型文件缺失、过大或不是普通文件：\(name)")
            }
            if name == "voices.bin" {
                guard size % styleBytes == 0, (1...256).contains(size / styleBytes) else {
                    throw SpeechModelError.invalid("voices.bin 不是支持的 Kokoro 音色表。")
                }
                speakers = size / styleBytes
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { handle.closeFile() }
            let prefix = String(decoding: try handle.read(upToCount: 256) ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !prefix.hasPrefix("<!doctype"), !prefix.hasPrefix("<html"),
                  !prefix.hasPrefix("version https://git-lfs") else {
                throw SpeechModelError.invalid("\(name) 是网页或 Git LFS 指针，请下载实际文件。")
            }
            total += Int64(size)
        }
        return (names, speakers, total)
    }

    static func chunks(_ text: String) -> [String] {
        var result: [String] = []
        var part = ""
        for character in text {
            part.append(character)
            if part.count >= 180 || "。！？.!?\n".contains(character) {
                if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(part) }
                part = ""
            }
        }
        if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(part) }
        return result
    }
}
