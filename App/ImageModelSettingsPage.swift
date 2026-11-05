import SwiftUI
import ModelZoo

struct ImageModelSettingsPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ModelLibrary.self) private var library
    @Environment(ImageGenerationSession.self) private var generator
    let model: LocalModel
    @State private var configuration = ImageModelConfiguration()
    @State private var specification: ModelZoo.Specification?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Text(model.title)
                if model.format == .checkpoint {
                    Picker("基础配置", selection: Binding(
                        get: { configuration.template ?? "" },
                        set: { configuration.template = $0.isEmpty ? nil : $0; configuration.components = [:]; refresh() }
                    )) {
                        Text("按原文件名匹配目录").tag("")
                        ForEach(ImageModelTools.profiles, id: \.file) { Text($0.name).tag($0.file) }
                    }
                    Text("基础配置必须与权重一致。原始 PyTorch Checkpoint 不能直接运行；这里只接受 Draw Things 格式。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            if let specification {
                Section {
                    ForEach(ImageModelResources.components(for: specification), id: \.file) { component in
                        VStack(alignment: .leading, spacing: 6) {
                            Picker(component.role, selection: Binding(
                                get: { configuration.components[component.file]?.uuidString ?? "" },
                                set: { configuration.components[component.file] = UUID(uuidString: $0) }
                            )) {
                                Text("使用配套资源").tag("")
                                ForEach(library.models.filter { $0.format == .checkpoint && $0.id != model.id }) {
                                    Text($0.title).tag($0.id.uuidString)
                                }
                            }
                            Text(component.file).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(componentStatus(component.file)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("配套组件") } footer: {
                    Text("可选择已导入且架构匹配的 Draw Things .ckpt 组件。原始 Safetensors VAE／文本编码器需在主模型转换时选择。缺少的标准组件可在生图页下载。")
                }
            }
        }
        .navigationTitle("模型与配套组件")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { configuration = model.imageConfiguration ?? ImageModelConfiguration(); refresh() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    Task { if await library.configureImage(model, configuration: configuration) { dismiss() } }
                }
                .disabled(specification == nil || library.isWriting || generator.isGenerating)
            }
        }
    }

    private func refresh() {
        do {
            specification = try ImageModelResources.specification(for: model, url: library.fileURL(for: model), configuration: configuration)
            errorMessage = nil
        } catch { specification = nil; errorMessage = error.localizedDescription }
    }

    private func componentStatus(_ filename: String) -> String {
        if let id = configuration.components[filename] {
            return library.models.contains { $0.id == id } ? "已指定本机组件" : "指定的组件已被删除，请重新选择"
        }
        if model.format == .drawThingsBundle, let url = try? library.fileURL(for: model),
           FileManager.default.fileExists(atPath: url.appendingPathComponent(filename).path) { return "已随模型保存" }
        let cache = URL.applicationSupportDirectory.appendingPathComponent("ImageRuntime").appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: cache.path) ? "已缓存" : "尚未下载"
    }
}
