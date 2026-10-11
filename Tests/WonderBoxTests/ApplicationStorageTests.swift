import AppKit
import Darwin
import Foundation
import SwiftUI
import XCTest
@testable import WonderBox

final class ApplicationStorageTests: XCTestCase {
    func testGasMaskFindsDirectLibraryDataAndNamedLogsWithoutMatchingSimilarApps() throws {
        let home = try fixture()
        let app = application(home, "Gas Mask", identifier: "ee.clockwise.gmask")
        let owned = try directory(home, "Library/Gas Mask")
        let log = try file(home, "Library/Logs/Gas Mask.log")
        let rotated = try file(home, "Library/Logs/Gas Mask.log.1")
        let standard = try directory(home, "Library/Application Support/Gas Mask")
        let preference = try file(home, "Library/Preferences/Gas Mask.plist")
        let hostPreference = try file(home, "Library/Preferences/ByHost/Gas Mask_14AE0918-8480-54BA-9443-260B334E8691.plist")
        let otherPreference = try file(home, "Library/Preferences/Gas Mask Pro.plist")
        let unrelated = try directory(home, "Library/Gas Mask Pro")
        let unrelatedLog = try file(home, "Library/Logs/Gas Mask.log.backup")
        let found = discover(app, home)
        XCTAssertTrue(found.urls.contains(owned))
        XCTAssertTrue(found.urls.contains(log))
        XCTAssertTrue(found.urls.contains(rotated))
        XCTAssertTrue(found.urls.contains(standard))
        XCTAssertTrue(found.urls.contains(preference))
        XCTAssertTrue(found.urls.contains(hostPreference))
        XCTAssertFalse(found.urls.contains(otherPreference))
        XCTAssertFalse(found.urls.contains(unrelated))
        XCTAssertFalse(found.urls.contains(unrelatedLog))
        XCTAssertEqual(RelatedFileCategory.category(for: owned), .support)
    }

    func testBundleAliasesSurviveRemovalAndFindLegacyProductDirectory() throws {
        let home = try fixture()
        var app = application(home, "Localized Label", identifier: "fixture.product")
        app.relatedNames = ["Original Product", "../Documents", "Caches"]
        let data = try directory(home, "Library/Original Product")
        let caches = try directory(home, "Library/Caches")
        let found = discover(app, home)
        XCTAssertTrue(found.urls.contains(data))
        XCTAssertFalse(found.urls.contains(caches))
    }

    func testSharedLibraryRootsAreNeverSelectedByAProductOrIdentifierCollision() throws {
        let home = try fixture()
        for name in ["Mail", "Messages", "Preferences", "Containers", "Caches", "Application Support", "Keychains", "CloudStorage"] {
            let protected = try directory(home, "Library/" + name)
            let app = application(home, name, identifier: name)
            XCTAssertFalse(discover(app, home).urls.contains(protected), name)
        }
    }

    func testDirectLibraryExactProbeStillWorksWhenListingIsDenied() throws {
        let home = try fixture()
        let app = application(home, "Gas Mask", identifier: "ee.clockwise.gmask")
        let data = try directory(home, "Library/Gas Mask")
        let library = home.appendingPathComponent("Library")
        let found = RelatedFileScanner.discover(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: []) { url in
            if url == library { throw CocoaError(.fileReadNoPermission) }
            return try RelatedFileScanner.children(url)
        }
        XCTAssertTrue(found.urls.contains(data))
        XCTAssertTrue(found.inaccessibleLocations.contains(library))
    }

