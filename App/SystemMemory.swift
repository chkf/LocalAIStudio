import Darwin
import Foundation

struct SystemMemory {
    let total: UInt64
    let free: UInt64
    let active: UInt64
    let inactive: UInt64
    let wired: UInt64
    let compressed: UInt64

    // Free includes speculative pages in Mach's VM statistics. The complement
    // includes reclaimable caches; it is not memory pressure or an app budget.
    var used: UInt64 { total - min(total, free) }
    var usedFraction: Double? {
        total > 0 ? Double(used) / Double(total) : nil
    }

    static func read() -> SystemMemory? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(host, host_flavor_t(HOST_VM_INFO64), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(pageSize)
        return SystemMemory(
            total: ProcessInfo.processInfo.physicalMemory,
            free: UInt64(statistics.free_count) * page,
            active: UInt64(statistics.active_count) * page,
            inactive: UInt64(statistics.inactive_count) * page,
            wired: UInt64(statistics.wire_count) * page,
            compressed: UInt64(statistics.compressor_page_count) * page
        )
    }
}
