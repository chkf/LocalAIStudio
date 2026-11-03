import SwiftUI
import UIKit

struct GeneratePage: View {
    @Environment(ModelLibrary.self) private var library
    @Environment(ChatSession.self) private var chat
    @Environment(ImageGenerationSession.self) private var generator
    @AppStorage("imageModelID") private var selectedID = ""
    @State private var prompt = ""
    @State private var negativePrompt = ""
    @State private var size = 512
    @State private var steps = 0
    @State private var loraID = ""
    @State private var loraWeight = 0.8
    let openModels: () -> Void

    private var supported: [LocalModel] {
        library.models.filter { $0.supportsImageGeneration }
    }

    private var selectedModel: LocalModel? {
        supported.first { $0.id.uuidString == selectedID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if supported.isEmpty {
                        ContentUnavailableView {
                            Label("添加生图 Checkpoint", systemImage: "photo.badge.plus")
                        } description: {
                            Text("导入支持的 Checkpoint，或在模型详情中转换 Safetensors。")
                        } actions: {
                            Button("管理模型", action: openModels)
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Picker("Checkpoint", selection: $selectedID) {
                            ForEach(supported) { model in
                                Text(model.name).tag(model.id.uuidString)
                            }
                        }
                        .accessibilityIdentifier("imageModelPicker")
                        Picker("LoRA", selection: $loraID) {
                            Text("不使用").tag("")
                            ForEach(library.models.filter { $0.format == .drawThingsBundle && $0.kind == .lora &&
                                (selectedModel?.architecture == nil || $0.architecture == selectedModel?.architecture) }) { adapter in
                                Text(adapter.name).tag(adapter.id.uuidString)
                            }
                        }
                        .accessibilityIdentifier("imageLoRAPicker")
                        if !loraID.isEmpty {
                            HStack {
                                Text("LoRA 强度")
                                Slider(value: $loraWeight, in: -1...2, step: 0.05)
                                Text(loraWeight.formatted(.number.precision(.fractionLength(2))))
                            }
                        }
                        TextField("描述你想生成的画面", text: $prompt, axis: .vertical)
                            .lineLimit(3...6)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("imagePrompt")
                        TextField("负面提示词（可选）", text: $negativePrompt, axis: .vertical)
                            .lineLimit(1...3)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Picker("尺寸", selection: $size) {
                                Text("512").tag(512)
                                Text("768").tag(768)
                            }
                            Picker("步数", selection: $steps) {
                                Text("模型默认").tag(0)
                                ForEach([4, 8, 16, 24, 32, 50], id: \.self) { n in
                                    Text("\(n)").tag(n)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        Button {
                            if generator.isGenerating {
                                generator.cancel()
                            } else if let selectedModel {
                                Task {
                                    guard !library.isProcessing else { return }
                                    await chat.unload()
                                    guard !library.isProcessing else { return }
                                    do {
                                        let url = try library.fileURL(for: selectedModel)
                                        let adapter = library.models.first { $0.id.uuidString == loraID }
                                        let selectedLoRA = try adapter.map { (model: $0, url: try library.fileURL(for: $0), weight: loraWeight) }
                                        await generator.generate(model: selectedModel, sourceURL: url,
                                                                 prompt: prompt, negativePrompt: negativePrompt,
                                                                 size: size, steps: steps, lora: selectedLoRA)
                                    } catch { generator.errorMessage = error.localizedDescription }
                                }
                            }
                        } label: {
                            Label(generator.isGenerating ? "取消生成" : "生成",
                                  systemImage: generator.isGenerating ? "stop.fill" : "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(library.isProcessing || (!generator.isGenerating && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .accessibilityIdentifier("generateImage")
                        if generator.isGenerating {
                            ProgressView(generator.status)
                        } else if !generator.status.isEmpty {
                            Text(generator.status).foregroundStyle(.secondary)
                        }
                        if let url = generator.resultURL, let picture = UIImage(contentsOfFile: url.path) {
                            Image(uiImage: picture)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                            ShareLink("分享或保存图片", item: url)
                                .buttonStyle(.bordered)
                        }
                        Text("需要兼容的 Draw Things Checkpoint 和配套资源。大模型可能触发 iOS 内存限制。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("生图")
            .onAppear { if selectedModel == nil { selectedID = supported.first?.id.uuidString ?? "" } }
            .onChange(of: selectedID) { _, _ in loraID = "" }
            .onChange(of: supported.count) { _, _ in
                if selectedModel == nil { selectedID = supported.first?.id.uuidString ?? "" }
            }
            .alert("生图失败", isPresented: Binding(
                get: { generator.errorMessage != nil },
                set: { if !$0 { generator.errorMessage = nil } }
            )) {
                Button("好") { generator.errorMessage = nil }
            } message: {
                Text(generator.errorMessage ?? "")
            }
        }
    }
}
