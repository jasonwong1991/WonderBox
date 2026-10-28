import Darwin
import Foundation

/// Cookie privacy is enforced for the calling app, not inherited from an
/// administrator password or from Finder. Never retry these denials as root.
enum UninstallFileAccess {
    static func isCookieLocation(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = url.standardizedFileURL.path
        let library = home.standardizedFileURL.appendingPathComponent("Library").path
        let cookies = library + "/Cookies"
        if path == cookies || path.hasPrefix(cookies + "/") { return true }
        let relative = path.hasPrefix(library + "/Containers/") || path.hasPrefix(library + "/Group Containers/")
        return relative && (path.hasSuffix("/Library/Cookies") || path.contains("/Library/Cookies/"))
    }

    static func isPermissionDenial(_ error: NSError) -> Bool {
        var current: NSError? = error
        for _ in 0..<8 {
            guard let value = current else { return false }
            if value.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(value.code) { return true }
            if value.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(value.code) { return true }
            if value.domain == NSOSStatusErrorDomain && value.code == -5000 { return true }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    static var cookieAccessMessage: String {
        String(localized: "macOS denied access to Cookies. Administrator authorization does not grant privacy access. Give this copy of WonderBox Full Disk Access, quit and reopen WonderBox, then retry. Other selected files were processed independently.")
    }
}

struct DirectTrashResult: Sendable {
    var moved = 0
    var failed: [URL] = []
    var privacyDenied: [URL] = []
    var errors: [URL: NSError] = [:]

    static func attempt(_ urls: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        presence: (URL) -> FilePresence = FilePresence.check,
                        move: (URL) throws -> Void = { url in
                            var destination: NSURL?
                            try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
                        }) -> Self {
        var result = Self()
        var seen = Set<URL>()
        for url in urls where url.isFileURL && seen.insert(url.standardizedFileURL).inserted {
            guard presence(url) != .missing else { continue }
            if Task.isCancelled { result.failed.append(url); continue }
            do {
                try move(url)
                if presence(url) == .missing { result.moved += 1 }
                else { result.failed.append(url) }
            } catch {
                result.failed.append(url)
                result.errors[url] = error as NSError
                if UninstallFileAccess.isCookieLocation(url, home: home), UninstallFileAccess.isPermissionDenial(error as NSError) {
                    result.privacyDenied.append(url)
                }
                if SystemTrashService.isCancellation(error as NSError) {
                    // The caller must not retry remaining items after a cancelled operation.
                    break
                }
            }
        }
        // Cancellation must leave every not-yet-processed source in the retry list.
        for url in urls where url.isFileURL && !seen.contains(url.standardizedFileURL) && presence(url) != .missing {
            if !result.failed.contains(url) { result.failed.append(url) }
        }
        return result
    }
}
