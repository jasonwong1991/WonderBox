import Foundation

struct MenuBarMetricOptions: Equatable, Sendable {
    static let cpuKey = "menuBarShowCPU"
    static let memoryKey = "menuBarShowMemory"
    var menuBarVisible = true
    var showCPU = false
    var showMemory = false
    var isEnabled: Bool { menuBarVisible && (showCPU || showMemory) }
}

struct MenuBarResourceSample: Sendable {
    var sampledAt = Date()
    var uptime = ProcessInfo.processInfo.systemUptime
    var cpuTotal: UInt64?
    var cpuIdle: UInt64?
    var memoryFraction: Double?
}

struct MenuBarMetricSnapshot: Equatable, Sendable {
    var cpu: Double?
    var memory: Double?

    init(cpu: Double? = nil, memory: Double? = nil) {
        self.cpu = cpu
        self.memory = memory
    }

    init(current: MenuBarResourceSample, previous: MenuBarResourceSample?) {
        memory = current.memoryFraction
        guard let previous,
              (0.25...10).contains(current.uptime - previous.uptime),
              (0...10).contains(current.sampledAt.timeIntervalSince(previous.sampledAt)),
              let total = current.cpuTotal, let idle = current.cpuIdle,
              let oldTotal = previous.cpuTotal, let oldIdle = previous.cpuIdle,
              total > oldTotal, idle >= oldIdle, idle - oldIdle <= total - oldTotal else { return }
        cpu = Double((total - oldTotal) - (idle - oldIdle)) / Double(total - oldTotal)
    }

    func title(options: MenuBarMetricOptions) -> String {
        guard options.menuBarVisible else { return "" }
        var items: [String] = []
        if options.showCPU { items.append("CPU " + Self.percent(cpu)) }
        if options.showMemory { items.append("RAM " + Self.percent(memory)) }
        return items.joined(separator: " · ")
    }

    private static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite, (0...1).contains(value) else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }
}
