import Foundation
import SwiftUI

/// Activity Monitor categories. `used` matches the "Memory Used" figure: App + Wired + Compressed.
struct MemoryBreakdown: Equatable, Sendable {
    var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: MemoryPressure = .normal

    var used: UInt64 { app + wired + compressed }

    var available: UInt64 {
        total - min(total, used + cached)
    }

    var usedFraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(used) / Double(total))
    }
}

/// Values of `kern.memorystatus_vm_pressure_level`.
enum MemoryPressure: Int, Equatable, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    var title: String {
        switch self {
        case .normal: "正常"
        case .warning: "偏高"
        case .critical: "严重"
        }
    }

    var color: Color {
        switch self {
        case .normal: .healthy
        case .warning: .warning
        case .critical: .critical
        }
    }
}

enum MemoryOptimizationStep: String, CaseIterable, Sendable {
    case pressure
    case purge

    /// Parses the helper reply payload, e.g. "pressure purge".
    static func parse(_ payload: String) -> Set<MemoryOptimizationStep> {
        Set(payload.split(separator: " ").compactMap { MemoryOptimizationStep(rawValue: String($0)) })
    }
}

struct MemoryOptimizationReport: Equatable, Sendable {
    /// Changes below this are indistinguishable from normal allocator churn between two samples.
    static let noticeableChange: UInt64 = 32 * 1_048_576
    /// How many responding applications to name in the summary.
    static let namedApplicationLimit = 3

    let before: MemoryBreakdown
    let after: MemoryBreakdown
    let steps: Set<MemoryOptimizationStep>
    /// Applications whose footprint shrank noticeably, largest release first.
    var applicationReleases: [ApplicationMemoryRelease] = []

    var usedDelta: Int64 { delta(\.used) }
    var appDelta: Int64 { delta(\.app) }
    var compressedDelta: Int64 { delta(\.compressed) }
    var cachedDelta: Int64 { delta(\.cached) }

    var summary: String {
        var parts: [String] = []
        if isNoticeableRelease(usedDelta) {
            var detail: [String] = []
            if isNoticeableRelease(appDelta) {
                detail.append("App \(AppFormatters.signedMemory(appDelta))")
            }
            if isNoticeableRelease(compressedDelta) {
                detail.append("已压缩 \(AppFormatters.signedMemory(compressedDelta))")
            }
            let suffix = detail.isEmpty ? "" : "（\(detail.joined(separator: " · "))）"
            parts.append("已用内存 \(AppFormatters.signedMemory(usedDelta))\(suffix)")
        }
        if isNoticeableRelease(cachedDelta) {
            parts.append("缓存文件 \(AppFormatters.signedMemory(cachedDelta))")
        }

        var text = parts.isEmpty
            ? "当前没有可回收的缓存；已压缩内存由运行中的 App 持有，退出高占用 App 即可释放"
            : "已释放 " + parts.joined(separator: " · ")
        if !steps.contains(.pressure) {
            text += "；未能向 App 发送内存压力通知"
        } else if applicationReleases.isEmpty {
            text += "；各 App 未释放明显缓存"
        } else {
            let named = applicationReleases.prefix(Self.namedApplicationLimit).map {
                "\($0.name) \(AppFormatters.signedMemory(-Int64(clamping: $0.bytes)))"
            }
            text += "；响应的 App：" + named.joined(separator: " · ")
        }
        return text
    }

    static func releases(
        before: [ApplicationMemoryUsage],
        after: [ApplicationMemoryUsage]
    ) -> [ApplicationMemoryRelease] {
        let previous = Dictionary(before.map { ($0.id, $0.footprint) }, uniquingKeysWith: { first, _ in first })
        return after.compactMap { usage -> ApplicationMemoryRelease? in
            guard let earlier = previous[usage.id], earlier > usage.footprint else { return nil }
            let released = earlier - usage.footprint
            guard released >= noticeableChange else { return nil }
            return ApplicationMemoryRelease(name: usage.name, bytes: released)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private func delta(_ keyPath: KeyPath<MemoryBreakdown, UInt64>) -> Int64 {
        Int64(clamping: after[keyPath: keyPath]) - Int64(clamping: before[keyPath: keyPath])
    }

    private func isNoticeableRelease(_ delta: Int64) -> Bool {
        delta < 0 && delta.magnitude >= Self.noticeableChange
    }
}

struct ApplicationMemoryRelease: Equatable, Sendable {
    let name: String
    let bytes: UInt64
}

/// Physical footprint of one application, aggregated across its helper processes.
struct ApplicationMemoryUsage: Identifiable, Equatable, Sendable {
    var id: URL { location }
    let location: URL
    let name: String
    /// Activity Monitor's "Memory" column: private pages in RAM plus the app's compressed and swapped pages.
    let footprint: UInt64
    /// Pages currently in RAM, including shared framework pages.
    let resident: UInt64
    let processCount: Int
    let isQuittable: Bool

    /// Conservative estimate of the app's pages held in the compressor or swap.
    /// Shared resident pages are not part of the footprint, so this never overstates.
    var nonResident: UInt64 { footprint - min(footprint, resident) }
}
