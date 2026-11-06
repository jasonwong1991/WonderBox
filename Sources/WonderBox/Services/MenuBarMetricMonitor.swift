import AppKit
import CSMC
import Foundation

/// The status item has its own cheap sampler: window/scene visibility must not freeze it,
/// and keeping it alive must not keep disk, GPU, power history or process scans running.
@MainActor
final class MenuBarMetricMonitor: ObservableObject {
    typealias Reader = @Sendable (MenuBarMetricOptions) async -> MenuBarResourceSample
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    @Published private(set) var snapshot = MenuBarMetricSnapshot()
    @Published private(set) var isRunning = false
    private var options = MenuBarMetricOptions()
    private var task: Task<Void, Never>?
    private var generation = 0
    private var isSleeping = false
    private let read: Reader
    private let sleep: Sleeper
    private let notifications: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(read: @escaping Reader = { options in
        await Task.detached(priority: .utility) {
            let cpu = options.showCPU ? SystemMonitor.cpuTicks() : nil
            let memory = options.showMemory ? SystemMonitor.memoryBreakdownReading() : nil
            // Read only the same system sensor used by the Power page. No energy
            // subscription, component scans, helper or estimated CPU + GPU sum.
            let power = options.showPower && ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
                ? PowerReading.validated(wc_smc_read_system_power(), source: "SMC · PSTR")?.watts : nil
            return MenuBarResourceSample(cpuTotal: cpu?.total, cpuIdle: cpu?.idle,
                                         memoryFraction: memory.flatMap { $0.total > 0 ? $0.usedFraction : nil },
                                         systemPowerWatts: power)
        }.value
    }, sleep: @escaping Sleeper = { try await Task.sleep(for: .seconds($0)) },
         notifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.read = read
        self.sleep = sleep
        self.notifications = notifications
        observers = [
            notifications.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSleeping(true) }
            },
            notifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSleeping(false) }
            }
        ]
    }

    deinit {
        task?.cancel()
        observers.forEach(notifications.removeObserver)
    }

    func configure(_ options: MenuBarMetricOptions) {
        guard self.options != options else { return }
        self.options = options
        restart()
    }

    func setSleeping(_ sleeping: Bool) {
        guard isSleeping != sleeping else { return }
        isSleeping = sleeping
        restart()
    }

    private func restart() {
        generation += 1
        task?.cancel()
        task = nil
        isRunning = false
        snapshot = MenuBarMetricSnapshot()
        guard options.isEnabled, !isSleeping else { return }
        isRunning = true
        let options = options, token = generation, read = read, sleep = sleep
        // Avoid holding the owner alive across a timer suspension.
        task = Task { [weak self] in
            var previous: MenuBarResourceSample?
            var first = true
            while !Task.isCancelled {
                let current = await read(options)
                guard !Task.isCancelled, self?.generation == token else { return }
                self?.snapshot = MenuBarMetricSnapshot(current: current, previous: previous)
                previous = current
                // CPU needs a real second sample, not a fabricated 0% at launch/wake.
                let interval: TimeInterval = first && options.showCPU ? 1 : 3
                first = false
                do { try await sleep(interval) } catch { return }
            }
        }
    }
}