    func testSymlinkedDirectLibraryDataIsNotAssociatedOrFollowed() throws {
        let home = try fixture()
        let target = try directory(home, "keep")
        let library = try directory(home, "Library")
        let link = library.appendingPathComponent("Gas Mask")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertFalse(discover(application(home, "Gas Mask", identifier: "ee.clockwise.gmask"), home).urls.contains(link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testSelectedDirectLibraryDataMovesOnlyWithinTheDisposableFixture() throws {
        let home = try fixture()
        let app = application(home, "Gas Mask", identifier: "ee.clockwise.gmask")
        _ = try directory(home, "Applications/Gas Mask.app")
        let data = try file(home, "Library/Gas Mask/Local/example.hst")
        let scan = RelatedFileScanner.scan(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [])
        XCTAssertTrue(scan.files.contains { $0.url == data.deletingLastPathComponent().deletingLastPathComponent() })
        _ = try directory(home, ".Trash")
        let result = ApplicationScanner.uninstall(application: app, relatedFiles: scan.files, home: home) { url in
            try FileManager.default.moveItem(at: url, to: home.appendingPathComponent(".Trash/" + url.lastPathComponent))
        }
        XCTAssertEqual(result.trashed, 2)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".Trash/Gas Mask/Local/example.hst").path))
    }

    func testAllocatedSizeIncludesHiddenFilesAndFilesInsideNestedPackages() throws {
        let home = try fixture()
        let root = try directory(home, "data")
        let hidden = try file(home, "data/.hidden-database", bytes: 16_384)
        let nested = try file(home, "data/Embedded.app/Contents/data", bytes: 24_576)
        let result = ApplicationDataSize.measure(root)
        XCTAssertTrue(result.isComplete)
        XCTAssertGreaterThanOrEqual(result.bytes, blocks(hidden) + blocks(nested))
    }

