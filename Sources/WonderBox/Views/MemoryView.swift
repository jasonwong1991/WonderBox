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
            MemorySegment(title: String(localized: "App Memory"), value: memory.app, color: AppSection.memory.tint),
            MemorySegment(title: String(localized: "Wired"), value: memory.wired, color: Color(hex: 0xE1A127)),
            MemorySegment(title: String(localized: "Compressed"), value: memory.compressed, color: Color(hex: 0x7A67D8)),
            MemorySegment(title: String(localized: "Cached Files"), value: memory.cached, color: Color(hex: 0x3178F6)),
            MemorySegment(title: String(localized: "Available"), value: memory.available, color: Color.secondary.opacity(0.35))
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: String(localized: "Memory"),
                    subtitle: String(localized: "\(AppFormatters.memory(memory.used)) of \(AppFormatters.memory(memory.total)) used"),
                    actionTitle: optimizer.isOptimizing ? String(localized: "Optimizing…") : String(localized: "Optimize Memory"),
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
            "Force Quit?",
            isPresented: $showForceQuitConfirmation,
            titleVisibility: .visible,
            presenting: forceQuitTarget
        ) { target in
            Button("Force Quit \(target.name)", role: .destructive) {
                Task { await optimizer.quit(target, force: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("Unsaved changes in \(target.name) will be lost.")
        }
    }

    private var breakdownPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Memory Breakdown")
                    .font(.headline)
                Spacer()
                StatusPill(
                    text: String(localized: "Pressure: \(memory.pressure.title)"),
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
                Label("Swap used: \(AppFormatters.memory(memory.swapUsed))", systemImage: "arrow.left.arrow.right.circle")
                    .font(.subheadline)
                Spacer()
                Text("Optimizing asks every app to release its caches; background browser tabs may reload")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .appPanel()
    }

    private var applicationsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Top Memory Users")
                    .font(.headline)
                Spacer()
                Text("By physical footprint, including helper processes and compressed pages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await optimizer.refreshApplications() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Recount")
                .accessibilityLabel("Recount memory usage")
                .disabled(optimizer.isRefreshingApplications)
            }

            if optimizer.applications.isEmpty {
                if optimizer.isRefreshingApplications {
                    ProgressView("Measuring process memory…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    EmptyContentView(
                        symbol: "memorychip",
                        title: String(localized: "Cannot Read Process Information"),
                        detail: String(localized: "The sandbox does not allow reading other processes’ memory usage")
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

            Text("Compressed memory is live data owned by running apps; it only shrinks when they release caches or quit. Quitting a heavy app above immediately frees its compressed and swapped pages.")
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
                    Button("Force Quit…", role: .destructive) {
                        forceQuitTarget = usage
                        showForceQuitConfirmation = true
                    }
                } label: {
                    Text("Quit")
                } primaryAction: {
                    Task { await optimizer.quit(usage, force: false) }
                }
                .fixedSize()
                .frame(width: 88, alignment: .trailing)
                .help("Quit \(usage.name) (\(AppFormatters.percent(share)) of physical memory)")
            } else {
                Color.clear.frame(width: 88)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(usage.name), \(AppFormatters.memory(usage.footprint))")
    }

    private func rowDetail(_ usage: ApplicationMemoryUsage) -> String {
        var parts = [String(localized: "\(usage.processCount) processes")]
        if usage.nonResident >= MemoryOptimizationReport.noticeableChange {
            parts.append(String(localized: "about \(AppFormatters.memory(usage.nonResident)) compressed or swapped"))
        }
        return parts.joined(separator: " · ")
    }

    private func fraction(of value: UInt64) -> Double {
        guard memory.total > 0 else { return 0 }
        return min(1, Double(value) / Double(memory.total))
    }
}
