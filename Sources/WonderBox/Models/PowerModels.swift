import Foundation

enum PowerComponent: String, CaseIterable, Identifiable, Sendable {
    case system, cpu, gpu
    var id: Self { self }
    var title: String {
        switch self {
        case .system: String(localized: "System Power")
        case .cpu: "CPU"
        case .gpu: "GPU"
        }
    }
}

struct PowerReading: Equatable, Sendable {
    let watts: Double
    let source: String
    var isCPUPackage = false

    static func validated(_ watts: Double, source: String, isCPUPackage: Bool = false) -> Self? {
        guard watts.isFinite, (0...2000).contains(watts) else { return nil }
        return Self(watts: watts, source: source, isCPUPackage: isCPUPackage)
    }

    static func formatted(_ watts: Double?) -> String {
        watts.map { String(format: "%.2f W", $0) } ?? "—"
    }
}

struct PowerSnapshot: Equatable, Sendable {
    var sampledAt = Date()
    var readings: [PowerComponent: PowerReading] = [:]
    var fans: [FanReading] = []

    func reading(_ component: PowerComponent, at now: Date) -> PowerReading? {
        guard (0...10).contains(now.timeIntervalSince(sampledAt)) else { return nil }
        return readings[component]
    }
}

struct EnergyCounter: Sendable {
    let channel: String
    let unit: String
    let value: Int64

    func watts(elapsed: TimeInterval) -> Double? {
        guard elapsed.isFinite, (0.5...10).contains(elapsed), value >= 0 else { return nil }
        let scale: Double
        switch unit {
        case "J": scale = 1
        case "mJ": scale = 1e-3
        case "uJ", "µJ": scale = 1e-6
        case "nJ": scale = 1e-9
        default: return nil
        }
        return PowerReading.validated(Double(value) * scale / elapsed, source: channel)?.watts
    }
}

enum PowerClassifier {
    static func readings(energy: [EnergyCounter], elapsed: TimeInterval, smc: [String: Double]) -> [PowerComponent: PowerReading] {
        var result: [PowerComponent: PowerReading] = [:]
        func counter(_ names: [String]) -> PowerReading? {
            for name in names {
                let matches = energy.filter { $0.channel == name }
                // Unexpected duplicate aggregate channels are ambiguous; don't sum them.
                if matches.count == 1, let watts = matches[0].watts(elapsed: elapsed) {
                    return PowerReading(watts: watts, source: "IOReport · " + name)
                }
            }
            return nil
        }
        func sensor(_ keys: [String], package: Bool = false) -> PowerReading? {
            for key in keys {
                if let watts = smc[key], let reading = PowerReading.validated(watts, source: "SMC · " + key, isCPUPackage: package) { return reading }
            }
            return nil
        }
        result[.system] = sensor(["PSTR"])
        result[.cpu] = counter(["CPU Energy"]) ?? sensor(["PCTR"]) ?? sensor(["PCPC", "PCPT", "PCPR"], package: true)
        result[.gpu] = counter(["GPU Energy", "GPU"])
        if result[.gpu] == nil {
            let rails = ["PG0R", "PG1R"].filter { smc[$0] != nil }
            if !rails.isEmpty, rails.allSatisfy({ PowerReading.validated(smc[$0]!, source: $0) != nil }) {
                result[.gpu] = PowerReading.validated(rails.reduce(0) { $0 + smc[$1]! }, source: "SMC · " + rails.joined(separator: " + "))
            } else if rails.isEmpty {
                result[.gpu] = sensor(["PCGC", "PCPG"])
            }
        }
        return result
    }
}

enum PowerHistoryRange: TimeInterval, CaseIterable, Identifiable {
    case minute = 60, quarterHour = 900, hour = 3600
    var id: Self { self }
    var title: String {
        switch self {
        case .minute: String(localized: "1 minute")
        case .quarterHour: String(localized: "15 minutes")
        case .hour: String(localized: "1 hour")
        }
    }
}

struct PowerHistoryPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let watts: Double
    let segment: Int
}

/// In-memory session history, not an extrapolation across sleep or app shutdown.
struct PowerHistory {
    static let duration: TimeInterval = 3600
    static let maximumSamples = 3601
    private(set) var samples: [PowerSnapshot] = []

    mutating func append(_ snapshot: PowerSnapshot) {
        if let last = samples.last, snapshot.sampledAt < last.sampledAt { samples.removeAll() }
        samples.removeAll { $0.sampledAt < snapshot.sampledAt.addingTimeInterval(-Self.duration) }
        // Repeated manual refreshes must not evict a full hour of normal samples.
        if let last = samples.last {
            let sameSources = last.readings.count == snapshot.readings.count
                && last.readings.allSatisfy { snapshot.readings[$0.key]?.source == $0.value.source }
            if last.sampledAt == snapshot.sampledAt || (sameSources && snapshot.sampledAt.timeIntervalSince(last.sampledAt) < 1) {
                samples.removeLast()
            }
        }
        samples.append(snapshot)
        if samples.count > Self.maximumSamples { samples.removeFirst(samples.count - Self.maximumSamples) }
    }

    func points(for component: PowerComponent, range: PowerHistoryRange, endingAt end: Date) -> [PowerHistoryPoint] {
        var points: [PowerHistoryPoint] = []
        var segment = 0
        var previous: PowerSnapshot?
        for sample in samples where sample.sampledAt >= end.addingTimeInterval(-range.rawValue) && sample.sampledAt <= end {
            guard let value = sample.readings[component], value.watts.isFinite, (0...2000).contains(value.watts) else {
                segment += 1; previous = nil; continue
            }
            if let previous, sample.sampledAt.timeIntervalSince(previous.sampledAt) > 10
                || previous.readings[component]?.source != value.source { segment += 1 }
            points.append(PowerHistoryPoint(date: sample.sampledAt, watts: value.watts, segment: segment))
            previous = sample
        }
        return points
    }

    /// Time-weighted mean over observed intervals only. Gaps contribute neither time nor energy.
    static func average(_ points: [PowerHistoryPoint]) -> Double? {
        var energy = 0.0, duration = 0.0
        for (left, right) in zip(points, points.dropFirst()) where left.segment == right.segment {
            let elapsed = right.date.timeIntervalSince(left.date)
            guard elapsed > 0, elapsed <= 10 else { continue }
            energy += (left.watts + right.watts) / 2 * elapsed
            duration += elapsed
        }
        return duration > 0 ? energy / duration : points.last?.watts
    }

    /// Preserve spikes and missing-data boundaries while bounding the chart's drawing cost.
    static func chartPoints(_ points: [PowerHistoryPoint], range: PowerHistoryRange) -> [PowerHistoryPoint] {
        let width = max(1, range.rawValue / 240)
        var result: [PowerHistoryPoint] = [], bucket: [PowerHistoryPoint] = []
        func flush() {
            guard let first = bucket.first, let last = bucket.last,
                  let low = bucket.min(by: { $0.watts < $1.watts }), let high = bucket.max(by: { $0.watts < $1.watts }) else { return }
            var seen = Set<Date>()
            result += [first, low, high, last].sorted { $0.date < $1.date }.filter { seen.insert($0.date).inserted }
            bucket.removeAll(keepingCapacity: true)
        }
        for point in points {
            if let first = bucket.first, first.segment != point.segment
                || floor(first.date.timeIntervalSince1970 / width) != floor(point.date.timeIntervalSince1970 / width) { flush() }
            bucket.append(point)
        }
        flush()
        return result
    }
}
