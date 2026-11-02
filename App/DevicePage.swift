import SwiftUI
import UIKit

struct DevicePage: View {
    @Environment(DeviceMonitor.self) private var monitor
    @Environment(ChatSession.self) private var chat
    @Environment(ModelLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detail: Detail?

    private enum Detail: String, Identifiable {
        case memory = "内存", storage = "存储", device = "设备信息", tasks = "运行记录"
        var id: String { rawValue }
    }

    private var layout: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let snapshot = monitor.snapshot {
                        memoryCard(snapshot)
                        storageCard(snapshot)
                        statusCard(snapshot)
                        taskStatus
                    } else {
                        ProgressView("正在读取设备状态…")
                            .frame(maxWidth: .infinity, minHeight: 280)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background {
                ZStack {
                    Color(uiColor: .systemGroupedBackground)
                    if !reduceTransparency {
                        LinearGradient(
                            colors: [.blue.opacity(scheme == .dark ? 0.12 : 0.05), .clear],
                            startPoint: .topTrailing, endPoint: .bottomLeading
                        )
                    }
                }
                .ignoresSafeArea()
            }
            .navigationTitle("System")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("设备信息", systemImage: "info.circle") { detail = .device }
                        .accessibilityIdentifier("deviceDetailsButton")
                }
            }
            .sheet(item: $detail) { selected in
                NavigationStack {
                    List { detailContent(selected) }
                        .navigationTitle(selected.rawValue)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { detail = nil }
                                    .accessibilityIdentifier("closeDeviceDetails")
                            }
                        }
                }
            }
        }
    }

    private func memoryCard(_ snapshot: DeviceSnapshot) -> some View {
        Button { detail = .memory } label: {
            VStack(alignment: .leading, spacing: 20) {
                Text("RAM").font(.title2.bold())
                layout {
                    VStack(alignment: .leading, spacing: 18) {
                        memoryValue("已用", bytes: snapshot.systemMemory?.used, prominent: true)
                        memoryValue("空闲", bytes: snapshot.systemMemory?.free, prominent: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    memoryRing(snapshot.systemMemory?.usedFraction)
                }
                Divider()
                HStack {
                    Label("本 App", systemImage: "square.3.layers.3d")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(bytes(snapshot.appMemory)).font(.headline).monospacedDigit()
                        .accessibilityIdentifier("deviceMemoryValue")
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground, in: .rect(cornerRadius: 28))
            .overlay(cardBorder)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("systemMemoryCard")
    }

    private func memoryValue(_ title: String, bytes value: UInt64?, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map { String(format: "%.1f", Double($0) / 1_000_000_000) } ?? "—")
                    .font(prominent ? .largeTitle.bold() : .title.bold())
                if value != nil { Text("GB").font(.body).foregroundStyle(.secondary) }
            }
            .monospacedDigit()
        }
    }

    private func memoryRing(_ fraction: Double?) -> some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(.secondary.opacity(0.22), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            if let fraction {
                Circle().trim(from: 0, to: fraction * 0.75)
                    .stroke(.orange, style: StrokeStyle(lineWidth: 10, lineCap: .round))
            }
        }
        .rotationEffect(.degrees(135))
        .overlay {
            Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .font(.largeTitle.bold()).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.35)
                .padding(.horizontal, 14)
        }
        .frame(width: 138, height: 138)
        .padding(5)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("整机 RAM 已用比例")
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "无法读取")
        .accessibilityIdentifier("systemRAMGauge")
    }

    private func storageCard(_ snapshot: DeviceSnapshot) -> some View {
        Button { detail = .storage } label: {
            VStack(spacing: 16) {
                layout {
                    Label("剩余存储", systemImage: "internaldrive")
                        .font(.body)
                    Spacer(minLength: 0)
                    Text(diskBytes(snapshot.freeStorage))
                        .font(.title.bold()).monospacedDigit()
                }
                if let total = snapshot.totalStorage, total > 0, let free = snapshot.freeStorage {
                    ProgressView(value: min(1, max(0, 1 - Double(free) / Double(total))))
                        .tint(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(22)
            .background(cardBackground, in: .rect(cornerRadius: 28))
            .overlay(cardBorder)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("systemStorageCard")
    }

    private func statusCard(_ snapshot: DeviceSnapshot) -> some View {
        Button { detail = .device } label: {
            layout {
                metric("App CPU", symbol: "cpu", value: snapshot.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—", color: .blue, id: "deviceCPUValue")
                if !typeSize.isAccessibilitySize { Divider().frame(height: 44) }
                metric("电池", symbol: snapshot.batteryState == "正在充电" ? "battery.100percent.bolt" : "battery.75percent", value: snapshot.batteryPercent.map { "\($0)%" } ?? "—", color: snapshot.lowPowerMode ? .orange : .green, id: "deviceBatteryValue")
                if !typeSize.isAccessibilitySize { Divider().frame(height: 44) }
                metric("热状态", symbol: "thermometer.medium", value: snapshot.thermalState, color: snapshot.thermalState == "正常" ? .mint : .orange, id: "deviceThermalValue")
            }
            .padding(20)
            .background(cardBackground, in: .rect(cornerRadius: 28))
            .overlay(cardBorder)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
    }

    private func metric(_ title: String, symbol: String, value: String, color: Color, id: String) -> some View {
        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .center, spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(title).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.subheadline)
            Text(value).font(.title2.bold()).monospacedDigit()
                .accessibilityIdentifier(id)
        }
        .frame(maxWidth: .infinity, alignment: typeSize.isAccessibilitySize ? .leading : .center)
    }

    private var taskStatus: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { detail = .tasks } label: {
                HStack {
                    Text("运行状态")
                    Spacer()
                    Text(chat.isBusy ? "运行中" : "空闲").font(.title3.weight(.medium))
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 14)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("systemTaskStatus")
            if chat.isBusy {
                Text(library.models.first { $0.id == chat.lastModelID }?.name ?? "AI 任务")
                    .font(.headline).lineLimit(2)
                HStack {
                    ProgressView()
                    Text(chat.status).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("停止", systemImage: "stop.fill") { chat.cancel() }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("stopSystemTask")
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func detailContent(_ selected: Detail) -> some View {
        if let snapshot = monitor.snapshot {
            switch selected {
            case .memory:
                Section("整机 RAM") {
                    LabeledContent("总量", value: bytes(snapshot.physicalMemory))
                    if let memory = snapshot.systemMemory {
                        LabeledContent("已用", value: bytes(memory.used))
                        LabeledContent("空闲", value: bytes(memory.free))
                        LabeledContent("活跃", value: bytes(memory.active))
                        LabeledContent("非活跃", value: bytes(memory.inactive))
                        LabeledContent("有线", value: bytes(memory.wired))
                        LabeledContent("压缩", value: bytes(memory.compressed))
                    } else {
                        Text("系统未返回整机内存统计。不会用 App 内存或进程预算替代。")
                    }
                }
                Section("本 App") {
                    LabeledContent("实际占用", value: bytes(snapshot.appMemory))
                    LabeledContent("进程剩余预算", value: bytes(snapshot.availableMemory))
                }
                Section {
                    Text("已用 = 总量 − Mach 空闲页（包含推测页）。已用中包含可回收缓存，不等于内存压力；各分类也不应简单相加。进程预算不是整机剩余 RAM。")
                }
            case .storage:
                Section {
                    LabeledContent("总容量", value: diskBytes(snapshot.totalStorage))
                    LabeledContent("当前可用", value: diskBytes(snapshot.freeStorage))
                    LabeledContent("重要用途可用", value: diskBytes(snapshot.importantStorage))
                    if let error = snapshot.storageError { Text(error).foregroundStyle(.red) }
                } footer: {
                    Text("重要用途可用容量可能包含系统可清理的空间。首屏显示当前可用空间。")
                }
                LabeledContent("模型文件占用", value: diskBytes(library.totalBytes))
            case .device:
                Section("设备") {
                    LabeledContent("型号", value: monitor.hardwareIdentifier)
                    LabeledContent("系统", value: "iOS \(UIDevice.current.systemVersion)")
                    LabeledContent("处理器核心", value: "\(ProcessInfo.processInfo.activeProcessorCount)")
                    LabeledContent("网络", value: monitor.network?.connection ?? "不可用")
                    LabeledContent("电池", value: snapshot.batteryState)
                    LabeledContent("低电量模式", value: snapshot.lowPowerMode ? "开启" : "关闭")
                    LabeledContent("热状态", value: snapshot.thermalState)
                    Text("系统等级，非摄氏温度").foregroundStyle(.secondary)
                }
                Section("采样") {
                    LabeledContent("状态", value: monitor.isSampling ? "前台监测中" : "已暂停")
                    LabeledContent("更新时间", value: snapshot.date.formatted(date: .omitted, time: .standard))
                    LabeledContent("最近样本") {
                        Text("\(monitor.history.count)").monospacedDigit()
                            .accessibilityIdentifier("deviceSampleCount")
                    }
                    Text("前台每 2 秒采样，切换页面继续监测；进入后台后保留快照，回来立即刷新。App CPU 以单核心 100% 计，多线程可能超过 100%。")
                }
                Section("GPU") {
                    LabeledContent("Metal 设备", value: monitor.metalDeviceName ?? "不可用")
                    Text("没有整机 GPU 实时使用率或独立显存读数。")
                }
                #if targetEnvironment(simulator)
                Section { Text("模拟器读数来自宿主 Mac，不能用于评估 iPhone 性能。电池与进程预算需要真机验证。") }
                #endif
            case .tasks:
                if chat.isBusy { Section("当前任务") { Text(chat.status) } }
                if chat.performanceRecords.isEmpty {
                    ContentUnavailableView("暂无推理记录", systemImage: "clock")
                } else {
                    ForEach(chat.performanceRecords.reversed()) { record in
                        Section(record.modelName) {
                            LabeledContent("时间", value: record.date.formatted())
                            LabeledContent("后端", value: record.backend)
                            LabeledContent("量化", value: record.quantization ?? "未确认")
                            if let seconds = record.loadSeconds { LabeledContent("加载", value: String(format: "%.2f s", seconds)) }
                            if let seconds = record.firstTokenSeconds { LabeledContent("首 Token", value: String(format: "%.2f s", seconds)) }
                            if let speed = record.tokensPerSecond { LabeledContent("生成速度", value: String(format: "%.1f tok/s", speed)) }
                        }
                    }
                }
            }
        }
    }

    private var cardBackground: Color {
        Color(uiColor: .secondarySystemGroupedBackground).opacity(reduceTransparency ? 1 : 0.88)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 28)
            .strokeBorder(.primary.opacity(contrast == .increased ? 0.3 : 0.06), lineWidth: 1)
            .allowsHitTesting(false)
    }

    private func bytes(_ value: UInt64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—"
    }

    private func diskBytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
    }
}
