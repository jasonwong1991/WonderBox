import Charts
import SwiftUI

struct PowerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PowerContent(monitor: model.powerMonitor, isMonitoring: model.isMonitoring)
            .task { await model.powerMonitor.refresh() }
    }
}

struct PowerContent: View {
    @ObservedObject var monitor: PowerMonitor
    let isMonitoring: Bool
    @State private var component: PowerComponent = .system
    @State private var range: PowerHistoryRange = .minute

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: String(localized: "Power"), subtitle: String(localized: "Live power and recent history, in watts"))

                TimelineView(.periodic(from: .now, by: 3)) { context in
                    // A newly published sample can be slightly newer than the current timeline tick.
                    let now = max(context.date, monitor.snapshot.sampledAt)
                    VStack(alignment: .leading, spacing: 22) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 14) { readingCards(at: now, minimumWidth: 210) }
                            LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 14) {
                                readingCards(at: now, minimumWidth: 0)
                            }
                        }
                        PowerHistoryCard(history: monitor.history, component: $component, range: $range, end: now)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label(isMonitoring ? String(localized: "Refreshes every 3 seconds") : String(localized: "Monitoring paused"),
                          systemImage: isMonitoring ? "waveform.path" : "pause.circle")
                        .font(.subheadline.weight(.medium))
                    if !monitor.hasSampled {
                        Text("Waiting for power samples…")
                    } else if isMonitoring && monitor.snapshot.readings.isEmpty {
                        Text("Power sensors are unavailable on this Mac or in this app sandbox. Missing readings are shown as —, not zero.")
                    }
                    Text("CPU/GPU power uses macOS energy counters where available; system power uses the SMC system sensor. These are hardware-reported or model-based readings, not wall-outlet measurements. Components may overlap and must not be added together.")
                    Text("History stays in memory for up to one hour while live monitoring runs, including on other tabs. Sleep, paused monitoring and missing sensors leave gaps; quitting clears history.")
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .appPanel()
            }
            .padding(28)
            .frame(maxWidth: 1_100, alignment: .leading)
        }
        .accessibilityIdentifier("power.page")
        .sectionRefresh(.power, busy: monitor.isRefreshing) { await monitor.refresh() }
    }

    @ViewBuilder
    private func readingCards(at date: Date, minimumWidth: CGFloat) -> some View {
        ForEach(PowerComponent.allCases) { item in
            readingCard(item, at: date).frame(minWidth: minimumWidth)
        }
    }

    private func readingCard(_ item: PowerComponent, at date: Date) -> some View {
        let reading = monitor.snapshot.reading(item, at: date)
        return VStack(alignment: .leading, spacing: 8) {
            Label(item.title, systemImage: item.symbol).font(.subheadline.weight(.medium)).foregroundStyle(item.tint)
            Text(PowerReading.formatted(reading?.watts))
                .font(.system(size: 27, weight: .bold, design: .rounded)).monospacedDigit()
                .accessibilityLabel(item.title + ": " + PowerReading.formatted(reading?.watts))
            Text(reading?.source ?? (monitor.isRefreshing && !monitor.hasSampled
                 ? String(localized: "Measuring power…") : String(localized: "No current reading")))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if reading?.isCPUPackage == true {
                Text("CPU package; may include integrated GPU").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .appPanel()
    }
}

struct PowerHistoryCard: View {
    let history: PowerHistory
    @Binding var component: PowerComponent
    @Binding var range: PowerHistoryRange
    let end: Date

    var body: some View {
        let points = history.points(for: component, range: range, endingAt: end)
        let drawn = PowerHistory.chartPoints(points, range: range)
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { componentPicker; Spacer(minLength: 8); rangePicker }
                VStack(alignment: .leading, spacing: 12) { componentPicker; rangePicker }
            }
            HStack(spacing: 28) {
                statistic(String(localized: "Average Power"), value: PowerHistory.average(points))
                statistic(String(localized: "Peak Power"), value: points.map(\.watts).max())
                Spacer()
            }
            Chart {
                ForEach(drawn) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Watts", point.watts),
                             series: .value("Segment", point.segment))
                        .foregroundStyle(component.tint)
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                if let last = drawn.last {
                    PointMark(x: .value("Time", last.date), y: .value("Watts", last.watts))
                        .foregroundStyle(component.tint).symbolSize(20)
                }
            }
            .chartXScale(domain: end.addingTimeInterval(-range.rawValue)...end)
            .chartYScale(domain: 0...max(1, (points.map(\.watts).max() ?? 0) * 1.15))
            .chartXAxis {
                AxisMarks(values: [end.addingTimeInterval(-range.rawValue), end.addingTimeInterval(-range.rawValue / 2), end]) { axis in
                    AxisGridLine()
                    AxisValueLabel(anchor: axis.index == 0 ? .topLeading : axis.index == 2 ? .topTrailing : .top) {
                        if let date = axis.as(Date.self) {
                            if range == .minute { Text(date, format: .dateTime.minute().second()).monospacedDigit() }
                            else { Text(date, format: .dateTime.hour().minute()).monospacedDigit() }
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { axis in
                    AxisGridLine()
                    AxisValueLabel {
                        if let value = axis.as(Double.self) { Text(value.formatted(.number.precision(.fractionLength(0...2))) + " W") }
                    }
                }
            }
            .frame(height: 210)
            .overlay {
                if points.isEmpty { Text("No power samples in this time range").font(.caption).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(component.title + " · " + range.title)
            .accessibilityValue(String(localized: "Average Power") + ": " + PowerReading.formatted(PowerHistory.average(points))
                                + "; " + String(localized: "Peak Power") + ": " + PowerReading.formatted(points.map(\.watts).max()))
            Text("Statistics cover observed intervals only. Gaps and changes of data source are not connected.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .appPanel()
        .accessibilityIdentifier("power.history")
    }

    private var componentPicker: some View {
        Picker("Power Component", selection: $component) {
            ForEach(PowerComponent.allCases) { item in Text(item.title).tag(item) }
        }
        .labelsHidden().frame(width: 180)
        .accessibilityIdentifier("power.component")
    }

    private var rangePicker: some View {
        Picker("Time Range", selection: $range) {
            ForEach(PowerHistoryRange.allCases) { item in Text(item.title).tag(item) }
        }
        .labelsHidden().pickerStyle(.segmented).frame(width: 280)
        .accessibilityIdentifier("power.range")
    }

    private func statistic(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(PowerReading.formatted(value)).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }
}

private extension PowerComponent {
    var tint: Color {
        switch self {
        case .system: AppSection.power.tint
        case .cpu: AppSection.cpu.tint
        case .gpu: AppSection.gpu.tint
        }
    }
    var symbol: String {
        switch self {
        case .system: "bolt.fill"
        case .cpu: "cpu"
        case .gpu: "cube.transparent"
        }
    }
}
