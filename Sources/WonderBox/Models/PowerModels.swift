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

    func reading(_ component: PowerComponent, at now: Date) -> PowerReading? {
        guard (0...10).contains(now.timeIntervalSince(sampledAt)) else { return nil }
        return readings[component]
    }
}

struct EnergyCounter: Sendable {
    let channel: String
    let unit: String
    let value: Int64
    var source: Source = .energyModel
    enum Source: Sendable { case energyModel, clpc }

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
    private enum CPUFamily: String { case total = "CPU Energy", efficiency = "ECPU Energy", performance = "PCPU Energy", middle = "MCPU Energy" }
    private struct CPUChannel {
        let die: Int?
        let family: CPUFamily
        let name: String
        let watts: Double?
    }

    private static func cpuChannel(_ counter: EnergyCounter, elapsed: TimeInterval) -> CPUChannel? {
        var name = counter.channel
        var die: Int?
        if name.hasPrefix("DIE_") {
            let parts = name.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(parts[1]), (0..<8).contains(number), String(number) == parts[1] else { return nil }
            die = number
            name = String(parts[2])
        }
        let family: CPUFamily
        switch name {
        case "CPU Energy": family = .total
        case "ECPU Energy", "eCPUs Energy": family = .efficiency
        case "PCPU Energy", "pCPUs Energy": family = .performance
        case "MCPU Energy", "mCPUs Energy": family = .middle
        default: return nil
        }
        return CPUChannel(die: die, family: family, name: counter.channel, watts: counter.watts(elapsed: elapsed))
    }

    private static func cpuReading(_ energy: [EnergyCounter], elapsed: TimeInterval) -> PowerReading? {
        let channels = energy.compactMap { cpuChannel($0, elapsed: elapsed) }
        func sum(_ values: [CPUChannel], source: String) -> PowerReading? {
            guard !values.isEmpty, values.allSatisfy({ $0.watts != nil }),
                  Set(values.map(\.name)).count == values.count else { return nil }
            return PowerReading.validated(values.reduce(0) { $0 + $1.watts! }, source: source)
        }
        func typed(_ values: [CPUChannel]) -> [CPUChannel]? {
            guard !values.isEmpty else { return nil }
            let grouped = Dictionary(grouping: values, by: \.family)
            // A CPU total needs every exposed type and at least performance plus
            // efficiency/middle cores. A single type is not whole-CPU power.
            guard grouped[.performance] != nil, grouped[.efficiency] != nil || grouped[.middle] != nil else { return nil }
            var selected: [CPUChannel] = []
            for family in [CPUFamily.efficiency, .middle, .performance] {
                guard let variants = grouped[family] else { continue }
                // Canonical and plural spellings can be aliases, not additive sources.
                let canonical = variants.filter { $0.name.hasSuffix(family.rawValue) }
                let preferred = canonical.isEmpty ? variants : canonical
                guard preferred.count == 1 else { return nil }
                selected += preferred
            }
            return selected
        }

        let total = channels.filter { $0.die == nil && $0.family == .total }
        if total.count == 1, let reading = sum(total, source: "IOReport · CPU Energy") { return reading }
        let perDie = channels.filter { $0.die != nil }
        let dies = Set(perDie.compactMap(\.die)).sorted()
        // Multi-die machines expose separate totals. Never add a whole-chip
        // aggregate to its per-die or per-type counters, or publish one die alone.
        if dies.count >= 2, dies == Array(0..<dies.count) {
            let totals = perDie.filter { $0.family == .total }
            if totals.count == dies.count, Set(totals.compactMap(\.die)) == Set(dies),
               let reading = sum(totals, source: "IOReport · " + totals.map(\.name).sorted().joined(separator: " + ")) { return reading }
            var selected: [CPUChannel] = []
            for die in dies {
                guard let family = typed(perDie.filter { $0.die == die && $0.family != .total }) else { return nil }
                selected += family
            }
            return sum(selected, source: "IOReport · CPU core types (\(dies.count) dies)")
        }
        // A partial per-die family must not be mixed with unscoped counters.
        guard perDie.isEmpty, let types = typed(channels.filter { $0.die == nil && $0.family != .total }) else { return nil }
        return sum(types, source: "IOReport · " + types.map(\.name).joined(separator: " + "))
    }

    static func readings(energy: [EnergyCounter], elapsed: TimeInterval, smc: [String: Double], allowLegacyCPU: Bool = true) -> [PowerComponent: PowerReading] {
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
        // macOS 27 can stop updating legacy CPU energy without Apple's entitlement.
        // Prefer a separately identified CLPC aggregate; keep measured zero valid.
        let clpc = energy.filter { $0.source == .clpc && $0.channel == "CPU Energy" && $0.unit == "nJ" }
        if clpc.count == 1, let watts = clpc[0].watts(elapsed: elapsed) {
            result[.cpu] = PowerReading(watts: watts, source: "IOReport CLPC · CPU Energy")
        }
        let legacy = energy.filter { $0.source == .energyModel }
        if result[.cpu] == nil, allowLegacyCPU { result[.cpu] = cpuReading(legacy, elapsed: elapsed) }
        if result[.cpu] == nil { result[.cpu] = sensor(["PCTR"]) ?? sensor(["PCPC", "PCPT", "PCPR"], package: true) }
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