    func testAllocatedSizeDoesNotCountExternalSymlinkTargetsOrDuplicateHardLinks() throws {
        let home = try fixture()
        let root = try directory(home, "data")
        let owned = try file(home, "data/own", bytes: 16_384)
        let outside = try file(home, "outside", bytes: 512_000)
        let initial = ApplicationDataSize.measure(root)
        try FileManager.default.linkItem(at: owned, to: root.appendingPathComponent("hardlink"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside-link"), withDestinationURL: outside)
        let result = ApplicationDataSize.measure(root)
        XCTAssertTrue(result.isComplete)
        // A directory may allocate another block as entries are added, but not the target's data.
        XCTAssertLessThan(result.bytes, initial.bytes + blocks(outside))
        XCTAssertLessThan(result.bytes, initial.bytes + blocks(owned))
    }

    func testSizeBudgetOrCancellationIsExplicitlyIncompleteRatherThanACompletedZero() throws {
        let home = try fixture()
        let root = try directory(home, "data")
        _ = try file(home, "data/item", bytes: 16_384)
        XCTAssertFalse(ApplicationDataSize.measure(root, maximumEntries: 0).isComplete)
        XCTAssertFalse(ApplicationDataSize.measure(root, isCancelled: { true }).isComplete)
        XCTAssertFalse(ApplicationDataSize.measure(root, timeout: 0).isComplete)
    }

    func testPartialMeasurementPropagatesToRelatedFilesAndTotal() throws {
        let home = try fixture()
        let app = application(home, "Gas Mask", identifier: "ee.clockwise.gmask")
        _ = try directory(home, "Library/Gas Mask")
        let scan = RelatedFileScanner.scan(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [],
                                          measure: { _ in AllocatedSizeMeasurement(bytes: 123, isComplete: false) })
        XCTAssertEqual(scan.files.first?.size, 123)
        XCTAssertEqual(scan.files.first?.isSizeComplete, false)
        let usage = ApplicationStorageUsage(files: scan.files, isComplete: true)
        XCTAssertFalse(usage.isComplete)
        XCTAssertEqual(usage.relatedSize, 123)
    }

    func testTotalSizeSortAndLargeFilterIncludeDataWithoutChangingBundleSize() {
        let home = URL(fileURLWithPath: "/fixture")
        var small = application(home, "Small Bundle", identifier: "fixture.small", size: 100_000_000)
        small.storageUsage = usage("/fixture/Library/Small Bundle", size: 2_000_000_000)
        var large = application(home, "Large Bundle", identifier: "fixture.large", size: 1_000_000_000)
        large.storageUsage = usage("/fixture/Library/Large Bundle", size: 10)
        XCTAssertEqual(small.size, 100_000_000)
        XCTAssertEqual(small.totalSize, 2_100_000_000)
        XCTAssertEqual(ApplicationOrganizer.sort([large, small], by: .size, ascending: false).first?.id, small.id)
        XCTAssertEqual(ApplicationOrganizer.filter([small], by: .large).count, 1)
        XCTAssertFalse(small.totalSizeText.hasPrefix("≥"))
        var pending = small; pending.storageUsage = nil
        XCTAssertTrue(pending.totalSizeText.hasPrefix("≥"))
    }

    func testNestedAndSharedRootsAreCountedOnceAndSelectionDoesNotChangeTotal() {
        let parent = RelatedFile(url: URL(fileURLWithPath: "/fixture/Library/App"), displayPath: "App", size: 100, isSelected: false)
        let child = RelatedFile(url: parent.url.appendingPathComponent("Cache"), displayPath: "Cache", size: 30)
        let u = ApplicationStorageUsage(files: [child, parent, parent], isComplete: true)
        XCTAssertEqual(u.files.count, 1)
        XCTAssertEqual(u.relatedSize, 100)
        var a = application(URL(fileURLWithPath: "/fixture"), "One", size: 10)
        var b = application(URL(fileURLWithPath: "/fixture"), "Two", size: 20)
        a.storageUsage = u; b.storageUsage = u
        XCTAssertEqual(ApplicationStorageUsage.combinedSize([a, b]), 130)
        XCTAssertEqual(ApplicationStorageUsage.add(.max, 1), .max)
    }

    @MainActor
    func testBackgroundMeasurementUpdatesWholeListAndSortingWithoutSelectingEveryApp() async {
        let home = URL(fileURLWithPath: "/fixture")
        let apps = [application(home, "One", size: 100), application(home, "Two", size: 200)]
        let model = AppModel(applications: apps, applicationStorageLoader: { applications in
            ApplicationStorageScanner.updates(applications, scan: { app in
                RelatedFileScan(files: [.init(url: home.appendingPathComponent("Library/" + app.name), displayPath: app.name, size: app.name == "One" ? 1_000 : 1)], inaccessibleLocations: [])
            })
        })
        model.applicationSort = .size
        model.measureApplicationSizes()
        XCTAssertTrue(model.isMeasuringApplicationSizes)
        await model.waitForApplicationSizes()
        XCTAssertFalse(model.isMeasuringApplicationSizes)
        XCTAssertEqual(model.measuredApplicationCount, 2)
        XCTAssertEqual(model.filteredApplications.first?.name, "One")
        XCTAssertEqual(model.filteredApplicationSize, 1_301)
        XCTAssertTrue(model.filteredApplicationSizeIsComplete)
        XCTAssertNil(model.selectedApplication)
    }

    @MainActor
    func testLateBackgroundReplyCannotOverwriteFreshSelectedApplicationScan() async {
        let holder = StreamHolder()
        let home = URL(fileURLWithPath: "/fixture")
        let app = application(home, "One", size: 100)
        let model = AppModel(applications: [app], applicationStorageLoader: { _ in
            AsyncStream { holder.set($0) }
        }, relatedFileLoader: { _ in
            RelatedFileScan(files: [.init(url: home.appendingPathComponent("Library/One"), displayPath: "One", size: 500)], inaccessibleLocations: [])
        })
        model.measureApplicationSizes()
        await model.selectApplication(app)
        holder.yield(ApplicationStorageUpdate(id: app.id, usage: usage("/fixture/Library/One", size: 10)))
        holder.finish()
        await model.waitForApplicationSizes()
        XCTAssertEqual(model.applications.first?.totalSize, 600)
        XCTAssertEqual(model.selectedApplication?.totalSize, 600)
    }

    @MainActor
    func testCancelledGenerationCannotUpdateReopenedList() async {
        let holder = StreamHolder()
        let app = application(URL(fileURLWithPath: "/fixture"), "One", size: 100)
        let model = AppModel(applications: [app], applicationStorageLoader: { _ in AsyncStream { holder.set($0) } })
        model.measureApplicationSizes()
        model.cancelApplicationSizeScan()
        holder.yield(ApplicationStorageUpdate(id: app.id, usage: usage("/fixture/Library/One", size: 999)))
        holder.finish()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(model.applications.first?.storageUsage)
        XCTAssertFalse(model.isMeasuringApplicationSizes)
    }

    func testBackgroundInventoryHasOnlyOneConcurrentWorker() async {
        let counter = WorkerCounter()
        let apps = (0..<20).map { application(URL(fileURLWithPath: "/fixture"), "App\($0)") }
        var count = 0
        for await _ in ApplicationStorageScanner.updates(apps, scan: { _ in
            counter.begin(); defer { counter.end() }
            usleep(5_000)
            return RelatedFileScan(files: [], inaccessibleLocations: [])
        }) { count += 1 }
        XCTAssertEqual(count, 20)
        XCTAssertEqual(counter.peak, 1)
    }

    @MainActor
    func testStorageSummaryFitsTheExistingSmallUninstallerWindow() async throws {
        let home = try fixture()
        var app = application(home, "Gas Mask", identifier: "ee.clockwise.gmask", size: 10_000_000)
        _ = try directory(home, "Applications/Gas Mask.app")
        let data = try directory(home, "Library/Gas Mask")
        app.storageUsage = ApplicationStorageUsage(files: [.init(url: data, displayPath: "~/Library/Gas Mask", size: 50_000_000)], isComplete: true)
        let usage = app.storageUsage!
        let model = AppModel(applications: [app], relatedFileLoader: { _ in RelatedFileScan(files: usage.files, inaccessibleLocations: []) })
        await model.selectApplication(app)
        let host = NSHostingView(rootView: ApplicationsView().environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 610), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; host.frame = window.contentView!.bounds; host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.height, 610)
        if ProcessInfo.processInfo.environment["WONDERBOX_RENDER_PREVIEWS"] == "1" {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/wonderbox-app-storage-preview.png"))
        }
        window.contentView = nil
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wonderbox-app-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func application(_ home: URL, _ name: String, identifier: String? = "fixture.app", size: UInt64 = 100) -> InstalledApplication {
        InstalledApplication(url: home.appendingPathComponent("Applications/\(name).app"), name: name, bundleIdentifier: identifier, version: nil, size: size, installedAt: nil, lastUsedAt: nil)
    }
    private func directory(_ root: URL, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }
    private func file(_ root: URL, _ path: String, bytes: Int = 8_192) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url.standardizedFileURL
    }
    private func blocks(_ url: URL) -> UInt64 { var info = stat(); _ = lstat(url.path, &info); return UInt64(max(0, info.st_blocks)) * 512 }
    private func discover(_ app: InstalledApplication, _ home: URL) -> RelatedFileScanner.Discovery {
        RelatedFileScanner.discover(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [])
    }
    private func usage(_ path: String, size: UInt64) -> ApplicationStorageUsage {
        ApplicationStorageUsage(files: [.init(url: URL(fileURLWithPath: path), displayPath: path, size: size)], isComplete: true)
    }
}

private final class StreamHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<ApplicationStorageUpdate>.Continuation?
    func set(_ value: AsyncStream<ApplicationStorageUpdate>.Continuation) { lock.withLock { continuation = value } }
    func yield(_ value: ApplicationStorageUpdate) { _ = lock.withLock { continuation?.yield(value) } }
    func finish() { lock.withLock { continuation?.finish() } }
}

private final class WorkerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0
    var peak: Int { lock.withLock { maximum } }
    func begin() { lock.withLock { active += 1; maximum = max(maximum, active) } }
    func end() { lock.withLock { active -= 1 } }
}
