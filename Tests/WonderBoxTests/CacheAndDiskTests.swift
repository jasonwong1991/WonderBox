import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import WonderBox

final class CacheAndDiskTests: XCTestCase {
    @MainActor
    func testCacheDetailSheetOffscreenPreview() throws {
        guard ProcessInfo.processInfo.environment["WONDERBOX_RENDER_PREVIEWS"] == "1" else { return }
        let chrome = CacheApplicationIdentity(id: "com.google.chrome", name: "Google Chrome", bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
        let wechat = CacheApplicationIdentity(id: "com.tencent.xinwechat", name: "WeChat", bundleURL: URL(fileURLWithPath: "/Applications/WeChat.app"))
        var cache = CleanupItem(url: URL(fileURLWithPath: "/fixture/Library/Caches/com.google.chrome"), size: 256 * 1_024 * 1_024, isSelected: true, isDirectory: true)
        var shader = CleanupItem(url: URL(fileURLWithPath: "/fixture/Library/Application Support/Google/Chrome/Default/GPUCache"), size: 32 * 1_024 * 1_024, isSelected: false, isDirectory: true)
        var chat = CleanupItem(url: URL(fileURLWithPath: "/fixture/Library/Containers/com.tencent.xinWeChat/Data/Library/Caches"), size: 16 * 1_024 * 1_024, isSelected: false, isDirectory: true)
        cache.application = chrome; shader.application = chrome; chat.application = wechat
        let category = CleanupCategory(kind: .caches, size: cache.size + shader.size + chat.size, itemCount: 3, isSelected: true, locations: [], items: [cache, shader, chat])
        let host = NSHostingView(rootView: CleanupDetailSheet(category: category, initiallyExpandedApps: [chrome.id]).environmentObject(AppModel()).background(Color.appBackground))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/wonderbox-app-caches-preview.png"))
        window.contentView = nil
    }

    func testReadOnlyLiveDiscoveryAndDirectoryListingTiming() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let start = Date()
        let items = try DiskAnalyzer.list(home)
        let listed = Date().timeIntervalSince(start)
        let catalog = CacheApplicationCatalog.discover()
        let caches = MessagingCacheScanner.locations(for: .wechat, home: home)
        XCTAssertTrue(caches.allSatisfy { MessagingCacheScanner.isSafe($0, for: .wechat, home: home) })
        XCTAssertTrue(caches.allSatisfy { CacheApplicationCatalog.resolve($0, home: home, catalog: catalog) != nil })
        print("Read-only smoke: \(items.count) directory entries listed in \(String(format: "%.1f", listed * 1_000)) ms; \(caches.count) WeChat cache roots; \(catalog.count) app identities")
    }

