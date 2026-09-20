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
        guard let remaining else { return String(localized: "On indefinitely") }
        return String(localized: "\(AppFormatters.duration(remaining)) left")
    }

    func enable(duration: TimeInterval?, keepDisplayAwake: Bool) {
        disable()
        lastError = nil
        self.keepDisplayAwake = keepDisplayAwake

        let reason = "WonderBox is keeping the Mac awake" as CFString
        var systemID: IOPMAssertionID = 0
        let systemResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &systemID
        )
        guard systemResult == kIOReturnSuccess else {
            lastError = String(localized: "The system rejected the wake request (\(systemResult))")
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
