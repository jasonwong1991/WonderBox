import Darwin
import Foundation

/// Small metadata snapshots, never application contents. Shared by the opt-in login
/// item and the UI; a queued event conveys identity, not authority to delete paths.
public struct WatchedApplication: Codable, Equatable, Sendable {
    public let url: URL
    public let name: String
    public let bundleIdentifier: String
    public var relatedNames: [String]
    public var bookmark: Data?
    public var modifiedAt: Date?
    public var metadataStamp: String?

    public init(url: URL, name: String, bundleIdentifier: String, relatedNames: [String] = [], bookmark: Data? = nil, modifiedAt: Date? = nil, metadataStamp: String? = nil) {
        self.url = url; self.name = name; self.bundleIdentifier = bundleIdentifier
        self.relatedNames = relatedNames; self.bookmark = bookmark; self.modifiedAt = modifiedAt; self.metadataStamp = metadataStamp
    }
    public var relocatedURL: URL? {
        guard let bookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
    }
}

public struct UninstallWatchEvent: Codable, Identifiable, Sendable {
    public let id: UUID
    public let application: WatchedApplication
    public let createdAt: Date
    public init(application: WatchedApplication, createdAt: Date = Date()) {
        id = UUID(); self.application = application; self.createdAt = createdAt
    }
}

public enum UninstallWatchInventory {
    public static var roots: [URL] {
        [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }
    public static func isMissing(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) != 0 else { return false }
        return errno == ENOENT || errno == ENOTDIR
    }
    public static func isTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains(".Trash") || url.standardizedFileURL.pathComponents.contains(".Trashes")
    }
    public static func isWatchable(_ app: WatchedApplication, roots: [URL] = roots) -> Bool {
        let id = app.bundleIdentifier
        return app.url.isFileURL && app.url.pathExtension.lowercased() == "app"
            && roots.contains { app.url.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") }
            && id.contains(".") && !id.contains("/") && !id.contains("..")
            && !id.hasPrefix("com.apple.") && !id.hasPrefix("com.wondercraft.WonderBox")
    }

    /// An incomplete listing is never used as evidence of removal. Reuse bookmarks
    /// for unchanged bundles to keep event-triggered inventories metadata-only.
    public static func scan(roots: [URL] = roots, previous: [WatchedApplication] = [], captureBookmarks: Bool = true) -> (applications: [WatchedApplication], complete: Bool) {
        var complete = true
        var result: [WatchedApplication] = []
        let cached = Dictionary(previous.map { ($0.url, $0) }, uniquingKeysWith: { _, last in last })
        for root in roots {
            if isMissing(root) { continue }
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in complete = false; return true }) else { complete = false; continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                enumerator.skipDescendants()
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else { complete = false; continue }
                var rootInfo = stat(), plistInfo = stat()
                let hasStamp = lstat(url.path, &rootInfo) == 0 && lstat(url.appendingPathComponent("Contents/Info.plist").path, &plistInfo) == 0
                let stamp = hasStamp ? "\(rootInfo.st_dev):\(rootInfo.st_ino):\(plistInfo.st_ino):\(plistInfo.st_mtimespec.tv_sec):\(plistInfo.st_mtimespec.tv_nsec)" : nil
                if let old = cached[url], stamp != nil, old.metadataStamp == stamp, old.modifiedAt == values.contentModificationDate { result.append(old); continue }
                // Read the plist directly: Bundle caches metadata across in-place app upgrades.
                guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")), data.count <= 1_048_576,
                      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let id = info["CFBundleIdentifier"] as? String else {
                    // A malformed bundle is not an uninstallation. Retain its old identity
                    // if known, but don't let a pre-existing stub block every other app.
                    if let old = cached[url] { result.append(old) }
                    continue
                }
                let names = [info["CFBundleDisplayName"] as? String, info["CFBundleName"] as? String, url.deletingPathExtension().lastPathComponent].compactMap { $0 }
                let app = WatchedApplication(url: url.standardizedFileURL, name: names.first ?? url.lastPathComponent, bundleIdentifier: id,
                    relatedNames: names, bookmark: captureBookmarks ? try? url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil) : nil, modifiedAt: values.contentModificationDate, metadataStamp: stamp)
                if isWatchable(app, roots: roots) { result.append(app) }
            }
        }
        return (result, complete)
    }
}

/// Debounce removals so in-place updates, renames and duplicate installations do
/// not produce uninstall prompts. A bookmark that resolves outside Trash is a move.
public struct UninstallWatchTracker {
    private var previous: [WatchedApplication]?
    private var missingSince: [URL: Date] = [:]
    public init() {}
    public var hasPendingRemovals: Bool { !missingSince.isEmpty }
    public mutating func update(_ current: [WatchedApplication], complete: Bool, now: Date = Date(),
                                grace: TimeInterval = 30,
                                isMissing: (URL) -> Bool = UninstallWatchInventory.isMissing,
                                relocated: (WatchedApplication) -> URL? = { $0.relocatedURL }) -> [WatchedApplication] {
        guard complete else { return [] }
        guard let old = previous else { previous = current; return [] }
        let ids = Set(current.map(\.bundleIdentifier))
        let paths = Set(current.map(\.url))
        var retained: [WatchedApplication] = []
        var removed: [WatchedApplication] = []
        for app in old {
            if paths.contains(app.url) || ids.contains(app.bundleIdentifier) || !isMissing(app.url) {
                missingSince[app.url] = nil
                continue
            }
            if let moved = relocated(app), !isMissing(moved) {
                missingSince[app.url] = nil
                // A surviving bookmark in Trash is positive evidence, unlike a
                // missing path during an updater's replace operation. No 30s wait.
                if UninstallWatchInventory.isTrash(moved) { removed.append(app) }
                continue
            }
            let first = missingSince[app.url] ?? now
            missingSince[app.url] = first
            if now.timeIntervalSince(first) >= grace {
                removed.append(app); missingSince[app.url] = nil
            } else { retained.append(app) }
        }
        previous = current + retained
        var emitted = Set<String>()
        return removed.filter { emitted.insert($0.bundleIdentifier).inserted }
    }
}

public enum UninstallWatchStore {
    public static let changedNotification = Notification.Name("com.wondercraft.WonderBox.uninstall-events-changed")
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WonderBox/UninstallWatcher", isDirectory: true)
    }
    public static func write(_ event: UninstallWatchEvent, directory: URL = directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(event)
        let url = directory.appendingPathComponent(event.id.uuidString + ".json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func events(directory: URL = directory) -> [UninstallWatchEvent] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.prefix(512).compactMap { url in
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_048_576,
                  let data = try? Data(contentsOf: url), let event = try? JSONDecoder().decode(UninstallWatchEvent.self, from: data),
                  event.id.uuidString == url.deletingPathExtension().lastPathComponent else { return nil }
            return event
        }.sorted { $0.createdAt < $1.createdAt }
    }
    public static func remove(_ event: UninstallWatchEvent, directory: URL = directory) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(event.id.uuidString + ".json"))
    }
    public static func suppress(_ identifier: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var values = suppressions()
        values[identifier] = Date().addingTimeInterval(300)
        try JSONEncoder().encode(values).write(to: directory.appendingPathComponent("suppressed.json"), options: .atomic)
    }
    public static func suppressions() -> [String: Date] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("suppressed.json")), data.count < 1_048_576,
              let values = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return values.filter { $0.value > Date() }
    }
}
