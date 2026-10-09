import Charts
import SwiftUI

struct ProcessorHistoryCard: View {
    let kind: ProcessorKind
    let value: String
    let detail: String
    let history: ProcessorHistory

    private var tint: Color { kind == .cpu ? AppSection.cpu.tint : AppSection.gpu.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(kind.title, systemImage: kind == .cpu ? "cpu" : "cube.transparent")
                        .font(.subheadline.weight(.medium)).foregroundStyle(tint)
                    Text(value).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Text("Last 60 seconds").font(.caption).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 3)) { context in
                historyChart(endingAt: context.date)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appPanel()
    }

    func historyChart(endingAt end: Date) -> some View {
        let points = history.points(for: kind, endingAt: end)
        return Chart {
            ForEach(points) { point in
                LineMark(x: .value("Time", point.date), y: .value("Usage", point.value * 100),
                         series: .value("Segment", point.segment))
                    .interpolationMethod(.linear)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            if let latest = points.last {
                PointMark(x: .value("Time", latest.date), y: .value("Usage", latest.value * 100))
                    .foregroundStyle(tint).symbolSize(18)
            }
        }
        .chartXScale(domain: end.addingTimeInterval(-ProcessorHistory.duration)...end)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: [end.addingTimeInterval(-60), end.addingTimeInterval(-30), end]) { axis in
                AxisGridLine()
                AxisValueLabel(anchor: axis.index == 0 ? .topLeading : axis.index == 2 ? .topTrailing : .top) {
                    if let date = axis.as(Date.self) { Text(date, format: .dateTime.minute().second()).monospacedDigit() }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { axis in
                AxisGridLine()
                AxisValueLabel { if let value = axis.as(Int.self) { Text("\(value)%") } }
            }
        }
        .frame(maxWidth: .infinity).frame(height: 160)
        .overlay {
            if points.isEmpty {
                Text("Waiting for usage samples…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(kind.title) usage over the last 60 seconds"))
        .accessibilityValue(value)
    }
}
