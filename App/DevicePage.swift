import Charts
import SwiftUI
import UIKit

struct DevicePage: View {
    @Environment(DeviceMonitor.self) private var monitor
    @Environment(ChatSession.self) private var chat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
    }

    private var timeWindow: ClosedRange<Date> {
        let end = monitor.snapshot?.date ?? .now
        return end.addingTimeInterval(-300)...end
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let snapshot = monitor.snapshot {
                        samplingStatus(snapshot)
                        memorySection(snapshot)
                        Divider()
                        cpuSection(snapshot)
                        statusSection(snapshot)
                        Divider()
                        gpuSection
                        detailsSection(snapshot)
                        performanceSection
                        #if targetEnvironment(simulator)
                        Text("模拟器中的 RAM、CPU、GPU 和存储反映宿主 Mac，不能用于评估 iPhone 推理性能。内存预算与电池信息需真机验证。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        #endif
                    } else {
                        ProgressView("正在读取设备状态…")
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .navigationTitle("设备")
        }
    }

    private func samplingStatus(_ snapshot: DeviceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(monitor.isSampling ? "前台监测中" : "采样已暂停",
                      systemImage: monitor.isSampling ? "waveform.path" : "pause.circle")
                Spacer()
                Text(snapshot.date.formatted(date: .omitted, time: .standard))
                    .monospacedDigit()
                    .accessibilityLabel("设备快照更新于")
                    .accessibilityValue(snapshot.date.formatted(date: .omitted, time: .standard))
                    .accessibilityIdentifier("deviceUpdatedAt")
            }
            Text("App 内每 2 秒更新 · 切换页面继续监测")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func memorySection(_ snapshot: DeviceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("内存").font(.headline)
                Spacer()
                Text("最近 5 分钟 · \(monitor.history.count) 次采样")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityValue(String(monitor.history.count))
                    .accessibilityIdentifier("deviceSampleCount")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(memory(snapshot.appMemory))
                    .font(.largeTitle.weight(.semibold))
                    .monospacedDigit()
                    .accessibilityIdentifier("deviceMemoryValue")
                Text("本 App 实际占用 · phys_footprint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            memoryChart
            columns {
                VStack(alignment: .leading, spacing: 4) {
                    Text("进程剩余预算").font(.caption).foregroundStyle(.secondary)
                    Text(memory(snapshot.availableMemory)).font(.title3.weight(.medium)).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text("总物理 RAM").font(.caption).foregroundStyle(.secondary)
                    Text(memory(snapshot.physicalMemory)).font(.title3.weight(.medium)).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("预算是本进程当前还能申请的内存，不是设备空闲 RAM；它会随系统状态变化。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var memoryChart: some View {
        Chart(monitor.history) { sample in
            if let value = sample.appMemory {
                LineMark(
                    x: .value("时间", sample.date),
                    y: .value("App 内存 (MiB)", Double(value) / 1_048_576),
                    series: .value("连续采样段", sample.segment)
                )
                .foregroundStyle(.green)
                .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(
                    x: .value("时间", sample.date),
                    y: .value("App 内存 (MiB)", Double(value) / 1_048_576)
                )
                .foregroundStyle(.green)
                .symbolSize(8)
            }
        }
        .chartXScale(domain: timeWindow)
        .chartYScale(domain: 0...max(1, Double(monitor.history.compactMap(\.appMemory).max() ?? 0) / 1_048_576 * 1.15))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) {
                AxisTick()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text("\(number.formatted(.number.precision(.fractionLength(0)))) MiB")
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: 110)
        .accessibilityLabel("本 App 内存占用曲线，最近 5 分钟，单位 MiB")
        .accessibilityIdentifier("deviceMemoryChart")
    }

    private func cpuSection(_ snapshot: DeviceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU").font(.headline)
                Spacer()
                Text(cpuText(snapshot.cpuPercent))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .accessibilityIdentifier("deviceCPUValue")
            }
            Chart(monitor.history) { sample in
                if let value = sample.cpuPercent {
                    LineMark(
                        x: .value("时间", sample.date),
                        y: .value("App CPU (%)", value),
                        series: .value("连续采样段", sample.segment)
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("时间", sample.date), y: .value("App CPU (%)", value))
                        .foregroundStyle(.blue)
                        .symbolSize(8)
                }
            }
            .chartXScale(domain: timeWindow)
            .chartYScale(domain: 0...max(100, ceil((monitor.history.compactMap(\.cpuPercent).max() ?? 0) / 25) * 25))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) {
                    AxisTick()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text("\(number.formatted(.number.precision(.fractionLength(0))))%")
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .frame(height: 90)
            .accessibilityLabel("本 App CPU 使用率曲线，最近 5 分钟，单位百分比")
            .accessibilityIdentifier("deviceCPUChart")

            VStack(alignment: .leading, spacing: 3) {
                Text("本 App 的平均使用量 · 单核满载 100%，多核可超过 100%。")
                if let date = snapshot.cpuDate {
                    Text("CPU 采样于 \(date.formatted(date: .omitted, time: .standard))")
                        .monospacedDigit()
                        .accessibilityIdentifier("deviceCPUUpdatedAt")
                } else {
                    Text("正在建立采样基线…")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func statusSection(_ snapshot: DeviceSnapshot) -> some View {
        columns {
            VStack(alignment: .leading, spacing: 6) {
                Label("热状态", systemImage: "thermometer.medium")
                    .font(.caption).foregroundStyle(.secondary)
                Text(snapshot.thermalState)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(snapshot.thermalState == "正常" ? Color.primary : .orange)
                Text("系统等级，非摄氏温度")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Label("电池", systemImage: "battery.100percent")
                    .font(.caption).foregroundStyle(.secondary)
                Text(snapshot.batteryPercent.map { "\($0)%" } ?? "不可用")
                    .font(.title3.weight(.semibold)).monospacedDigit()
                Text(snapshot.lowPowerMode ? "\(snapshot.batteryState) · 低电量模式" : snapshot.batteryState)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var gpuSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GPU / Metal").font(.headline)
            Text(monitor.metalDeviceName ?? "Metal 设备不可用")
                .font(.subheadline.weight(.medium))
            if let record = chat.performanceRecords.last {
                Text("最近一次推理后端：\(record.backend)")
                    .font(.subheadline)
            }
            Text("显示 Metal 报告的硬件名称。全系统 GPU 利用率和独立显存没有可用读数。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func detailsSection(_ snapshot: DeviceSnapshot) -> some View {
        DisclosureGroup("更多设备信息") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("设备", value: UIDevice.current.model)
                LabeledContent("硬件标识", value: monitor.hardwareIdentifier)
                LabeledContent("系统", value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                LabeledContent("处理器核心数", value: String(ProcessInfo.processInfo.processorCount))
                Divider()
                LabeledContent("存储总容量", value: storage(snapshot.totalStorage))
                LabeledContent("当前空闲", value: storage(snapshot.freeStorage))
                LabeledContent("可用于下载", value: storage(snapshot.importantStorage))
                Text(snapshot.storageError.map { "无法读取存储容量：\($0)" }
                     ?? "可用于下载的空间包含系统可回收的缓存，可能高于当前空闲空间。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                LabeledContent("网络", value: monitor.network?.connection ?? "正在读取…")
                if let network = monitor.network {
                    LabeledContent("高成本连接", value: network.expensive ? "是" : "否")
                    LabeledContent("低数据模式", value: network.constrained ? "开启" : "关闭")
                }
                Text("连接路径由系统报告，不代表互联网测速或某个网站可达。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("离开 App 或锁屏后暂停监测；恢复时重新采样。曲线空白表示这段时间没有有效读数。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.top, 12)
        }
        .accessibilityIdentifier("deviceDetails")
    }

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI 推理性能").font(.headline)
            if chat.performanceRecords.isEmpty {
                Text("尚无记录").foregroundStyle(.secondary)
            } else {
                ForEach(chat.performanceRecords.reversed().prefix(10)) { record in
                    NavigationLink {
                        PerformanceDetail(record: record)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.modelName).font(.subheadline).lineLimit(2)
                                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let speed = record.tokensPerSecond {
                                    Text("\(speed.formatted(.number.precision(.fractionLength(1)))) Tokens/s")
                                        .font(.subheadline).monospacedDigit()
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("只记录实际完成的推理。Token 数与速度来自引擎统计，缺失时不作估算。")
                .font(.caption).foregroundStyle(.secondary)
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
        guard let value else { return "采样中…" }
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
