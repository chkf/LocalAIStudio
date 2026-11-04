import Foundation

/// Reads only ONNX ModelProto metadata_props (field 14). The graph and its large
/// tensors are seeked over; malformed metadata must never reach sherpa's _Exit.
/// This is a preflight for the supported Kokoro 510 × 1 × 256 voice format,
/// not an ONNX graph/operator validator.
private struct KokoroMetadataReader {
    let handle: FileHandle
    var offset: UInt64 = 0
    var fields = 0

    mutating func tag(until end: UInt64) throws -> (number: UInt64, wire: UInt64) {
        fields += 1
        guard fields <= 16_384 else { throw malformed() }
        let value = try varint(until: end)
        guard value >> 3 > 0, value >> 3 <= 0x1fff_ffff else { throw malformed() }
        return (value >> 3, value & 7)
    }

    mutating func varint(until end: UInt64) throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < end, let byte = try handle.read(upToCount: 1)?.first,
                  shift != 63 || byte <= 1 else { throw malformed() }
            offset += 1
            result |= UInt64(byte & 127) << shift
            if byte & 128 == 0 { return result }
        }
        throw malformed()
    }

    mutating func messageEnd(until end: UInt64) throws -> UInt64 {
        let length = try varint(until: end)
        guard length <= end - offset else { throw malformed() }
        return offset + length
    }

    mutating func skip(wire: UInt64, until end: UInt64) throws {
        let next: UInt64
        switch wire {
        case 0: _ = try varint(until: end); return
        case 1: guard end - offset >= 8 else { throw malformed() }; next = offset + 8
        case 2: next = try messageEnd(until: end)
        case 5: guard end - offset >= 4 else { throw malformed() }; next = offset + 4
        default: throw malformed()
        }
        try seek(to: next)
    }

    mutating func seek(to next: UInt64) throws {
        try handle.seek(toOffset: next)
        offset = next
    }

    mutating func string(until end: UInt64) throws -> String {
        let next = try messageEnd(until: end)
        let size = next - offset
        guard size <= 65_536, let data = try handle.read(upToCount: Int(size)),
              data.count == Int(size), let value = String(data: data, encoding: .utf8),
              !value.contains("\0") else { throw malformed() }
        offset = next
        return value
    }

    func malformed() -> SpeechModelError {
        .invalid("ONNX 文件或 Kokoro 元数据损坏、截断或超出支持范围。")
    }
}

enum KokoroMetadata {
    static func validate(_ file: URL, speakers: Int) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { handle.closeFile() }
        let end = try handle.seekToEnd()
        var reader = KokoroMetadataReader(handle: handle)
        try reader.seek(to: 0)
        var metadata: [String: String] = [:]
        var metadataBytes: UInt64 = 0
        var hasGraph = false
        while reader.offset < end {
            let tag = try reader.tag(until: end)
            if tag.number == 14 {
                guard tag.wire == 2 else { throw reader.malformed() }
                let entryEnd = try reader.messageEnd(until: end)
                metadataBytes += entryEnd - reader.offset
                guard metadataBytes <= 1_024 * 1_024, metadata.count < 256 else { throw reader.malformed() }
                var key: String?
                var value: String?
                while reader.offset < entryEnd {
                    let field = try reader.tag(until: entryEnd)
                    switch field.number {
                    case 1:
                        guard field.wire == 2, key == nil else { throw reader.malformed() }
                        key = try reader.string(until: entryEnd)
                    case 2:
                        guard field.wire == 2, value == nil else { throw reader.malformed() }
                        value = try reader.string(until: entryEnd)
                    default: try reader.skip(wire: field.wire, until: entryEnd)
                    }
                }
                guard let key, !key.isEmpty, let value, metadata[key] == nil else { throw reader.malformed() }
                metadata[key] = value
            } else if tag.number == 7 {
                guard tag.wire == 2, !hasGraph else { throw reader.malformed() }
                let graphEnd = try reader.messageEnd(until: end)
                guard graphEnd > reader.offset else { throw reader.malformed() }
                hasGraph = true
                try reader.seek(to: graphEnd)
            } else {
                try reader.skip(wire: tag.wire, until: end)
            }
        }
        guard hasGraph else { throw reader.malformed() }
        if let type = metadata["model_type"], type != "kokoro" {
            throw SpeechModelError.invalid("该 ONNX 不是 sherpa-onnx Kokoro 模型。")
        }
        guard let rate = integer(metadata["sample_rate"]), (8_000...192_000).contains(rate),
              let count = integer(metadata["n_speakers"]), count == speakers else {
            throw SpeechModelError.invalid("Kokoro 采样率无效，或模型的 n_speakers 与 voices.bin 音色数量不匹配。")
        }
        let shape = metadata["style_dim"]?.split(separator: ",", omittingEmptySubsequences: false)
            .map { integer(String($0)) }
        guard shape == [510, 1, 256] else {
            throw SpeechModelError.invalid("仅支持 style_dim 为 510,1,256 的 sherpa-onnx Kokoro 音色表。")
        }
        // has_espeak is unused legacy metadata in the pinned engine, but its
        // integer-reading macro still terminates on negative values.
        for key in ["version", "has_espeak"] {
            if let value = metadata[key], !value.isEmpty, integer(value) == nil {
                throw SpeechModelError.invalid("Kokoro 元数据 \(key) 无效。")
            }
        }
    }

    private static func integer(_ value: String?) -> Int32? {
        guard let value else { return nil }
        // Match C atoi's whitespace, not Unicode whitespace: accepting e.g.
        // NBSP before n_speakers would make native code read 0 and terminate.
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\u{000B}\u{000C}"))
        guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (48...57).contains($0) }),
              let result = Int32(trimmed) else { return nil }
        return result
    }
}
