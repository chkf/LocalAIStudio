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

private enum Page: Hashable {
    case chat, generate, device, models
}

private struct MainView: View {
    @State private var selection: Page = .chat

    var body: some View {
        TabView(selection: $selection) {
            Tab("AI", systemImage: "bubble.left.and.bubble.right", value: Page.chat) {
                ChatPage()
            }
            Tab("生图", systemImage: "photo", value: Page.generate) {
                GeneratePage()
            }
            Tab("设备", systemImage: "waveform.path.ecg", value: Page.device) {
                DevicePage()
            }
            Tab("模型", systemImage: "square.stack.3d.up", value: Page.models) {
                ModelsPage()
            }
        }
        .tint(.green)
    }
}

private struct InfoPanel: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
            Text(title)
                .font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glassEffect(in: .rect(cornerRadius: 22))
    }
}

private struct ChatPage: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    InfoPanel(
                        icon: "brain.head.profile",
                        title: "本地对话",
                        detail: "将支持 Gemma 4 E4B 和其他兼容模型。推理引擎尚未接入。"
                    )
                    InfoPanel(
                        icon: "photo.on.rectangle",
                        title: "多模态理解",
                        detail: "图片输入、流式输出及模型切换将在接入引擎后提供。"
                    )
                }
                .padding()
            }
            .navigationTitle("AI")
        }
    }
}

private struct GeneratePage: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    InfoPanel(
                        icon: "wand.and.stars",
                        title: "图像生成",
                        detail: "计划支持兼容的本地 Checkpoint、LoRA 和图生图功能。"
                    )
                    InfoPanel(
                        icon: "exclamationmark.circle",
                        title: "尚未接入生图引擎",
                        detail: "下载模型不代表可以运行；具体架构、量化格式需要逐一验证。"
                    )
                }
                .padding()
            }
            .navigationTitle("生图")
        }
    }
}

private struct DevicePage: View {
    @AppStorage("appearance") private var appearance = "system"
    @State private var refreshedAt = Date()

    private var thermalText: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "正常"
        case .fair: "偏热"
        case .serious: "较热"
        case .critical: "严重"
        @unknown default: "未知"
        }
    }

    private var batteryText: String {
        let value = UIDevice.current.batteryLevel
        return value >= 0 ? "\(Int(value * 100))%" : "未知"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("设备快照") {
                    LabeledContent("总 RAM") {
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory),
                            countStyle: .memory
                        ))
                    }
                    LabeledContent("电量", value: batteryText)
                    LabeledContent("热状态", value: thermalText)
                    LabeledContent("处理器核心数", value: String(ProcessInfo.processInfo.processorCount))
                    Button("刷新快照") { refreshedAt = .now }
                    Text("更新于 \(refreshedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("外观") {
                    Picker("主题", selection: $appearance) {
                        Text("系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Text("App 内存峰值、推理性能与小组件将在引擎接入后实现；iOS 不开放全系统独立 GPU 显存指标。")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设备")
            .onAppear {
                UIDevice.current.isBatteryMonitoringEnabled = true
                refreshedAt = .now
            }
        }
    }
}

private struct ModelsPage: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    InfoPanel(
                        icon: "square.and.arrow.down",
                        title: "模型库",
                        detail: "计划支持本地文件导入、HTTPS 下载、模型格式识别与文件管理。"
                    )
                    InfoPanel(
                        icon: "externaldrive",
                        title: "文件保存在本机",
                        detail: "不会预装多 GB 的模型；首版先完成下载与存储，再逐步连接推理引擎。"
                    )
                }
                .padding()
            }
            .navigationTitle("模型")
        }
    }
}
