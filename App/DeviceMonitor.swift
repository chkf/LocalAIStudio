import Darwin
import Foundation
import Metal
import Network
import Observation
import UIKit
import os

struct DeviceSnapshot {
    let systemMemory = SystemMemory.read()
    let date: Date
    let physicalMemory: UInt64
    let appMemory: UInt64?
    let availableMemory: UInt64?
    let cpuPercent: Double?
    let cpuDate: Date?
    let batteryPercent: Int?
    let batteryState: String
    let lowPowerMode: Bool
    let thermalState: String
    let totalStorage: Int64?
    let freeStorage: Int64?
    let importantStorage: Int64?
    let storageError: String?
}

struct DeviceSample: Identifiable {
    let date: Date
    let appMemory: UInt64?
    let cpuPercent: Double?
    let segment: Int

    var id: Date { date }
}

struct NetworkSnapshot {
    let connection: String
    let expensive: Bool
    let constrained: Bool

    init(path: NWPath) {
        if path.status != .satisfied {
            connection = "未连接"
        } else if path.usesInterfaceType(.wifi) {
            connection = "Wi-Fi"
        } else if path.usesInterfaceType(.cellular) {
            connection = "蜂窝网络"
        } else if path.usesInterfaceType(.wiredEthernet) {
            connection = "有线网络"
        } else {
            connection = "其他网络"
        }
        expensive = path.isExpensive
        constrained = path.isConstrained
    }
}

@MainActor
@Observable
final class DeviceMonitor {
    private(set) var snapshot: DeviceSnapshot?
    private(set) var network: NetworkSnapshot?
    private(set) var history: [DeviceSample] = []
    private(set) var isSampling = false
    let hardwareIdentifier = DeviceMonitor.readHardwareIdentifier()
    let metalDeviceName = MTLCreateSystemDefaultDevice()?.name

    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var previousCPU: (seconds: Double, time: ContinuousClock.Instant)?
    @ObservationIgnored private var sampleSegment = 0

    func start() {
        guard samplingTask == nil else { return }
        isSampling = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        previousCPU = nil
        sampleSegment += 1
        refresh()

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let value = NetworkSnapshot(path: path)
            Task { @MainActor [weak self] in
                guard let self, self.isSampling else { return }
                self.network = value
            }
        }
        monitor.start(queue: DispatchQueue(label: "LocalAIStudio.network"))
        pathMonitor = monitor

        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        isSampling = false
        samplingTask?.cancel()
        samplingTask = nil
        pathMonitor?.pathUpdateHandler = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        previousCPU = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    func refresh() {
        guard isSampling else { return }
        let date = Date.now
        let process = ProcessInfo.processInfo
        let device = UIDevice.current
        let cpuPercent = sampleCPU(seconds: Self.readCPUSeconds(), at: ContinuousClock.now)
        let appMemory = Self.readAppMemory()

        var totalStorage: Int64?
        var freeStorage: Int64?
        var importantStorage: Int64?
        var storageError: String?
        do {
            let volumeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            let values = try volumeURL.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
            totalStorage = values.volumeTotalCapacity.map(Int64.init)
            freeStorage = values.volumeAvailableCapacity.map(Int64.init)
            importantStorage = values.volumeAvailableCapacityForImportantUsage
        } catch {
            storageError = error.localizedDescription
        }

        // A simulator process has the Mac's budget, not an iPhone's memory limit.
        #if targetEnvironment(simulator)
        let availableMemory: UInt64? = nil
        #else
        let availableMemory: UInt64? = UInt64(os_proc_available_memory())
        #endif

        snapshot = DeviceSnapshot(
            date: date,
            physicalMemory: process.physicalMemory,
            appMemory: appMemory,
            availableMemory: availableMemory,
            cpuPercent: cpuPercent ?? snapshot?.cpuPercent,
            cpuDate: cpuPercent == nil ? snapshot?.cpuDate : date,
            batteryPercent: device.batteryLevel < 0 ? nil : Int((device.batteryLevel * 100).rounded()),
            batteryState: Self.batteryDescription(device.batteryState),
            lowPowerMode: process.isLowPowerModeEnabled,
            thermalState: Self.thermalDescription(process.thermalState),
            totalStorage: totalStorage,
            freeStorage: freeStorage,
            importantStorage: importantStorage,
            storageError: storageError
        )
        appendSample(date: date, appMemory: appMemory, cpuPercent: cpuPercent)
    }

    func sampleCPU(seconds: Double?, at time: ContinuousClock.Instant) -> Double? {
        guard let seconds else {
            previousCPU = nil
            return nil
        }
        defer { previousCPU = (seconds, time) }
        guard let previousCPU else { return nil }
        let elapsed = previousCPU.time.duration(to: time).components
        let wallSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        guard wallSeconds > 0 else { return nil }
        return max(0, (seconds - previousCPU.seconds) / wallSeconds * 100)
    }

    func appendSample(date: Date, appMemory: UInt64?, cpuPercent: Double?) {
        // Missing readings and foreground sessions must not be joined by a chart line.
        if appMemory == nil || cpuPercent == nil { sampleSegment += 1 }
        history.append(DeviceSample(
            date: date, appMemory: appMemory, cpuPercent: cpuPercent, segment: sampleSegment
        ))
        history.removeAll { $0.date < date.addingTimeInterval(-300) }
        // Also bound memory if repeated foreground transitions add extra samples.
        if history.count > 151 { history.removeFirst(history.count - 151) }
    }

    private static func readAppMemory() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    private static func readCPUSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    private static func readHardwareIdentifier() -> String {
        var system = utsname()
        guard uname(&system) == 0 else { return "不可用" }
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func batteryDescription(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown: "不可用"
        case .unplugged: "未充电"
        case .charging: "正在充电"
        case .full: "已充满"
        @unknown default: "未知"
        }
    }

    private static func thermalDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "正常"
        case .fair: "偏热"
        case .serious: "较热"
        case .critical: "严重"
        @unknown default: "未知"
        }
    }
}
