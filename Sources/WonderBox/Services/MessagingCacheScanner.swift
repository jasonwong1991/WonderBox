import Darwin
import Foundation

enum MessagingApplication: String, CaseIterable, Hashable, Sendable {
    case wechat, wecom
    var name: String { self == .wechat ? String(localized: "WeChat") : String(localized: "WeCom") }
    var kind: CleanupKind { self == .wechat ? .wechatCaches : .wecomCaches }
    var identifiers: [String] {
        self == .wechat ? ["com.tencent.xinwechat", "com.tencent.wechat", "com.tencent.weixin"]
            : ["com.tencent.weworkmac", "com.tencent.wework", "com.tencent.wecom"]
    }
    var aliases: Set<String> {
        self == .wechat ? ["wechat", "weixin", "xinwechat", "微信"] : ["wecom", "wework", "weworkmac", "wxwork", "企业微信"]
    }
    func matches(_ value: String) -> Bool {
        aliases.contains(RunningApplicationNames.normalize(value)) || identifiers.contains { ApplicationScanner.belongs(value, toIdentifier: $0) }
    }
    func isRunning(_ names: Set<String>) -> Bool { names.contains(where: matches) }
}

enum MessagingProcessInspector {
    static func current() -> Set<MessagingApplication> {
        running(in: ProcessMemoryInspector.allProcessIdentifiers().compactMap(ProcessMemoryInspector.executablePath))
    }

    /// libproc works off the main thread and sees background helpers too. Inspect bundle metadata
    /// once per executable bundle, including renamed apps; never read message/account files.
    static func running(in executablePaths: [String]) -> Set<MessagingApplication> {
        var found = Set<MessagingApplication>()
        var seen = Set<String>()
        for path in executablePaths {
            let executable = URL(fileURLWithPath: path).lastPathComponent
            found.formUnion(MessagingApplication.allCases.filter { $0.aliases.contains(RunningApplicationNames.normalize(executable)) })
            guard let bundlePath = ProcessMemoryInspector.applicationBundlePath(containing: path), seen.insert(bundlePath).inserted else { continue }
            let url = URL(fileURLWithPath: bundlePath)
            let name = url.deletingPathExtension().lastPathComponent
            let identifier = Bundle(url: url)?.bundleIdentifier
            found.formUnion(MessagingApplication.allCases.filter { $0.matches(name) || identifier.map($0.matches) == true })
        }
        return found
    }
}

/// Only explicit cache directories. Message databases, attachments, cookies, login data, and entire
/// account/profile roots are never candidates; messaging caches are opt-in and go to the Trash.
enum MessagingCacheScanner {
    static let cacheNames: Set<String> = ["Caches", "Cache", "GPUCache", "Code Cache", "ShaderCache", "GrShaderCache", "DawnCache", "NetworkCache"]
    private static let protectedNames: Set<String> = [
        "msg", "message", "messages", "messagedb", "db", "database", "databases", "filestorage", "files", "file",
        "image", "images", "video", "videos", "audio", "attachment", "attachments", "local storage", "indexeddb", "session storage", "cookies",
        "chat", "chats", "chatlog", "chatlogs", "chatdata", "chatfiles", "messagetemp", "msgattach"
    ]
    private static let structuralNames: Set<String> = ["Profiles", "Default", "QtWebEngine", "WebKit", "WebsiteData", "WebView", "WebViews", "Browser", "Service Worker"]

