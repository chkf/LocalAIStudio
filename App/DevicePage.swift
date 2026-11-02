import SwiftUI
import UIKit

struct DevicePage: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ChatSession.self) private var chat
    @State private var monitor = DeviceMonitor()
    @State private var isVisible = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("设备", value: UIDevice.current.model)
                    LabeledContent("硬件标识", value: monitor.hardwareIdentifier)
                    LabeledContent("系统", value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                    LabeledContent("处理器核心数", value: String(ProcessInfo.processInfo.processorCount))
                }

                if let snapshot = monitor.snapshot {
                    Section {
                        LabeledContent("总 RAM", value: memory(snapshot.physicalMemory))
                        LabeledContent("App 内存占用", value: memory(snapshot.appMemory))
                        LabeledContent("App 当前可用预算", value: memory(snapshot.availableMemory))
                    } header: {
                        Text("内存")
                    } footer: {
                        Text("可用预算是当前进程还能申请的内存，会随系统状态变化；不是设备空闲 RAM，也不保证模型一定能运行。")
                    }

                    Section {
                        LabeledContent("App CPU", value: cpuText(snapshot.cpuPercent))
                        LabeledContent("系统热状态", value: snapshot.thermalState)
                        LabeledContent("低电量模式", value: snapshot.lowPowerMode ? "开启" : "关闭")
                        LabeledContent("电量", value: snapshot.batteryPercent.map { "\($0)%" } ?? "不可用")
                        LabeledContent("充电状态", value: snapshot.batteryState)
                    } header: {
                        Text("当前状态")
                    } footer: {
                        Text("CPU 是两次采样间本 App 的平均使用量，单核满载为 100%，多线程可超过 100%。不包含其他 App。")
                    }

                    Section {
                        LabeledContent("存储总容量", value: storage(snapshot.totalStorage))
                        LabeledContent("当前空闲", value: storage(snapshot.freeStorage))
                        LabeledContent("可用于下载", value: storage(snapshot.importantStorage))
                    } header: {
                        Text("存储")
                    } footer: {
                        if let error = snapshot.storageError {
                            Text("无法读取存储容量：\(error)")
                        } else {
                            Text("可用于下载的空间包含系统可回收的缓存，可能高于当前空闲空间。")
                        }
                    }

                    Section {
                        LabeledContent("连接", value: monitor.network?.connection ?? "正在读取…")
                        if let network = monitor.network {
                            LabeledContent("高成本连接", value: network.expensive ? "是" : "否")
                            LabeledContent("低数据模式", value: network.constrained ? "开启" : "关闭")
                        }
                    } header: {
                        Text("网络")
                    } footer: {
                        Text("显示系统报告的连接路径，不代表互联网测速或某个网站可达。")
                    }

                    Section {
                        if chat.performanceRecords.isEmpty {
                            Text("尚无推理性能记录").foregroundStyle(.secondary)
                        } else {
                            ForEach(chat.performanceRecords.reversed().prefix(10)) { record in
                                NavigationLink {
                                    PerformanceDetail(record: record)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(record.modelName).lineLimit(2)
                                        Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                        if let speed = record.tokensPerSecond {
                                            Text("\(speed.formatted(.number.precision(.fractionLength(1)))) Tokens/s")
                                                .font(.subheadline).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("最近的 AI 性能")
                    } footer: {
                        Text("只记录实际完成的推理。Token 数与速度来自引擎统计，缺失时不作估算。")
                    }

                    Section {
                        LabeledContent("更新于", value: snapshot.date.formatted(date: .omitted, time: .standard))
                        #if targetEnvironment(simulator)
                        Text("模拟器中的 RAM、CPU 和存储反映宿主 Mac，不能用于评估 iPhone 推理性能。内存预算与电池信息需真机验证。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        #endif
                    } footer: {
                        Text("仅在此页面处于前台时每 2 秒更新。")
                    }
                }
            }
            .monospacedDigit()
            .navigationTitle("设备")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SettingsButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新快照", systemImage: "arrow.clockwise") {
                        monitor.refresh()
                    }
                }
            }
        }
        .onAppear {
            isVisible = true
            if scenePhase == .active { monitor.start() }
        }
        .onDisappear {
            isVisible = false
            monitor.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if isVisible && phase == .active {
                monitor.start()
            } else {
                monitor.stop()
            }
        }
    }

    private func memory(_ value: UInt64?) -> String {
        guard let value else { return "不可用" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    private func storage(_ value: Int64?) -> String {
        guard let value else { return "不可用" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func cpuText(_ value: Double?) -> String {
        guard let value else { return "暂无读数" }
        return "\(value.formatted(.number.precision(.fractionLength(1))))%"
    }
}

private struct PerformanceDetail: View {
    let record: InferenceRecord

    var body: some View {
        List {
            LabeledContent("模型", value: record.modelName)
            LabeledContent("量化", value: record.quantization ?? "尚未确认")
            LabeledContent("后端", value: record.backend)
            LabeledContent("时间", value: record.date.formatted(date: .abbreviated, time: .standard))
            LabeledContent("最近一次加载", value: seconds(record.loadSeconds))
            LabeledContent("首 Token 延迟", value: seconds(record.firstTokenSeconds))
            LabeledContent("生成速度", value: record.tokensPerSecond.map {
                "\($0.formatted(.number.precision(.fractionLength(2)))) Tokens/s"
            } ?? "引擎未提供")
            LabeledContent("输出 Token", value: record.outputTokens.map(String.init) ?? "引擎未提供")
        }
        .navigationTitle("推理记录")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func seconds(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(2)))) 秒" } ?? "引擎未提供"
    }
}
