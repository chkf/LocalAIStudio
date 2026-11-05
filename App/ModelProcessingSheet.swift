import SwiftUI

struct ModelProcessingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ModelLibrary.self) private var library
    @Environment(SpeechController.self) private var speech
    @Environment(ChatSession.self) private var chat
    @Environment(ImageGenerationSession.self) private var images
    let model: LocalModel
    @State private var isLoRA = false
    @State private var template = ""
    @State private var version = ""
    @State private var vaeID = ""
    @State private var textEncoderID = ""
    @State private var textEncoder2ID = ""

    private var supportsRawComponents: Bool {
        ["v1", "v2", "sdxl_base_v0.9", "sdxl_refiner_v0.9"].contains(
            ImageModelTools.profiles.first { $0.file == template }?.version.rawValue ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.title)
                    LabeledContent("已识别架构", value: model.architecture ?? "尚未确认")
                    Picker("转换类型", selection: $isLoRA) {
                        Text("生图主模型").tag(false)
                        Text("LoRA").tag(true)
                    }
                    if isLoRA {
                        Picker("底模架构", selection: $version) {
                            Text("自动识别").tag("")
                            ForEach(Array(Set(ImageModelTools.profiles.map { $0.version.rawValue })).sorted(), id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                    } else {
                        Picker("基础配置", selection: $template) {
                            Text("请选择").tag("")
                            ForEach(ImageModelTools.profiles, id: \.file) { profile in
                                Text(profile.name).tag(profile.file)
                            }
                        }
                        if supportsRawComponents {
                            Picker("独立 VAE", selection: $vaeID) {
                                Text("使用模型内置或标准 VAE").tag("")
                                ForEach(library.models.filter { $0.kind == .vae && $0.format == .safetensors }) {
                                    Text($0.title).tag($0.id.uuidString)
                                }
                            }
                            Picker("文本编码器", selection: $textEncoderID) {
                                Text("使用内置或标准组件").tag("")
                                ForEach(library.models.filter { $0.kind == .textEncoder && $0.format == .safetensors }) {
                                    Text($0.title).tag($0.id.uuidString)
                                }
                            }
                            if ImageModelTools.profiles.first(where: { $0.file == template })?.version.rawValue == "sdxl_base_v0.9" {
                                Picker("第二文本编码器（bigG）", selection: $textEncoder2ID) {
                                    Text("使用内置或标准组件").tag("")
                                    ForEach(library.models.filter { $0.kind == .textEncoder && $0.format == .safetensors }) {
                                        Text($0.title).tag($0.id.uuidString)
                                    }
                                }
                            }
                        } else if !template.isEmpty {
                            Text("此架构使用标准配套组件；转换后可在生图页指定兼容的 Draw Things VAE／文本编码器。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("基础配置决定配套组件和采样方式，请选择与下载模型一致的版本。转换器会再次核对架构。缺少的标准配套资源会在生成时下载。")
                }
                Section {
                    Text("转换结果另存为新模型，原文件保留。转换时会停止聊天和生图；部分上游转换步骤无法立即中断，取消后会等待并清理产物。")
                }
            }
            .navigationTitle("转换模型")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                isLoRA = model.kind == .lora || model.adapter?.hasPrefix("LoRA") == true
                if let architecture = model.architecture {
                    let matches = ImageModelTools.profiles.filter { $0.version.rawValue == architecture }
                    if matches.count == 1 { template = matches[0].file }
                }
            }
            .onChange(of: template) { _, _ in
                vaeID = ""; textEncoderID = ""; textEncoder2ID = ""
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("转换") {
                        do {
                            let vae = try library.models.first { $0.id.uuidString == vaeID }.map { try library.fileURL(for: $0) }
                            let encoder = try library.models.first { $0.id.uuidString == textEncoderID }.map { try library.fileURL(for: $0) }
                            let encoder2 = try library.models.first { $0.id.uuidString == textEncoder2ID }.map { try library.fileURL(for: $0) }
                            let operation: ImageModelOperation = isLoRA ? .lora(version: version.isEmpty ? nil : version) : .convert(template: template, vae: vae, textEncoder: encoder, textEncoder2: encoder2)
                            Task {
                                await library.process(model, operation: operation) {
                                    await speech.stopAndWait()
                                    await images.stop()
                                    await chat.unload()
                                }
                            }
                            dismiss()
                        } catch { library.errorMessage = error.localizedDescription }
                    }
                    .disabled(library.isWriting || (!isLoRA && template.isEmpty))
                    .accessibilityIdentifier("convertModel")
                }
            }
        }
    }
}
