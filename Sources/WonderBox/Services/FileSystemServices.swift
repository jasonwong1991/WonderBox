import AppKit
import CoreServices
import Darwin
import Foundation

enum FileSystemScanner {
    private static let sizeKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey
    ]

    static func allocatedSize(of url: URL) -> UInt64 {
        guard let values = try? url.resourceValues(forKeys: sizeKeys) else { return 0 }
        if values.isRegularFile == true || values.isSymbolicLink == true {
            return UInt64(max(0, values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0))
        }
        guard values.isDirectory == true,
              let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: Array(sizeKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
              )
        else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if Task.isCancelled { break }
            autoreleasepool {
                guard let fileValues = try? fileURL.resourceValues(forKeys: sizeKeys),
                      fileValues.isRegularFile == true || fileValues.isSymbolicLink == true
                else { return }
                total += UInt64(max(0, fileValues.totalFileAllocatedSize ?? fileValues.fileAllocatedSize ?? 0))
            }
        }
        return total
    }

    static func indexedPhysicalSize(of url: URL) -> UInt64? {
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString),
              let number = MDItemCopyAttribute(item, "kMDItemPhysicalSize" as CFString) as? NSNumber
        else { return nil }
        let value = number.uint64Value
        return value > 1 ? value : nil
    }

    static func indexedDate(_ attribute: String, of url: URL) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString),
              let value = MDItemCopyAttribute(item, attribute as CFString)
        else { return nil }
        return value as? Date
    }

    static func children(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }
}

extension Bundle {
    /// Localized product name, preferring the display name Finder shows.
    var productName: String? {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
    }
}

enum ApplicationScanner {
    static func scanApplications() -> [InstalledApplication] {
        let manager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        var applications: [InstalledApplication] = []
        var seen = Set<String>()

        for root in roots where manager.fileExists(atPath: root.path) {
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                if Task.isCancelled { return applications }
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                if let application = application(from: url) {
                    applications.append(application)
                }
            }
        }
        return applications.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func application(from url: URL) -> InstalledApplication? {
        guard url.pathExtension.lowercased() == "app", FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bundle = Bundle(url: url)
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return InstalledApplication(
            url: url,
            name: bundle?.productName ?? url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: bundle?.bundleIdentifier,
            version: (bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String),
            size: FileSystemScanner.indexedPhysicalSize(of: url) ?? FileSystemScanner.allocatedSize(of: url),
            installedAt: FileSystemScanner.indexedDate("kMDItemDateAdded", of: url)
                ?? values?.creationDate
                ?? values?.contentModificationDate,
            lastUsedAt: FileSystemScanner.indexedDate("kMDItemLastUsedDate", of: url)
        )
    }

    static func relatedFiles(for application: InstalledApplication) -> [RelatedFile] {
        let manager = FileManager.default
        let library = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        let identifiers = [application.bundleIdentifier, application.name].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        var candidates: [URL] = []

        for identifier in identifiers {
            candidates.append(contentsOf: [
                library.appendingPathComponent("Caches/\(identifier)"),
                library.appendingPathComponent("Application Support/\(identifier)"),
                library.appendingPathComponent("Logs/\(identifier)"),
                library.appendingPathComponent("WebKit/\(identifier)"),
                library.appendingPathComponent("HTTPStorages/\(identifier)"),
                library.appendingPathComponent("Containers/\(identifier)"),
                library.appendingPathComponent("Application Scripts/\(identifier)")
            ])
        }
        if let identifier = application.bundleIdentifier {
            candidates.append(library.appendingPathComponent("Preferences/\(identifier).plist"))
            candidates.append(library.appendingPathComponent("Saved Application State/\(identifier).savedState"))
        }

        var seen = Set<String>()
        return candidates.compactMap { url in
            let standardized = url.standardizedFileURL
            guard manager.fileExists(atPath: standardized.path),
                  seen.insert(standardized.path).inserted
            else { return nil }
            return RelatedFile(
                url: standardized,
                displayPath: "~/" + standardized.path.replacingOccurrences(of: manager.homeDirectoryForCurrentUser.path + "/", with: ""),
                size: FileSystemScanner.allocatedSize(of: standardized)
            )
        }.sorted { $0.size > $1.size }
    }

