import AVFoundation
import SwiftUI

struct ChatSettingsPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatSession.self) private var chat
    @State private var options = ChatPreferences()

    var body: some View {
        NavigationStack {
            Form {
                Section("模型配置") {
                    Picker("最大输出 Token", selection: $options.maxOutputTokens) {
                        ForEach([128, 256, 512, 1024, 2048, 4096], id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    }
                    Stepper("Top-K · \(options.topK)", value: $options.topK, in: 1...128)
                    LabeledContent("Top-P", value: options.topP.formatted(.number.precision(.fractionLength(2))))
                    Slider(value: $options.topP, in: 0.05...1, step: 0.05)
                    LabeledContent("Temperature", value: options.temperature.formatted(.number.precision(.fractionLength(2))))
                    Slider(value: $options.temperature, in: 0...2, step: 0.05)
                    Picker("加速器", selection: $options.backend) {
                        Text("自动").tag("auto")
                        Text("CPU").tag("cpu")
                        Text("GPU").tag("gpu")
                    }
                    Toggle("启用思考", isOn: $options.enableThinking)
                    Toggle("推测解码", isOn: $options.enableSpeculativeDecoding)
                    Text("特殊模式需要模型支持。最大输出量受上下文窗口限制。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("系统提示词") {
                    TextEditor(text: $options.systemPrompt)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("systemPromptEditor")
                }
                Section("Audio") {
                    Toggle("自动朗读回复", isOn: $options.autoSpeak)
                    Picker("语音语言", selection: $options.speechLanguage) {
                        Text("中文").tag("zh-CN")
                        Text("English").tag("en-US")
                        Text("日本語").tag("ja-JP")
                    }
                    Picker("朗读声音", selection: $options.voiceIdentifier) {
                        Text("系统默认").tag("")
                        ForEach(AVSpeechSynthesisVoice.speechVoices().filter { $0.language == options.speechLanguage }, id: \.identifier) { voice in
                            Text(voice.name).tag(voice.identifier)
                        }
                    }
                    Text("使用 iOS 原生语音合成与设备端识别，不包含 Kokoro 或 Parakeet 权重。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("图像输入尚未接入，因此暂不提供无效的视觉 Token 预算开关。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("对话设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        Task { await chat.applyPreferences(options); dismiss() }
                    }
                    .disabled(chat.isBusy)
                    .accessibilityIdentifier("applyChatSettings")
                }
            }
            .onAppear { options = chat.preferences }
            .onChange(of: options.speechLanguage) { _, _ in options.voiceIdentifier = "" }
        }
    }
}
