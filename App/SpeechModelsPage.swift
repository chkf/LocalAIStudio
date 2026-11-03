import SwiftUI
import UniformTypeIdentifiers

struct SpeechModelsPage: View {
    @Environment(SpeechController.self) private var speech
    @Environment(ChatSession.self) private var chat
    @Environment(ImageGenerationSession.self) private var images
    @Environment(ModelLibrary.self) private var library
    @State private var importing = false
    @State private var pendingDelete: SpeechModel?
    @State private var sample = "你好，这是本地语音朗读。Hello from AI Studio."

    var body: some View {
        @Bindable var models = speech.models
        Form {
            Section("朗读方式") {
                Picker("语音模型", selection: $models.selectedID) {
                    Text("iOS 系统语音").tag("")
                    ForEach(models.models) { model in
                        Text(model.name).tag(model.id.uuidString)
                    }
                }
                .disabled(speech.isSynthesizing)
                if let selected = models.selected {
                    Picker("音色", selection: $models.speaker) {
                        ForEach(0..<selected.speakers, id: \.self) { index in
                            Text("音色 \(index)").tag(index)
                        }
                    }
                    VStack {
                        LabeledContent("语速", value: models.speed.formatted(.number.precision(.fractionLength(1))) + "×")
                        Slider(value: $models.speed, in: 0.5...2, step: 0.1)
                    }
                    Text("音色编号沿用模型音色表；官方多语言包的中文音色从 45 开始。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("试听文本", text: $sample, axis: .vertical).lineLimit(2...4)
                Button(speech.isSynthesizing ? "停止朗读" : "试听") {
                    if speech.isSynthesizing { speech.stopSpeaking() }
                    else {
                        speech.speak(sample, language: chat.preferences.speechLanguage,
                                     voiceIdentifier: chat.preferences.voiceIdentifier) {
                            guard !chat.isBusy, !images.isGenerating, !library.isProcessing else { return false }
                            await chat.unload()
                            return !images.isGenerating && !library.isProcessing
                        }
                    }
                }
                .disabled(chat.isBusy || images.isGenerating || library.isProcessing || sample.isEmpty)
            }
            Section("添加语音模型") {
                Button("下载 Kokoro 中英文模型（约 151 MB）") { models.install() }
                    .disabled(models.isInstalling)
                Button("导入 Kokoro 模型文件夹") { importing = true }
                    .disabled(models.isInstalling)
                if models.isInstalling {
                    ProgressView(models.status)
                    Button("取消下载或导入", role: .cancel) { models.cancelInstall() }
                } else if !models.status.isEmpty {
                    Text(models.status).font(.caption).foregroundStyle(.secondary)
                }
                Text("下载后可离线使用。支持 sherpa-onnx 格式的 Kokoro v1.0 模型包，需包含 ONNX 权重、voices.bin、tokens.txt 和中英文词典；不支持直接导入任意 TTS 权重。")
                    .font(.caption).foregroundStyle(.secondary)
                Link("模型来源与许可", destination: URL(string: "https://huggingface.co/csukuangfj/kokoro-int8-multi-lang-v1_0")!)
            }
            if !models.models.isEmpty {
                Section("已下载与导入") {
                    ForEach(models.models) { model in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(model.name)
                                Text(ByteCountFormatter.string(fromByteCount: model.byteCount, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("删除", role: .destructive) { pendingDelete = model }
                                .disabled(speech.isSynthesizing)
                        }
                    }
                }
            }
        }
        .navigationTitle("语音模型")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: models.selectedID) { _, _ in models.speaker = 0 }
        .sheet(isPresented: $importing) {
            ModelDocumentPicker(contentTypes: [.folder], asCopy: false, allowsMultipleSelection: false) { urls in
                importing = false
                if let first = urls.first { models.install(from: first) }
            }
        }
        .confirmationDialog("删除语音模型？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let model = pendingDelete { models.delete(model) }
                pendingDelete = nil
            }
        }
        .alert("语音", isPresented: Binding(
            get: { models.errorMessage != nil || speech.errorMessage != nil },
            set: { if !$0 { models.errorMessage = nil; speech.errorMessage = nil } }
        )) {
            Button("好") { models.errorMessage = nil; speech.errorMessage = nil }
        } message: { Text(models.errorMessage ?? speech.errorMessage ?? "") }
        .onDisappear { speech.stopSpeaking() }
    }
}
