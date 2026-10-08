import Foundation

struct CacheApplicationIdentity: Equatable, Sendable {
    let id: String
    let name: String
    let bundleURL: URL?
    var aliases: Set<String> = []
}

struct ApplicationCacheGroup: Identifiable {
    let application: CacheApplicationIdentity
    let items: [CleanupItem]
    var id: String { application.id }
    var size: UInt64 { items.reduce(0) { $0 + $1.size } }
    var isSizeEstimated: Bool { items.allSatisfy(\.isSizeEstimated) }
    func selectedCount(in selection: Set<URL>) -> Int { items.filter { selection.contains($0.id) }.count }

    static func groups(_ items: [CleanupItem]) -> [Self] {
        let unknown = CacheApplicationIdentity(id: "unidentified", name: String(localized: "Other Caches"), bundleURL: nil)
        let indexed = Dictionary(grouping: items) { $0.application?.id ?? unknown.id }
        return indexed.map { key, items in
            Self(application: items.first?.application ?? unknown, items: items.sorted { $0.url.path < $1.url.path })
        }.sorted {
            if $0.id == "unidentified" { return false }
            if $1.id == "unidentified" { return true }
            return $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending
        }
    }
}

enum CacheApplicationCatalog {
    /// Metadata only; don't reuse application inventory here, because it recursively sizes bundles.
    static func discover(roots: [URL]? = nil) -> [CacheApplicationIdentity] {
        let roots = roots ?? [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                              URL(fileURLWithPath: "/System/Library/CoreServices"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var found: [String: CacheApplicationIdentity] = [:]
        for root in roots {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in files where url.pathExtension.lowercased() == "app" {
                if Task.isCancelled { return Array(found.values) }
                files.skipDescendants()
                guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { continue }
                let name = bundle.productName ?? url.deletingPathExtension().lastPathComponent
                let aliases = [name, url.deletingPathExtension().lastPathComponent, bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? name]
                let key = identifier.lowercased()
                if found[key] == nil { found[key] = CacheApplicationIdentity(id: key, name: name, bundleURL: url, aliases: Set(aliases.map(RunningApplicationNames.normalize))) }
            }
        }
        return Array(found.values)
    }

    static func resolve(_ url: URL, home: URL, catalog: [CacheApplicationIdentity]) -> CacheApplicationIdentity? {
        let path = url.standardizedFileURL.path
        let prefix = home.appendingPathComponent("Library").standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var components = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        if components.count >= 2, ["Containers", "Group Containers"].contains(components[0]) {
            let container = home.appendingPathComponent("Library/\(components[0])/\(components[1])")
            components[1] = MessagingCacheScanner.containerIdentifier(container) ?? components[1]
        }
        // Check the owner component, not descendants such as Cache/com.other.app.
        let owner = components.dropFirst().first ?? ""
        if let matched = catalog.filter({ ApplicationScanner.belongs(owner, toIdentifier: $0.id) })
            .max(by: { $0.id.count < $1.id.count }) { return matched }
        if let family = MessagingApplication.allCases.first(where: { $0.matches(owner) }) {
            return catalog.first { family.matches($0.id) }
                ?? CacheApplicationIdentity(id: family.identifiers[0], name: family.name, bundleURL: nil)
        }
        var names = Set<String>()
        let ownerComponents = Array(components.dropFirst().prefix(3))
        for start in ownerComponents.indices {
            for end in start..<ownerComponents.count { names.insert(RunningApplicationNames.normalize(ownerComponents[start...end].joined())) }
        }
        return catalog.filter { !$0.aliases.isDisjoint(with: names) }.sorted { $0.id < $1.id }.first
    }

    static func attribute(_ categories: inout [CleanupCategory], home: URL, catalog: [CacheApplicationIdentity]) {
        for categoryIndex in categories.indices where [.caches, .browserCaches, .wechatCaches, .wecomCaches].contains(categories[categoryIndex].kind) {
            for index in categories[categoryIndex].items.indices {
                categories[categoryIndex].items[index].application = resolve(categories[categoryIndex].items[index].url, home: home, catalog: catalog)
            }
        }
    }
}
