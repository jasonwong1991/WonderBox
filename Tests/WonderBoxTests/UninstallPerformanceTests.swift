import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI
import XCTest
@testable import WonderBox

final class UninstallPerformanceTests: XCTestCase {
    func testDiscoveryDoesNotEnterLargeRelatedDirectoriesOrWaitForSizes() throws {
        let home = try fixture()
        let app = application(home, "Messenger")
        let data = try directory(home, "Library/Application Support/Messenger")
        let descendants = try directory(data, "profiles/cache/messages")
        let result = RelatedFileScanner.scan(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [], list: { url in
            XCTAssertFalse(url.path.hasPrefix(data.path), "Discovery must not enumerate app data: \(url)")
            return try RelatedFileScanner.children(url)
        }, inspectContents: false, measure: ApplicationDataSize.shallow)
        XCTAssertEqual(result.files.map(\.url), [data])
        XCTAssertFalse(result.files[0].hasMeasuredSize)
        XCTAssertFalse(result.files[0].isSizeComplete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: descendants.path))
    }

    func testVendorMatchingUsesExactProbesNotEnumerationOfOtherAppsData() throws {
        let home = try fixture()
        let app = application(home, "Messenger")
        let vendor = try directory(home, "Library/Application Support/Vendor")
        let leaf = try directory(vendor, "Messenger")
        let unrelated = try directory(home, "Library/Application Support/Other Product")
        let result = RelatedFileScanner.discover(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [], list: { url in
            XCTAssertFalse(url == vendor || url == unrelated, "Vendor discovery must not list other apps' data")
            return try RelatedFileScanner.children(url)
        })
        XCTAssertTrue(result.urls.contains(leaf))
        XCTAssertFalse(result.urls.contains(unrelated))
    }

    func testQuickSizingHasOneEntryBudgetForTheWholeAppAndDoesNotRepeatPartialWalks() throws {
        let home = try fixture()
        var files: [RelatedFile] = []
        for index in 0..<6 {
            let root = try directory(home, "Data\(index)")
            try populate(root, count: 600)
            files.append(.init(url: root, displayPath: root.path, size: 0, isSizeComplete: false, hasMeasuredSize: false))
        }
        let cache = RelatedFileScanCache()
        let started = ProcessInfo.processInfo.systemUptime
        let quick = RelatedFileSizeScanner.measure(files, policy: .quick, cache: cache)
        let duration = ProcessInfo.processInfo.systemUptime - started
        let entries = files.compactMap { cache.cachedMeasurement($0.url)?.entriesVisited }.reduce(0, +)
        XCTAssertLessThanOrEqual(entries, ApplicationSizePolicy.quick.maximumEntries)
        XCTAssertTrue(quick.files.contains { !$0.isSizeComplete })
        XCTAssertLessThan(duration, 1, "Quick sizing is not a per-directory 5-second walk")
        let repeated = RelatedFileSizeScanner.measure(quick.files, policy: .quick, cache: cache)
        // Already budgeted roots use their cached lower bounds, not a repeated traversal.
        for index in quick.files.indices where quick.files[index].hasMeasuredSize {
            XCTAssertEqual(repeated.files[index].size, quick.files[index].size)
            XCTAssertEqual(repeated.files[index].isSizeComplete, quick.files[index].isSizeComplete)
        }
        print("Quick sizing fixture: 3,600 files, \(entries) entries visited in \(Int(duration * 1_000)) ms")
    }

    func testFullSizingFinishesTheSameLargeTreeAndCacheAvoidsRepeatingIt() throws {
        let home = try fixture()
        let root = try directory(home, "data")
        try populate(root, count: 3_000)
        let files = [RelatedFile(url: root, displayPath: root.path, size: 0, isSizeComplete: false, hasMeasuredSize: false)]
        let cache = RelatedFileScanCache()
        let quick = RelatedFileSizeScanner.measure(files, policy: .quick, cache: cache)
        XCTAssertFalse(quick.files[0].isSizeComplete)
        let full = RelatedFileSizeScanner.measure(quick.files, policy: .full, cache: cache)
        XCTAssertTrue(full.files[0].isSizeComplete)
        XCTAssertGreaterThan(full.files[0].size, quick.files[0].size)
        XCTAssertEqual(cache.cachedMeasurement(root)?.entriesVisited, 3_000)
        let cached = RelatedFileSizeScanner.measure(full.files, policy: .quick, cache: cache)
        XCTAssertEqual(cached.files, full.files)
    }

    func testFileBytesDoNotDriveTraversalCostAndCancellationIsCheckedPerEntry() throws {
        let home = try fixture()
        let root = try directory(home, "data")
        let sparse = root.appendingPathComponent("database")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let fd = open(sparse.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, off_t(64 * 1_024 * 1_024 * 1_024)), 0); close(fd)
        let single = ApplicationDataSize.measure(root)
        XCTAssertTrue(single.isComplete)
        XCTAssertEqual(single.entriesVisited, 1) // 64 GB logical file, without allocating 64 GB.
        try populate(root, count: 2_000)
        var probes = 0
        let partial = ApplicationDataSize.measure(root, isCancelled: { probes += 1; return probes > 15 })
        XCTAssertFalse(partial.isComplete)
        XCTAssertLessThanOrEqual(partial.entriesVisited, 15)
    }

    func testStreamingWalkDoesNotLeakDescriptorsWhenCancelledOrBudgeted() throws {
        let home = try fixture()
        let root = try directory(home, "data")
        try populate(try directory(root, "a/b/c"), count: 8)
        let before = descriptors()
        for _ in 0..<100 { _ = ApplicationDataSize.measure(root, maximumEntries: 3) }
        XCTAssertLessThanOrEqual(descriptors(), before + 2)
    }

    func testCacheClearAndDirectoryMutationInvalidateSizeAndListingSnapshots() throws {
        let home = try fixture()
        let root = try directory(home, "data")
        let cache = RelatedFileScanCache()
        XCTAssertTrue(try cache.children(root).isEmpty)
        cache.storeMeasurement(.init(bytes: 55), at: root)
        XCTAssertEqual(cache.cachedMeasurement(root)?.bytes, 55)
        try populate(root, count: 1)
        XCTAssertEqual(try cache.children(root).count, 1)
        XCTAssertNil(cache.cachedMeasurement(root))
        cache.storeMeasurement(.init(bytes: 66), at: root)
        cache.clear()
        XCTAssertNil(cache.cachedMeasurement(root))
    }

    func testRootDedupHandlesPunctuationSiblingsAndScalesToThousandsOfEntries() {
        let paths = ["/fixture/a", "/fixture/a/child", "/fixture/a-other", "/fixture/a-other/child", "/fixture/ab", "/fixture/a", "/fixture/z"]
        let files = paths.map { RelatedFile(url: URL(fileURLWithPath: $0), displayPath: $0, size: 1) }
        XCTAssertEqual(Set(ApplicationStorageUsage.uniqueRoots(files).map { $0.url.path }), ["/fixture/a", "/fixture/a-other", "/fixture/ab", "/fixture/z"])
        let thousands = (0..<5_000).flatMap { index in
            ["/fixture/app\(index)", "/fixture/app\(index)/child"].map { RelatedFile(url: URL(fileURLWithPath: $0), displayPath: $0, size: 1) }
        }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(ApplicationStorageUsage.uniqueRoots(thousands).count, 5_000)
        let duration = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(duration, 2)
        print("10,000-root dedup fixture: \(Int(duration * 1_000)) ms")
    }

    func testReadOnlyWeChatDiscoveryAndBudgetedSizes() throws {
        guard ProcessInfo.processInfo.environment["WONDERBOX_PERFORMANCE_SMOKE"] == "1" else { throw XCTSkip("Opt-in read-only application performance smoke") }
        let url = URL(fileURLWithPath: "/Applications/WeChat.app")
        guard let app = ApplicationScanner.application(from: url) else { throw XCTSkip("Local WeChat sample is absent") }
        let cache = RelatedFileScanCache()
        let started = ProcessInfo.processInfo.systemUptime
        let discovery = ApplicationScanner.relatedFileScan(for: app, cache: cache, mode: .discovery)
        let discoveryTime = ProcessInfo.processInfo.systemUptime - started
        let sizingStarted = ProcessInfo.processInfo.systemUptime
        let sizes = RelatedFileSizeScanner.measure(discovery.files, policy: .quick, cache: cache)
        let sizingTime = ProcessInfo.processInfo.systemUptime - sizingStarted
        let entries = discovery.files.compactMap { cache.cachedMeasurement($0.url)?.entriesVisited }.reduce(0, +)
        XCTAssertLessThanOrEqual(entries, 1_500)
        XCTAssertEqual(Set(discovery.files.map(\.url)), Set(sizes.files.map(\.url)))
        let warmStarted = ProcessInfo.processInfo.systemUptime
        let warm = ApplicationScanner.relatedFileScan(for: app, cache: cache, mode: .discovery)
        let warmTime = ProcessInfo.processInfo.systemUptime - warmStarted
        XCTAssertEqual(Set(warm.files.map(\.url)), Set(discovery.files.map(\.url)))
        print("Read-only WeChat smoke: \(discovery.files.count) roots, cold discovery \(Int(discoveryTime * 1000)) ms, warm discovery \(Int(warmTime * 1000)) ms, quick sizes \(Int(sizingTime * 1000)) ms, \(entries) entries; partial: \(!sizes.files.allSatisfy(\.isSizeComplete))")
    }

    @MainActor
    func testListAppearsWhileSizeWorkerRunsAndSelectionEditsSurviveItsReply() async throws {
        let home = try fixture(), gate = WorkerGate()
        let app = application(home, "One")
        let file = RelatedFile(url: home.appendingPathComponent("data"), displayPath: "data", size: 0, isSizeComplete: false, hasMeasuredSize: false)
        let model = AppModel(applications: [app], relatedFileLoader: { _ in .init(files: [file], inaccessibleLocations: []) }, relatedSizeLoader: { files, _ in
            gate.run()
            var file = files[0]
            file = .init(url: file.url, displayPath: file.displayPath, size: 9_000, isSelected: file.isSelected)
            return .init(files: [file], inaccessibleLocations: [])
        })
        await model.selectApplication(app)
        await wait { gate.started }
        XCTAssertFalse(model.isScanningRelatedFiles)
        XCTAssertTrue(model.isMeasuringRelatedSizes)
        XCTAssertEqual(model.relatedFiles.count, 1)
        model.setRelatedFile(file, selected: false)
        gate.release()
        await model.waitForRelatedSizes()
        XCTAssertEqual(model.relatedFiles.first?.size, 9_000)
        XCTAssertFalse(model.relatedFiles[0].isSelected)
        XCTAssertEqual(model.selectedApplication?.totalSize, 9_100)
        XCTAssertTrue(model.selectedApplication?.storageUsage?.isComplete == true)
        model.cancelApplicationWork()
    }

    @MainActor
    func testChangingAppsActuallyCancelsTheOldSizeWorkerAndDropsLateReplies() async throws {
        let home = try fixture(), gate = WorkerGate()
        let one = application(home, "One"), two = application(home, "Two")
        let file = RelatedFile(url: home.appendingPathComponent("data"), displayPath: "data", size: 0, isSizeComplete: false, hasMeasuredSize: false)
        let model = AppModel(applications: [one, two], applicationStorageLoader: { _ in AsyncStream { $0.finish() } },
                             relatedFileLoader: { app in .init(files: app.name == "One" ? [file] : [], inaccessibleLocations: []) },
                             relatedSizeLoader: { files, _ in gate.run(); return .init(files: files, inaccessibleLocations: []) })
        await model.selectApplication(one)
        await wait { gate.started }
        await model.selectApplication(two)
        await wait { gate.wasCancelled }
        XCTAssertEqual(model.selectedApplication?.id, two.id)
        XCTAssertTrue(model.relatedFiles.isEmpty)
        XCTAssertFalse(model.isMeasuringRelatedSizes)
        model.cancelApplicationWork()
    }

    @MainActor
    func testChangingAppsAlsoCancelsAnUnfinishedDiscoveryWorker() async throws {
        let home = try fixture(), gate = WorkerGate()
        let one = application(home, "One"), two = application(home, "Two")
        let model = AppModel(applications: [one, two], applicationStorageLoader: { _ in AsyncStream { $0.finish() } }, relatedFileLoader: { app in
            if app.name == "One" { gate.run() }
            return .init(files: [], inaccessibleLocations: [])
        })
        let old = Task { await model.selectApplication(one) }
        await wait { gate.started }
        await model.selectApplication(two)
        await wait { gate.wasCancelled }
        await old.value
        XCTAssertEqual(model.selectedApplication?.id, two.id)
        model.cancelApplicationWork()
    }

    @MainActor
    func testLeavingUninstallerCancelsInventoryAndDoesNotStartHiddenSizeWork() async throws {
        let home = try fixture(), gate = WorkerGate()
        let app = application(home, "One")
        let model = AppModel(applicationInventoryLoader: { gate.run(); return [app] }, applicationStorageLoader: { _ in
            XCTFail("Cancelled inventory must not start a background size pass after leaving the tab")
            return AsyncStream { $0.finish() }
        })
        let scan = Task { await model.scanApplications() }
        await wait { gate.started }
        model.suspendApplicationWork()
        await wait { gate.wasCancelled }
        await scan.value
        XCTAssertFalse(model.isScanningApplications)
        XCTAssertFalse(model.isMeasuringApplicationSizes)
        XCTAssertTrue(model.applications.isEmpty)
    }

    @MainActor
    func testInventoryBatchesUpdatesAndCachedPresentationInvalidatesWithFiltersAndSizes() async throws {
        let home = try fixture()
        let apps = (0..<160).map { application(home, "App\($0)") }
        let model = AppModel(applications: apps, applicationStorageLoader: { apps in AsyncStream { continuation in
            for app in apps {
                continuation.yield(.init(id: app.id, usage: .init(files: [.init(url: home.appendingPathComponent("Data/" + app.name), displayPath: app.name, size: 1000)], isComplete: true)))
            }
            continuation.finish()
        } })
        XCTAssertEqual(model.filteredApplicationSize, 16_000)
        var publications = 0
        let subscription = model.$applications.dropFirst().sink { _ in publications += 1 }
        model.measureApplicationSizes()
        await model.waitForApplicationSizes()
        XCTAssertLessThanOrEqual(publications, 12)
        XCTAssertEqual(model.filteredApplicationSize, 176_000)
        model.applicationSearch = "App159"
        XCTAssertEqual(model.filteredApplications.count, 1)
        XCTAssertEqual(model.filteredApplicationSize, 1100)
        model.applicationSearch = ""
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 { _ = model.filteredApplications; _ = model.filteredApplicationSize; _ = model.filteredApplicationSizeIsComplete }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
        _ = subscription
    }

    @MainActor
    func testPendingAndPartialSizesKeepTheCompactLayoutAndRemovalAvailable() async throws {
        let home = try fixture(), app = application(home, "Messenger")
        _ = try directory(home, "Applications/Messenger.app")
        let root = try directory(home, "Library/Containers/net.fixture.messenger")
        let file = RelatedFile(url: root, displayPath: "~/Library/Containers/net.fixture.messenger", size: 0, isSizeComplete: false, hasMeasuredSize: false)
        let model = AppModel(applications: [app], relatedFileLoader: { _ in .init(files: [file], inaccessibleLocations: []) },
                             relatedSizeLoader: { files, _ in .init(files: files, inaccessibleLocations: []) })
        await model.selectApplication(app)
        await model.waitForRelatedSizes()
        XCTAssertFalse(model.isScanningRelatedFiles)
        XCTAssertTrue(model.relatedFiles[0].isSelected)
        for language in ["en", "zh-Hans"] {
            let host = NSHostingView(rootView: ApplicationsView().environmentObject(model).environment(\.locale, Locale(identifier: language)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 610), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host; host.frame = window.contentView!.bounds; host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, 760)
            XCTAssertLessThanOrEqual(host.fittingSize.height, 610)
            if ProcessInfo.processInfo.environment["WONDERBOX_RENDER_PREVIEWS"] == "1" {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/wonderbox-uninstall-performance-\(language).png"))
            }
            window.contentView = nil
        }
        model.cancelApplicationWork()
    }

    @MainActor
    private func wait(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Worker did not reach the expected state")
    }
    private func descriptors() -> Int { (0..<1024).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count }
    private func application(_ home: URL, _ name: String) -> InstalledApplication {
        .init(url: home.appendingPathComponent("Applications/" + name + ".app"), name: name, bundleIdentifier: "net.fixture." + name.lowercased(), version: nil, size: 100, installedAt: nil, lastUsedAt: nil)
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wonderbox-uninstall-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.standardizedFileURL
    }
    private func directory(_ home: URL, _ path: String) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: url.path).standardizedFileURL
    }
    private func populate(_ root: URL, count: Int) throws {
        for index in 0..<count { try Data([1]).write(to: root.appendingPathComponent("file-\(index)")) }
    }
}

private final class WorkerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false, didCancel = false, released = false
    var started: Bool { lock.withLock { didStart } }
    var wasCancelled: Bool { lock.withLock { didCancel } }
    func release() { lock.withLock { released = true } }
    func run() {
        lock.withLock { didStart = true }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !lock.withLock({ released }) && ProcessInfo.processInfo.systemUptime < deadline {
            if Task.isCancelled { lock.withLock { didCancel = true }; return }
            usleep(1_000)
        }
    }
}
