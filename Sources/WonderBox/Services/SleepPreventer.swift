import Foundation
import IOKit.pwr_mgt

@MainActor
final class SleepPreventer: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var expiresAt: Date?
    @Published private(set) var remaining: TimeInterval?
    @Published private(set) var keepDisplayAwake = false
    @Published private(set) var lastError: String?

    private var assertionIDs: [IOPMAssertionID] = []
    private var countdownTask: Task<Void, Never>?

    var remainingText: String {
        guard let remaining else { return "持续开启" }
        let minutes = max(0, Int(remaining) / 60)
        let hours = minutes / 60
        if hours > 0 { return "剩余 \(hours) 小时 \(minutes % 60) 分" }
        return "剩余 \(minutes) 分钟"
    }

    func enable(duration: TimeInterval?, keepDisplayAwake: Bool) {
        disable()
        lastError = nil
        self.keepDisplayAwake = keepDisplayAwake

        let reason = "WonderBox 保持 Mac 唤醒" as CFString
        var systemID: IOPMAssertionID = 0
        let systemResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &systemID
        )
        guard systemResult == kIOReturnSuccess else {
            lastError = "系统拒绝了唤醒请求（\(systemResult)）"
            return
        }
        assertionIDs.append(systemID)

        if keepDisplayAwake {
            var displayID: IOPMAssertionID = 0
            let displayResult = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &displayID
            )
            if displayResult == kIOReturnSuccess {
                assertionIDs.append(displayID)
            }
        }

        isActive = true
        expiresAt = duration.map { Date().addingTimeInterval($0) }
        remaining = duration
        startCountdown()
    }

    func disable() {
        countdownTask?.cancel()
        countdownTask = nil
        for id in assertionIDs {
            IOPMAssertionRelease(id)
        }
        assertionIDs.removeAll()
        isActive = false
        expiresAt = nil
        remaining = nil
    }

    private func startCountdown() {
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let expiresAt = self.expiresAt {
                    let value = expiresAt.timeIntervalSinceNow
                    if value <= 0 {
                        self.disable()
                        return
                    }
                    self.remaining = value
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