    static func owner(of url: URL, home: URL) -> MessagingApplication? {
        let library = home.appendingPathComponent("Library").standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(library) else { return nil }
        let components = path.dropFirst(library.count).split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }
        let identity: String
        switch components[0] {
        case "Containers", "Group Containers":
            let container = home.appendingPathComponent("Library/\(components[0])/\(components[1])")
            identity = containerIdentifier(container) ?? components[1]
        case "Caches", "Application Support", "WebKit": identity = components[1]
        default: return nil
        }
        return MessagingApplication.allCases.first { $0.matches(identity) }
    }

    static func containerIdentifier(_ url: URL) -> String? {
        let metadata = url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let values = try? metadata.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]),
              values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? Int.max) < 1_048_576,
              let data = try? Data(contentsOf: metadata),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["MCMMetadataIdentifier"] as? String
    }

    static func locations(for application: MessagingApplication, home: URL) -> [URL] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        var candidates: [URL] = []
        // Non-sandboxed versions store application caches here.
        for url in FileSystemScanner.children(of: library.appendingPathComponent("Caches")) where application.matches(url.lastPathComponent) {
            if isRealDirectory(url) { candidates.append(url) }
        }
        for parent in ["Containers", "Group Containers"] {
            for container in FileSystemScanner.children(of: library.appendingPathComponent(parent)) {
                guard isRealDirectory(container), application.matches(containerIdentifier(container) ?? container.lastPathComponent) else { continue }
                let base = parent == "Containers" ? container.appendingPathComponent("Data") : container
                for relative in ["Library/Caches", "Documents/Caches"] {
                    let root = base.appendingPathComponent(relative)
                    if isRealDirectory(root) { candidates.append(root) }
                }
                // WebKit/Qt profiles also contain login and persistent website data. Never select
                // the whole profile: only NetworkCache / Cache / GPUCache etc inside it.
                candidates += explicitCaches(in: base.appendingPathComponent("Library/WebKit"), depth: 3)
                let support = base.appendingPathComponent("Library/Application Support")
                for root in FileSystemScanner.children(of: support) where application.matches(root.lastPathComponent) || structuralNames.contains(root.lastPathComponent) {
                    candidates += explicitCaches(in: root, depth: 3)
                }
                // Legacy Documents/<bundle-id>/<version>/<account>/Caches and modern
                // Documents/xwechat_files/<account>/Cache or WXWork/Profiles/<account>/Cache.
                for root in FileSystemScanner.children(of: base.appendingPathComponent("Documents")) where application.matches(root.lastPathComponent) || root.lastPathComponent == "xwechat_files" {
                    candidates += explicitCaches(in: root, depth: 3, profiles: true)
                }
            }
        }
        for root in FileSystemScanner.children(of: library.appendingPathComponent("Application Support")) where application.matches(root.lastPathComponent) {
            candidates += explicitCaches(in: root, depth: 3, profiles: true)
        }
        for root in FileSystemScanner.children(of: library.appendingPathComponent("WebKit")) where application.matches(root.lastPathComponent) {
            candidates += explicitCaches(in: root, depth: 3)
        }
        let safe = Set(candidates.filter { isSafe($0, for: application, home: home) }.map(\.standardizedFileURL))
        // Parent caches absorb their children: no double accounting or double removal.
        return safe.filter { candidate in !safe.contains { $0 != candidate && candidate.path.hasPrefix($0.path + "/") } }
            .sorted { $0.path < $1.path }
    }

    private static func explicitCaches(in directory: URL, depth: Int, profiles: Bool = false) -> [URL] {
        guard depth >= 0, isRealDirectory(directory) else { return [] }
        var found: [URL] = []
        for child in FileSystemScanner.children(of: directory) where isRealDirectory(child) {
            if Task.isCancelled { return found }
            let name = child.lastPathComponent
            if cacheNames.contains(name) || (directory.lastPathComponent == "Service Worker" && ["CacheStorage", "ScriptCache"].contains(name)) {
                found.append(child)
            } else if depth > 0, !protectedNames.contains(name.lowercased()),
                      structuralNames.contains(name) || MessagingApplication.allCases.contains(where: { $0.matches(name) })
                        || (profiles && isProfileComponent(name)) {
                found += explicitCaches(in: child, depth: depth - 1, profiles: profiles)
            }
        }
        return found
    }

    private static func isProfileComponent(_ name: String) -> Bool {
        // Account IDs / version directories, not arbitrary named chat/resource trees.
        let lower = name.lowercased()
        return lower.hasPrefix("wxid_") || (name.count >= 8 && name.allSatisfy(\.isHexDigit))
            || (name.first?.isNumber == true && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" })
    }

    static func isSafe(_ url: URL, for application: MessagingApplication, home: URL) -> Bool {
        let candidate = url.standardizedFileURL
        guard owner(of: candidate, home: home) == application else { return false }
        let relative = candidate.path.dropFirst(home.standardizedFileURL.path.count + 1).split(separator: "/").map(String.init)
        guard !relative.contains(where: { protectedNames.contains($0.lowercased()) }) else { return false }
        guard hasKnownLayout(relative, application: application) else { return false }
        let isTopLevelCache = candidate.deletingLastPathComponent() == home.appendingPathComponent("Library/Caches").standardizedFileURL
        let isCache = cacheNames.contains(candidate.lastPathComponent)
            || (candidate.deletingLastPathComponent().lastPathComponent == "Service Worker" && ["CacheStorage", "ScriptCache"].contains(candidate.lastPathComponent))
        guard isTopLevelCache || isCache else { return false }
        // Reject symlinks at any level, including a replaced parent between scan and cleanup.
        var ancestor = candidate
        let homePath = home.standardizedFileURL.path
        while ancestor.path != homePath, ancestor.path != "/" {
            var info = stat()
            guard lstat(ancestor.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return false }
            ancestor.deleteLastPathComponent()
        }
        return isRealDirectory(candidate)
    }

    /// A folder named “Cache” somewhere in an account isn't sufficient. Keep deletion validation
    /// aligned with discovery's fixed base paths, structural names and bounded profile depth.
    private static func hasKnownLayout(_ relative: [String], application: MessagingApplication) -> Bool {
        guard relative.count >= 3, relative[0] == "Library" else { return false }
        switch relative[1] {
        case "Caches": return relative.count == 3
        case "WebKit": return isCacheTail(Array(relative.dropFirst(3)), profiles: false)
        case "Application Support": return isCacheTail(Array(relative.dropFirst(3)), profiles: true)
        case "Containers", "Group Containers":
            var suffix = Array(relative.dropFirst(3))
            if relative[1] == "Containers" {
                guard suffix.first == "Data" else { return false }
                suffix.removeFirst()
            }
            if suffix == ["Library", "Caches"] || suffix == ["Documents", "Caches"] { return true }
            if Array(suffix.prefix(2)) == ["Library", "WebKit"] {
                return isCacheTail(Array(suffix.dropFirst(2)), profiles: false)
            }
            if suffix.count >= 4, Array(suffix.prefix(2)) == ["Library", "Application Support"],
               application.matches(suffix[2]) || structuralNames.contains(suffix[2]) {
                return isCacheTail(Array(suffix.dropFirst(3)), profiles: false)
            }
            if suffix.count >= 3, suffix.first == "Documents", application.matches(suffix[1]) || suffix[1] == "xwechat_files" {
                return isCacheTail(Array(suffix.dropFirst(2)), profiles: true)
            }
            return false
        default: return false
        }
    }

    private static func isCacheTail(_ components: [String], profiles: Bool) -> Bool {
        guard !components.isEmpty, components.count <= 4 else { return false }
        return components.dropLast().allSatisfy { component in
            structuralNames.contains(component) || MessagingApplication.allCases.contains(where: { $0.matches(component) })
                || (profiles && isProfileComponent(component))
        }
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
