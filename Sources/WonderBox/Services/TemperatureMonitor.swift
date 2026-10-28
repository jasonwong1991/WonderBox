import CSMC
import Foundation

struct TemperatureReading: Identifiable, Equatable, Sendable {
    let id: String
    let celsius: Double
    // The Tf namespace includes limits and aggregate registers as well as core
    // sensors. Keep unclassified keys visible, but exclude them from CPU/GPU summaries.
    private static let tfGPUKeys: Set<String> = ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
    private static let tfCPUKeys: Set<String> = ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
    var isGPU: Bool { id.hasPrefix("TG") || id.hasPrefix("Tg") || Self.tfGPUKeys.contains(id) }
    var isCPU: Bool { !isGPU && (!id.hasPrefix("Tf") || Self.tfCPUKeys.contains(id)) }
    var title: String {
        let bytes = Array(id.utf8)
        if bytes.count == 4, id.hasPrefix("TC"), bytes[3] == 99, let core = Int(String(UnicodeScalar(bytes[2])), radix: 16) {
            return String(localized: "CPU Core \(core + 1)")
        }
        return isGPU ? String(localized: "GPU Sensor") : isCPU ? String(localized: "CPU Sensor") : String(localized: "SMC Sensor")
    }
    var formatted: String { String(format: "%.1f °C", celsius) }

    static func validated(key: String, celsius: Double) -> Self? {
        guard key.count == 4, key.hasPrefix("T"), celsius.isFinite, (10...125).contains(celsius) else { return nil }
        return Self(id: key, celsius: celsius)
    }

    static func summary(_ readings: [Self], gpu: Bool = false) -> String {
        readings.filter { gpu ? $0.isGPU : $0.isCPU }.max(by: { $0.celsius < $1.celsius })?.formatted ?? "—"
    }
}

enum TemperatureMonitor {
    static func sample(rediscover: Bool = false) -> [TemperatureReading] {
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil else { return [] }
        var values = [WCTemperatureReading](repeating: WCTemperatureReading(), count: 256)
        let count = Int(wc_smc_read_temperatures(&values, Int32(values.count), rediscover ? 1 : 0))
        return values.prefix(count).compactMap { raw in
            var key = raw.key
            let name = withUnsafeBytes(of: &key) { bytes in
                String(decoding: bytes.prefix(4), as: UTF8.self)
            }
            return TemperatureReading.validated(key: name, celsius: raw.celsius)
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}
