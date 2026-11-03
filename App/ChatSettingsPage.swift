import AVFoundation
import SwiftUI

struct ChatSettingsPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatSession.self) private var chat
    @State private var options = ChatPreferences()
    @State private var tokenLimit = ""
    @State private var topK = ""
    @State private var topP = ""
    @State private var temperature = ""
    @State private var searchKey = ""
    @State private var originalSearchKey = ""
    @State private var settingsError: String?
    @State private var hasLoaded = false

    private var editedOptions: ChatPreferences? {
        guard let tokens = Int(tokenLimit), (128...4096).contains(tokens),
              let k = Int(topK), (1...128).contains(k),
              let p = try? Double(topP, format: .number), (0.05...1).contains(p),
              let t = try? Double(temperature, format: .number), (0...2).contains(t)
        else { return nil }
        var result = options
        result.maxOutputTokens = tokens
        result.topK = k
        result.topP = p
        result.temperature = t
        return result
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("模型配置") {
                    numericRow("最大输出 Token", text: $tokenLimit, range: "128–4096")
                    numericRow("Top-K", text: $topK, range: "1–128")
                    numericRow("Top-P", text: $topP, range: "0.05–1", decimal: true)
                    numericRow("Temperature", text: $temperature, range: "0–2", decimal: true)
                    if editedOptions == nil {
                        Text("请输入标注范围内的数值，Token 和 Top-K 需为整数。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
                Section("联网工具") {
                    Toggle("允许联网", isOn: Binding(
                        get: { options.webEnabled == true }, set: { options.webEnabled = $0 }
                    ))
                    .accessibilityIdentifier("webAccessToggle")
                    SecureField("Brave Search API Key", text: $searchKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("webSearchKey")
                    Link("获取搜索 API Key", destination: URL(string: "https://api-dashboard.search.brave.com/")!)
                    Text("联网默认关闭。开启后，模型可搜索和读取公开网页；搜索词和链接会发给对应服务。搜索需要自己的 Brave Key，网页读取无需 Key；Key 只保存在本机钥匙串。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("联网调用会增加等待时间和上下文占用；需要模型正确输出工具请求，部分模型可能不兼容。搜索服务按你的账户额度计费。")
                        .font(.caption).foregroundStyle(.secondary)
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
                    NavigationLink("语音模型与朗读") { SpeechModelsPage() }
                    Text("语音输入使用设备端识别；朗读可选择系统声音或导入的 Kokoro 模型。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("图像输入尚未接入，因此暂不提供无效的视觉 Token 预算开关。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("对话设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        guard let updated = editedOptions else { return }
                        do {
                            if searchKey != originalSearchKey { try WebSearchKey.save(searchKey) }
                            Task { await chat.applyPreferences(updated); dismiss() }
                        } catch { settingsError = error.localizedDescription }
                    }
                    .disabled(chat.isBusy || editedOptions == nil)
                    .accessibilityIdentifier("applyChatSettings")
                }
            }
            .onAppear {
                guard !hasLoaded else { return }
                hasLoaded = true
                do { searchKey = try WebSearchKey.read(); originalSearchKey = searchKey }
                catch { settingsError = error.localizedDescription }
                options = chat.preferences
                tokenLimit = String(options.maxOutputTokens)
                topK = String(options.topK)
                topP = options.topP.formatted(.number.grouping(.never))
                temperature = options.temperature.formatted(.number.grouping(.never))
            }
            .alert("联网设置", isPresented: Binding(
                get: { settingsError != nil }, set: { if !$0 { settingsError = nil } }
            )) {
                Button("好") { settingsError = nil }
            } message: { Text(settingsError ?? "") }
            .onChange(of: options.speechLanguage) { _, _ in options.voiceIdentifier = "" }
        }
    }

    private func numericRow(_ title: String, text: Binding<String>, range: String, decimal: Bool = false) -> some View {
        LabeledContent {
            TextField(range, text: text)
                .keyboardType(decimal ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .foregroundStyle(.tint)
                .frame(minWidth: 72, maxWidth: 110)
                .accessibilityLabel(title)
                .accessibilityHint("范围：\(range)")
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(range).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

}
