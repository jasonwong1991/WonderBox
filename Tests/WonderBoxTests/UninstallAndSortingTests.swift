import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import WonderBox

final class UninstallAndSortingTests: XCTestCase {
    func testAppInTrashStillFindsItsSandboxContainerAndPreferences() throws {
        let home = try fixture()
        let app = try application(home: home, inTrash: true)
        let container = try directory(home, "Library/Containers/com.thinkyeah.ezshare/Data/Library/Caches").deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let preference = try file(home, "Library/Preferences/com.thinkyeah.ezshare.plist")
        let unrelated = try directory(home, "Library/Containers/com.thinkyeah.ezsharestore")
        let found = discover(app, home: home)
        XCTAssertTrue(found.urls.contains(container.standardizedFileURL))
        XCTAssertTrue(found.urls.contains(preference.standardizedFileURL))
        XCTAssertFalse(found.urls.contains(unrelated.standardizedFileURL))
        XCTAssertTrue(found.inaccessibleLocations.isEmpty)
    }

    func testUUIDContainerMetadataMatchesOnlyItsOwnIdentifier() throws {
        let home = try fixture()
        let app = try application(home: home)
        let own = try directory(home, "Library/Containers/00000000-0000-0000-0000-000000000001")
        let other = try directory(home, "Library/Containers/00000000-0000-0000-0000-000000000002")
        let group = try directory(home, "Library/Group Containers/00000000-0000-0000-0000-000000000003")
        try metadata(own, identifier: "com.thinkyeah.ezshare")
        try metadata(other, identifier: "com.thinkyeah.ezsharestore")
        try metadata(group, identifier: "TEAM.com.thinkyeah.ezshare")
        XCTAssertEqual(Set(discover(app, home: home).urls), Set([own, group].map(\.standardizedFileURL)))
    }

