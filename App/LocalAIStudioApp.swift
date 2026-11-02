import SwiftUI
import UIKit

@main
struct LocalAIStudioApp: App {
    @AppStorage("appearance") private var appearance = "system"

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .preferredColorScheme(preferredScheme)
        }
    }
}

private enum Page: Hashable { case chat, generate, device, models }

private struct MainView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("chatModelID") private var selectedModelID = ""
    @State private var selection: Page = .chat
    @State private var library = ModelLibrary()
    @State private var chat = ChatSession()
    @State private var monitor = DeviceMonitor()

    var body: some View {
        TabView(selection: $selection) {
            Tab("AI", systemImage: "bubble.left.and.bubble.right", value: Page.chat) {
                ChatPage(openModels: { selection = .models })
            }
            Tab("生图", systemImage: "photo", value: Page.generate) {
                GeneratePage(openModels: { selection = .models })
            }
            Tab("System", systemImage: "waveform.path.ecg", value: Page.device) {
                DevicePage()
            }
            Tab("模型", systemImage: "square.stack.3d.up", value: Page.models) {
                ModelsPage { model in
                    Task {
                        await chat.unload()
                        selectedModelID = model.id.uuidString
                        selection = .chat
                    }
                }
            }
        }
        .tint(.green)
        .environment(library)
        .environment(chat)
        .environment(monitor)
        .task { await library.open() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { monitor.start() }
            else { monitor.stop() }
            if phase == .background {
                library.cancelImport()
                chat.saveDraft()
                chat.cancel()
                Task { await chat.unload() }
                Task {
                    await library.download?.pause()
                }
            }
        }
        .onDisappear { monitor.stop() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            chat.cancel()
            Task { await chat.unload() }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { library.errorMessage != nil || library.download?.errorMessage != nil || chat.errorMessage != nil },
            set: { if !$0 { clearError() } }
        )) {
            Button("好", role: .cancel) { clearError() }
        } message: {
            Text(library.errorMessage ?? library.download?.errorMessage ?? chat.errorMessage ?? "")
        }
    }

    private func clearError() {
        library.errorMessage = nil
        library.download?.errorMessage = nil
        chat.errorMessage = nil
    }
}

struct SettingsButton: View {
    @State private var isPresented = false

    var body: some View {
        Button("设置", systemImage: "gearshape") { isPresented = true }
            .accessibilityIdentifier("settingsButton")
            .sheet(isPresented: $isPresented) { SettingsPage() }
    }
}

private struct SettingsPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("主题", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("appearancePicker")
                }
                Section {
                    LabeledContent("降低透明度", value: reduceTransparency ? "已开启" : "未开启")
                    LabeledContent("减少动态效果", value: reduceMotion ? "已开启" : "未开启")
                    LabeledContent("增加对比度", value: contrast == .increased ? "已开启" : "未开启")
                } header: {
                    Text("系统辅助功能")
                } footer: {
                    Text("玻璃效果和原生控件会遵循系统设置。可在 iPhone 的辅助功能中调整。")
                }
                Section("本机数据") {
                    Text("模型由你下载或导入，不随 App 预装。对话和模型文件保存在这台设备上，删除 App 会一并移除。")
                    Text("下载和推理在进入后台时暂停或停止；再次打开后可以继续下载或重新发送消息。")
                        .foregroundStyle(.secondary)
                }
                Section("开源许可") {
                    NavigationLink("第三方组件") {
                        ScrollView {
                            Text(licenseText)
                                .font(.footnote).textSelection(.enabled).padding()
                        }
                        .navigationTitle("第三方组件")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() }.accessibilityIdentifier("closeSettings") }
        }
    }

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") else {
            return "LiteRT-LM — Apache License 2.0\nhttps://github.com/google-ai-edge/LiteRT-LM"
        }
        do { return try String(contentsOf: url, encoding: .utf8) }
        catch { return "无法读取许可文件：\(error.localizedDescription)" }
    }
}

private struct GeneratePage: View {
    let openModels: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("本地生图尚未接入", systemImage: "photo.badge.plus")
            } description: {
                Text("当前版本可以导入和检查模型文件。图片生成将在完成引擎与实际模型验证后开放。")
            } actions: {
                Button("管理模型", action: openModels)
                    .buttonStyle(.borderedProminent)
            }
            .navigationTitle("生图")
        }
    }
}
