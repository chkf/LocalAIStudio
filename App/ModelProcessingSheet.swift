import SwiftUI

struct ModelProcessingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ModelLibrary.self) private var library
    @Environment(ChatSession.self) private var chat
    @Environment(ImageGenerationSession.self) private var images
    let model: LocalModel
    @State private var isLoRA = false
    @State private var template = ""
    @State private var version = ""
    @State private var vaeID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.name)
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
                        Picker("独立 VAE", selection: $vaeID) {
                            Text("使用模型内置或标准 VAE").tag("")
                            ForEach(library.models.filter { $0.kind == .vae && $0.format == .safetensors }) {
                                Text($0.name).tag($0.id.uuidString)
                            }
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
                if let architecture = model.architecture,
                   let profile = ImageModelTools.profiles.first(where: { $0.version.rawValue == architecture }) {
                    template = profile.file
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("转换") {
                        do {
                            let vae = try library.models.first { $0.id.uuidString == vaeID }.map { try library.fileURL(for: $0) }
                            let operation: ImageModelOperation = isLoRA ? .lora(version: version.isEmpty ? nil : version) : .convert(template: template, vae: vae)
                            Task {
                                await library.process(model, operation: operation) {
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