    static func uninstall(application: InstalledApplication, relatedFiles: [RelatedFile]) -> String {
        let manager = FileManager.default
        var removed = 0
        var failures: [String] = []
        for url in [application.url] + relatedFiles.map(\.url) {
            guard manager.fileExists(atPath: url.path) else { continue }
            do {
                var result: NSURL?
                try manager.trashItem(at: url, resultingItemURL: &result)
                removed += 1
            } catch {
                failures.append(url.lastPathComponent)
            }
        }
        if failures.isEmpty {
            return String(localized: "Moved \(removed) items to the Trash")
        }
        return String(localized: "Removed \(removed) items; \(failures.count) need higher privileges")
    }

    static func installedBundleIdentifiers() -> Set<String> {
        let manager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        var identifiers = Set<String>()
        for root in roots where manager.fileExists(atPath: root.path) {
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                enumerator.skipDescendants()
                if let identifier = Bundle(url: url)?.bundleIdentifier {
                    identifiers.insert(identifier.lowercased())
                }
            }
        }
        return identifiers
    }
}

enum ApplicationOrganizer {
    static let largeApplicationThreshold: UInt64 = 1_000_000_000
    static let staleApplicationAge: TimeInterval = 180 * 24 * 60 * 60

    static func filter(
        _ applications: [InstalledApplication],
        by filter: ApplicationFilter,
        now: Date = Date()
    ) -> [InstalledApplication] {
        switch filter {
        case .all:
            return applications
        case .large:
            return applications.filter { $0.size >= largeApplicationThreshold }
        case .stale:
            let cutoff = now.addingTimeInterval(-staleApplicationAge)
            return applications.filter { application in
                guard let lastUsedAt = application.lastUsedAt else { return true }
                return lastUsedAt < cutoff
            }
        }
    }

    static func sort(
        _ applications: [InstalledApplication],
        by sort: ApplicationSort,
        ascending: Bool
    ) -> [InstalledApplication] {
        applications.sorted { lhs, rhs in
            switch sort {
            case .name:
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            case .size:
                if lhs.size != rhs.size {
                    if lhs.size == 0 { return false }
                    if rhs.size == 0 { return true }
                    return ascending ? lhs.size < rhs.size : lhs.size > rhs.size
                }
            case .installedAt:
                if let result = compare(lhs.installedAt, rhs.installedAt, ascending: ascending) { return result }
            case .lastUsedAt:
                if let result = compare(lhs.lastUsedAt, rhs.lastUsedAt, ascending: ascending) { return result }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func compare(_ lhs: Date?, _ rhs: Date?, ascending: Bool) -> Bool? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?) where lhs != rhs:
            return ascending ? lhs < rhs : lhs > rhs
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return nil
        }
    }
}

enum StorageCleaner {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func quickCleanCategories(from categories: [CleanupCategory]) -> [CleanupCategory] {
        categories.filter { category in
            category.kind.isSelectedByDefault &&
                !category.kind.isDeepOnly &&
                category.kind != .systemCaches &&
                category.isSelected &&
                category.accessMessage == nil
        }
    }

