import Foundation

enum MaintenanceController {
    @MainActor
    static func cleanSystemCaches() -> String {
        guard let helper = HelperLocator.executable(named: "WonderMaintenanceHelper") else {
            return String(localized: "The maintenance helper is not installed")
        }
        switch AdministratorShell.run("\(AdministratorShell.quote(helper.path)) clean-system-caches") {
        case let .success(output):
            DiagnosticLogger.shared.record(.systemCachesCleaned)
            return output.isEmpty ? String(localized: "System caches cleaned") : L10n.message(output)
        case let .failure(failure):
            DiagnosticLogger.shared.record(.systemCachesCleaned, outcome: failure.isCancelled ? .cancelled : .failure,
                                           errorFamily: .helper, metrics: [.errorCode: Int64(failure.code)])
            return failure.isCancelled ? String(localized: "System cache authorization was cancelled") : failure.message
        }
    }
}
