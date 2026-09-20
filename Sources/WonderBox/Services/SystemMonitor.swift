import Darwin
import Foundation
import IOKit.ps

struct SystemInformation: Sendable {
    let computerName: String
    let modelIdentifier: String
    let processorName: String
    let operatingSystem: String
    let architecture: String

    static let current: SystemInformation = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return SystemInformation(
            computerName: Host.current().localizedName ?? "Mac",
            modelIdentifier: sysctlString("hw.model") ?? "Mac",
            processorName: sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.model") ?? "Apple Silicon",
            operatingSystem: os,
            architecture: sysctlString("hw.machine") ?? "arm64"
        )
    }()

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

struct SystemCounters: Sendable {
    let cpuTotal: UInt64
    let cpuIdle: UInt64
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let sampledAt: Date
}

struct SystemSample: Sendable {
    let snapshot: MetricSnapshot
    let counters: SystemCounters
}

enum SystemMonitor {
    static func sample(previous: SystemCounters?) -> SystemSample {
        let cpu = cpuTicks()
        let network = networkBytes()
        let now = Date()
        let counters = SystemCounters(
            cpuTotal: cpu.total,
            cpuIdle: cpu.idle,
            receivedBytes: network.received,
            sentBytes: network.sent,
            sampledAt: now
        )

        let cpuUsage: Double
        if let previous,
           counters.cpuTotal >= previous.cpuTotal,
           counters.cpuIdle >= previous.cpuIdle {
            let totalDelta = counters.cpuTotal - previous.cpuTotal
            let idleDelta = counters.cpuIdle - previous.cpuIdle
            cpuUsage = totalDelta > 0 ? Double(totalDelta - min(totalDelta, idleDelta)) / Double(totalDelta) : 0
        } else {
            cpuUsage = 0
        }

        let elapsed = max(0.1, now.timeIntervalSince(previous?.sampledAt ?? now))
        let down = delta(current: counters.receivedBytes, previous: previous?.receivedBytes)
        let up = delta(current: counters.sentBytes, previous: previous?.sentBytes)
        let disk = diskUsage()
        let battery = batteryStatus()

        let snapshot = MetricSnapshot(
            cpuUsage: min(1, max(0, cpuUsage)),
            memory: memoryBreakdown(),
            diskUsed: disk.used,
            diskTotal: disk.total,
            networkDownPerSecond: UInt64(Double(down) / elapsed),
            networkUpPerSecond: UInt64(Double(up) / elapsed),
            batteryLevel: battery.level,
            isCharging: battery.charging,
            thermalState: ProcessInfo.processInfo.thermalState,
            uptime: ProcessInfo.processInfo.systemUptime,
            sampledAt: now
        )
        return SystemSample(snapshot: snapshot, counters: counters)
    }

    private static func delta(current: UInt64, previous: UInt64?) -> UInt64 {
        guard let previous, current >= previous else { return 0 }
        return current - previous
    }

    private static func cpuTicks() -> (total: UInt64, idle: UInt64) {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        return (user + system + idle + nice, idle)
    }

    static func memoryBreakdown() -> MemoryBreakdown {
        var breakdown = MemoryBreakdown(swapUsed: swapUsage(), pressure: pressureLevel())
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return breakdown }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)
        // Match Activity Monitor: App Memory = anonymous pages minus purgeable pages.
        let internalPages = UInt64(info.internal_page_count)
        let purgeablePages = UInt64(info.purgeable_count)
        breakdown.app = (internalPages - min(internalPages, purgeablePages)) * page
        breakdown.wired = UInt64(info.wire_count) * page
        breakdown.compressed = UInt64(info.compressor_page_count) * page
        breakdown.cached = UInt64(info.external_page_count) * page
        return breakdown
    }

    private static func swapUsage() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    private static func pressureLevel() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }

    private static func diskUsage() -> (used: UInt64, total: UInt64) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        let total = UInt64(max(0, values?.volumeTotalCapacity ?? 0))
        let available = UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
        return (total > available ? total - available : 0, total)
    }

    private static func networkBytes() -> (received: UInt64, sent: UInt64) {
        var addressPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressPointer) == 0, let first = addressPointer else { return (0, 0) }
        defer { freeifaddrs(addressPointer) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            if let address = interface.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK),
               interface.ifa_flags & UInt32(IFF_UP) != 0,
               interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
               let data = interface.ifa_data {
                let stats = data.assumingMemoryBound(to: if_data.self).pointee
                received += UInt64(stats.ifi_ibytes)
                sent += UInt64(stats.ifi_obytes)
            }
            pointer = interface.ifa_next
        }
        return (received, sent)
    }

    private static func batteryStatus() -> (level: Double?, charging: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, false) }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Double,
                  let maximum = description[kIOPSMaxCapacityKey] as? Double,
                  maximum > 0
            else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String
            let charging = (description[kIOPSIsChargingKey] as? Bool) == true || state == kIOPSACPowerValue
            return (current / maximum, charging)
        }
        return (nil, false)
    }
}
