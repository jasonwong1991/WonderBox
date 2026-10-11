import Darwin
import Foundation

enum FilePresence: Equatable {
    case present, missing, inaccessible

    static func check(_ url: URL) -> Self {
        var info = stat()
        if lstat(url.path, &info) == 0 { return .present }
        // fileExists returns false for permission errors too: that is not proof of removal.
        return errno == ENOENT || errno == ENOTDIR ? .missing : .inaccessible
    }
}

enum ContainerMetadata {
    static func identifier(at url: URL) -> String? {
        guard let container = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              container.isDirectory == true, container.isSymbolicLink != true else { return nil }
        let metadata = url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let values = try? metadata.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]),
              values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? Int.max) < 1_048_576,
              let data = try? Data(contentsOf: metadata),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["MCMMetadataIdentifier"] as? String
    }
}

struct RelatedFileScan: Sendable {
    var files: [RelatedFile]
    var inaccessibleLocations: [URL]
    var identity: ApplicationRelatedIdentity? = nil
    var isDiscoveryComplete = true

    var accessMessage: String? {
        if !isDiscoveryComplete && inaccessibleLocations.isEmpty {
            return String(localized: "Some plugin locations exceeded the inspection limit. The related-file list may be incomplete.")
        }
        if inaccessibleLocations.isEmpty {
            return identity?.isComplete == false ? String(localized: "Some application components could not be inspected. The related-file list may be incomplete.") : nil
        }
        return String(localized: "Some locations could not be read. The related-file list may be incomplete. Grant Full Disk Access, then rescan.")
    }
}

enum RelatedFileScanner {
    // A product name is not proof of ownership of macOS's shared Library folders.
    static let sharedLibraryDirectories: Set<String> = Set([
        "Accounts", "Apple", "Application Scripts", "Application Support", "Assistant", "Assistants", "Audio", "Autosave Information",
        "Caches", "Calendars", "CloudStorage", "ColorPickers", "Colors", "Compositions", "Containers", "Cookies",
        "Developer", "Dictionaries", "Favorites", "FontCollections", "Fonts", "Frameworks", "Group Containers",
        "HTTPStorages", "IdentityServices", "Input Methods", "Internet Plug-Ins", "Keychains", "LaunchAgents",
        "LaunchDaemons", "Logs", "Mail", "Messages", "Metadata", "Mobile Documents", "Passes", "Photos",
        "PreferencePanes", "Preferences", "Printers", "PrivilegedHelperTools", "Safari", "Saved Application State",
        "Screen Savers", "Services", "Sounds", "Spotlight", "WebKit", "QuickLook", "QuickTime", "ColorSync",
        "Components", "Contextual Menu Items", "Documentation", "Extensions", "Keyboards", "Scripting Additions", "StartupItems", "Widgets", "Web Server"
    ].map { $0.lowercased() })
    struct Discovery {
        var urls: [URL] = []
        var inaccessibleLocations: [URL] = []
        var associations: [URL: RelatedFileAssociation] = [:]
        var isComplete = true
    }

