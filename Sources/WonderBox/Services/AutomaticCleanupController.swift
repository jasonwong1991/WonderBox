import Foundation

struct AutomaticCleanupPolicy: Equatable {
    enum Trigger: String, CaseIterable, Identifiable {
        case size, interval, either
        var id: Self { self }
        var title: String {
            switch self {
            case .size: String(localized: "Cache size")
            case .interval: String(localized: "Time interval")
            case .either: String(localized: "Size or interval")
            }
        }
    }
    var enabled = false
    var trigger: Trigger = .either
    var thresholdMB = 1024
    var intervalHours = 24

    var thresholdBytes: UInt64 { UInt64(max(128, min(102400, thresholdMB))) * 1_048_576 }
    var intervalSeconds: TimeInterval { Double(max(1, min(720, intervalHours))) * 3600 }
    func shouldClean(bytes: UInt64, lastRun: Date, now: Date) -> Bool {
        guard enabled, bytes > 0 else { return false }
        let large = bytes >= thresholdBytes
        let due = now.timeIntervalSince(lastRun) >= intervalSeconds
        switch trigger {
        case .size: return large
        case .interval: return due
        case .either: return large || due
        }
    }
}

@MainActor
final class AutomaticCleanupController: ObservableObject {
    @Published var policy: AutomaticCleanupPolicy { didSet { save() } }
    @Published private(set) var lastRun: Date?
    @Published private(set) var message: String?
    @Published private(set) var isRunning = false
    private let defaults: UserDefaults
    private var timer: Task<Void, Never>?
    private var lastAttempt: Date?
    private var scheduledFrom: Date

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.lastRun = defaults.object(forKey: "autoCleanupLastRun") as? Date
        self.scheduledFrom = defaults.object(forKey: "autoCleanupScheduledFrom") as? Date ?? Date()
        self.policy = AutomaticCleanupPolicy(
            enabled: defaults.bool(forKey: "autoCleanupEnabled"),
            trigger: .init(rawValue: defaults.string(forKey: "autoCleanupTrigger") ?? "") ?? .either,
            thresholdMB: max(128, min(102400, defaults.object(forKey: "autoCleanupThresholdMB") as? Int ?? 1024)),
            intervalHours: max(1, min(720, defaults.object(forKey: "autoCleanupIntervalHours") as? Int ?? 24)))
    }
    deinit { timer?.cancel() }

    func consumeFirstUsePrompt() -> Bool {
        guard !defaults.bool(forKey: "autoCleanupPromptShown") else { return false }
        defaults.set(true, forKey: "autoCleanupPromptShown")
        return !policy.enabled
    }

    private func save() {
        if policy.enabled && !defaults.bool(forKey: "autoCleanupEnabled") {
            scheduledFrom = Date()
            defaults.set(scheduledFrom, forKey: "autoCleanupScheduledFrom")
        }
        defaults.set(policy.enabled, forKey: "autoCleanupEnabled")
        defaults.set(policy.trigger.rawValue, forKey: "autoCleanupTrigger")
        defaults.set(policy.thresholdMB, forKey: "autoCleanupThresholdMB")
        defaults.set(policy.intervalHours, forKey: "autoCleanupIntervalHours")
    }

    func start(perform: @escaping @MainActor (AutomaticCleanupPolicy, Date) async -> String?) {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.policy.enabled, !self.isRunning,
                   self.lastAttempt.map({ Date().timeIntervalSince($0) >= 300 }) ?? true {
                    self.lastAttempt = Date()
                    self.isRunning = true
                    let result = await perform(self.policy, max(self.lastRun ?? self.scheduledFrom, self.scheduledFrom))
                    if let result {
                        self.message = result
                        self.lastRun = Date()
                        self.defaults.set(self.lastRun, forKey: "autoCleanupLastRun")
                    }
                    self.isRunning = false
                }
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }
}
