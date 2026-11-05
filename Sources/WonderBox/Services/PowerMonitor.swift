import CSMC
import Foundation

/// Serial ownership of the optional IOReport subscription and its previous sample.
actor PowerSampler {
    private var reader: OpaquePointer?
    private var lastDiscovery = -Double.infinity
    private var generation = 0
    deinit { wc_energy_destroy(reader) }

    func reset() {
        generation += 1
        wc_energy_destroy(reader)
        reader = nil
        lastDiscovery = -.infinity
    }

    func sample() async -> PowerSnapshot {
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil else { return PowerSnapshot() }
        let now = ProcessInfo.processInfo.systemUptime
        if reader == nil && now - lastDiscovery >= 60 {
            reader = wc_energy_create()
            lastDiscovery = now
        }
        var rawEnergy = [WCEnergyReading](repeating: WCEnergyReading(), count: 64)
        var elapsed = 0.0
        var energyCount = Int(wc_energy_sample(reader, &rawEnergy, Int32(rawEnergy.count), &elapsed))
        if reader != nil, elapsed == 0 {
            let token = generation
            // A first/wake sample establishes energy baselines. Obtain a real delta
            // before publishing instead of leaving CPU blank until the next timer.
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return PowerSnapshot() }
            guard !Task.isCancelled, generation == token else { return PowerSnapshot() }
            energyCount = Int(wc_energy_sample(reader, &rawEnergy, Int32(rawEnergy.count), &elapsed))
        }
        let energy = rawEnergy.prefix(energyCount).map { raw in
            EnergyCounter(channel: string(raw.channel), unit: string(raw.unit), value: raw.energy,
                          source: raw.source == 1 ? .clpc : .energyModel)
        }
        var rawPower = [WCPowerReading](repeating: WCPowerReading(), count: 16)
        let powerCount = Int(wc_smc_read_power(&rawPower, Int32(rawPower.count)))
        let smc = Dictionary(uniqueKeysWithValues: rawPower.prefix(powerCount).map { (string($0.key), $0.watts) })
        return PowerSnapshot(sampledAt: Date(), readings: PowerClassifier.readings(energy: energy, elapsed: elapsed, smc: smc,
                             allowLegacyCPU: ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27))
    }

    private func string<T>(_ tuple: T) -> String {
        var value = tuple
        return withUnsafeBytes(of: &value) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }
}

@MainActor
final class PowerMonitor: ObservableObject {
    @Published private(set) var snapshot = PowerSnapshot()
    @Published private(set) var history = PowerHistory()
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasSampled = false
    private let sample: @Sendable () async -> PowerSnapshot
    private let reset: @Sendable () async -> Void
    private var needsReset = false
    private var generation = 0

    init(sample: (@Sendable () async -> PowerSnapshot)? = nil) {
        let sampler = PowerSampler()
        self.sample = sample ?? { await sampler.sample() }
        self.reset = { await sampler.reset() }
    }

    func pause() {
        generation += 1
        needsReset = true
        guard hasSampled else { return }
        snapshot = PowerSnapshot()
        history.append(snapshot)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        // Avoid tiny IOReport deltas when a toolbar click coincides with periodic sampling.
        if !needsReset && hasSampled && (0..<1).contains(Date().timeIntervalSince(snapshot.sampledAt)) { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let currentGeneration = generation
        if needsReset { needsReset = false; await reset() }
        guard !Task.isCancelled, generation == currentGeneration else { return }
        let value = await sample()
        guard !Task.isCancelled, generation == currentGeneration else { return }
        snapshot = value
        history.append(value)
        hasSampled = true
    }
}