    static func children(_ url: URL) throws -> [URL] {
        // Fetch names only. Inspecting every child's resource values here turns a shallow
        // lookup into thousands of eager metadata requests for each Library root.
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [], options: [])
    }

    /// Shallow discovery (one extra vendor level), plus exact probes when lookup but not enumeration is allowed.
    /// UUID containers are matched by their own metadata, never by searching their contents.
    static func discover(for application: InstalledApplication, home: URL, systemLibrary: URL,
                         temporaryDirectories: [URL], list: (URL) throws -> [URL] = children,
                         containerIdentifier: (URL) -> String? = ContainerMetadata.identifier,
                         launchMetadata: (URL) -> [String: Any]? = ApplicationIdentityScanner.metadata,
                         bundleMetadata: (URL) -> [String: Any]? = ApplicationIdentityScanner.metadata,
                         maximumPluginInspections: Int = 512) -> Discovery {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let identifier = application.bundleIdentifier.flatMap { validComponent($0) && !$0.hasPrefix(".") ? $0 : nil }
        let identity = application.relatedIdentity ?? ApplicationRelatedIdentity()
        let names = Set(([application.name, application.url.deletingPathExtension().lastPathComponent] + application.relatedNames + identity.dataNames).filter { validComponent($0) && !$0.hasPrefix(".") })
        let lowerNames = Set(names.map { $0.lowercased() })
        typealias Rule = (root: URL, matches: (String) -> Bool, exact: [String], container: Bool)
        var rules: [Rule] = []
        var componentRules: [Rule] = []
        let identifiers = (identifier.map { [$0] } ?? []) + identity.componentIdentifiers.filter(ApplicationIdentityScanner.validIdentifier)
        for identifier in Set(identifiers).sorted() {
            var identifierRules: [Rule] = []
            let byIdentifier: (String) -> Bool = { ApplicationScanner.belongs($0, toIdentifier: identifier) }
            let userRoots = ["Application Scripts", "Application Support", "Caches", "Containers", "Cookies", "Group Containers",
                             "HTTPStorages", "LaunchAgents", "Logs", "Preferences", "Preferences/ByHost", "Saved Application State", "WebKit"]
            let systemRoots = ["Application Support", "Caches", "LaunchAgents", "LaunchDaemons", "Logs", "Preferences", "PrivilegedHelperTools"]
            for root in userRoots {
                let exact = [identifier, identifier + ".plist", identifier + ".binarycookies", identifier + ".savedState"]
                identifierRules.append((library.appendingPathComponent(root), byIdentifier, exact, ["Containers", "Group Containers"].contains(root)))
            }
            for root in systemRoots {
                identifierRules.append((systemLibrary.appendingPathComponent(root), byIdentifier, [identifier, identifier + ".plist"], false))
            }
            identifierRules += temporaryDirectories.map { ($0, byIdentifier, [identifier], false) }
            if identifier == application.bundleIdentifier { rules += identifierRules }
            else { componentRules += identifierRules }
        }
        let byName: (String) -> Bool = { lowerNames.contains($0.lowercased()) }
        let directNames = names.filter { !sharedLibraryDirectories.contains($0.lowercased()) && !$0.hasPrefix(".") }
        let directIdentifier = identifier.map { [$0] } ?? []
        let directMatches = Set((Array(directNames) + directIdentifier).map { $0.lowercased() })
        rules.append((library, { directMatches.contains($0.lowercased()) && !sharedLibraryDirectories.contains($0.lowercased()) },
                      Array(directNames) + directIdentifier.filter { !sharedLibraryDirectories.contains($0.lowercased()) }, false))
        rules += ["Application Support", "Caches", "Logs"].map { (library.appendingPathComponent($0), byName, Array(names), false) }
        rules += ["Application Support", "Logs"].map { (systemLibrary.appendingPathComponent($0), byName, Array(names), false) }
        let byLogName: (String) -> Bool = { candidate in
            lowerNames.contains { name in
                let lower = candidate.lowercased()
                if lower == name + ".log" { return true }
                let prefix = name + ".log."
                return lower.hasPrefix(prefix) && !lower.dropFirst(prefix.count).isEmpty
                    && lower.dropFirst(prefix.count).allSatisfy(\.isNumber)
            }
        }
        rules.append((library.appendingPathComponent("Logs"), byLogName, names.map { $0 + ".log" }, false))
        let namedPreferences = Set(names.map { ($0 + ".plist").lowercased() })
        rules.append((library.appendingPathComponent("Preferences"), { namedPreferences.contains($0.lowercased()) },
                      names.map { $0 + ".plist" }, false))
        let byHostName: (String) -> Bool = { candidate in
            guard candidate.lowercased().hasSuffix(".plist") else { return false }
            let stem = String(candidate.dropLast(6))
            return names.contains { name in
                for separator in ["_", "."] {
                    let prefix = name + separator
                    if stem.lowercased().hasPrefix(prefix.lowercased()), UUID(uuidString: String(stem.dropFirst(prefix.count))) != nil { return true }
                }
                return false
            }
        }
        rules.append((library.appendingPathComponent("Preferences/ByHost"), byHostName, [], false))
        let byPrefix: (String) -> Bool = { name in lowerNames.contains { name.lowercased().hasPrefix($0 + "_") || name.lowercased().hasPrefix($0 + "-") } }
        rules += ["Application Support/CrashReporter", "Logs/DiagnosticReports"].map { (library.appendingPathComponent($0), byPrefix, [], false) }

        var result = Discovery()
        var seen = Set<URL>()
        struct Identity: Hashable { let device: dev_t; let inode: ino_t }
        var identities = Set<Identity>()
        var unreadable = Set<URL>()
        var listings: [URL: [URL]] = [:]
        func listing(_ root: URL) -> [URL] {
            let root = root.standardizedFileURL
            if let cached = listings[root] { return cached }
            do {
                let children = try list(root).filter { $0.deletingLastPathComponent().standardizedFileURL == root }
                listings[root] = children
                return children
            } catch {
                listings[root] = []
                if FilePresence.check(root) != .missing { unreadable.insert(root) }
                return []
            }
        }
        func append(_ url: URL, association: RelatedFileAssociation = .standard) {
            let url = url.standardizedFileURL
            if url.deletingLastPathComponent() == library.appendingPathComponent("Caches").standardizedFileURL,
               RelatedFileLocations.sharedCacheRoots.contains(where: { $0.lowercased() == url.lastPathComponent.lowercased() }) { return }
            guard FilePresence.check(url) != .missing,
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
            // Shared group data stays opt-in even when a name rule also finds it.
            let association: RelatedFileAssociation = url.deletingLastPathComponent().lastPathComponent == "Group Containers" ? .applicationGroup : association
            if let previous = result.associations[url] {
                if association == .applicationGroup || association == .declaredHelper { result.associations[url] = association }
                else if previous == .embeddedComponent && association == .standard { result.associations[url] = association }
                return
            }
            var info = stat()
            if lstat(url.path, &info) == 0, !identities.insert(Identity(device: info.st_dev, inode: info.st_ino)).inserted { return }
            if seen.insert(url).inserted { result.urls.append(url); result.associations[url] = association }
        }
        var associatedRules = rules.map { ($0, RelatedFileAssociation.standard) }
        associatedRules += componentRules.map { ($0, RelatedFileAssociation.embeddedComponent) }
        // Autosave folders can contain unsaved work; XDG leaves can be shared with a CLI.
        // Keep both opt-in even if an identifier exactly matches the selected app.
        let dataLeaves = Set(Array(names) + identifiers).sorted()
        let lowerDataLeaves = Set(dataLeaves.map { $0.lowercased() })
        let exactDataName: (String) -> Bool = { lowerDataLeaves.contains($0.lowercased()) }
        associatedRules.append(((library.appendingPathComponent("Autosave Information"), exactDataName, dataLeaves, false), .autosaveData))
        for path in RelatedFileLocations.xdgRoots {
            associatedRules.append(((home.appendingPathComponent(path), exactDataName, dataLeaves, false), .crossPlatformData))
        }
        for id in Set(identifiers) {
            let recentNames = RelatedFileLocations.recentDocumentExtensions.map { id + "." + $0 }
            let lowered = Set(recentNames.map { $0.lowercased() })
            associatedRules.append(((library.appendingPathComponent(RelatedFileLocations.recentDocuments),
                                     { lowered.contains($0.lowercased()) }, recentNames, false),
                                    id == identifier ? .standard : .embeddedComponent))
        }
        let legacyNames = identity.legacyDataNames.filter(ElectronDataIdentityScanner.validName)
        if !legacyNames.isEmpty {
            let lowered = Set(legacyNames.map { $0.lowercased() })
            let rule: Rule = (library.appendingPathComponent("Application Support"), { lowered.contains($0.lowercased()) }, legacyNames, false)
            associatedRules.append((rule, .legacyData))
        }
        for group in identity.applicationGroups.filter(ApplicationIdentityScanner.validIdentifier) {
            for root in ["Group Containers", "Application Scripts"] {
                let rule: Rule = (library.appendingPathComponent(root), { $0 == group }, [group], root == "Group Containers")
                associatedRules.append((rule, .applicationGroup))
            }
            let preferences: Rule = (library.appendingPathComponent("Preferences"), { $0 == group + ".plist" }, [group + ".plist"], false)
            associatedRules.append((preferences, .applicationGroup))
            let byHost: Rule = (library.appendingPathComponent("Preferences/ByHost"), { candidate in
                guard candidate.hasPrefix(group + "."), candidate.hasSuffix(".plist") else { return false }
                return UUID(uuidString: String(candidate.dropFirst(group.count + 1).dropLast(6))) != nil
            }, [], false)
            associatedRules.append((byHost, .applicationGroup))
        }
        for helper in identity.declaredHelperIdentifiers.filter(ApplicationIdentityScanner.validIdentifier) {
            for root in ["LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools"] {
                let rule: Rule = (systemLibrary.appendingPathComponent(root), { $0 == helper || $0 == helper + ".plist" }, [helper, helper + ".plist"], false)
                associatedRules.append((rule, .declaredHelper))
            }
        }
        for (rule, association) in associatedRules {
            if Task.isCancelled { break }
            let root = rule.root.standardizedFileURL
            // Do not follow a replaced support root outside the known location.
            if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            let base = root.path.hasPrefix(home.path + "/") ? home : systemLibrary
            if root.path.hasPrefix(base.path + "/"), !ApplicationIdentityScanner.noSymlinkComponents(root, below: base) { continue }
            for url in listing(root) {
                if rule.matches(url.lastPathComponent) { append(url, association: association) }
                else if rule.container, let owner = containerIdentifier(url) {
                    if identity.applicationGroups.contains(owner) { append(url, association: .applicationGroup) }
                    else if identifiers.contains(where: { ApplicationScanner.belongs(owner, toIdentifier: $0) }) {
                        append(url, association: identifier.map { ApplicationScanner.belongs(owner, toIdentifier: $0) } == true ? association : .embeddedComponent)
                    }
                }
            }
            for name in rule.exact { append(root.appendingPathComponent(name), association: association) }
        }
        // Shared updater/crash SDK caches are one known level deeper than normal caches.
        // Exact probes only: a user's app cache may contain millions of unrelated entries.
        for path in RelatedFileLocations.sharedCacheRoots {
            let root = library.appendingPathComponent("Caches").appendingPathComponent(path)
            guard ApplicationIdentityScanner.noSymlinkComponents(root, below: home) else { continue }
            for name in dataLeaves {
                if Task.isCancelled { break }
                let leaf = root.appendingPathComponent(name)
                if FilePresence.check(leaf) == .present { append(leaf, association: .vendorSubfolder) }
            }
        }
        // External plugins are associated by their own exact bundle identifier, never
        // filename, vendor prefix or framework/team identity. Inspect bounded plists only.
        let pluginOwners = Set(identifiers.map { $0.lowercased() })
        var pluginInspections = 0
        if !pluginOwners.isEmpty {
            for baseLibrary in [library, systemLibrary] {
                let base = baseLibrary == library ? home : systemLibrary
                for location in RelatedFileLocations.pluginRoots {
                    let root = baseLibrary.appendingPathComponent(location.path)
                    guard ApplicationIdentityScanner.noSymlinkComponents(root, below: base) else { continue }
                    for plugin in listing(root) where location.extensions.contains(plugin.pathExtension.lowercased()) {
                        if Task.isCancelled { break }
                        guard ApplicationIdentityScanner.isMaterializedDirectory(plugin) else { continue }
                        guard pluginInspections < maximumPluginInspections else { result.isComplete = false; break }
                        pluginInspections += 1
                        let infoPaths = ["Contents/Info.plist", "Info.plist"]
                        for path in infoPaths {
                            let info = plugin.appendingPathComponent(path)
                            guard FilePresence.check(info) != .missing else { continue }
                            if ApplicationIdentityScanner.noSymlinkComponents(info, below: base),
                               let values = bundleMetadata(info),
                               let owner = values["CFBundleIdentifier"] as? String,
                               pluginOwners.contains(owner.lowercased()) {
                                append(plugin, association: .externalPlugin)
                            }
                            // A flat fallback must not override a different/malformed canonical
                            // bundle plist, or bypass a linked/unreadable Contents/Info.plist.
                            break
                        }
                    }
                }
            }
        }
        // Probe exact product leaves one level below vendor directories. Do NOT enumerate
        // each vendor/product's children: a photo or chat app may have millions of them.
        // Case-insensitive filesystems resolve these aliases; inode dedup handles duplicates.
        let vendorLeaves = Set(Array(names) + identifiers)
        for root in [library.appendingPathComponent("Application Support"), systemLibrary.appendingPathComponent("Application Support")] {
            let base = root.path.hasPrefix(library.path + "/") ? home : systemLibrary
            guard ApplicationIdentityScanner.noSymlinkComponents(root, below: base) else { continue }
            for vendor in listing(root) where !seen.contains(vendor.standardizedFileURL) && ApplicationIdentityScanner.isMaterializedDirectory(vendor) {
                if Task.isCancelled { break }
                for name in vendorLeaves {
                    let child = vendor.appendingPathComponent(name)
                    // An unreadable unrelated vendor is not proof that an app-named leaf
                    // exists. Do not create phantom matches from permission-denied probes.
                    if FilePresence.check(child) == .present { append(child, association: .vendorSubfolder) }
                }
            }
        }
        // A launch label need not resemble the bundle identifier. Associate only a literal
        // executable path inside this bundle; do not search arbitrary arguments or scripts.
        for root in [library.appendingPathComponent("LaunchAgents"), systemLibrary.appendingPathComponent("LaunchAgents"), systemLibrary.appendingPathComponent("LaunchDaemons")] {
            let base = root.path.hasPrefix(library.path + "/") ? home : systemLibrary
            guard ApplicationIdentityScanner.noSymlinkComponents(root, below: base) else { continue }
            for item in listing(root) where item.pathExtension == "plist" {
                if Task.isCancelled { break }
                guard let plist = launchMetadata(item),
                      let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first,
                      program.hasPrefix("/"),
                      URL(fileURLWithPath: program).standardizedFileURL.path.hasPrefix(application.url.standardizedFileURL.path + "/")
                else { continue }
                append(item, association: .launchItem)
            }
        }
        result.inaccessibleLocations = unreadable.sorted { $0.path < $1.path }
        result.urls.sort { $0.path < $1.path }
        return result
    }

    static func scan(for application: InstalledApplication, home: URL, systemLibrary: URL, temporaryDirectories: [URL],
                     list: (URL) throws -> [URL] = children,
                     containerIdentifier: (URL) -> String? = ContainerMetadata.identifier,
                     launchMetadata: (URL) -> [String: Any]? = ApplicationIdentityScanner.metadata,
                     bundleMetadata: (URL) -> [String: Any]? = ApplicationIdentityScanner.metadata,
                     maximumPluginInspections: Int = 512,
                     inspectContents: Bool = true,
                     measure: (URL) -> AllocatedSizeMeasurement = { ApplicationDataSize.measure($0) }) -> RelatedFileScan {
        let discovered = discover(for: application, home: home, systemLibrary: systemLibrary, temporaryDirectories: temporaryDirectories,
                                  list: list, containerIdentifier: containerIdentifier, launchMetadata: launchMetadata,
                                  bundleMetadata: bundleMetadata, maximumPluginInspections: maximumPluginInspections)
        var inaccessible = Set(discovered.inaccessibleLocations)
        let roots = ApplicationStorageUsage.uniqueRoots(discovered.urls.map {
            let association = discovered.associations[$0] ?? .standard
            return RelatedFile(url: $0, displayPath: $0.path, size: 0, isSelected: !association.requiresReview, association: association)
        })
        let files = roots.map { root -> RelatedFile in
            let url = root.url
            if FilePresence.check(url) == .inaccessible { inaccessible.insert(url) }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if inspectContents && isDirectory && ApplicationIdentityScanner.isMaterializedDirectory(url) {
                // Surface container access failures instead of presenting an unreadable 0-byte folder as empty.
                do { _ = try list(url) } catch { inaccessible.insert(url) }
                if ["Containers", "Group Containers"].contains(url.deletingLastPathComponent().lastPathComponent) {
                    let data = url.appendingPathComponent("Data")
                    if FilePresence.check(data) != .missing {
                        do { _ = try list(data) } catch { inaccessible.insert(data) }
                    }
                }
            }
            let prefix = home.standardizedFileURL.path + "/"
            let measurement = measure(url)
            inaccessible.formUnion(measurement.inaccessible)
            return RelatedFile(url: url, displayPath: url.path.hasPrefix(prefix) ? "~/" + url.path.dropFirst(prefix.count) : url.path,
                               size: measurement.bytes, isSelected: root.isSelected, isSizeComplete: measurement.isComplete,
                               hasMeasuredSize: measurement.hasMeasuredSize, association: root.association)
        }.sorted { $0.size == $1.size ? $0.url.path < $1.url.path : $0.size > $1.size }
        return RelatedFileScan(files: files, inaccessibleLocations: inaccessible.sorted { $0.path < $1.path }, identity: application.relatedIdentity,
                               isDiscoveryComplete: discovered.isComplete)
    }

    /// Retain failed/unchecked items and require explicit selection for newly discovered leftovers.
    /// Never delete fresh discoveries automatically after the original confirmation.
    static func remainingFiles(previous: [RelatedFile], scanned: [RelatedFile], presence: (URL) -> FilePresence = FilePresence.check) -> [RelatedFile] {
        let selections = Dictionary(previous.map { ($0.url.standardizedFileURL, $0.isSelected) }, uniquingKeysWith: { first, _ in first })
        var retained: [URL: RelatedFile] = [:]
        for var file in scanned {
            file.isSelected = selections[file.url.standardizedFileURL] ?? false
            retained[file.url.standardizedFileURL] = file
        }
        for file in previous where retained[file.url.standardizedFileURL] == nil && presence(file.url) != .missing {
            retained[file.url.standardizedFileURL] = file
        }
        return retained.values.sorted { $0.size == $1.size ? $0.url.path < $1.url.path : $0.size > $1.size }
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.utf8.contains(0)
    }
}
