import AppKit
import Foundation

/// Drives system-wide memory reclamation through the privileged helper and reports what actually changed.
@MainActor
final class MemoryOptimizer: ObservableObject {
    @Published private(set) var isOptimizing = false
    @Published private(set) var report: MemoryOptimizationReport?
    @Published private(set) var message: String?
    @Published private(set) var applications: [ApplicationMemoryUsage] = []
    @Published private(set) var isRefreshingApplications = false

    /// True when `message` describes a failure rather than an optimization result.
    var messageIsError: Bool { message != nil && report == nil }

    /// Wide enough to catch mid-sized apps that respond, not just the dozen shown in the ranking.
    private nonisolated static let attributionSampleSize = 40

    func optimize() async {
        guard !isOptimizing else { return }
        isOptimizing = true
        message = nil
        report = nil

        let before = await Task.detached(priority: .utility) {
            (memory: SystemMonitor.memoryBreakdown(),
             applications: ProcessMemoryInspector.topConsumers(limit: Self.attributionSampleSize))
        }.value
        let service = await PrivilegedService.ensureReady()
        guard service.succeeded else {
            message = service.message
            isOptimizing = false
            return
        }

        let reply = await Task.detached(priority: .userInitiated) { PrivilegedService.send("optimize-memory") }.value
        switch reply {
        case let .success(payload):
            // Let the kernel finish accounting for pages other processes just released.
            try? await Task.sleep(for: .seconds(1))
            let after = await Task.detached(priority: .utility) {
                (memory: SystemMonitor.memoryBreakdown(),
                 applications: ProcessMemoryInspector.topConsumers(limit: Self.attributionSampleSize))
            }.value
            let result = MemoryOptimizationReport(
                before: before.memory,
                after: after.memory,
                steps: MemoryOptimizationStep.parse(payload),
                applicationReleases: MemoryOptimizationReport.releases(
                    before: before.applications,
                    after: after.applications
                )
            )
            report = result
            message = result.summary
        case let .failure(text):
            message = text
        case .unavailable:
            message = "后台增强服务连接已中断"
        }
        isOptimizing = false
        await refreshApplications()
    }

    func refreshApplications() async {
        guard !isRefreshingApplications else { return }
        isRefreshingApplications = true
        applications = await Task.detached(priority: .utility) { ProcessMemoryInspector.topConsumers() }.value
        isRefreshingApplications = false
    }

    func quit(_ usage: ApplicationMemoryUsage, force: Bool) async {
        let target = usage.location.standardizedFileURL.path
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL.path == target
        }
        guard !running.isEmpty else {
            await refreshApplications()
            return
        }
        for application in running {
            _ = force ? application.forceTerminate() : application.terminate()
        }
        // Give the app time to tear down its helper processes before re-sampling.
        try? await Task.sleep(for: .seconds(1.5))
        await refreshApplications()
    }

    func dismissMessage() {
        message = nil
        report = nil
    }
}
