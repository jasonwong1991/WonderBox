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

    var accessMessage: String? {
        guard !inaccessibleLocations.isEmpty else { return nil }
        return String(localized: "Some locations could not be read. The related-file list may be incomplete. Grant Full Disk Access, then rescan.")
    }
}

enum RelatedFileScanner {
    struct Discovery {
        var urls: [URL] = []
        var inaccessibleLocations: [URL] = []
    }

    static func children(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
    }

    /// One-level discovery, plus exact probes when a root permits lookup but not enumeration.
    /// UUID containers are matched by their own metadata, never by searching their contents.
    static func discover(for application: InstalledApplication, home: URL, systemLibrary: URL,
                         temporaryDirectories: [URL], list: (URL) throws -> [URL] = children) -> Discovery {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let identifier = application.bundleIdentifier.flatMap { validComponent($0) ? $0 : nil }
        let names = Set([application.name, application.url.deletingPathExtension().lastPathComponent].filter(validComponent))
        let lowerNames = Set(names.map { $0.lowercased() })
        var rules: [(root: URL, matches: (String) -> Bool, exact: [String], container: Bool)] = []
        if let identifier {
            let byIdentifier: (String) -> Bool = { ApplicationScanner.belongs($0, toIdentifier: identifier) }
            let userRoots = ["Application Scripts", "Application Support", "Caches", "Containers", "Cookies", "Group Containers",
                             "HTTPStorages", "LaunchAgents", "Logs", "Preferences", "Preferences/ByHost", "Saved Application State", "WebKit"]
            let systemRoots = ["Application Support", "Caches", "LaunchAgents", "LaunchDaemons", "Logs", "Preferences", "PrivilegedHelperTools"]
            for root in userRoots {
                let exact = [identifier, identifier + ".plist", identifier + ".binarycookies", identifier + ".savedState"]
                rules.append((library.appendingPathComponent(root), byIdentifier, exact, ["Containers", "Group Containers"].contains(root)))
            }
            for root in systemRoots {
                rules.append((systemLibrary.appendingPathComponent(root), byIdentifier, [identifier, identifier + ".plist"], false))
            }
            rules += temporaryDirectories.map { ($0, byIdentifier, [identifier], false) }
        }
        let byName: (String) -> Bool = { lowerNames.contains($0.lowercased()) }
        rules += ["Application Support", "Caches", "Logs"].map { (library.appendingPathComponent($0), byName, Array(names), false) }
        rules += ["Application Support", "Logs"].map { (systemLibrary.appendingPathComponent($0), byName, Array(names), false) }
        let byPrefix: (String) -> Bool = { name in lowerNames.contains { name.lowercased().hasPrefix($0 + "_") || name.lowercased().hasPrefix($0 + "-") } }
        rules += ["Application Support/CrashReporter", "Logs/DiagnosticReports"].map { (library.appendingPathComponent($0), byPrefix, [], false) }

        var result = Discovery()
        var seen = Set<URL>()
        var unreadable = Set<URL>()
        var listings: [URL: [URL]] = [:]
        func append(_ url: URL) {
            let url = url.standardizedFileURL
            guard FilePresence.check(url) != .missing,
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
            if seen.insert(url).inserted { result.urls.append(url) }
        }
        for rule in rules {
            if Task.isCancelled { break }
            let root = rule.root.standardizedFileURL
            // Do not follow a replaced support root outside the known location.
            if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            if listings[root] == nil {
                do { listings[root] = try list(root) }
                catch {
                    listings[root] = []
                    if FilePresence.check(root) != .missing { unreadable.insert(root) }
                }
            }
            for url in listings[root] ?? [] {
                guard url.deletingLastPathComponent().standardizedFileURL == root else { continue }
                if rule.matches(url.lastPathComponent) { append(url) }
                else if rule.container, let identifier, let owner = ContainerMetadata.identifier(at: url),
                        ApplicationScanner.belongs(owner, toIdentifier: identifier) { append(url) }
            }
            for name in rule.exact { append(root.appendingPathComponent(name)) }
        }
        result.inaccessibleLocations = unreadable.sorted { $0.path < $1.path }
        result.urls.sort { $0.path < $1.path }
        return result
    }

    static func scan(for application: InstalledApplication, home: URL, systemLibrary: URL, temporaryDirectories: [URL]) -> RelatedFileScan {
        let discovered = discover(for: application, home: home, systemLibrary: systemLibrary, temporaryDirectories: temporaryDirectories)
        var inaccessible = Set(discovered.inaccessibleLocations)
        let files = discovered.urls.map { url -> RelatedFile in
            if FilePresence.check(url) == .inaccessible { inaccessible.insert(url) }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                // Surface container access failures instead of presenting an unreadable 0-byte folder as empty.
                do { _ = try children(url) } catch { inaccessible.insert(url) }
                if ["Containers", "Group Containers"].contains(url.deletingLastPathComponent().lastPathComponent) {
                    let data = url.appendingPathComponent("Data")
                    if FilePresence.check(data) != .missing {
                        do { _ = try children(data) } catch { inaccessible.insert(data) }
                    }
                }
            }
            let prefix = home.standardizedFileURL.path + "/"
            return RelatedFile(url: url, displayPath: url.path.hasPrefix(prefix) ? "~/" + url.path.dropFirst(prefix.count) : url.path,
                               size: FileSystemScanner.allocatedSize(of: url))
        }.sorted { $0.size == $1.size ? $0.url.path < $1.url.path : $0.size > $1.size }
        return RelatedFileScan(files: files, inaccessibleLocations: inaccessible.sorted { $0.path < $1.path })
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
