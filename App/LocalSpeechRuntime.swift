import Foundation
import SherpaOnnx
import os

final class SpeechCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

actor LocalSpeechRuntime {
    private var engine: SherpaOnnxOfflineTtsWrapper?

    func load(directory: URL) throws {
        guard os_proc_available_memory() > 0 else {
            throw SpeechModelError.invalid("当前没有可用的推理内存。")
        }
        let files = try SpeechModelFiles.inspect(directory).files
        let weight = files.first { $0.hasSuffix(".onnx") }!
        // Keep NSString owners alive until the C API finishes copying configuration paths.
        let paths: [NSString] = [
            directory.appendingPathComponent(weight).path,
            directory.appendingPathComponent("voices.bin").path,
            directory.appendingPathComponent("tokens.txt").path,
            ["lexicon-us-en.txt", "lexicon-zh.txt"].map { directory.appendingPathComponent($0).path }.joined(separator: ","),
            files.filter { $0.hasSuffix(".fst") }.map { directory.appendingPathComponent($0).path }.joined(separator: ",")
        ].map { $0 as NSString }
        var config = sherpaOnnxOfflineTtsConfig(model: sherpaOnnxOfflineTtsModelConfig(numThreads: 2))
        config.model.kokoro.model = paths[0].utf8String
        config.model.kokoro.voices = paths[1].utf8String
        config.model.kokoro.tokens = paths[2].utf8String
        config.model.kokoro.lexicon = paths[3].utf8String
        config.rule_fsts = paths[4].utf8String
        let candidate = withExtendedLifetime(paths) { SherpaOnnxOfflineTtsWrapper(config: &config) }
        guard candidate.tts != nil else {
            throw SpeechModelError.invalid("无法加载 Kokoro，请确认这是完整的 sherpa-onnx 模型包。")
        }
        engine = candidate
    }

    func generate(_ text: String, speaker: Int, speed: Float, cancellation: SpeechCancellation) throws -> (samples: [Float], rate: Double) {
        guard let engine else { throw SpeechModelError.invalid("语音模型尚未加载。") }
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard (0..<Int(engine.numSpeakers)).contains(speaker) else {
            throw SpeechModelError.invalid("音色编号超出当前模型范围，请重新选择。")
        }
        let arg = Unmanaged.passUnretained(cancellation).toOpaque()
        let audio = engine.generateWithCallbackWithArg(text: text, callback: { _, _, pointer in
            guard let pointer else { return 0 }
            return Unmanaged<SpeechCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled ? 0 : 1
        }, arg: arg, sid: speaker, speed: speed)
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard audio.n > 0, audio.sampleRate > 0 else {
            throw SpeechModelError.invalid("语音合成没有返回音频，请检查文本语言和模型文件。")
        }
        return (audio.samples, Double(audio.sampleRate))
    }

    func unload() { engine = nil }
}