    /// - Parameter runningApplications: normalized names (see `RunningApplicationNames`) of apps whose
    ///   browser caches must not be touched while they hold the files open.
    static func scan(mode: CleanupScanMode = .standard, runningApplications: Set<String> = []) -> [CleanupCategory] {
        let cacheRoot = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let systemCacheRoot = URL(fileURLWithPath: "/Library/Caches", isDirectory: true)
        let logRoot = home.appendingPathComponent("Library/Logs", isDirectory: true)
        let developerRoot = home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        let downloadsRoot = home.appendingPathComponent("Downloads", isDirectory: true)

        var locations: [(CleanupKind, [URL], Bool)] = [
            (.caches, FileSystemScanner.children(of: cacheRoot) + sandboxedCaches(), CleanupKind.caches.isSelectedByDefault),
            (.systemCaches, FileSystemScanner.children(of: systemCacheRoot), CleanupKind.systemCaches.isSelectedByDefault),
            (.logs, FileSystemScanner.children(of: logRoot), CleanupKind.logs.isSelectedByDefault),
            (.developer, FileSystemScanner.children(of: developerRoot), CleanupKind.developer.isSelectedByDefault),
            (.installers, installerFiles(in: downloadsRoot), CleanupKind.installers.isSelectedByDefault)
        ]
        var packageLocations: [URL] = []
        if mode == .deep {
            let deviceBackupRoot = home.appendingPathComponent("Library/Application Support/MobileSync/Backup", isDirectory: true)
            packageLocations = packageCacheLocations()
            locations.append(contentsOf: [
                (.applicationLeftovers, applicationLeftovers(), false),
                (.deviceBackups, FileSystemScanner.children(of: deviceBackupRoot), false),
                (.developerDeep, developerDeepLocations(), false),
                (.packageCaches, packageLocations, false),
                (.browserCaches, browserCaches(runningApplications: runningApplications), false),
                (.partialDownloads, partialDownloadFiles(in: downloadsRoot), false)
            ])
        }
        // Package caches are few but hold hundreds of thousands of files; size each tree on its own,
        // concurrently with everything else, so one huge cache cannot starve the others of their time budget.
        let packageGroup = DispatchGroup()
        var packageEstimates: [String: UInt64] = [:]
        packageGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            packageEstimates = DirectorySizeEstimator.estimate(packageLocations, timeout: 30, individually: true)
            packageGroup.leave()
        }
        var estimates = DirectorySizeEstimator.estimate(
            locations.filter { $0.0 != .packageCaches }.flatMap(\.1),
            timeout: mode == .deep ? 8 : 4
        )
        packageGroup.wait()
        estimates.merge(packageEstimates) { _, new in new }
        var categories = locations.map { kind, urls, selected in
            makeCategory(kind, locations: urls, selected: selected, estimates: estimates)
        }
        let trash = FinderTrashService.snapshot()
        categories.append(CleanupCategory(
            kind: .trash,
            size: trash.size,
            itemCount: trash.itemCount,
            isSelected: trash.accessMessage == nil && CleanupKind.trash.isSelectedByDefault,
            locations: [],
            items: [],
            accessMessage: trash.accessMessage
        ))
        return categories
    }

    static func clean(_ categories: [CleanupCategory]) -> String {
        let manager = FileManager.default
        var removed: UInt64 = 0
        var removedCount = 0
        var failedCount = 0

        // Empty the existing Trash before moving new recoverable items into it.
        if let trash = categories.first(where: { $0.kind == .trash }) {
            switch FinderTrashService.empty() {
            case .success:
                removed += trash.size
                removedCount += trash.itemCount
            case .failure:
                failedCount += max(1, trash.itemCount)
            }
        }

        for category in categories where category.kind != .trash {
            let selectedItems: [(url: URL, size: UInt64)] = category.items.isEmpty
                ? category.locations.map { ($0, 0) }
                : category.items.filter(\.isSelected).map { ($0.url, $0.size) }
            for item in selectedItems where isSafe(item.url, for: category.kind) {
                if Task.isCancelled { break }
                let itemSize = item.size > 0 ? item.size : FileSystemScanner.allocatedSize(of: item.url)
                do {
                    if category.kind.movesToTrash {
                        var result: NSURL?
                        try manager.trashItem(at: item.url, resultingItemURL: &result)
                    } else {
                        try manager.removeItem(at: item.url)
                    }
                    removed += itemSize
                    removedCount += 1
                } catch {
                    failedCount += 1
                }
            }
        }

        if failedCount > 0 {
            return String(localized: "Cleaned \(removedCount) items; \(failedCount) are protected by the system")
        }
        return String(localized: "Cleaned \(removedCount) items, freeing about \(AppFormatters.bytes(removed))")
    }

    static func isSafe(_ url: URL, for kind: CleanupKind) -> Bool {
        let path = url.standardizedFileURL.path
        let underAllowedRoot = allowedRoots(for: kind).contains { root in
            path.hasPrefix(root + "/") && path != root
        }
        switch kind {
        case .caches:
            return underAllowedRoot || isSandboxedCachePath(path, library: home.appendingPathComponent("Library"))
        case .browserCaches:
            return underAllowedRoot && isBrowserCacheDirectory(url)
        default:
            return underAllowedRoot
        }
    }

    /// `<library>/Containers/<id>/Data/Library/Caches/<item>` or `<library>/Group Containers/<id>/Library/Caches/<item>`.
    static func isSandboxedCachePath(_ path: String, library: URL) -> Bool {
        for (root, infix) in sandboxedCacheLayouts {
            let prefix = library.appendingPathComponent(root).standardizedFileURL.path + "/"
            guard path.hasPrefix(prefix) else { continue }
            let components = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
            // <id> + infix + at least one item component
            guard components.count >= infix.count + 2 else { return false }
            return Array(components[1...infix.count]) == infix
        }
        return false
    }

    /// The URL itself must be one of the Chromium cache directories, not a parent or a sibling.
    static func isBrowserCacheDirectory(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        return browserCacheDirectoryNames.contains { name in
            components.count > name.count && Array(components.suffix(name.count)) == name
        }
    }

    private static func makeCategory(
        _ kind: CleanupKind,
        locations: [URL],
        selected: Bool = true,
        estimates: [String: UInt64]
    ) -> CleanupCategory {
        var seen = Set<String>()
        let uniqueLocations = locations.filter { seen.insert($0.standardizedFileURL.path).inserted }
        let items: [CleanupItem] = uniqueLocations.map { (url: URL) -> CleanupItem in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            let estimate = estimates[url.standardizedFileURL.path]
            return CleanupItem(
                url: url,
                size: estimate ?? 0,
                isSelected: selected,
                modifiedAt: values?.contentModificationDate,
                isDirectory: values?.isDirectory == true,
                isSizeEstimated: estimate != nil
            )
        }.sorted(by: { (lhs: CleanupItem, rhs: CleanupItem) -> Bool in
            if lhs.size == rhs.size {
                return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
            }
            return lhs.size > rhs.size
        })
        return CleanupCategory(
            kind: kind,
            size: items.reduce(0) { $0 + $1.size },
            itemCount: items.count,
            isSelected: selected,
            locations: uniqueLocations,
            items: items,
            accessMessage: nil
        )
    }

    static func isLikelyBundleIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { part in
            part.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
        }
    }

    private static func allowedRoots(for kind: CleanupKind) -> [String] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        switch kind {
        case .caches:
            return [library.appendingPathComponent("Caches").path]
        case .systemCaches:
            return ["/Library/Caches"]
        case .logs:
            return [library.appendingPathComponent("Logs").path]
        case .developer:
            return [library.appendingPathComponent("Developer/Xcode/DerivedData").path]
        case .installers, .partialDownloads:
            return [home.appendingPathComponent("Downloads").path]
        case .applicationLeftovers:
            return leftoverRootSpecifications().map { $0.root.path }
        case .deviceBackups:
            return [library.appendingPathComponent("Application Support/MobileSync/Backup").path]
        case .developerDeep:
            return developerDeepRoots().map(\.path)
        case .packageCaches:
            return packageCacheRoots().map(\.path)
        case .browserCaches:
            return [library.appendingPathComponent("Application Support").path]
        case .trash:
            return [home.appendingPathComponent(".Trash").path]
        }
    }

    // MARK: Sandboxed application caches

    /// Container root under ~/Library and the fixed path from a container to its Caches directory.
    private static let sandboxedCacheLayouts: [(root: String, infix: [String])] = [
        ("Containers", ["Data", "Library", "Caches"]),
        ("Group Containers", ["Library", "Caches"])
    ]

    private static func sandboxedCaches() -> [URL] {
        sandboxedCaches(in: home.appendingPathComponent("Library", isDirectory: true))
    }

    static func sandboxedCaches(in library: URL) -> [URL] {
        var result: [URL] = []
        for (root, infix) in sandboxedCacheLayouts {
            for container in FileSystemScanner.children(of: library.appendingPathComponent(root, isDirectory: true)) {
                if Task.isCancelled { return result }
                let caches = infix.reduce(container) { $0.appendingPathComponent($1, isDirectory: true) }
                guard isRealDirectory(caches) else { continue }
                result.append(contentsOf: FileSystemScanner.children(of: caches))
            }
        }
        return result
    }

    // MARK: Package manager caches

    /// Download caches that package managers rebuild on demand. Toolchains and installed versions
    /// (nvm, rustup, SDKs) are deliberately absent: removing those breaks projects.
    private static func packageCacheRoots() -> [URL] {
        [
            ".cache",
            ".npm/_cacache",
            ".npm/_npx",
            ".yarn/berry/cache",
            ".pnpm-store",
            "Library/pnpm/store",
            ".bun/install/cache",
            ".cargo/registry",
            "go/pkg/mod",
            ".gradle/caches",
            ".m2/repository",
            ".cocoapods/repos"
        ].map { home.appendingPathComponent($0, isDirectory: true) }
    }

    private static func packageCacheLocations() -> [URL] {
        packageCacheRoots().flatMap { root -> [URL] in
            guard isRealDirectory(root) else { return [] }
            // ~/.cache is the XDG umbrella; list each tool separately so users can keep one and drop another.
            return root.lastPathComponent == ".cache" ? FileSystemScanner.children(of: root) : [root]
        }
    }

    // MARK: Browser and Electron caches

    /// Cache directories Chromium creates inside a profile or an Electron app's user-data directory.
    private static let browserCacheDirectoryNames: [[String]] = [
        ["Cache"],
        ["Code Cache"],
        ["GPUCache"],
        ["DawnCache"],
        ["DawnGraphiteCache"],
        ["DawnWebGPUCache"],
        ["ShaderCache"],
        ["GrShaderCache"],
        ["Service Worker", "CacheStorage"],
        ["Service Worker", "ScriptCache"]
    ]

    /// Chromium's process-singleton markers; present in the user-data directory while the app runs.
    private static let singletonMarkers = ["SingletonLock", "SingletonSocket", "SingletonCookie"]

    private static func browserCaches(runningApplications: Set<String>) -> [URL] {
        browserCaches(
            in: home.appendingPathComponent("Library/Application Support", isDirectory: true),
            runningApplications: runningApplications
        )
    }

    /// Walks up to three directory levels below Application Support (`App/`, `Vendor/App/`, `Vendor/App/Profile/`)
    /// looking only for the known cache names, so unrelated app data is never enumerated.
    static func browserCaches(in applicationSupport: URL, runningApplications: Set<String>) -> [URL] {
        var result: [URL] = []
        for application in FileSystemScanner.children(of: applicationSupport) where isRealDirectory(application) {
            if Task.isCancelled { return result }
            var userDataDirectories = [application]
            let vendorChildren = FileSystemScanner.children(of: application).filter(isRealDirectory)
            userDataDirectories.append(contentsOf: vendorChildren)
            userDataDirectories.append(contentsOf: vendorChildren.flatMap { FileSystemScanner.children(of: $0).filter(isRealDirectory) })

            for userData in userDataDirectories {
                let caches = browserCacheDirectoryNames
                    .map { $0.reduce(userData) { $0.appendingPathComponent($1, isDirectory: true) } }
                    .filter(isRealDirectory)
                guard !caches.isEmpty else { continue }
                guard !isOwnerRunning(of: userData, below: applicationSupport, runningApplications: runningApplications) else { continue }
                result.append(contentsOf: caches)
            }
        }
        return result
    }

    private static func isOwnerRunning(of userData: URL, below applicationSupport: URL, runningApplications: Set<String>) -> Bool {
        let root = applicationSupport.resolvingSymlinksInPath().path
        var directory = userData.resolvingSymlinksInPath()
        var names: [String] = []
        while directory.path != root, directory.path != "/" {
            if singletonMarkers.contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
                return true
            }
            names.insert(directory.lastPathComponent, at: 0)
            directory.deleteLastPathComponent()
        }
        // Electron names the folder after the product ("Code", "discord"); vendors nest it ("Google/Chrome");
        // browsers add a profile level ("Default"). Try every contiguous run of components.
        for start in names.indices {
            for end in start..<names.count {
                let candidate = RunningApplicationNames.normalize(names[start...end].joined(separator: " "))
                if runningApplications.contains(candidate) { return true }
            }
        }
        return false
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private static func applicationLeftovers() -> [URL] {
        let installed = ApplicationScanner.installedBundleIdentifiers()
        let cutoff = Date().addingTimeInterval(-90 * 24 * 60 * 60)
        var candidates: [URL] = []

        for specification in leftoverRootSpecifications() {
            for url in FileSystemScanner.children(of: specification.root) {
                if Task.isCancelled { return candidates }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                guard let modifiedAt = values?.contentModificationDate, modifiedAt < cutoff else { continue }
                let identifier = specification.identifier(url).lowercased()
                guard isLikelyBundleIdentifier(identifier),
                      !identifier.hasPrefix("com.apple."),
                      !installed.contains(where: {
                          identifier == $0 || identifier.hasPrefix($0 + ".") || $0.hasPrefix(identifier + ".")
                      })
                else { continue }
                candidates.append(url)
                if candidates.count >= 300 { return candidates }
            }
        }
        return candidates
    }

    private static func leftoverRootSpecifications() -> [(root: URL, identifier: (URL) -> String)] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let directName: (URL) -> String = { $0.lastPathComponent }
        return [
            (library.appendingPathComponent("Application Support", isDirectory: true), directName),
            (library.appendingPathComponent("WebKit", isDirectory: true), directName),
            (library.appendingPathComponent("HTTPStorages", isDirectory: true), directName),
            (library.appendingPathComponent("Containers", isDirectory: true), directName),
            (library.appendingPathComponent("Application Scripts", isDirectory: true), directName),
            (library.appendingPathComponent("Preferences", isDirectory: true), {
                $0.deletingPathExtension().lastPathComponent
            }),
            (library.appendingPathComponent("Saved Application State", isDirectory: true), {
                $0.lastPathComponent.replacingOccurrences(of: ".savedState", with: "")
            })
        ]
    }

    private static func developerDeepRoots() -> [URL] {
        let developer = home.appendingPathComponent("Library/Developer", isDirectory: true)
        return [
            developer.appendingPathComponent("CoreSimulator/Caches", isDirectory: true),
            developer.appendingPathComponent("Xcode/iOS DeviceSupport", isDirectory: true),
            developer.appendingPathComponent("Xcode/watchOS DeviceSupport", isDirectory: true),
            developer.appendingPathComponent("Xcode/tvOS DeviceSupport", isDirectory: true),
            developer.appendingPathComponent("Xcode/DocumentationCache", isDirectory: true),
            developer.appendingPathComponent("Xcode/UserData/Previews/Simulator Devices", isDirectory: true)
        ]
    }

    private static func developerDeepLocations() -> [URL] {
        developerDeepRoots().flatMap { FileSystemScanner.children(of: $0) }
    }

    private static func partialDownloadFiles(in directory: URL) -> [URL] {
        let extensions = Set(["download", "crdownload", "part", "partial"])
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        return FileSystemScanner.children(of: directory).filter { url in
            guard extensions.contains(url.pathExtension.lowercased()) else { return false }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return (values?.contentModificationDate ?? .distantFuture) < cutoff
        }
    }

    private static func installerFiles(in directory: URL) -> [URL] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = [
            directory.path,
            "-maxdepth", "1",
            "-type", "f",
            "(",
            "-iname", "*.dmg", "-o",
            "-iname", "*.pkg", "-o",
            "-iname", "*.zip", "-o",
            "-iname", "*.xip",
            ")",
            "-mtime", "+7",
            "-print0"
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }

        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return data.split(separator: 0).map {
            URL(fileURLWithPath: String(decoding: $0, as: UTF8.self))
        }
    }
}

