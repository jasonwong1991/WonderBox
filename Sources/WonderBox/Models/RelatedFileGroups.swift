import Foundation

enum RelatedFileCategory: String, CaseIterable, Identifiable {
    case support, caches, preferences, containers, logs, startup, autosaves, plugins, other
    var id: Self { self }
    var title: String {
        switch self {
        case .support: String(localized: "Application Support")
        case .caches: String(localized: "Caches")
        case .preferences: String(localized: "Preferences")
        case .containers: String(localized: "Containers")
        case .logs: String(localized: "Logs and Reports")
        case .startup: String(localized: "Startup and Helpers")
        case .autosaves: String(localized: "Autosave Data")
        case .plugins: String(localized: "Plugins")
        case .other: String(localized: "Other Files")
        }
    }

    static func category(for url: URL) -> Self {
        let components = url.standardizedFileURL.pathComponents
        if components.contains("Autosave Information") { return .autosaves }
        if RelatedFileLocations.pluginRoots.contains(where: { url.path.contains("/" + $0.path + "/") && $0.extensions.contains(url.pathExtension.lowercased()) }) { return .plugins }
        if components.contains(".cache") { return .caches }
        if components.contains(".config") || url.path.contains("/.local/state/") { return .preferences }
        if url.path.contains("/.local/share/") { return .support }
        if url.deletingLastPathComponent().lastPathComponent == "Library" { return .support }
        if components.contains("Caches") || components.contains("HTTPStorages") || components.contains("WebKit") { return .caches }
        if components.contains("Preferences") || components.contains("Cookies") || components.contains("Saved Application State") { return .preferences }
        if components.contains("Containers") || components.contains("Group Containers") { return .containers }
        if components.contains("Logs") || components.contains("CrashReporter") { return .logs }
        if components.contains("LaunchAgents") || components.contains("LaunchDaemons") || components.contains("PrivilegedHelperTools") { return .startup }
        if components.contains("Application Support") || components.contains("Application Scripts") { return .support }
        // A temporary test home can itself live below /var/folders/…/T. Its actual Library
        // structure takes precedence over that ancestor; real Darwin cache roots fall back here.
        if components.contains("folders") && (components.contains("C") || components.contains("T")) { return .caches }
        return .other
    }
}

struct RelatedFileGroup: Identifiable {
    var id: RelatedFileCategory { category }
    let category: RelatedFileCategory
    let files: [RelatedFile]
    var size: UInt64 { files.reduce(0) { ApplicationStorageUsage.add($0, $1.size) } }
    var selectedCount: Int { files.filter(\.isSelected).count }

    static func groups(for files: [RelatedFile]) -> [Self] {
        let grouped = Dictionary(grouping: files) { RelatedFileCategory.category(for: $0.url) }
        return RelatedFileCategory.allCases.compactMap { category in
            guard let items = grouped[category], !items.isEmpty else { return nil }
            return Self(category: category, files: items.sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending })
        }
    }
}
