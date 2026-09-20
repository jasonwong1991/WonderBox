import Foundation

enum MaintenanceController {
    @MainActor
    static func cleanSystemCaches() -> String {
        guard let helper = HelperLocator.executable(named: "WonderMaintenanceHelper") else {
            return String(localized: "The maintenance helper is not installed")
        }
        switch AdministratorShell.run("\(AdministratorShell.quote(helper.path)) clean-system-caches") {
        case let .success(output):
            return output.isEmpty ? String(localized: "System caches cleaned") : L10n.message(output)
        case let .failure(failure):
            return failure.isCancelled ? String(localized: "System cache authorization was cancelled") : failure.message
        }
    }
}
