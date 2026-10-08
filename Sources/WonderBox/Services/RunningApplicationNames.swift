import AppKit
import Foundation

/// Names of running GUI applications in the same normalized form Electron and Chromium use for their
/// user-data folders, so `Application Support/<Folder>` can be matched against a live process.
enum RunningApplicationNames {
    @MainActor
    static func current() -> Set<String> {
        var names = Set<String>()
        for application in NSWorkspace.shared.runningApplications {
            if application.activationPolicy == .prohibited {
                // Mini-program and background helpers can keep messaging caches open after the main
                // window closes. Preserve their identifiers without changing generic browser aliases.
                if let id = application.bundleIdentifier, MessagingApplication.allCases.contains(where: { $0.matches(id) }) {
                    names.insert(normalize(id))
                }
                continue
            }
            let bundle = application.bundleURL.flatMap(Bundle.init(url:))
            let candidates: [String?] = [
                application.localizedName,
                bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
                bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                application.executableURL?.lastPathComponent,
                application.bundleIdentifier,
                application.bundleIdentifier?.split(separator: ".").last.map(String.init)
            ]
            for candidate in candidates.compactMap({ $0 }) {
                names.insert(normalize(candidate))
            }
        }
        return names
    }

    /// "Cherry Studio", "CherryStudio" and "cherry-studio" all describe the same app.
    static func normalize(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }
}
