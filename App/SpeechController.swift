import AVFoundation
import Observation
import Speech

@MainActor @Observable
final class SpeechController {
    private(set) var isRecording = false
    var errorMessage: String?
    let models = SpeechModels()
    private(set) var isSynthesizing = false
    @ObservationIgnored private let localRuntime = LocalSpeechRuntime()
    @ObservationIgnored private var speechTask: Task<Void, Never>?
    @ObservationIgnored private var speechCancellation: SpeechCancellation?
    @ObservationIgnored private var playbackEngine: AVAudioEngine?
    @ObservationIgnored private var playerNode: AVAudioPlayerNode?

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?

    func speak(_ text: String, language: String, voiceIdentifier: String,
               prepare: @escaping @MainActor () async -> Bool) {
        guard !text.isEmpty else { return }
        // The active task retains its model until cancellation has finished.
        guard speechTask == nil else { stopSpeaking(); return }
        stopTranscription()
        synthesizer.stopSpeaking(at: .immediate)
        if models.selectedID.isEmpty {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = (voiceIdentifier.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: voiceIdentifier))
                ?? AVSpeechSynthesisVoice(language: language)
            synthesizer.speak(utterance)
            return
        }
        guard let model = models.selected else {
            errorMessage = "所选语音模型已不可用，请重新选择或切回系统语音。"
            return
        }
        let cancellation = SpeechCancellation()
        speechCancellation = cancellation
        isSynthesizing = true
        let speaker = models.speaker
        let speed = Float(models.speed)
        speechTask = Task {
            do {
                guard await prepare(), !cancellation.isCancelled else { throw CancellationError() }
                try await localRuntime.load(directory: models.directory(for: model))
                try Task.checkCancellation()
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                let engine = AVAudioEngine()
                let node = AVAudioPlayerNode()
                engine.attach(node)
                playbackEngine = engine
                playerNode = node
                var started = false
                for part in SpeechModelFiles.chunks(text) {
                    try Task.checkCancellation()
                    let audio = try await localRuntime.generate(part, speaker: speaker, speed: speed, cancellation: cancellation)
                    try Task.checkCancellation()
                    guard let format = AVAudioFormat(standardFormatWithSampleRate: audio.rate, channels: 1),
                          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count)),
                          let channel = buffer.floatChannelData?[0] else {
                        throw SpeechModelError.invalid("无法创建朗读音频缓冲区。")
                    }
                    buffer.frameLength = buffer.frameCapacity
                    audio.samples.withUnsafeBufferPointer { samples in
                        channel.update(from: samples.baseAddress!, count: samples.count)
                    }
                    if !started {
                        engine.connect(node, to: engine.mainMixerNode, format: format)
                        try engine.start()
                        node.play()
                        started = true
                    }
                    // One bounded sentence at a time; cancellation must also unblock playback.
                    let finished = SpeechCancellation()
                    node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in finished.cancel() }
                    while !finished.isCancelled {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
            } catch is CancellationError { }
            catch { if !cancellation.isCancelled { errorMessage = error.localizedDescription } }
            playerNode?.stop()
            playbackEngine?.stop()
            playerNode = nil
            playbackEngine = nil
            await localRuntime.unload()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            isSynthesizing = false
            speechCancellation = nil
            speechTask = nil
        }
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        speechCancellation?.cancel()
        speechTask?.cancel()
        playerNode?.stop()
    }

    func stopAndWait() async {
        stopSpeaking()
        await speechTask?.value
    }

    func startTranscription(language: String, onText: @escaping @MainActor (String) -> Void) async {
        guard !isRecording else { return }
        let authorized = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard authorized else {
            errorMessage = "请在系统设置中允许语音识别权限。"
            return
        }
        let microphoneAllowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard microphoneAllowed else {
            errorMessage = "请在系统设置中允许麦克风权限。"
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            errorMessage = "当前语言不支持设备端语音识别。"
            return
        }

        do {
            await stopAndWait()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let audioRequest = SFSpeechAudioBufferRecognitionRequest()
            audioRequest.shouldReportPartialResults = true
            audioRequest.requiresOnDeviceRecognition = true
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                audioRequest.append(buffer)
            }
            request = audioRequest
            audioEngine = engine
            recognitionTask = recognizer.recognitionTask(with: audioRequest) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    if let result { onText(result.bestTranscription.formattedString) }
                    if let error { self.errorMessage = error.localizedDescription }
                    if error != nil || result?.isFinal == true { self.stopTranscription() }
                }
            }
            try engine.start()
            isRecording = true
        } catch {
            stopTranscription()
            errorMessage = "无法开始录音：\(error.localizedDescription)"
        }
    }

    func stopTranscription() {
        isRecording = false
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        recognitionTask?.cancel()
        audioEngine = nil
        request = nil
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
