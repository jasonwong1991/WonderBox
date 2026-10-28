import AppKit
import Darwin
import Foundation
import SwiftUI
import WonderSupport
import XCTest
@testable import WonderBox

final class UninstallPolishTests: XCTestCase {
    func testTrashEvidenceDoesNotWaitForTheUpdaterGracePeriod() {
        let app = WatchedApplication(url: URL(fileURLWithPath: "/Applications/Fixture.app"), name: "Fixture", bundleIdentifier: "org.fixture.app")
        var tracker = UninstallWatchTracker()
        let now = Date()
        _ = tracker.update([app], complete: true, now: now)
        let removed = tracker.update([], complete: true, now: now, grace: 30,
                                     isMissing: { $0 == app.url }, relocated: { _ in URL(fileURLWithPath: "/Users/fixture/.Trash/Fixture.app") })
        XCTAssertEqual(removed, [app])
        XCTAssertFalse(tracker.hasPendingRemovals)
    }

    func testUnconfirmedAbsenceStillProtectsUpdatesAndRestores() {
        let app = WatchedApplication(url: URL(fileURLWithPath: "/Applications/Fixture.app"), name: "Fixture", bundleIdentifier: "org.fixture.app")
        var tracker = UninstallWatchTracker()
        let now = Date()
        _ = tracker.update([app], complete: true, now: now)
        XCTAssertTrue(tracker.update([], complete: true, now: now, grace: 8, isMissing: { _ in true }, relocated: { _ in nil }).isEmpty)
        XCTAssertTrue(tracker.hasPendingRemovals)
        XCTAssertTrue(tracker.update([app], complete: true, now: now.addingTimeInterval(7), grace: 8).isEmpty)
        XCTAssertFalse(tracker.hasPendingRemovals)
    }

    func testInventoryCanRevalidateWithoutCreatingBookmarks() throws {
        let root = try fixture()
        try createBundle(root.appendingPathComponent("Fixture.app"))
        let snapshot = UninstallWatchInventory.scan(roots: [root], captureBookmarks: false)
        XCTAssertTrue(snapshot.complete)
        XCTAssertEqual(snapshot.applications.count, 1)
        XCTAssertNil(snapshot.applications.first?.bookmark)
    }