    func testContainerMetadataDoesNotFollowSymlinkedMetadataOrContainer() throws {
        let home = try fixture()
        let app = try application(home: home)
        let outside = try directory(home, "outside")
        try metadata(outside, identifier: "com.thinkyeah.ezshare")
        let alias = home.appendingPathComponent("Library/Containers/com.thinkyeah.ezshare")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let container = try directory(home, "Library/Containers/UUID")
        try FileManager.default.createSymbolicLink(at: container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"),
                                                 withDestinationURL: outside.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        XCTAssertNil(ContainerMetadata.identifier(at: alias))
        XCTAssertNil(ContainerMetadata.identifier(at: container))
        XCTAssertTrue(discover(app, home: home).urls.isEmpty)
    }

    func testUnreadableRootReportsIncompleteScanButExactContainerIsStillProbed() throws {
        let home = try fixture()
        let app = try application(home: home)
        let container = try directory(home, "Library/Containers/com.thinkyeah.ezshare")
        let root = container.deletingLastPathComponent().standardizedFileURL
        let found = RelatedFileScanner.discover(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: []) { url in
            if url.standardizedFileURL == root { throw CocoaError(.fileReadNoPermission) }
            return try RelatedFileScanner.children(url)
        }
        XCTAssertTrue(found.urls.contains(container.standardizedFileURL))
        XCTAssertEqual(found.inaccessibleLocations, [root])
        XCTAssertNotNil(RelatedFileScan(files: [], inaccessibleLocations: found.inaccessibleLocations).accessMessage)
    }

    func testMissingSupportRootsDoNotMasqueradeAsPermissionFailures() throws {
        let home = try fixture()
        let app = try application(home: home)
        let found = discover(app, home: home)
        XCTAssertTrue(found.inaccessibleLocations.isEmpty)
        XCTAssertTrue(found.urls.isEmpty)
    }

    func testIdentifierAndProductNameCannotEscapeKnownRoots() throws {
        let home = try fixture()
        let outside = try file(home, "Important.plist")
        let app = InstalledApplication(url: home.appendingPathComponent("App.app"), name: "../../Important.plist", bundleIdentifier: "../../Important", version: nil, size: 0, installedAt: nil, lastUsedAt: nil)
        XCTAssertFalse(discover(app, home: home).urls.contains(outside))
    }

    func testUninstallOfTrashedAppMovesOnlySelectedRelatedFiles() throws {
        let home = try fixture()
        let app = try application(home: home, inTrash: true)
        let container = try directory(home, "Library/Containers/com.thinkyeah.ezshare")
        let keep = try file(home, "Library/Preferences/com.thinkyeah.ezshare.plist")
        var unchecked = related(keep); unchecked.isSelected = false
        var moved: [URL] = []
        let outcome = ApplicationScanner.uninstall(application: app, relatedFiles: [related(container), unchecked], home: home) { url in
            moved.append(url)
            try FileManager.default.moveItem(at: url, to: home.appendingPathComponent(".Trash/" + url.lastPathComponent))
        }
        XCTAssertEqual(outcome.trashed, 1)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertEqual(moved, [container])
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
    }

    func testClaimedSuccessWithRemainingSourceIsReportedAsFailure() throws {
        let home = try fixture()
        let app = try application(home: home, inTrash: true)
        let container = try directory(home, "Library/Containers/com.thinkyeah.ezshare")
        let outcome = ApplicationScanner.uninstall(application: app, relatedFiles: [related(container)], home: home, trash: { _ in })
        XCTAssertEqual(outcome.trashed, 0)
        XCTAssertEqual(outcome.failed, [container])
    }

    func testUninstallPermissionFailureRetainsFailedLocationForHelperAndRetry() throws {
        let home = try fixture()
        let app = try application(home: home, inTrash: true)
        let container = try directory(home, "Library/Containers/com.thinkyeah.ezshare")
        let outcome = ApplicationScanner.uninstall(application: app, relatedFiles: [related(container)], home: home) { _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        XCTAssertEqual(outcome.failed, [container])
        let remaining = RelatedFileScanner.remainingFiles(previous: [related(container)], scanned: [])
        XCTAssertEqual(remaining.map(\.url), [container])
        XCTAssertTrue(remaining[0].isSelected)
    }

    func testPostUninstallRescanPreservesChoicesAndLeavesNewDiscoveriesUnchecked() {
        let failed = related(URL(fileURLWithPath: "/fixture/failed"))
        var kept = related(URL(fileURLWithPath: "/fixture/kept")); kept.isSelected = false
        let removed = related(URL(fileURLWithPath: "/fixture/removed"))
        let fresh = related(URL(fileURLWithPath: "/fixture/fresh"))
        let remaining = RelatedFileScanner.remainingFiles(previous: [failed, kept, removed], scanned: [kept, fresh]) { url in
            url == removed.url ? .missing : .inaccessible
        }
        XCTAssertEqual(Set(remaining.map(\.url)), Set([failed.url, kept.url, fresh.url]))
        XCTAssertTrue(try XCTUnwrap(remaining.first { $0.url == failed.url }).isSelected)
        XCTAssertFalse(try XCTUnwrap(remaining.first { $0.url == kept.url }).isSelected)
        XCTAssertFalse(try XCTUnwrap(remaining.first { $0.url == fresh.url }).isSelected)
    }

    func testMissingAppDoesNotPreventLeftoverRemoval() throws {
        let home = try fixture()
        let app = try application(home: home)
        try FileManager.default.removeItem(at: app.url)
        let cache = try file(home, "Library/Caches/com.thinkyeah.ezshare")
        let trash = try directory(home, ".Trash")
        let outcome = ApplicationScanner.uninstall(application: app, relatedFiles: [related(cache)], home: home) { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        XCTAssertEqual(outcome.trashed, 1)
        XCTAssertTrue(outcome.failed.isEmpty)
    }

    func testTrashDetectionRequiresActualTrashPathComponent() throws {
        let home = try fixture()
        XCTAssertTrue(ApplicationScanner.isInTrash(home.appendingPathComponent(".Trash/EZ Share.app"), home: home))
        XCTAssertTrue(ApplicationScanner.isInTrash(home.appendingPathComponent(".Trash/WonderBox-ABC/EZ Share.app"), home: home))
        XCTAssertFalse(ApplicationScanner.isInTrash(home.appendingPathComponent(".TrashBackup/EZ Share.app"), home: home))
        XCTAssertFalse(ApplicationScanner.isInTrash(home.appendingPathComponent("Documents/.Trash/EZ Share.app"), home: home))
    }

    func testClickSizeStartsDescendingAndSecondClickReversesOrder() {
        var order = CleanupDetailOrdering()
        order.select(.size)
        XCTAssertFalse(order.ascending)
        let groups = ApplicationCacheGroup.groups(cacheItems())
        XCTAssertEqual(order.groups(groups).map(\.size), [900, 30, 10])
        order.select(.size)
        XCTAssertTrue(order.ascending)
        XCTAssertEqual(order.groups(groups).map(\.size), [10, 30, 900])
        order.select(.name)
        XCTAssertTrue(order.ascending)
        XCTAssertEqual(order.groups(groups).map(\.application.name), ["Alpha", "Zulu", "Other Caches"])
    }

    func testSizeSortIncludesOtherCachesAndHasStableTies() {
        var items = cacheItems()
        var large = CleanupItem(url: items[0].url, size: 900, isSelected: true)
        large.application = items[0].application
        items[0] = large
        let order = CleanupDetailOrdering(field: .size, ascending: false)
        let forward = order.groups(ApplicationCacheGroup.groups(items)).map(\.id)
        let reverse = order.groups(ApplicationCacheGroup.groups(items.reversed())).map(\.id)
        XCTAssertEqual(forward, reverse)
        XCTAssertTrue(forward.prefix(2).contains("unidentified"))
    }

    func testUnknownSizeIsNotTreatedAsZeroAndStaysLastBothDirections() {
        let unknown = CleanupItem(url: URL(fileURLWithPath: "/fixture/unknown"), size: 0, isSelected: false, isSizeEstimated: false)
        let zero = CleanupItem(url: URL(fileURLWithPath: "/fixture/zero"), size: 0, isSelected: true)
        let large = CleanupItem(url: URL(fileURLWithPath: "/fixture/large"), size: 20, isSelected: true)
        for ascending in [true, false] {
            let ordered = CleanupDetailOrdering(field: .size, ascending: ascending).items([unknown, zero, large])
            XCTAssertEqual(ordered.last?.url, unknown.url)
            XCTAssertEqual(ordered.first?.url, ascending ? zero.url : large.url)
        }
    }

    func testSortingDoesNotChangeCacheSelectionOrGroupMembership() {
        let items = cacheItems()
        let selected = Set(items.filter(\.isSelected).map(\.id))
        let groups = ApplicationCacheGroup.groups(items)
        for field: CleanupDetailSort in [.name, .size] {
            let order = CleanupDetailOrdering(field: field, ascending: false)
            let sorted = order.groups(groups)
            XCTAssertEqual(Set(sorted.flatMap(\.items).map(\.id)), Set(items.map(\.id)))
            XCTAssertEqual(sorted.reduce(0) { $0 + $1.selectedCount(in: selected) }, selected.count)
            XCTAssertEqual(Set(order.items(items).filter(\.isSelected).map(\.id)), selected)
        }
    }

    func testReadOnlyDiscoveryOfLocalEZShareSample() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".Trash/EZ Share.app")
        guard let app = ApplicationScanner.application(from: url) else { throw XCTSkip("Local EZ Share sample is absent") }
        let container = home.appendingPathComponent("Library/Containers/com.thinkyeah.ezshare")
        guard FilePresence.check(container) == .present else { throw XCTSkip("Local container is absent") }
        let scan = ApplicationScanner.relatedFileScan(for: app)
        XCTAssertTrue(scan.files.contains { $0.url.standardizedFileURL == container.standardizedFileURL })
        print("Read-only EZ Share smoke: matched sandbox container; \(scan.files.count) related locations, \(scan.inaccessibleLocations.count) access warnings. No files removed.")
    }

    @MainActor
    func testOffscreenSortedCacheAndSettingsLayout() throws {
        guard ProcessInfo.processInfo.environment["WONDERBOX_RENDER_PREVIEWS"] == "1" else { throw XCTSkip("Opt-in UI render") }
        let items = cacheItems().map { source -> CleanupItem in
            var item = CleanupItem(url: source.url, size: source.size * 1_048_576, isSelected: source.isSelected, isDirectory: true)
            item.application = source.application
            return item
        }
        let category = CleanupCategory(kind: .caches, size: 940, itemCount: items.count, isSelected: true, locations: [], items: items)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            try render(CleanupDetailSheet(category: category, initiallyExpandedApps: ["a"], ordering: .init(field: .size, ascending: false))
                .environmentObject(AppModel()).preferredColorScheme(scheme), size: NSSize(width: 900, height: 650), name: "sorted-caches-\(suffix)")
            try render(SettingsView().environmentObject(AppModel()).preferredColorScheme(scheme), size: NSSize(width: 820, height: 1800), name: "settings-width-\(suffix)")
        }
    }

