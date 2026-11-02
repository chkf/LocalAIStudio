import SwiftUI
import os

struct ChatPage: View {
    @Environment(ModelLibrary.self) private var library
    @Environment(ChatSession.self) private var chat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("chatModelID") private var selectedModelID = ""
    @State private var confirmingLoad = false
    @State private var confirmingClear = false
    @State private var dispatching = false
    let openModels: () -> Void

    private var selectedModel: LocalModel? {
        library.models.first { $0.id.uuidString == selectedModelID && $0.format == .litertLM }
    }
    private var busy: Bool { chat.isBusy || dispatching }

    var body: some View {
        @Bindable var chat = chat
        NavigationStack {
            VStack(spacing: 0) {
                modelPicker
                if chat.messages.isEmpty {
                    ContentUnavailableView {
                        Label("在这台 iPhone 上对话", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text(selectedModel == nil ? "先导入并选择一个 LiteRT-LM 模型。" : "消息由本地模型处理。首次发送时会加载所选模型。")
                    } actions: {
                        if selectedModel == nil {
                            Button("选择模型", action: openModels).buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    ScrollViewReader { scroll in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 24) {
                                ForEach(chat.messages) { message in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(message.role == .user ? "你" : "AI")
                                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        Text(message.text).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if message.isInterrupted {
                                            Text("已中断").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .id(message.id)
                                }
                                Color.clear.frame(height: 1).id("end")
                            }
                            .padding()
                        }
                        .defaultScrollAnchor(.bottom)
                        .onChange(of: chat.messages.last?.text) { _, _ in scroll.scrollTo("end", anchor: .bottom) }
                    }
                }
                if !chat.status.isEmpty {
                    Text(chat.status).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal).padding(.bottom, 8)
                        .accessibilityIdentifier("chatStatus")
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("发送消息…", text: $chat.draft, axis: .vertical)
                        .lineLimit(1...6)
                        .accessibilityIdentifier("chatInput")
                    if busy {
                        Button("停止", systemImage: "stop.fill") { chat.cancel() }
                            .labelStyle(.iconOnly).buttonStyle(.bordered)
                            .accessibilityIdentifier("stopGeneration")
                    } else {
                        Button("发送", systemImage: "arrow.up") { attemptSend() }
                            .labelStyle(.iconOnly).buttonStyle(.borderedProminent)
                            .disabled(selectedModel == nil || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("sendMessage")
                    }
                }
                .padding(14)
                .background {
                    if reduceTransparency {
                        RoundedRectangle(cornerRadius: 24).fill(Color(uiColor: .secondarySystemBackground))
                    } else {
                        Color.clear.glassEffect(in: .rect(cornerRadius: 24))
                    }
                }
                .padding(.horizontal).padding(.bottom, 8)
            }
            .navigationTitle("AI")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SettingsButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("对话选项", systemImage: "ellipsis") {
                        Button("卸载模型", systemImage: "eject") { Task { await chat.unload() } }
                            .disabled(chat.loadedModelID == nil && !chat.isBusy)
                        Button("清空对话", systemImage: "trash", role: .destructive) { confirmingClear = true }
                    }
                }
            }
            .confirmationDialog("首次尝试这个模型", isPresented: $confirmingLoad, titleVisibility: .visible) {
                Button("加载并发送") { send() }
            } message: {
                Text("模型的实际内存需求尚未经本机验证，文件大小不能代表运行峰值。\(memoryBudgetText) 动态上下文最多 2048 Token，固定上下文按模型配置；单轮输出最多 512 Token。你可以停止生成或卸载模型。")
            }
            .confirmationDialog("清空当前对话？", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("清空对话", role: .destructive) { Task { await chat.clear() } }
            }
            .onDisappear { chat.saveDraft() }
        }
    }

    private var modelPicker: some View {
        HStack {
            Menu {
                ForEach(library.models.filter { $0.format == .litertLM }) { model in
                    Button(model.name) {
                        Task {
                            await chat.unload()
                            selectedModelID = model.id.uuidString
                        }
                    }
                }
                Button("管理模型…", action: openModels)
            } label: {
                Label(selectedModel?.name ?? "未选择模型", systemImage: "chevron.up.chevron.down")
                    .font(.subheadline).lineLimit(1)
            }
            .disabled(busy)
            Spacer()
            if chat.loadedModelID != nil {
                Label("已加载", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal).padding(.vertical, 10)
    }

    private var memoryBudgetText: String {
        #if targetEnvironment(simulator)
        return "模拟器不能验证 iPhone 内存预算。"
        #else
        return "当前进程可用预算约 \(ByteCountFormatter.string(fromByteCount: Int64(os_proc_available_memory()), countStyle: .memory))，该值会随系统状态变化。"
        #endif
    }

    private func attemptSend() {
        guard let model = selectedModel else { return }
        if chat.loadedModelID != model.id { confirmingLoad = true }
        else { send() }
    }

    private func send() {
        guard let model = selectedModel, !busy else { return }
        dispatching = true
        Task {
            defer { dispatching = false }
            do { await chat.send(model: model, fileURL: try await library.fileURL(for: model)) }
            catch { chat.errorMessage = error.localizedDescription }
        }
    }
}
