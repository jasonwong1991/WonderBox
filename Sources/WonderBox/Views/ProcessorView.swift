import AppKit
import SwiftUI

struct ProcessorView: View {
    @EnvironmentObject private var model: AppModel
    let kind: ProcessorKind

    var body: some View {
        ProcessorContent(kind: kind, monitor: model.processorMonitor)
    }
}

private struct ProcessorContent: View {
    @EnvironmentObject private var model: AppModel
    let kind: ProcessorKind
    @ObservedObject var monitor: ProcessorMonitor
    @State private var search = ""
    @State private var forceQuitTarget: ApplicationProcessorUsage?
    @State private var showForceQuitConfirmation = false

    private var applications: [ApplicationProcessorUsage] {
        let ranked = monitor.applications.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
        }.sorted {
            let left = percent($0) ?? -1
            let right = percent($1) ?? -1
            return left == right ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : left > right
        }
        return search.isEmpty ? Array(ranked.prefix(20)) : ranked
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: kind.title, subtitle: String(localized: "Live application usage, including helper processes"))

                MetricCard(title: kind.title,
                           value: kind == .cpu ? AppFormatters.percent(model.snapshot.cpuUsage)
                               : model.snapshot.gpuUsage.map(AppFormatters.percent) ?? "—",
                           detail: kind == .cpu ? model.systemInfo.processorName : model.systemInfo.graphicsName,
                           symbol: kind == .cpu ? "cpu" : "cube.transparent",
                           tint: kind == .cpu ? AppSection.cpu.tint : AppSection.gpu.tint,
                           history: kind == .cpu ? model.cpuHistory : model.gpuHistory)

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(kind == .cpu ? "Top CPU Users" : "Top GPU Users").font(.headline)
                        Spacer()
                        Text("Refreshes every 3 seconds").font(.caption).foregroundStyle(.secondary)
                        Button { Task { await monitor.refresh() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Recount")
                        .accessibilityLabel("Refresh process usage")
                        .disabled(monitor.isRefreshing)
                    }
                    TextField("Search apps", text: $search)
                        .textFieldStyle(.roundedBorder)

                    if kind == .gpu && !monitor.gpuCountersAvailable {
                        InlineMessage(text: String(localized: "This GPU driver does not expose per-process usage; unavailable values are shown as —."))
                    }
                    if monitor.applications.isEmpty {
                        if monitor.isRefreshing {
                            ProgressView("Measuring process usage…").frame(maxWidth: .infinity, minHeight: 100)
                        } else {
                            Text("Waiting for the next sample…").foregroundStyle(.secondary)
                        }
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(applications) { usage in
                                row(usage)
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                    Text(kind == .cpu
                         ? "100% means one fully occupied CPU core; multi-core apps can exceed 100%."
                         : "GPU usage is sampled from driver counters. Concurrent GPU contexts can total more than 100%; this is not the overall device utilization.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .appPanel()
            }
            .padding(28)
            .frame(maxWidth: 1_050, alignment: .leading)
        }
        .task { await monitor.prime() }
        .confirmationDialog("Force quit this application?", isPresented: $showForceQuitConfirmation, titleVisibility: .visible) {
            if let target = forceQuitTarget {
                Button("Force Quit", role: .destructive) { Task { await monitor.quit(target, force: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved changes may be lost.")
        }
    }

    private func percent(_ usage: ApplicationProcessorUsage) -> Double? {
        kind == .cpu ? usage.cpuPercent : usage.gpuPercent
    }

    private func row(_ usage: ApplicationProcessorUsage) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: usage.location.path))
                .resizable().scaledToFit().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(usage.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(usage.processCount) processes").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            ProgressView(value: min(1, (percent(usage) ?? 0) / 100))
                .tint(kind == .cpu ? AppSection.cpu.tint : AppSection.gpu.tint)
                .controlSize(.small).frame(width: 110).accessibilityHidden(true)
            Text(percent(usage).map { String(format: "%.1f%%", $0) } ?? "—")
                .font(.system(.body, design: .rounded, weight: .semibold))
                .monospacedDigit().frame(width: 90, alignment: .trailing)
            if usage.isQuittable {
                Menu {
                    Button("Force Quit…", role: .destructive) {
                        forceQuitTarget = usage
                        showForceQuitConfirmation = true
                    }
                } label: { Text("Quit") } primaryAction: {
                    Task { await monitor.quit(usage, force: false) }
                }
                .frame(width: 88, alignment: .trailing)
            } else { Color.clear.frame(width: 88) }
        }
        .padding(.vertical, 9)
    }
}