    @MainActor
    private func render<V: View>(_ view: V, size: NSSize, name: String) throws {
        let host = NSHostingView(rootView: view.background(Color.appBackground))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/wonderbox-\(name).png"))
        window.contentView = nil
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wonderbox-uninstall-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func directory(_ home: URL, _ path: String) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func file(_ home: URL, _ path: String) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
        return url
    }
    private func application(home: URL, inTrash: Bool = false) throws -> InstalledApplication {
        let url = try directory(home, (inTrash ? ".Trash" : "Applications") + "/EZ Share.app")
        return InstalledApplication(url: url, name: "极速分享", bundleIdentifier: "com.thinkyeah.ezshare", version: "1.2.8", size: 1, installedAt: nil, lastUsedAt: nil)
    }
    private func related(_ url: URL) -> RelatedFile { .init(url: url, displayPath: url.path, size: 1) }
    private func discover(_ app: InstalledApplication, home: URL) -> RelatedFileScanner.Discovery {
        RelatedFileScanner.discover(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [])
    }
    private func metadata(_ url: URL, identifier: String) throws {
        try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": identifier], format: .binary, options: 0)
            .write(to: url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
    }
    private func cacheItems() -> [CleanupItem] {
        var a = CleanupItem(url: URL(fileURLWithPath: "/fixture/Alpha/Cache"), size: 10, isSelected: true)
        var z = CleanupItem(url: URL(fileURLWithPath: "/fixture/Zulu/Cache"), size: 30, isSelected: false)
        a.application = .init(id: "a", name: "Alpha", bundleURL: nil)
        z.application = .init(id: "z", name: "Zulu", bundleURL: nil)
        return [a, z, CleanupItem(url: URL(fileURLWithPath: "/fixture/Other"), size: 900, isSelected: true)]
    }
}
