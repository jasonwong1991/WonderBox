import Foundation

/// A bounded, real-time window, not a day-long history or zero-filled placeholder data.
struct ProcessorHistory {
    static let duration: TimeInterval = 60
    static let maximumSamples = 121
    private(set) var samples: [MetricSnapshot] = []

    mutating func append(_ snapshot: MetricSnapshot) {
        if let last = samples.last, snapshot.sampledAt < last.sampledAt { samples.removeAll() }
        samples.removeAll { $0.sampledAt < snapshot.sampledAt.addingTimeInterval(-Self.duration)
            || $0.sampledAt == snapshot.sampledAt }
        samples.append(snapshot)
        samples = Array(samples.suffix(Self.maximumSamples))
    }

    func points(for kind: ProcessorKind, endingAt end: Date) -> [ProcessorHistoryPoint] {
        var points: [ProcessorHistoryPoint] = []
        var segment = 0
        var previous: Date?
        for sample in samples where sample.sampledAt >= end.addingTimeInterval(-Self.duration) && sample.sampledAt <= end {
            let value = kind == .cpu ? sample.cpuUsage : sample.gpuUsage
            guard let value, value.isFinite else { segment += 1; previous = nil; continue }
            if let previous, sample.sampledAt.timeIntervalSince(previous) > 10 { segment += 1 }
            points.append(ProcessorHistoryPoint(date: sample.sampledAt, value: min(1, max(0, value)), segment: segment))
            previous = sample.sampledAt
        }
        return points
    }
}

struct ProcessorHistoryPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let value: Double
    let segment: Int
}
