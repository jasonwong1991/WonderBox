import Foundation

enum MaintenanceController {
    @MainActor
    static func cleanSystemCaches() -> String {
        guard let helper = HelperLocator.executable(named: "WonderMaintenanceHelper") else {
            return "维护 helper 未安装"
        }
        switch AdministratorShell.run("\(AdministratorShell.quote(helper.path)) clean-system-caches") {
        case let .success(output):
            return output.isEmpty ? "系统缓存已清理" : output
        case let .failure(failure):
            return failure.isCancelled ? "系统缓存授权已取消" : failure.message
        }
    }
}
