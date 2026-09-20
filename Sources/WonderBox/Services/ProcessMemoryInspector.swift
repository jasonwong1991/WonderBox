import Darwin
import Foundation

/// Aggregates process physical footprints (Activity Monitor's "Memory" column) per application bundle,
/// so multi-process apps such as browsers and Electron apps report their real total.
enum ProcessMemoryInspector {
    /// `PROC_PIDPATHINFO_MAXSIZE` is a macro and not imported into Swift.
    private static let pathBufferSize = 4 * Int(MAXPATHLEN)

    /// System UI processes that relaunch automatically; quitting them never frees memory for long.
    private static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.WindowManager",
        "com.apple.loginwindow",
        "com.apple.notificationcenterui"
    ]

    static func topConsumers(limit: Int = 12) -> [ApplicationMemoryUsage] {
        var groups: [String: (footprint: UInt64, resident: UInt64, count: Int)] = [:]
        for pid in allProcessIdentifiers() {
            if Task.isCancelled { break }
            guard let usage = resourceUsage(of: pid), usage.ri_phys_footprint > 0,
                  let path = executablePath(of: pid)
            else { continue }
            let key = applicationBundlePath(containing: path) ?? path
            groups[key, default: (0, 0, 0)].footprint += usage.ri_phys_footprint
            groups[key, default: (0, 0, 0)].resident += usage.ri_resident_size
            groups[key, default: (0, 0, 0)].count += 1
        }

        let ownBundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        return groups
            .sorted { $0.value.footprint > $1.value.footprint }
            .prefix(limit)
            .map { key, value in
                let location = URL(fileURLWithPath: key)
                let bundle = location.pathExtension == "app" ? Bundle(url: location) : nil
                let isProtected = bundle?.bundleIdentifier.map(protectedBundleIdentifiers.contains) ?? false
                return ApplicationMemoryUsage(
                    location: location,
                    name: bundle.map { $0.productName ?? location.deletingPathExtension().lastPathComponent }
                        ?? location.lastPathComponent,
                    footprint: value.footprint,
                    resident: value.resident,
                    processCount: value.count,
                    isQuittable: bundle != nil && !isProtected && key != ownBundlePath
                )
            }
    }

    static func footprint(of pid: pid_t) -> UInt64? {
        resourceUsage(of: pid)?.ri_phys_footprint
    }

    private static func resourceUsage(of pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info : nil
    }

    /// Outermost `.app` bundle on the path, so nested helper bundles roll up into their host application.
    static func applicationBundlePath(containing executablePath: String) -> String? {
        let components = executablePath.split(separator: "/")
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return "/" + components[...index].joined(separator: "/")
    }

    private static func allProcessIdentifiers() -> [pid_t] {
        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytesNeeded > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(bytesNeeded) / MemoryLayout<pid_t>.size + 32)
        let bytesWritten = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard bytesWritten > 0 else { return [] }
        return buffer.prefix(Int(bytesWritten) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
