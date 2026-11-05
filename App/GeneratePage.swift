import SwiftUI
import UIKit

struct GeneratePage: View {
    @Environment(ModelLibrary.self) private var library
    @Environment(SpeechController.self) private var speech
    @Environment(ChatSession.self) private var chat
    @Environment(ImageGenerationSession.self) private var generator
    @Environment(TaskPreparation.self) private var preparation
    @Environment(\.scenePhase) private var scenePhase
    @State private var generationTask: Task<Void, Never>?
    @State private var preparationID: UUID?
    @AppStorage("imageModelID") private var selectedID = ""
    private enum Field: Hashable { case prompt, negativePrompt }
    @FocusState private var focusedField: Field?
    @State private var prompt = ""
    @State private var negativePrompt = ""
    @State private var size = 512
    @State private var steps = 0
    @State private var loraID = ""
    @State private var loraWeight = 0.8
    let openModels: () -> Void

    private let stepOptions: [Int] = [4, 8, 16, 24, 32, 50]

    private var supported: [LocalModel] {
        library.models.filter { $0.supportsImageGeneration }
    }

    private var selectedModel: LocalModel? {
        supported.first { $0.id.uuidString == selectedID }
    }

    private var compatibleLoRAs: [LocalModel] {
        let architecture = selectedModel?.architecture
        return library.models.filter { model in
            guard model.format == .drawThingsBundle, model.kind == .lora else { return false }
            return architecture == nil || model.architecture == architecture
        }
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
                        modelControls
                        loraControls
                        promptFields
                        generationOptions
                        generateButton
                        generationResult
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("生图")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink("生成历史", systemImage: "clock.arrow.circlepath") { ImageHistoryPage() }
                        .accessibilityIdentifier("imageHistory")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘", systemImage: "keyboard.chevron.compact.down") { focusedField = nil }
                        .accessibilityIdentifier("dismissImageKeyboard")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if focusedField != nil {
                        Button("完成") { focusedField = nil }
                            .accessibilityIdentifier("finishImageEditing")
                    }
                }
            }
            .onDisappear { focusedField = nil }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { stop() }
            }
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
    @ViewBuilder
    private var modelControls: some View {
        Picker("Checkpoint", selection: $selectedID) {
            ForEach(supported) { model in
                Text(model.title).tag(model.id.uuidString)
            }
        }
        .accessibilityIdentifier("imageModelPicker")
        if let selectedModel {
            NavigationLink("模型与配套组件") { ImageModelSettingsPage(model: selectedModel) }
                .disabled(generator.isGenerating || library.isProcessing)
            Button("检查并下载配套资源") { start(selectedModel, prepareOnly: true) }
                .disabled(busy || preparation.isPreparing || library.isProcessing)
        }
    }

    @ViewBuilder
    private var loraControls: some View {
        Picker("LoRA", selection: $loraID) {
            Text("不使用").tag("")
            ForEach(compatibleLoRAs) { adapter in
                Text(adapter.title).tag(adapter.id.uuidString)
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
    }

    @ViewBuilder
    private var promptFields: some View {
        TextField("描述你想生成的画面", text: $prompt, axis: .vertical)
            .lineLimit(3...6)
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .prompt)
            .accessibilityIdentifier("imagePrompt")
        TextField("负面提示词（可选）", text: $negativePrompt, axis: .vertical)
            .focused($focusedField, equals: .negativePrompt)
            .lineLimit(1...3)
            .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private var generationOptions: some View {
        HStack {
            Picker("尺寸", selection: $size) {
                Text("512").tag(512)
                Text("768").tag(768)
            }
            Picker("步数", selection: $steps) {
                Text("模型默认").tag(0)
                ForEach(stepOptions, id: \.self) { n in
                    Text("\(n)").tag(n)
                }
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var generateButton: some View {
        Button {
            if busy { stop() }
            else if let selectedModel { start(selectedModel, prepareOnly: false) }
        } label: {
            Label(busy ? "取消生成" : "生成",
                  systemImage: busy ? "stop.fill" : "sparkles")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!busy && (library.isProcessing || preparation.isPreparing || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        .accessibilityIdentifier("generateImage")
    }

    @ViewBuilder
    private var generationResult: some View {
        if busy {
            ProgressView(LocalizedStringKey(generator.isGenerating ? generator.status : "准备生图…"))
        } else if !generator.status.isEmpty {
            Text(generator.status).foregroundStyle(.secondary)
        }
        if let url = generator.resultURL {
            GeneratedImagePreview(url: url)
            ShareLink("分享或保存图片", item: url)
                .buttonStyle(.bordered)
        }
        Text("需要兼容的 Draw Things Checkpoint 和配套资源。大模型可能触发 iOS 内存限制。")
            .font(.footnote).foregroundStyle(.secondary)
    }

    private var busy: Bool { generationTask != nil || generator.isGenerating }

    private func start(_ model: LocalModel, prepareOnly: Bool) {
        guard !busy, !library.isProcessing,
              let request = preparation.begin(prepareOnly ? "准备生图资源…" : "准备生图…") else { return }
        focusedField = nil
        preparationID = request
        generationTask = Task {
            defer {
                preparation.finish(request)
                preparationID = nil
                generationTask = nil
            }
            do {
                try Task.checkCancellation()
                guard preparation.isCurrent(request), UIApplication.shared.applicationState == .active else { return }
                await speech.stopAndWait()
                try Task.checkCancellation()
                guard preparation.isCurrent(request), UIApplication.shared.applicationState == .active else { return }
                await chat.unload()
                try Task.checkCancellation()
                guard preparation.isCurrent(request), UIApplication.shared.applicationState == .active,
                      !library.isProcessing else { return }
                let url = try library.fileURL(for: model)
                let components = try library.imageComponents(for: model)
                preparation.finish(request)
                if prepareOnly {
                    await generator.prepareResources(model: model, sourceURL: url, components: components)
                } else {
                    let adapter = library.models.first { $0.id.uuidString == loraID }
                    let selectedLoRA = try adapter.map { (model: $0, url: try library.fileURL(for: $0), weight: loraWeight) }
                    await generator.generate(model: model, sourceURL: url,
                        prompt: prompt, negativePrompt: negativePrompt, size: size, steps: steps,
                        lora: selectedLoRA, components: components)
                }
            } catch is CancellationError { }
            catch { generator.errorMessage = error.localizedDescription }
        }
    }

    private func stop() {
        if let preparationID { preparation.finish(preparationID) }
        generationTask?.cancel()
        generator.cancel()
    }

}