    func testDirectoryListingDoesNotWaitForRecursiveSizingAndKnowsEmptyFiles() throws {
        try withFixture { root in
            let folder = root.appendingPathComponent("Large")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4_096).write(to: folder.appendingPathComponent("nested"))
            try Data().write(to: root.appendingPathComponent("empty"))
            let items = try DiskAnalyzer.list(root)
            let directory = try XCTUnwrap(items.first { $0.isDirectory })
            XCTAssertEqual(directory.size, 0)
            XCTAssertFalse(directory.isSizeEstimated)
            let empty = try XCTUnwrap(items.first { !$0.isDirectory })
            XCTAssertEqual(empty.size, 0)
            XCTAssertTrue(empty.isSizeEstimated)
        }
    }

    func testDiskUpdatesListBeforeSizingAndDoNotTraverseCloudsOrSymlinks() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("wonderbox-stream-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root.appendingPathComponent("Keep"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: root.appendingPathComponent("Keep/file"))
        for name in ["CloudStorage", "Mobile Documents", "OneDrive", "Dropbox", ".hidden"] {
            try manager.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try manager.createSymbolicLink(at: root.appendingPathComponent("Alias"), withDestinationURL: root.appendingPathComponent("Keep"))
        var iterator = DiskAnalyzer.updates(root).makeAsyncIterator()
        guard case let .contents(items) = await iterator.next() else { return XCTFail("First update must be the listing") }
        XCTAssertEqual(items.map(\.url.lastPathComponent), ["Keep"])
        XCTAssertFalse(items[0].isSizeEstimated)
        var sawSize = false
        while let update = await iterator.next() {
            if case let .sizes(sizes) = update { sawSize = sizes.values.contains { $0 > 0 } || sawSize }
        }
        XCTAssertTrue(sawSize)
    }

    func testCommandCancellationTerminatesSizingWorkPromptly() async {
        let token = ScanCancellation()
        let start = Date()
        let worker = Task.detached {
            CommandRunner.output(of: "/bin/sleep", arguments: ["5"], timeout: 3, isCancelled: { token.isCancelled })
        }
        try? await Task.sleep(for: .milliseconds(60))
        token.cancel()
        _ = await worker.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testFailedSizingOutputIsNotTreatedAsACompletedEstimate() {
        let partial = CommandRunner.output(of: "/bin/sh", arguments: ["-c", "printf partial; exit 1"], timeout: 1)
        XCTAssertEqual(String(decoding: partial, as: UTF8.self), "partial")
        let completed = CommandRunner.output(of: "/bin/sh", arguments: ["-c", "printf partial; exit 1"], timeout: 1, requireSuccessfulExit: true)
        XCTAssertTrue(completed.isEmpty)
    }

    @MainActor
    func testRapidNavigationRejectsOldResultsAndUsesCacheUntilRescan() async throws {
        var streams: [String: AsyncStream<DiskScanUpdate>.Continuation] = [:]
        var launches = 0
        let browser = DiskBrowserController(loader: { url in
            launches += 1
            return AsyncStream { streams[url.path] = $0 }
        })
        let a = URL(fileURLWithPath: "/fixture/a")
        let b = URL(fileURLWithPath: "/fixture/b")
        let itemA = DiskScanItem(url: a.appendingPathComponent("Folder"), size: 0, isDirectory: true, modifiedAt: nil, isSizeEstimated: false)
        let itemB = DiskScanItem(url: b.appendingPathComponent("Folder"), size: 0, isDirectory: true, modifiedAt: nil, isSizeEstimated: false)
        browser.scan(a)
        let old = try XCTUnwrap(streams[a.path])
        old.yield(.contents([itemA]))
        await waitUntil { browser.items.first?.id == itemA.id }
        XCTAssertTrue(browser.isScanning)
        browser.scan(b) // Must not be blocked while a is sizing.
        let current = try XCTUnwrap(streams[b.path])
        old.yield(.sizes([itemA.url: 999]))
        old.yield(.finished)
        old.finish()
        current.yield(.contents([itemB]))
        current.yield(.sizes([itemB.url: 10]))
        current.yield(.finished)
        current.finish()
        await waitUntil { !browser.isScanning }
        XCTAssertEqual(browser.items.map(\.id), [itemB.id])
        XCTAssertEqual(browser.items.first?.size, 10)
        browser.scan(b)
        XCTAssertTrue(browser.isCached)
        XCTAssertEqual(launches, 2)
        browser.scan(b, force: true)
        XCTAssertFalse(browser.isCached)
        XCTAssertEqual(launches, 3)
        browser.cancel()
    }

    @MainActor
    func testFailedScanCanRetryAndRemovalInvalidatesAncestorCache() async {
        var streams: [String: AsyncStream<DiskScanUpdate>.Continuation] = [:]
        var launches = 0
        let browser = DiskBrowserController(loader: { url in
            launches += 1
            return AsyncStream { streams[url.path] = $0 }
        })
        let root = URL(fileURLWithPath: "/fixture")
        browser.scan(root)
        streams[root.path]?.yield(.failed("permission")); streams[root.path]?.finish()
        await waitUntil { !browser.isScanning }
        XCTAssertEqual(browser.error, "permission")
        browser.scan(root)
        XCTAssertEqual(launches, 2)
        streams[root.path]?.yield(.contents([])); streams[root.path]?.yield(.finished); streams[root.path]?.finish()
        await waitUntil { !browser.isScanning }
        browser.invalidate(root.appendingPathComponent("Child"))
        browser.scan(root)
        XCTAssertEqual(launches, 3)
        browser.cancel()
    }

    func testMessagingDiscoveryCoversContainersVersionsWebProfilesAndGroupCaches() throws {
        try withFixture { home in
            let paths = [
                "Library/Caches/com.tencent.xinWeChat",
                "Library/Containers/com.tencent.xinWeChat/Data/Library/Caches",
                "Library/Containers/com.tencent.xinWeChat/Data/Documents/Caches",
                "Library/Containers/com.tencent.xinWeChat/Data/Documents/com.tencent.xinWeChat/2.0b4.0.9/wxid_fixture/Caches",
                "Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_fixture/Cache",
                "Library/Containers/com.tencent.xinWeChat/Data/Library/WebKit/com.tencent.xinWeChat/WebsiteData/NetworkCache",
                "Library/Group Containers/TEAM.com.tencent.xinWeChat/Library/Caches",
                "Library/Containers/com.tencent.WeWorkMac/Data/Library/Caches",
                "Library/Containers/com.tencent.WeWorkMac/Data/Library/Application Support/QtWebEngine/Default/GPUCache",
                "Library/Application Support/WXWork/Profiles/12345678/Cache"
            ]
            for path in paths { try makeDirectory(path, in: home) }
            let wechat = MessagingCacheScanner.locations(for: .wechat, home: home)
            let wecom = MessagingCacheScanner.locations(for: .wecom, home: home)
            XCTAssertEqual(Set(wechat.map { relative($0, home: home) }), Set(paths.prefix(7)))
            XCTAssertEqual(Set(wecom.map { relative($0, home: home) }), Set(paths.suffix(3)))
            XCTAssertTrue(wechat.allSatisfy { MessagingCacheScanner.isSafe($0, for: .wechat, home: home) })
        }
    }

    func testMessagingCachesExcludeDatabasesMediaCookiesAndProfileRoots() throws {
        try withFixture { home in
            let base = "Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_fixture"
            for child in ["Cache", "Msg/Cache", "DB/Cache", "FileStorage/Cache", "Image/Cache", "Video/Cache", "ChatFiles/Cache", "Cookies", "Local Storage"] {
                try makeDirectory(base + "/" + child, in: home)
            }
            let candidates = MessagingCacheScanner.locations(for: .wechat, home: home)
            XCTAssertEqual(candidates.map { relative($0, home: home) }, [base + "/Cache"])
            for child in ["", "/Msg/Cache", "/FileStorage/Cache", "/Cookies", "/Local Storage"] {
                XCTAssertFalse(MessagingCacheScanner.isSafe(home.appendingPathComponent(base + child), for: .wechat, home: home))
            }
            XCTAssertFalse(MessagingCacheScanner.isSafe(home.appendingPathComponent(base + "/Cache"), for: .wecom, home: home))
        }
    }

    func testMessagingValidationRejectsCacheNamedFoldersOutsideSupportedLayouts() throws {
        try withFixture { home in
            let unsupported = [
                "Library/Containers/com.tencent.xinWeChat/Data/Documents/Invoices/Cache",
                "Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_fixture/Arbitrary/Cache",
                "Library/Containers/com.tencent.WeWorkMac/Data/Library/Application Support/Documents/Cache",
                "Library/Application Support/WXWork/RandomUserDocuments/Cache"
            ]
            for path in unsupported {
                try makeDirectory(path, in: home)
                let url = home.appendingPathComponent(path)
                let owner = try XCTUnwrap(MessagingCacheScanner.owner(of: url, home: home))
                XCTAssertFalse(MessagingCacheScanner.isSafe(url, for: owner, home: home), path)
            }
        }
    }

    func testMessagingCachesRejectSymlinksAndDeduplicateNestedCaches() throws {
        try withFixture { home in
            let base = "Library/Containers/com.tencent.xinWeChat/Data/Library"
            try makeDirectory(base + "/Caches/Cache", in: home)
            let cache = home.appendingPathComponent(base + "/Caches")
            XCTAssertEqual(MessagingCacheScanner.locations(for: .wechat, home: home), [cache.standardizedFileURL])
            try makeDirectory("Documents/Important", in: home)
            try FileManager.default.removeItem(at: cache)
            try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: home.appendingPathComponent("Documents/Important"))
            XCTAssertTrue(MessagingCacheScanner.locations(for: .wechat, home: home).isEmpty)
            XCTAssertFalse(MessagingCacheScanner.isSafe(cache, for: .wechat, home: home))
        }
    }

    func testUUIDContainersResolveMessagingOwnersFromMetadata() throws {
        try withFixture { home in
            let container = home.appendingPathComponent("Library/Containers/UUID-Fixture")
            try makeDirectory("Library/Containers/UUID-Fixture/Data/Library/Caches", in: home)
            let data = try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": "com.tencent.WeWorkMac"], format: .binary, options: 0)
            try data.write(to: container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
            let cache = container.appendingPathComponent("Data/Library/Caches")
            XCTAssertEqual(MessagingCacheScanner.owner(of: cache, home: home), .wecom)
            XCTAssertEqual(MessagingCacheScanner.locations(for: .wecom, home: home), [cache.standardizedFileURL])
        }
    }

    func testMessagingCachesAreOptInRecoverableAndRunningAliasesMatch() {
        for app in MessagingApplication.allCases {
            XCTAssertFalse(app.kind.isSelectedByDefault)
            XCTAssertTrue(app.kind.movesToTrash)
            XCTAssertFalse(app.kind.isDeepOnly)
            XCTAssertTrue(app.isRunning([app.identifiers[0]]))
        }
        XCTAssertTrue(MessagingApplication.wechat.isRunning(["微信"]))
        XCTAssertTrue(MessagingApplication.wecom.isRunning(["企业微信"]))
        XCTAssertFalse(MessagingApplication.wecom.isRunning(["wechat"]))
    }

    func testRunningAppIsCheckedAgainAtCleanupTime() throws {
        try withFixture { root in
            let cache = root.appendingPathComponent("Caches")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let category = CleanupCategory(kind: .wechatCaches, size: 1, itemCount: 1, isSelected: true, locations: [cache],
                                           items: [CleanupItem(url: cache, size: 1, isSelected: true)])
            let result = StorageCleaner.clean([category], runningApplications: ["wechat"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
            XCTAssertTrue(result.contains("Skipped") || result.contains("跳过"))
        }
    }

    func testAppStartingAfterConfirmationIsDetectedByLiveProcessCheck() throws {
        try withFixture { root in
            let cache = root.appendingPathComponent("Caches")
            try makeDirectory("Caches", in: root)
            let category = CleanupCategory(kind: .wecomCaches, size: 1, itemCount: 1, isSelected: true, locations: [cache],
                                           items: [CleanupItem(url: cache, size: 1, isSelected: true)])
            let result = StorageCleaner.clean([category], runningApplications: [], runningMessagingApplications: { [.wecom] })
            XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
            XCTAssertTrue(result.contains("Skipped") || result.contains("跳过"))
        }
    }

    func testBackgroundHelpersAndRenamedMessagingAppsAreDetected() throws {
        let paths = ["/Applications/WeChat.app/Contents/Frameworks/Helper.app/Contents/MacOS/worker",
                     "/Applications/企业微信.app/Contents/MacOS/WeWork", "/Applications/Ordinary.app/Contents/MacOS/worker"]
        XCTAssertEqual(MessagingProcessInspector.running(in: paths), [.wechat, .wecom])
        try withFixture { root in
            let contents = root.appendingPathComponent("Renamed.app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.tencent.xinWeChat", "CFBundleName": "Renamed"], format: .xml, options: 0)
            try info.write(to: contents.appendingPathComponent("Info.plist"))
            XCTAssertEqual(MessagingProcessInspector.running(in: [contents.appendingPathComponent("MacOS/worker").path]), [.wechat])
        }
    }

    func testAppAttributionMatchesIdentifiersAndAliasesWithoutMatchingAppstore() throws {
        let home = URL(fileURLWithPath: "/Users/fixture")
        let app = CacheApplicationIdentity(id: "com.example.demo", name: "Demo App", bundleURL: nil, aliases: ["demoapp"])
        let longer = CacheApplicationIdentity(id: "com.example.demo.helper", name: "Helper", bundleURL: nil)
        let catalog = [app, longer]
        XCTAssertEqual(CacheApplicationCatalog.resolve(home.appendingPathComponent("Library/Caches/com.example.demo.NetworkCache"), home: home, catalog: catalog)?.id, app.id)
        XCTAssertEqual(CacheApplicationCatalog.resolve(home.appendingPathComponent("Library/Caches/com.example.demo.helper"), home: home, catalog: catalog)?.id, longer.id)
        XCTAssertEqual(CacheApplicationCatalog.resolve(home.appendingPathComponent("Library/Group Containers/TEAM.com.example.demo/Library/Caches/Cache"), home: home, catalog: catalog)?.id, app.id)
        XCTAssertEqual(CacheApplicationCatalog.resolve(home.appendingPathComponent("Library/Application Support/Demo App/Default/Cache"), home: home, catalog: catalog)?.id, app.id)
        XCTAssertNil(CacheApplicationCatalog.resolve(home.appendingPathComponent("Library/Caches/com.example.demoappstore"), home: home, catalog: catalog))
    }

    func testApplicationGroupsSumCachesAndPreservePartialSelection() {
        let app = CacheApplicationIdentity(id: "com.example.demo", name: "Demo", bundleURL: nil)
        var a = CleanupItem(url: URL(fileURLWithPath: "/fixture/a"), size: 10, isSelected: true)
        var b = CleanupItem(url: URL(fileURLWithPath: "/fixture/b"), size: 20, isSelected: false)
        a.application = app; b.application = app
        let unknown = CleanupItem(url: URL(fileURLWithPath: "/fixture/unknown"), size: 30, isSelected: false)
        let groups = ApplicationCacheGroup.groups([a, b, unknown])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].size, 30)
        XCTAssertEqual(groups[0].selectedCount(in: [a.id]), 1)
        XCTAssertEqual(groups[1].id, "unidentified")
    }

    func testApplicationCatalogDoesNotNeedBundleSizing() throws {
        try withFixture { root in
            let contents = root.appendingPathComponent("Demo.app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.demo", "CFBundleName": "Demo", "CFBundleDisplayName": "Demo App"], format: .xml, options: 0)
            try info.write(to: contents.appendingPathComponent("Info.plist"))
            let catalog = CacheApplicationCatalog.discover(roots: [root])
            XCTAssertEqual(catalog.map(\.id), ["com.example.demo"])
            XCTAssertEqual(catalog.first?.name, "Demo App")
        }
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate())
    }
    private func withFixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wonderbox-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func makeDirectory(_ path: String, in root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    private func relative(_ url: URL, home: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(home.standardizedFileURL.path.count + 1))
    }
}
