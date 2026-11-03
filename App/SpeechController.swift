import AVFoundation
import Observation
import Speech

@MainActor @Observable
final class SpeechController {
    private(set) var isRecording = false
    var errorMessage: String?

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?

    func speak(_ text: String, language: String, voiceIdentifier: String) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = (voiceIdentifier.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: voiceIdentifier))
            ?? AVSpeechSynthesisVoice(language: language)
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
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
            stopSpeaking()
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
