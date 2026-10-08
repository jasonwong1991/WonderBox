import AppKit
import Darwin
import Foundation
import IOKit

enum ProcessorKind: String, Identifiable {
    case cpu, gpu
    var id: Self { self }
    var title: String { rawValue.uppercased() }
}

struct ApplicationProcessorUsage: Identifiable, Sendable {
    var id: URL { location }
    let location: URL
    let name: String
    let processCount: Int
    /// Activity Monitor convention: one fully occupied CPU core is 100%.
    let cpuPercent: Double
    /// Nil means the driver didn't expose counters; this is distinct from an idle GPU.
    let gpuPercent: Double?
    let isQuittable: Bool
}

struct ProcessProcessorCounter: Sendable {
    let pid: pid_t
    let startedAt: UInt64
    let path: String
    let cpuNanoseconds: UInt64
    // Track each context independently: closing one must not reset a process's other contexts.
    let gpuContexts: [UInt64: UInt64]
}

struct ProcessorSample: Sendable {
    let sampledAt: TimeInterval
    let processes: [ProcessProcessorCounter]
    let gpuCountersAvailable: Bool
}

enum ProcessProcessorInspector {
    static func sample() -> ProcessorSample {
        let gpu = gpuCounters()
        let processes = ProcessMemoryInspector.allProcessIdentifiers().compactMap { pid -> ProcessProcessorCounter? in
            guard let info = ProcessMemoryInspector.resourceUsage(of: pid),
                  let path = ProcessMemoryInspector.executablePath(of: pid) else { return nil }
            return ProcessProcessorCounter(
                pid: pid, startedAt: info.ri_proc_start_abstime, path: path,
                cpuNanoseconds: info.ri_user_time &+ info.ri_system_time,
                gpuContexts: gpu.contexts[pid] ?? [:]
            )
        }
        return ProcessorSample(sampledAt: ProcessInfo.processInfo.systemUptime, processes: processes,
                               gpuCountersAvailable: gpu.available)
    }

    static func usage(current: ProcessorSample, previous: ProcessorSample?) -> [ApplicationProcessorUsage] {
        guard let previous, current.sampledAt > previous.sampledAt else { return [] }
        let elapsedNanoseconds = (current.sampledAt - previous.sampledAt) * 1_000_000_000
        let old = Dictionary(uniqueKeysWithValues: previous.processes.map { ($0.pid, $0) })
        var groups: [String: (cpu: UInt64, gpu: UInt64, count: Int)] = [:]
        for process in current.processes {
            let path = ProcessMemoryInspector.applicationBundlePath(containing: process.path) ?? process.path
            var value = groups[path, default: (0, 0, 0)]
            value.count += 1
            // PID reuse and newly observed processes have no comparable baseline.
            if let baseline = old[process.pid], baseline.startedAt == process.startedAt, baseline.path == process.path {
                value.cpu += delta(process.cpuNanoseconds, baseline.cpuNanoseconds)
                for (context, time) in process.gpuContexts {
                    if let before = baseline.gpuContexts[context] { value.gpu += delta(time, before) }
                }
            }
            groups[path] = value
        }
        return groups.map { path, value in
            let location = URL(fileURLWithPath: path)
            let bundle = location.pathExtension == "app" ? Bundle(url: location) : nil
            return ApplicationProcessorUsage(
                location: location,
                name: bundle?.productName ?? (bundle == nil ? location.lastPathComponent : location.deletingPathExtension().lastPathComponent),
                processCount: value.count,
                cpuPercent: Double(value.cpu) / elapsedNanoseconds * 100,
                gpuPercent: current.gpuCountersAvailable && previous.gpuCountersAvailable
                    ? Double(value.gpu) / elapsedNanoseconds * 100 : nil,
                isQuittable: ProcessMemoryInspector.isQuittable(bundle: bundle, path: path)
            )
        }
    }

    private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    /// AGX publishes cumulative nanoseconds per Metal context. This is driver-dependent, not a
    /// promised cross-version API: leave GPU percentages unavailable if AppUsage is absent.
    private static func gpuCounters() -> (contexts: [pid_t: [UInt64: UInt64]], available: Bool) {
        var roots: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &roots) == KERN_SUCCESS else {
            return ([:], false)
        }
        defer { IOObjectRelease(roots) }
        var result: [pid_t: [UInt64: UInt64]] = [:]
        var available = false
        var root = IOIteratorNext(roots)
        while root != 0 {
            var children: io_iterator_t = 0
            if IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS {
                var child = IOIteratorNext(children)
                while child != 0 {
                    let creator = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                    let usage = IORegistryEntryCreateCFProperty(child, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]]
                    if let creator, let pidText = creator.split(separator: ",").first?.split(separator: " ").last,
                       let pid = pid_t(pidText), let usage {
                        var id: UInt64 = 0
                        if IORegistryEntryGetRegistryEntryID(child, &id) == KERN_SUCCESS {
                            // Context IDs are stable within a registry entry; sum its API counters.
                            let times = usage.compactMap { ($0["accumulatedGPUTime"] as? NSNumber)?.uint64Value }
                            if !times.isEmpty {
                                available = true
                                result[pid, default: [:]][id] = times.reduce(0, &+)
                            }
                        }
                    }
                    IOObjectRelease(child)
                    child = IOIteratorNext(children)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(root)
            root = IOIteratorNext(roots)
        }
        return (result, available)
    }
}

@MainActor
final class ProcessorMonitor: ObservableObject {
    @Published private(set) var applications: [ApplicationProcessorUsage] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var gpuCountersAvailable = false
    private var previous: ProcessorSample?

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let baseline = previous
        let sample = await Task.detached(priority: .utility) { ProcessProcessorInspector.sample() }.value
        applications = ProcessProcessorInspector.usage(current: sample, previous: baseline)
        previous = sample
        gpuCountersAvailable = sample.gpuCountersAvailable
    }

    func prime() async {
        await refresh()
        if applications.isEmpty {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    func quit(_ usage: ApplicationProcessorUsage, force: Bool) async {
        guard usage.isQuittable else { return }
        for app in NSWorkspace.shared.runningApplications where app.bundleURL?.standardizedFileURL == usage.location.standardizedFileURL {
            _ = force ? app.forceTerminate() : app.terminate()
        }
        try? await Task.sleep(for: .seconds(1))
        await refresh()
    }
}
