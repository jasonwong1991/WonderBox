import AppKit
import SwiftUI

struct MemoryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        MemoryContent(optimizer: model.memoryOptimizer)
    }
}

private struct MemorySegment: Identifiable {
    let title: String
    let value: UInt64
    let color: Color

    var id: String { title }
}

private struct MemoryContent: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var optimizer: MemoryOptimizer
    @State private var forceQuitTarget: ApplicationMemoryUsage?
    @State private var showForceQuitConfirmation = false

    private var memory: MemoryBreakdown { model.snapshot.memory }

    private var segments: [MemorySegment] {
        [
            MemorySegment(title: "App 内存", value: memory.app, color: AppSection.memory.tint),
            MemorySegment(title: "联动内存", value: memory.wired, color: Color(hex: 0xE1A127)),
            MemorySegment(title: "已压缩", value: memory.compressed, color: Color(hex: 0x7A67D8)),
            MemorySegment(title: "缓存文件", value: memory.cached, color: Color(hex: 0x3178F6)),
            MemorySegment(title: "可用", value: memory.available, color: Color.secondary.opacity(0.35))
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "内存",
                    subtitle: "已用 \(AppFormatters.memory(memory.used)) / \(AppFormatters.memory(memory.total))",
                    actionTitle: optimizer.isOptimizing ? "正在优化" : "优化内存",
                    actionSymbol: "wand.and.stars",
                    isWorking: optimizer.isOptimizing,
                    action: { Task { await model.optimizeMemory() } }
                )

                if let message = optimizer.message {
                    InlineMessage(text: message, isError: optimizer.messageIsError, dismiss: optimizer.dismissMessage)
                }

                breakdownPanel
                applicationsPanel
            }
            .padding(28)
            .frame(maxWidth: 1_050, alignment: .leading)
        }
        .task { await optimizer.refreshApplications() }
        .confirmationDialog(
            "强制退出？",
            isPresented: $showForceQuitConfirmation,
            titleVisibility: .visible,
            presenting: forceQuitTarget
        ) { target in
            Button("强制退出 \(target.name)", role: .destructive) {
                Task { await optimizer.quit(target, force: true) }
            }
            Button("取消", role: .cancel) {}
        } message: { target in
            Text("\(target.name) 中未保存的更改将会丢失。")
        }
    }

    private var breakdownPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("内存构成")
                    .font(.headline)
                Spacer()
                StatusPill(
                    text: "内存压力 \(memory.pressure.title)",
                    color: memory.pressure.color,
                    symbol: "gauge.with.dots.needle.33percent"
                )
            }

            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(segments.dropLast()) { segment in
                        segment.color
                            .frame(width: proxy.size.width * fraction(of: segment.value))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 14)
            .background(segments.last?.color ?? Color.subtleBackground)
            .clipShape(Capsule())

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(segments) { segment in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(segment.color)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(segment.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(AppFormatters.memory(segment.value))
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .monospacedDigit()
                        }
                    }
                }
            }

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Label("交换空间已用 \(AppFormatters.memory(memory.swapUsed))", systemImage: "arrow.left.arrow.right.circle")
                    .font(.subheadline)
                Spacer()
                Text("优化时会通知所有 App 释放缓存，浏览器后台标签页可能需要重新加载")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .appPanel()
    }

    private var applicationsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("内存占用排行")
                    .font(.headline)
                Spacer()
                Text("按物理占用统计，包含子进程与已压缩页面")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await optimizer.refreshApplications() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("重新统计")
                .accessibilityLabel("重新统计内存占用")
                .disabled(optimizer.isRefreshingApplications)
            }

            if optimizer.applications.isEmpty {
                if optimizer.isRefreshingApplications {
                    ProgressView("正在统计进程内存…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    EmptyContentView(
                        symbol: "memorychip",
                        title: "无法读取进程信息",
                        detail: "沙盒环境不允许读取其他进程的内存占用"
                    )
                    .frame(minHeight: 120)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(optimizer.applications) { usage in
                        applicationRow(usage)
                        if usage.id != optimizer.applications.last?.id {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
            }

            Text("已压缩内存是运行中 App 的活动数据，只有 App 释放缓存或退出时才会减少。退出上方的高占用 App 会直接释放其已压缩与交换部分。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .appPanel()
    }

    private func applicationRow(_ usage: ApplicationMemoryUsage) -> some View {
        let share = fraction(of: usage.footprint)
        return HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: usage.location.path))
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(usage.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(rowDetail(usage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            ProgressView(value: share)
                .tint(AppSection.memory.tint)
                .controlSize(.small)
                .frame(width: 110)
                .accessibilityHidden(true)

            Text(AppFormatters.memory(usage.footprint))
                .font(.system(.body, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)

            if usage.isQuittable {
                Menu {
                    Button("强制退出…", role: .destructive) {
                        forceQuitTarget = usage
                        showForceQuitConfirmation = true
                    }
                } label: {
                    Text("退出")
                } primaryAction: {
                    Task { await optimizer.quit(usage, force: false) }
                }
                .fixedSize()
                .frame(width: 88, alignment: .trailing)
                .help("退出 \(usage.name)（\(AppFormatters.percent(share)) 物理内存）")
            } else {
                Color.clear.frame(width: 88)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(usage.name)，\(AppFormatters.memory(usage.footprint))")
    }

    private func rowDetail(_ usage: ApplicationMemoryUsage) -> String {
        var parts = ["\(usage.processCount) 个进程"]
        if usage.nonResident >= MemoryOptimizationReport.noticeableChange {
            parts.append("约 \(AppFormatters.memory(usage.nonResident)) 已压缩或交换")
        }
        return parts.joined(separator: " · ")
    }

    private func fraction(of value: UInt64) -> Double {
        guard memory.total > 0 else { return 0 }
        return min(1, Double(value) / Double(memory.total))
    }
}
