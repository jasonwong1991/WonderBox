import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var message: String?
    @Published private(set) var requiresApproval = SMAppService.mainApp.status == .requiresApproval

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        requiresApproval = status == .requiresApproval
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            message = nil
        } catch {
            refresh()
            message = error.localizedDescription
        }
    }
}