private enum FinderTrashService {
    struct Snapshot {
        let itemCount: Int
        let size: UInt64
        let accessMessage: String?
    }

    enum EmptyResult {
        case success
        case failure
    }

    static func snapshot() -> Snapshot {
        let source = """
        tell application "Finder"
            set trashItems to every item of trash
            set totalSize to 0
            repeat with trashItem in trashItems
                try
                    set itemBytes to physical size of trashItem
                    if itemBytes is not missing value then set totalSize to totalSize + itemBytes
                on error
                    try
                        set itemBytes to size of trashItem
                        if itemBytes is not missing value then set totalSize to totalSize + itemBytes
                    end try
                end try
            end repeat
            return ((count of trashItems) as text) & "|" & (totalSize as text)
        end tell
        """
        switch execute(source) {
        case let .success(output):
            let fields = output.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let itemCount = Int(fields[0]),
                  let byteCount = Double(fields[1]),
                  byteCount.isFinite,
                  byteCount >= 0
            else {
                return Snapshot(itemCount: 0, size: 0, accessMessage: String(localized: "Finder returned an unexpected Trash size; please rescan"))
            }
            return Snapshot(
                itemCount: max(0, itemCount),
                size: UInt64(min(byteCount, Double(UInt64.max))),
                accessMessage: nil
            )
        case .failure:
            return Snapshot(
                itemCount: 0,
                size: 0,
                accessMessage: String(localized: "Allow WonderBox to control Finder in System Settings > Privacy & Security > Automation")
            )
        }
    }

