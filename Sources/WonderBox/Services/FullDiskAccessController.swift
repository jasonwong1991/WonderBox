import AppKit
import Darwin
import Foundation

enum FullDiskAccessStatus: Equatable, Sendable {
    case authorized
    case denied
    case unavailable

    var title: String {
        switch self {
        case .authorized: "已授权"
        case .denied: "未授权"
        case .unavailable: "待检查"
        }
    }
}

enum FullDiskAccessController {
    static var isSupported: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
    }

    static func currentStatus() -> FullDiskAccessStatus {
        guard isSupported else { return .unavailable }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return status(checking: [
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
            home.appendingPathComponent("Library/Safari/History.db")
        ])
    }

    static func status(checking candidates: [URL]) -> FullDiskAccessStatus {
        var foundProtectedFile = false
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            foundProtectedFile = true
            let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
            if descriptor >= 0 {
                close(descriptor)
                return .authorized
            }
            if errno == EACCES || errno == EPERM {
                return .denied
            }
        }
        return foundProtectedFile ? .denied : .unavailable
    }

    @MainActor
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