    func testFilesystemObserverSeesNestedApplicationChanges() async throws {
        let root = try fixture()
        let target = root.appendingPathComponent("Nested/Fixture.app")
        let notification = expectation(description: "Filesystem change, not a polling timer")
        let queue = DispatchQueue(label: "WonderBoxTests.directory-events")
        let observer = ApplicationDirectoryObserver(roots: [root], queue: queue) {
            if FileManager.default.fileExists(atPath: target.path) { notification.fulfill() }
        }
        defer { observer.stop() }
        guard observer.isActive else { throw XCTSkip("FSEvents unavailable on this test host") }
        let start = Date()
        try createBundle(target)
        await fulfillment(of: [notification], timeout: 4)
        print("Nested app directory notification: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }

    func testRealBookmarkMoveTriggersAQueuedReviewWithoutGraceDelay() async throws {
        let root = try fixture()
        let apps = root.appendingPathComponent("Applications")
        let source = apps.appendingPathComponent("Fixture.app")
        try createBundle(source)
        let initial = UninstallWatchInventory.scan(roots: [apps])
        XCTAssertEqual(initial.applications.count, 1)
        let trash = root.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let queued = expectation(description: "Real rename/bookmark/FSEvents/queue integration")
        let store = root.appendingPathComponent("Queue")
        let start = Date()
        let observer = ApplicationDirectoryObserver(roots: [apps], queue: DispatchQueue(label: "WonderBoxTests.integration")) {
            let current = UninstallWatchInventory.scan(roots: [apps], previous: initial.applications)
            var tracker = UninstallWatchTracker()
            _ = tracker.update(initial.applications, complete: true)
            for removed in tracker.update(current.applications, complete: current.complete, grace: 30) {
                do {
                    try UninstallWatchStore.write(UninstallWatchEvent(application: removed), directory: store)
                    queued.fulfill()
                } catch { XCTFail("Fixture queue write: \(error)") }
            }
        }
        defer { observer.stop() }
        guard observer.isActive else { throw XCTSkip("FSEvents unavailable on this test host") }
        try FileManager.default.moveItem(at: source, to: trash.appendingPathComponent("Fixture.app"))
        await fulfillment(of: [queued], timeout: 4)
        XCTAssertFalse(UninstallWatchStore.events(directory: store).isEmpty)
        print("Real fixture move to queued review: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }

    @MainActor
    func testDirectTrashSucceedsWithoutFinderOrAdministratorAttempt() async throws {
        let root = try fixture()
        let source = try file(root, "Library/Cookies/org.fixture.app.binarycookies")
        let destination = root.appendingPathComponent("recoverable-cookie")
        var finderCalls = 0
        let result = await SystemTrashService.remove([source], direct: { urls in
            DirectTrashResult.attempt(urls, home: root, move: { try FileManager.default.moveItem(at: $0, to: destination) })
        }, fallback: { _ in finderCalls += 1; return .init() })
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(finderCalls, 0)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testCookieDenialSkipsPointlessFinderAuthorizationAndKeepsOtherResults() async throws {
        let root = try fixture()
        let cookie = try file(root, "Library/Cookies/org.fixture.app.binarycookies")
        let ordinary = try file(root, "Applications/Fixture.app")
        let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        var finderCalls = 0
        let result = await SystemTrashService.remove([cookie, ordinary], direct: { urls in
            DirectTrashResult.attempt(urls, home: root, move: { _ in throw denied })
        }, fallback: { urls in
            finderCalls += 1
            XCTAssertEqual(urls, [ordinary])
            try? FileManager.default.moveItem(at: ordinary, to: root.appendingPathComponent("recoverable-app"))
            return .init(moved: 1)
        })
        XCTAssertEqual(finderCalls, 1)
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.failed, [cookie])
        XCTAssertTrue(result.needsFullDiskAccess)
        XCTAssertFalse(result.needsFinderPermission)
        XCTAssertTrue(result.message?.contains("Administrator authorization") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cookie.path))
    }

    @MainActor
    func testCancelDirectOperationDoesNotStartFinderAndRetainsUnprocessedFiles() async throws {
        let root = try fixture()
        let one = try file(root, "one"), two = try file(root, "two")
        let result = await SystemTrashService.remove([one, two], direct: { urls in
            DirectTrashResult.attempt(urls, home: root, move: { _ in throw CocoaError(.userCancelled) })
        }, fallback: { _ in XCTFail("Cancellation must not open an authorization dialog"); return .init() })
        XCTAssertTrue(result.isCancelled)
        XCTAssertEqual(Set(result.failed), [one, two])
    }

    func testCookiePolicyDoesNotClassifySimilarOrUnrelatedDirectories() {
        let home = URL(fileURLWithPath: "/Users/fixture")
        for path in ["Library/Cookies/a.binarycookies", "Library/Containers/org.fixture/Data/Library/Cookies/a"] {
            XCTAssertTrue(UninstallFileAccess.isCookieLocation(home.appendingPathComponent(path), home: home))
        }
        for path in ["Library/CookiesOther/a", "Downloads/Cookies/a", "Library/Application Support/Cookies/a"] {
            XCTAssertFalse(UninstallFileAccess.isCookieLocation(home.appendingPathComponent(path), home: home))
        }
        XCTAssertFalse(UninstallFileAccess.isCookieLocation(URL(fileURLWithPath: "/Applications/Cookies/a"), home: home))
        XCTAssertFalse(UninstallFileAccess.isPermissionDenial(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
    }

    func testUnreadableCookiesDoNotProduceGuessedPhantomFiles() throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission fixture needs a non-root test runner") }
        let home = try fixture()
        let cookie = try file(home, "Library/Cookies/org.fixture.app.binarycookies")
        let folder = cookie.deletingLastPathComponent()
        XCTAssertEqual(chmod(folder.path, 0), 0)
        defer { chmod(folder.path, 0o700) }
        let app = InstalledApplication(url: home.appendingPathComponent("Applications/Fixture.app"), name: "Fixture", bundleIdentifier: "org.fixture.app", version: nil, size: 0, installedAt: nil, lastUsedAt: nil)
        let result = RelatedFileScanner.discover(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [])
        XCTAssertTrue(result.urls.isEmpty, "No identifier/plist/savedState guesses without existence evidence")
        XCTAssertTrue(result.inaccessibleLocations.contains(folder))
    }

    func testCompleteDirectoryListingDoesNotNeedExactFallbackProbes() throws {
        let home = try fixture()
        let actual = try file(home, "Library/Cookies/org.fixture.app.binarycookies")
        let app = InstalledApplication(url: home.appendingPathComponent("Applications/Fixture.app"), name: "Fixture", bundleIdentifier: "org.fixture.app", version: nil, size: 0, installedAt: nil, lastUsedAt: nil)
        let result = RelatedFileScanner.discover(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [])
        XCTAssertEqual(result.urls, [actual])
    }

    @MainActor
    func testSelectAllPublishesImmediatelyAndSurvivesBackgroundSizing() async throws {
        let root = try fixture(), gate = SizeGate()
        defer { gate.release() }
        let urls = try ["one", "two", "three"].map { try file(root, $0) }
        let files = urls.enumerated().map { index, url in
            RelatedFile(url: url, displayPath: url.path, size: 0, isSelected: index == 0, isSizeComplete: false, hasMeasuredSize: false)
        }
        let review = ExternalUninstallReview(event: event(), discovery: { _, _ in .init(files: files, inaccessibleLocations: []) }, measure: { files, _ in
            gate.wait()
            return .init(files: files.map { RelatedFile(url: $0.url, displayPath: $0.displayPath, size: 100, isSelected: false) }, inaccessibleLocations: [])
        })
        await review.scan()
        XCTAssertFalse(review.isScanning)
        XCTAssertTrue(review.isMeasuring)
        XCTAssertEqual(review.files.count, 3)
        review.selectAll(true)
        XCTAssertEqual(review.selectedCount, 3)
        gate.release()
        await review.waitForSizes()
        XCTAssertEqual(review.selectedCount, 3)
        XCTAssertTrue(review.files.allSatisfy { $0.size == 100 })
        review.selectAll(false)
        XCTAssertEqual(review.selectedCount, 0)
        review.cancel()
    }

    @MainActor
    func testRemovalValidationDoesNotRescanAndRejectsAReplacement() async throws {
        let root = try fixture()
        let path = try file(root, "selected")
        let count = LockedCounter()
        let review = ExternalUninstallReview(event: event(), discovery: { _, _ in
            count.increment()
            return .init(files: [.init(url: path, displayPath: path.path, size: 1)], inaccessibleLocations: [])
        })
        await review.scan()
        XCTAssertEqual(review.validatedSelection(), [path])
        XCTAssertEqual(count.value, 1)
        try FileManager.default.moveItem(at: path, to: root.appendingPathComponent("original"))
        try Data([1]).write(to: path)
        XCTAssertTrue(review.validatedSelection().isEmpty)
        XCTAssertEqual(count.value, 1, "Confirmation must not repeat a global discovery scan")
    }

    func testApplicationMetadataDoesNotRequireAWholeBundleSizeWalk() throws {
        let root = try fixture(), app = root.appendingPathComponent("Fixture.app")
        try createBundle(app)
        let start = Date()
        let value = try XCTUnwrap(ApplicationScanner.application(from: app, measureBundle: false))
        XCTAssertEqual(value.bundleIdentifier, "org.fixture.app")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        if value.size == 0 { XCTAssertFalse(value.isBundleSizeComplete) }
    }

    @MainActor
    func testPermissionGuidanceResetsOnDismiss() {
        let model = AppModel()
        model.presentUninstallResult(message: "fixture", isError: true, needsFinderPermission: false, needsFullDiskAccess: true)
        XCTAssertTrue(model.uninstallNeedsFullDiskAccess)
        model.dismissOperationMessage()
        XCTAssertFalse(model.uninstallNeedsFullDiskAccess)
    }

    @MainActor
    func testDeferredBundleSizeUpdatesBothInventoryAndSelectedApp() async throws {
        let root = try fixture(), url = root.appendingPathComponent("Fixture.app")
        try createBundle(url)
        var app = try XCTUnwrap(ApplicationScanner.application(from: url, measureBundle: false))
        app.size = 0; app.isBundleSizeComplete = false
        let model = AppModel(applications: [app], applicationStorageLoader: { apps in
            ApplicationStorageScanner.updates(apps, scan: { _ in .init(files: [], inaccessibleLocations: []) })
        }, relatedFileLoader: { _ in .init(files: [], inaccessibleLocations: []) })
        model.measureApplicationSizes()
        await model.waitForApplicationSizes()
        XCTAssertGreaterThan(model.applications[0].size, 0)
        XCTAssertTrue(model.applications[0].isBundleSizeComplete)
        await model.selectApplication(app)
        XCTAssertGreaterThan(try XCTUnwrap(model.selectedApplication).size, 0)
        XCTAssertTrue(try XCTUnwrap(model.selectedApplication).isBundleSizeComplete)
        model.cancelApplicationWork()
    }

    func testInventoryCacheNoticesReplacementWithPreservedFolderDate() throws {
        let root = try fixture(), url = root.appendingPathComponent("Fixture.app")
        try createBundle(url)
        let before = UninstallWatchInventory.scan(roots: [root])
        let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try FileManager.default.removeItem(at: url.appendingPathComponent("Contents/Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.fixture.replaced", "CFBundleName": "Changed"], format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
        let after = UninstallWatchInventory.scan(roots: [root], previous: before.applications)
        XCTAssertEqual(after.applications.first?.bundleIdentifier, "org.fixture.replaced")
    }

    @MainActor
    func testSelectionAndCookieGuidanceLayoutsOffscreen() async throws {
        guard ProcessInfo.processInfo.environment["WONDERBOX_RENDER_PREVIEWS"] == "1" else { return }
        let root = try fixture()
        let files = try ["Library/Caches/org.fixture.app", "Library/Preferences/org.fixture.app.plist", "Library/Cookies/org.fixture.app.binarycookies"].enumerated().map { index, path in
            RelatedFile(url: try file(root, path), displayPath: "~/" + path, size: 1024, isSelected: index != 2)
        }
        let review = ExternalUninstallReview(event: event(), discovery: { _, _ in .init(files: files, inaccessibleLocations: []) })
        await review.scan()
        let model = AppModel()
        for (name, view) in [
            ("select-all", AnyView(ExternalUninstallSheet(event: event(), controller: model.uninstallWatcher, review: review).environmentObject(model))),
            ("cookie-guidance", AnyView(CookiePermissionGuidance().padding(24).frame(width: 650)))
        ] {
            let host = NSHostingView(rootView: view.background(Color.appBackground).preferredColorScheme(.light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 570), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host; host.frame = window.contentView!.bounds; host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/wonderbox-1.0.1-\(name).png"))
            window.contentView = nil
        }
    }

    private func event() -> UninstallWatchEvent {
        UninstallWatchEvent(application: WatchedApplication(url: URL(fileURLWithPath: "/Applications/Fixture.app"), name: "Fixture", bundleIdentifier: "org.fixture.app"))
    }
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wonderbox-uninstall-fix-\(UUID())").standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func file(_ root: URL, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
        return url
    }
    private func createBundle(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.fixture.app", "CFBundleName": "Fixture"], format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private final class SizeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    func release() { lock.withLock { released = true } }
    func wait() { while !lock.withLock({ released }) && !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) } }
}
