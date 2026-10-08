import Foundation

enum RelatedFileCategory: String, CaseIterable, Identifiable {
    case support, caches, preferences, containers, logs, startup, other
    var id: Self { self }
    var title: String {
        switch self {
        case .support: String(localized: "Application Support")
        case .caches: String(localized: "Caches")
        case .preferences: String(localized: "Preferences")
        case .containers: String(localized: "Containers")
        case .logs: String(localized: "Logs and Reports")
        case .startup: String(localized: "Startup and Helpers")
        case .other: String(localized: "Other Files")
        }
    }

    static func category(for url: URL) -> Self {
        let components = url.standardizedFileURL.pathComponents
        if components.contains("Caches") || components.contains("HTTPStorages") || components.contains("WebKit")
            || (components.contains("folders") && (components.contains("C") || components.contains("T"))) { return .caches }
        if components.contains("Preferences") || components.contains("Cookies") || components.contains("Saved Application State") { return .preferences }
        if components.contains("Containers") || components.contains("Group Containers") { return .containers }
        if components.contains("Logs") || components.contains("CrashReporter") { return .logs }
        if components.contains("LaunchAgents") || components.contains("LaunchDaemons") || components.contains("PrivilegedHelperTools") { return .startup }
        if components.contains("Application Support") || components.contains("Application Scripts") { return .support }
        return .other
    }
}

struct RelatedFileGroup: Identifiable {
    var id: RelatedFileCategory { category }
    let category: RelatedFileCategory
    let files: [RelatedFile]
    var size: UInt64 { files.reduce(0) { $0 + $1.size } }
    var selectedCount: Int { files.filter(\.isSelected).count }

    static func groups(for files: [RelatedFile]) -> [Self] {
        let grouped = Dictionary(grouping: files) { RelatedFileCategory.category(for: $0.url) }
        return RelatedFileCategory.allCases.compactMap { category in
            guard let items = grouped[category], !items.isEmpty else { return nil }
            return Self(category: category, files: items.sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending })
        }
    }
}
