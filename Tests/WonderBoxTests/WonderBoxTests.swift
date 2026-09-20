import Foundation
import XCTest
@testable import WonderBox

final class WonderBoxTests: XCTestCase {
    func testByteFormattingProducesReadableUnit() {
        let formatted = AppFormatters.bytes(1_048_576)
        XCTAssertTrue(formatted.contains("MB") || formatted.contains("兆"), formatted)
    }

    func testCleanupSafetyAcceptsOnlyChildrenOfExpectedRoot() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let safeCache = home.appendingPathComponent("Library/Caches/com.example.fixture")
        let cacheRoot = home.appendingPathComponent("Library/Caches")
        let unsafe = home.appendingPathComponent("Documents/important.txt")
        let safeSystemCache = URL(fileURLWithPath: "/Library/Caches/com.example.fixture")

        XCTAssertTrue(StorageCleaner.isSafe(safeCache, for: .caches))
        XCTAssertFalse(StorageCleaner.isSafe(cacheRoot, for: .caches))
        XCTAssertFalse(StorageCleaner.isSafe(unsafe, for: .caches))
        XCTAssertFalse(StorageCleaner.isSafe(safeCache, for: .logs))
        XCTAssertTrue(StorageCleaner.isSafe(safeSystemCache, for: .systemCaches))
        XCTAssertFalse(StorageCleaner.isSafe(URL(fileURLWithPath: "/Library/Caches"), for: .systemCaches))
    }

    func testApplicationScannerRejectsNonApplication() {
        XCTAssertNil(ApplicationScanner.application(from: URL(fileURLWithPath: "/tmp/example.txt")))
    }

    func testApplicationSortingSupportsSizeInstallAndLastUse() {
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 5_000)
        let applications = [
            application("Small", size: 10, installedAt: recent, lastUsedAt: nil),
            application("Large", size: 1_000, installedAt: old, lastUsedAt: recent),
            application("Medium", size: 100, installedAt: nil, lastUsedAt: old)
        ]

        XCTAssertEqual(
            ApplicationOrganizer.sort(applications, by: .size, ascending: false).map(\.name),
            ["Large", "Medium", "Small"]
        )
        XCTAssertEqual(
            ApplicationOrganizer.sort(applications, by: .installedAt, ascending: true).map(\.name),
            ["Large", "Small", "Medium"]
        )
        XCTAssertEqual(
            ApplicationOrganizer.sort(applications, by: .lastUsedAt, ascending: false).map(\.name),
            ["Large", "Medium", "Small"]
        )
    }

    func testApplicationFiltersLargeAndStaleApps() {
        let now = Date(timeIntervalSince1970: 20_000_000)
        let applications = [
            application("Current", size: 500, lastUsedAt: now),
            application("Large", size: ApplicationOrganizer.largeApplicationThreshold, lastUsedAt: now),
            application("Old", size: 100, lastUsedAt: now.addingTimeInterval(-ApplicationOrganizer.staleApplicationAge - 1)),
            application("Unknown", size: 100, lastUsedAt: nil)
        ]

        XCTAssertEqual(ApplicationOrganizer.filter(applications, by: .large, now: now).map(\.name), ["Large"])
        XCTAssertEqual(Set(ApplicationOrganizer.filter(applications, by: .stale, now: now).map(\.name)), ["Old", "Unknown"])
    }

    func testPercentFormattingClampsPresentationInput() {
        XCTAssertEqual(AppFormatters.percent(0.426), "43%")
    }

    func testAwakeDurationsRemainStableForPersistence() {
        XCTAssertEqual(AwakeDuration(rawValue: "oneHour"), .oneHour)
        XCTAssertEqual(AwakeDuration.thirtyMinutes.seconds, 1_800)
        XCTAssertEqual(AwakeDuration.oneHour.seconds, 3_600)
        XCTAssertEqual(AwakeDuration.twoHours.seconds, 7_200)
        XCTAssertNil(AwakeDuration.indefinitely.seconds)
    }

    func testMemoryBreakdownMatchesActivityMonitorCategories() {
        let memory = MemoryBreakdown(total: 1_000, app: 400, wired: 100, compressed: 200, cached: 150)
        XCTAssertEqual(memory.used, 700)
        XCTAssertEqual(memory.available, 150)
        XCTAssertEqual(memory.usedFraction, 0.7, accuracy: 0.0001)

        let overcommitted = MemoryBreakdown(total: 1_000, app: 900, wired: 100, compressed: 100, cached: 100)
        XCTAssertEqual(overcommitted.available, 0)
        XCTAssertEqual(overcommitted.usedFraction, 1)
    }

    func testMemoryOptimizationReportSummarizesEachReleasedCategory() {
        let megabyte: UInt64 = 1_048_576
        let before = MemoryBreakdown(total: 32_768 * megabyte, app: 8_000 * megabyte, wired: 4_000 * megabyte, compressed: 6_000 * megabyte, cached: 3_000 * megabyte)
        let after = MemoryBreakdown(total: 32_768 * megabyte, app: 7_000 * megabyte, wired: 4_000 * megabyte, compressed: 5_500 * megabyte, cached: 500 * megabyte)
        let report = MemoryOptimizationReport(before: before, after: after, steps: [.pressure, .purge])

        XCTAssertEqual(report.usedDelta, -1_500 * Int64(megabyte))
        XCTAssertEqual(report.compressedDelta, -500 * Int64(megabyte))
        XCTAssertTrue(report.summary.hasPrefix("已释放 已用内存 −"), report.summary)
        XCTAssertTrue(report.summary.contains("App −"), report.summary)
        XCTAssertTrue(report.summary.contains("已压缩 −"), report.summary)
        XCTAssertTrue(report.summary.contains("缓存文件 −"), report.summary)
        XCTAssertFalse(report.summary.contains("未能"), report.summary)
    }

    func testMemoryOptimizationReportIsHonestAboutNoise() {
        let before = MemoryBreakdown(total: 1 << 34, app: 1 << 32, wired: 1 << 30, compressed: 1 << 31, cached: 1 << 30)
        var after = before
        after.app -= 8 * 1_048_576
        after.cached += 4 * 1_048_576
        let report = MemoryOptimizationReport(before: before, after: after, steps: [.purge])

        XCTAssertTrue(report.summary.contains("没有可回收的缓存"), report.summary)
        XCTAssertTrue(report.summary.contains("未能向 App 发送内存压力通知"), report.summary)
    }

    func testMemoryOptimizationReportNamesRespondingApplications() {
        let megabyte: UInt64 = 1_048_576
        let before = MemoryBreakdown(total: 32_768 * megabyte, app: 8_000 * megabyte, wired: 4_000 * megabyte, compressed: 6_000 * megabyte, cached: 3_000 * megabyte)
        var after = before
        after.compressed -= 400 * megabyte
        let releases = [
            ApplicationMemoryRelease(name: "Chrome", bytes: 300 * megabyte),
            ApplicationMemoryRelease(name: "Code", bytes: 100 * megabyte)
        ]
        let report = MemoryOptimizationReport(before: before, after: after, steps: [.pressure, .purge], applicationReleases: releases)
        let expectedTail = "响应的 App：Chrome \(AppFormatters.signedMemory(-300 * Int64(megabyte))) · Code \(AppFormatters.signedMemory(-100 * Int64(megabyte)))"
        XCTAssertTrue(report.summary.hasSuffix(expectedTail), report.summary)

        let silent = MemoryOptimizationReport(before: before, after: after, steps: [.pressure])
        XCTAssertTrue(silent.summary.contains("各 App 未释放明显缓存"), silent.summary)
    }

    func testApplicationReleaseAttributionIgnoresGrowthAndNoise() {
        let megabyte: UInt64 = 1_048_576
        func usage(_ name: String, _ footprint: UInt64) -> ApplicationMemoryUsage {
            ApplicationMemoryUsage(
                location: URL(fileURLWithPath: "/Applications/\(name).app"),
                name: name,
                footprint: footprint,
                resident: footprint / 2,
                processCount: 1,
                isQuittable: true
            )
        }
        let before = [usage("Grew", 500 * megabyte), usage("Noise", 500 * megabyte), usage("Big", 1_000 * megabyte), usage("Small", 400 * megabyte)]
        let after = [usage("Grew", 600 * megabyte), usage("Noise", 490 * megabyte), usage("Big", 700 * megabyte), usage("Small", 300 * megabyte), usage("New", 200 * megabyte)]

        let releases = MemoryOptimizationReport.releases(before: before, after: after)
        XCTAssertEqual(releases.map(\.name), ["Big", "Small"])
        XCTAssertEqual(releases.first?.bytes, 300 * megabyte)
    }

    func testApplicationMemoryUsageEstimatesNonResidentShare() {
        let usage = ApplicationMemoryUsage(
            location: URL(fileURLWithPath: "/Applications/Fixture.app"),
            name: "Fixture",
            footprint: 1_000,
            resident: 300,
            processCount: 2,
            isQuittable: true
        )
        XCTAssertEqual(usage.nonResident, 700)

        let sharedHeavy = ApplicationMemoryUsage(
            location: usage.location, name: usage.name, footprint: 300, resident: 900, processCount: 1, isQuittable: true
        )
        XCTAssertEqual(sharedHeavy.nonResident, 0)
    }

    func testMemoryOptimizationStepParsingIgnoresUnknownTokens() {
        XCTAssertEqual(MemoryOptimizationStep.parse("pressure purge"), [.pressure, .purge])
        XCTAssertEqual(MemoryOptimizationStep.parse("purge"), [.purge])
        XCTAssertEqual(MemoryOptimizationStep.parse("系统非活跃缓存已整理"), [])
    }

    func testProcessMemoryInspectorRollsHelpersIntoHostApplication() {
        XCTAssertEqual(
            ProcessMemoryInspector.applicationBundlePath(
                containing: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
            ),
            "/Applications/Google Chrome.app"
        )
        XCTAssertEqual(
            ProcessMemoryInspector.applicationBundlePath(containing: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"),
            "/System/Library/CoreServices/Finder.app"
        )
        XCTAssertNil(ProcessMemoryInspector.applicationBundlePath(containing: "/usr/local/bin/node"))
    }

    func testProcessMemoryInspectorReadsOwnFootprintAndRanksByUsage() {
        XCTAssertGreaterThan(ProcessMemoryInspector.footprint(of: getpid()) ?? 0, 0)
        XCTAssertNil(ProcessMemoryInspector.footprint(of: pid_t.max))

        let consumers = ProcessMemoryInspector.topConsumers(limit: 5)
        XCTAssertFalse(consumers.isEmpty)
        XCTAssertLessThanOrEqual(consumers.count, 5)
        XCTAssertEqual(consumers.map(\.footprint), consumers.map(\.footprint).sorted(by: >))
        XCTAssertTrue(consumers.allSatisfy { $0.processCount >= 1 && !$0.name.isEmpty })
    }

    func testSignedMemoryFormattingUsesBinaryUnits() {
        // 1 GiB must read as exactly 1 GB in binary style, not 1.07 GB in decimal style.
        let gibibyte = AppFormatters.memory(1 << 30)
        XCTAssertTrue(gibibyte.hasPrefix("1") && !gibibyte.contains("."), gibibyte)
        XCTAssertTrue(AppFormatters.signedMemory(-(1 << 30)).hasPrefix("−"))
        XCTAssertTrue(AppFormatters.signedMemory(1 << 20).hasPrefix("+"))
    }

    func testFullDiskAccessProbeUsesReadableProtectedFile() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("wonderbox-fda-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let readable = directory.appendingPathComponent("protected.db")
        try Data([1]).write(to: readable)

        XCTAssertEqual(FullDiskAccessController.status(checking: [readable]), .authorized)
        XCTAssertEqual(
            FullDiskAccessController.status(checking: [directory.appendingPathComponent("missing.db")]),
            .unavailable
        )
    }

    func testQuickCleanExcludesPrivilegedAndDeepCategories() {
        let categories = CleanupKind.allCases.map { kind in
            CleanupCategory(
                kind: kind,
                size: 1,
                itemCount: 1,
                isSelected: true,
                locations: [],
                items: [],
                accessMessage: nil
            )
        }
        let selected = Set(StorageCleaner.quickCleanCategories(from: categories).map(\.kind))

        XCTAssertEqual(selected, [.caches, .logs, .installers, .trash])
        XCTAssertFalse(selected.contains(.systemCaches))
        XCTAssertFalse(selected.contains(where: \.isDeepOnly))
    }

    func testCleanupCategoryUsesPerItemSelection() {
        let root = URL(fileURLWithPath: "/tmp/wonderbox-cleanup-fixture")
        var category = CleanupCategory(
            kind: .caches,
            size: 3_000,
            itemCount: 2,
            isSelected: true,
            locations: [],
            items: [
                CleanupItem(url: root.appendingPathComponent("a"), size: 1_000, isSelected: true),
                CleanupItem(url: root.appendingPathComponent("b"), size: 2_000, isSelected: false)
            ]
        )
        XCTAssertEqual(category.selectedItemCount, 1)
        XCTAssertEqual(category.selectedSize, 1_000)
        category.isSelected = false
        XCTAssertEqual(category.selectedItemCount, 0)
        XCTAssertEqual(category.selectedSize, 0)
    }

    func testCleanupModesExposeDeepCategoriesOnlyWhenRequested() {
        let standard = CleanupKind.kinds(for: .standard)
        let deep = CleanupKind.kinds(for: .deep)

        XCTAssertFalse(standard.contains(where: \.isDeepOnly))
        XCTAssertTrue(deep.contains(.applicationLeftovers))
        XCTAssertTrue(deep.contains(.deviceBackups))
        XCTAssertTrue(deep.contains(.developerDeep))
        XCTAssertTrue(deep.contains(.partialDownloads))
        XCTAssertTrue(deep.contains(.packageCaches))
        XCTAssertTrue(deep.contains(.browserCaches))
        XCTAssertTrue(deep.filter(\.isDeepOnly).allSatisfy { !$0.isSelectedByDefault })
        // User data goes to the Trash; rebuildable caches are removed directly, like the standard cache category.
        XCTAssertTrue([CleanupKind.applicationLeftovers, .deviceBackups, .partialDownloads].allSatisfy(\.movesToTrash))
        XCTAssertFalse(CleanupKind.packageCaches.movesToTrash)
        XCTAssertFalse(CleanupKind.browserCaches.movesToTrash)
    }

    func testDeepCleanupSafetyAcceptsOnlyExpectedRoots() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(StorageCleaner.isSafe(
            home.appendingPathComponent("Library/Preferences/com.example.legacy.plist"),
            for: .applicationLeftovers
        ))
        XCTAssertTrue(StorageCleaner.isSafe(
            home.appendingPathComponent("Library/Application Support/MobileSync/Backup/FIXTURE"),
            for: .deviceBackups
        ))
        XCTAssertTrue(StorageCleaner.isSafe(
            home.appendingPathComponent("Library/Developer/CoreSimulator/Caches/FIXTURE"),
            for: .developerDeep
        ))
        XCTAssertTrue(StorageCleaner.isSafe(
            home.appendingPathComponent("Downloads/FIXTURE.partial"),
            for: .partialDownloads
        ))
        XCTAssertFalse(StorageCleaner.isSafe(home.appendingPathComponent("Documents/FIXTURE"), for: .applicationLeftovers))
        XCTAssertFalse(StorageCleaner.isSafe(
            home.appendingPathComponent("Library/Application Support/MobileSync/Backup"),
            for: .deviceBackups
        ))
    }

    func testBundleIdentifierHeuristicIsConservative() {
        XCTAssertTrue(StorageCleaner.isLikelyBundleIdentifier("com.example.Legacy-App"))
        XCTAssertFalse(StorageCleaner.isLikelyBundleIdentifier("Adobe"))
        XCTAssertFalse(StorageCleaner.isLikelyBundleIdentifier("com.example"))
        XCTAssertFalse(StorageCleaner.isLikelyBundleIdentifier("com.example.bad id"))
    }

    func testSandboxedCachePathsRequireExactContainerLayout() {
        let library = URL(fileURLWithPath: "/Users/fixture/Library")
        let containers = library.appendingPathComponent("Containers/com.example.app/Data")
        XCTAssertTrue(StorageCleaner.isSandboxedCachePath(containers.appendingPathComponent("Library/Caches/blob").path, library: library))
        XCTAssertTrue(StorageCleaner.isSandboxedCachePath(containers.appendingPathComponent("Library/Caches/nested/deeper").path, library: library))
        XCTAssertFalse(StorageCleaner.isSandboxedCachePath(containers.appendingPathComponent("Library/Caches").path, library: library))
        XCTAssertFalse(StorageCleaner.isSandboxedCachePath(containers.appendingPathComponent("Documents/chat.db").path, library: library))
        XCTAssertFalse(StorageCleaner.isSandboxedCachePath(containers.appendingPathComponent("Library/Application Support/x").path, library: library))
        XCTAssertTrue(StorageCleaner.isSandboxedCachePath(
            library.appendingPathComponent("Group Containers/group.example/Library/Caches/item").path,
            library: library
        ))
        XCTAssertFalse(StorageCleaner.isSandboxedCachePath(
            library.appendingPathComponent("Group Containers/group.example/Library/Preferences/item").path,
            library: library
        ))
    }

    func testCachesSafetyAcceptsSandboxedContainerCaches() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(StorageCleaner.isSafe(
            home.appendingPathComponent("Library/Containers/com.example.app/Data/Library/Caches/fixture"),
            for: .caches
        ))
        XCTAssertFalse(StorageCleaner.isSafe(
            home.appendingPathComponent("Library/Containers/com.example.app/Data/Documents/fixture"),
            for: .caches
        ))
    }

    func testPackageCacheSafetyExcludesToolchains() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(StorageCleaner.isSafe(home.appendingPathComponent(".cache/uv"), for: .packageCaches))
        XCTAssertTrue(StorageCleaner.isSafe(home.appendingPathComponent(".npm/_cacache/index-v5"), for: .packageCaches))
        XCTAssertTrue(StorageCleaner.isSafe(home.appendingPathComponent("go/pkg/mod/cache"), for: .packageCaches))
        XCTAssertFalse(StorageCleaner.isSafe(home.appendingPathComponent(".npm"), for: .packageCaches))
        XCTAssertFalse(StorageCleaner.isSafe(home.appendingPathComponent(".nvm/versions/node"), for: .packageCaches))
        XCTAssertFalse(StorageCleaner.isSafe(home.appendingPathComponent(".rustup/toolchains"), for: .packageCaches))
        XCTAssertFalse(StorageCleaner.isSafe(home.appendingPathComponent(".cache"), for: .packageCaches))
    }

    func testBrowserCacheSafetyAcceptsOnlyCacheDirectoriesThemselves() {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        XCTAssertTrue(StorageCleaner.isSafe(support.appendingPathComponent("Google/Chrome/Default/Service Worker/CacheStorage"), for: .browserCaches))
        XCTAssertTrue(StorageCleaner.isSafe(support.appendingPathComponent("discord/Cache"), for: .browserCaches))
        XCTAssertTrue(StorageCleaner.isSafe(support.appendingPathComponent("Code/GPUCache"), for: .browserCaches))
        XCTAssertFalse(StorageCleaner.isSafe(support.appendingPathComponent("Google/Chrome/Default/Service Worker"), for: .browserCaches))
        XCTAssertFalse(StorageCleaner.isSafe(support.appendingPathComponent("discord/Local Storage"), for: .browserCaches))
        XCTAssertFalse(StorageCleaner.isSafe(support.appendingPathComponent("Notion"), for: .browserCaches))
        XCTAssertFalse(StorageCleaner.isSafe(URL(fileURLWithPath: "/tmp/Cache"), for: .browserCaches))
    }

    func testBrowserCacheDiscoverySkipsRunningApplications() throws {
        let manager = FileManager.default
        let support = manager.temporaryDirectory.appendingPathComponent("wonderbox-support-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: support) }
        for path in [
            "Google/Chrome/Default/Service Worker/CacheStorage",
            "Google/Chrome/Default/Local Storage",
            "Microsoft Edge/Default/Code Cache",
            "discord/Cache",
            "CherryStudio/Cache",
            "Plain App/Data"
        ] {
            try manager.createDirectory(at: support.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data().write(to: support.appendingPathComponent("Microsoft Edge/SingletonLock"))
        func relative(_ urls: [URL]) -> Set<String> {
            let root = support.resolvingSymlinksInPath().path + "/"
            return Set(urls.map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: root, with: "") })
        }

        let everything = relative(StorageCleaner.browserCaches(in: support, runningApplications: []))
        XCTAssertEqual(everything, ["Google/Chrome/Default/Service Worker/CacheStorage", "discord/Cache", "CherryStudio/Cache"])

        let running: Set<String> = [RunningApplicationNames.normalize("Google Chrome"), RunningApplicationNames.normalize("Cherry Studio")]
        let filtered = relative(StorageCleaner.browserCaches(in: support, runningApplications: running))
        XCTAssertEqual(filtered, ["discord/Cache"])
    }

    func testSandboxedCacheDiscoveryListsOnlyCacheChildren() throws {
        let manager = FileManager.default
        let library = manager.temporaryDirectory.appendingPathComponent("wonderbox-library-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: library) }
        for path in [
            "Containers/com.example.a/Data/Library/Caches/one",
            "Containers/com.example.a/Data/Library/Caches/two",
            "Containers/com.example.a/Data/Documents/keep",
            "Containers/com.example.b/Data/Library/Preferences",
            "Group Containers/group.example/Library/Caches/shared"
        ] {
            try manager.createDirectory(at: library.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let found = Set(StorageCleaner.sandboxedCaches(in: library).map(\.lastPathComponent))
        XCTAssertEqual(found, ["one", "two", "shared"])
    }

    func testRunningApplicationNameNormalizationIgnoresSpacingAndCase() {
        XCTAssertEqual(RunningApplicationNames.normalize("Cherry Studio"), "cherrystudio")
        XCTAssertEqual(RunningApplicationNames.normalize("cherry-studio"), "cherrystudio")
        XCTAssertEqual(RunningApplicationNames.normalize("Google Chrome"), "googlechrome")
    }

    func testDiskAnalyzerListsImmediateChildrenAndSizes() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("wonderbox-disk-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.bin")
        try Data(repeating: 7, count: 8_192).write(to: file)
        let folder = root.appendingPathComponent("Folder")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 4_096).write(to: folder.appendingPathComponent("nested.bin"))

        let items = DiskAnalyzer.scan(root)
        XCTAssertEqual(Set(items.map { $0.url.lastPathComponent }), ["sample.bin", "Folder"])
        XCTAssertTrue(items.allSatisfy { $0.size > 0 })
        XCTAssertTrue(items.first(where: { $0.url.lastPathComponent == "Folder" })?.isDirectory == true)
    }

    @MainActor
    func testSleepAssertionLifecycle() {
        let preventer = SleepPreventer()
        preventer.enable(duration: 60, keepDisplayAwake: false)
        XCTAssertTrue(preventer.isActive)
        XCTAssertNotNil(preventer.expiresAt)
        preventer.disable()
        XCTAssertFalse(preventer.isActive)
    }

    @MainActor
    func testPrivilegedCleanupCategoriesAreOptIn() {
        let model = AppModel()
        XCTAssertFalse(model.cleanupCategories.first(where: { $0.kind == .systemCaches })?.isSelected ?? true)
        XCTAssertFalse(model.cleanupCategories.first(where: { $0.kind == .developer })?.isSelected ?? true)
    }

    func testMemorySectionIsNavigableFromLaunchArguments() {
        XCTAssertEqual(AppSection(rawValue: "memory"), .memory)
        XCTAssertEqual(AppSection.allCases.firstIndex(of: .memory), 1)
    }

    private func application(
        _ name: String,
        size: UInt64,
        installedAt: Date? = nil,
        lastUsedAt: Date? = nil
    ) -> InstalledApplication {
        InstalledApplication(
            url: URL(fileURLWithPath: "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: "com.example.\(name.lowercased())",
            version: "1.0",
            size: size,
            installedAt: installedAt,
            lastUsedAt: lastUsedAt
        )
    }
}
