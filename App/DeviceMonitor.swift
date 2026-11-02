import Darwin
import Foundation
import Network
import Observation
import UIKit
import os

struct DeviceSnapshot {
    let date: Date
    let physicalMemory: UInt64
    let appMemory: UInt64?
    let availableMemory: UInt64?
    let cpuPercent: Double?
    let batteryPercent: Int?
    let batteryState: String
    let lowPowerMode: Bool
    let thermalState: String
    let totalStorage: Int64?
    let freeStorage: Int64?
    let importantStorage: Int64?
    let storageError: String?
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
    let hardwareIdentifier = DeviceMonitor.readHardwareIdentifier()

    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var previousCPU: (seconds: Double, time: ContinuousClock.Instant)?

    func start() {
        guard samplingTask == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        previousCPU = nil
        network = nil
        refresh()

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let value = NetworkSnapshot(path: path)
            Task { @MainActor [weak self] in
                self?.network = value
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
        samplingTask?.cancel()
        samplingTask = nil
        pathMonitor?.pathUpdateHandler = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        previousCPU = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    func refresh() {
        let process = ProcessInfo.processInfo
        let device = UIDevice.current
        var cpuPercent: Double?
        if let cpuSeconds = Self.readCPUSeconds() {
            let now = ContinuousClock.now
            if let previousCPU {
                let elapsed = previousCPU.time.duration(to: now).components
                let wallSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                if wallSeconds > 0 {
                    cpuPercent = max(0, (cpuSeconds - previousCPU.seconds) / wallSeconds * 100)
                }
            }
            previousCPU = (cpuSeconds, now)
        } else {
            previousCPU = nil
        }

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
            date: .now,
            physicalMemory: process.physicalMemory,
            appMemory: Self.readAppMemory(),
            availableMemory: availableMemory,
            cpuPercent: cpuPercent,
            batteryPercent: device.batteryLevel < 0 ? nil : Int((device.batteryLevel * 100).rounded()),
            batteryState: Self.batteryDescription(device.batteryState),
            lowPowerMode: process.isLowPowerModeEnabled,
            thermalState: Self.thermalDescription(process.thermalState),
            totalStorage: totalStorage,
            freeStorage: freeStorage,
            importantStorage: importantStorage,
            storageError: storageError
        )
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