    static func empty() -> EmptyResult {
        switch execute("tell application \"Finder\" to empty trash") {
        case .success: .success
        case .failure: .failure
        }
    }

    private static func execute(_ source: String) -> Result<String, Error> {
        var errorInfo: NSDictionary?
        let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Finder Apple Event failed"
            return .failure(NSError(domain: "WonderBox.FinderTrash", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
        }
        return .success(descriptor?.stringValue ?? "")
    }
}

enum DirectorySizeEstimator {
    /// - Parameter individually: run one `du` per URL so a single slow tree only costs its own timeout.
    ///   Suited to a handful of large roots; the default batches URLs to keep process spawns low.
    static func estimate(
        _ urls: [URL],
        timeout: TimeInterval,
        ignoringNames: Set<String> = [],
        individually: Bool = false
    ) -> [String: UInt64] {
        guard !urls.isEmpty else { return [:] }
        let workerCount = min(4, urls.count)
        let resultLock = NSLock()
        var combined: [String: UInt64] = [:]
        func merge(_ result: [String: UInt64]) {
            resultLock.lock()
            combined.merge(result) { _, new in new }
            resultLock.unlock()
        }

        if individually {
            let indexLock = NSLock()
            var next = 0
            DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
                while true {
                    indexLock.lock()
                    let index = next
                    next += 1
                    indexLock.unlock()
                    guard index < urls.count else { return }
                    merge(runDU(for: [urls[index]], timeout: timeout, ignoringNames: ignoringNames))
                }
            }
            return combined
        }

        var groups = Array(repeating: [URL](), count: workerCount)
        for (index, url) in urls.enumerated() {
            groups[index % workerCount].append(url)
        }
        DispatchQueue.concurrentPerform(iterations: workerCount) { index in
            merge(runDU(for: groups[index], timeout: timeout, ignoringNames: ignoringNames))
        }
        return combined
    }

    private static func runDU(
        for urls: [URL],
        timeout: TimeInterval,
        ignoringNames: Set<String>
    ) -> [String: UInt64] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        let exclusions = ignoringNames.sorted().flatMap { ["-I", $0] }
        process.arguments = ["-sk"] + exclusions + urls.map(\.path)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return [:]
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.04)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.08)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let kibibytes = UInt64(parts[0]) else { continue }
            let path = URL(fileURLWithPath: String(parts[1])).standardizedFileURL.path
            result[path] = kibibytes * 1_024
        }
        return result
    }
}
