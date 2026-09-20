import AppKit
import Foundation

/// Runs fixed commands through the system administrator authorization prompt.
enum AdministratorShell {
    struct Failure: Error, Sendable {
        let message: String
        let isCancelled: Bool
    }

    @MainActor
    static func run(_ command: String) -> Result<String, Failure> {
        let source = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "授权已取消"
            return .failure(Failure(message: message, isCancelled: message == "User canceled."))
        }
        return .success(output?.stringValue ?? "")
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Locates helper executables and resources in the app bundle, next to the executable, or in the SwiftPM build tree.
enum HelperLocator {
    static func executable(named name: String) -> URL? {
        let manager = FileManager.default
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        if manager.isExecutableFile(atPath: bundled.path) { return bundled }

        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name)
        if let sibling, manager.isExecutableFile(atPath: sibling.path) { return sibling }

        let development = URL(fileURLWithPath: manager.currentDirectoryPath)
            .appendingPathComponent(".build/debug/\(name)")
        return manager.isExecutableFile(atPath: development.path) ? development : nil
    }

    static func resource(named name: String) -> URL? {
        let manager = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(name),
           manager.fileExists(atPath: bundled.path) {
            return bundled
        }
        let development = URL(fileURLWithPath: manager.currentDirectoryPath)
            .appendingPathComponent("Sources/WonderBox/Resources/\(name)")
        return manager.fileExists(atPath: development.path) ? development : nil
    }
}
