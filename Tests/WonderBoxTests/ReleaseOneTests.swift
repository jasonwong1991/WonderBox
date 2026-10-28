import AppKit
import Foundation
import SwiftUI
import WonderSupport
import XCTest
@testable import WonderBox

final class ReleaseOneTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)
    private func app(_ path: String = "/Applications/Fixture.app", id: String = "org.fixture.app") -> WatchedApplication {
        WatchedApplication(url: URL(fileURLWithPath: path), name: "Fixture", bundleIdentifier: id)
    }
    func testTemperatureValidationAndDistinctSensors() {
        for value in [Double.nan, .infinity, -1, 0, 1.5, 9, 126] { XCTAssertNil(TemperatureReading.validated(key: "TC0c", celsius: value)) }
        let readings = [TemperatureReading(id: "TC0c", celsius: 50), TemperatureReading(id: "TC1c", celsius: 65), TemperatureReading(id: "Tg0D", celsius: 45)]
        XCTAssertEqual(Set(readings.map(\.id)).count, 3)
        XCTAssertEqual(readings[0].title, String(localized: "CPU Core \(1)"))
        XCTAssertEqual(TemperatureReading.summary(readings), "65.0 °C")
        XCTAssertEqual(TemperatureReading.summary(readings, gpu: true), "45.0 °C")
        XCTAssertEqual(TemperatureReading.summary([]), "—")
    }
    func testLiveTemperatureReadOnly() {
        let readings = TemperatureMonitor.sample(rediscover: true)
        XCTAssertTrue(readings.allSatisfy { $0.celsius.isFinite && (1...125).contains($0.celsius) })
        print("Read-only temperature sensors: \(readings.prefix(24).map { "\($0.id)=\($0.formatted)" }.joined(separator: ", "))")
    }
    func testWatcherDebouncesAndEmitsOnlyOnce() {
        var tracker = UninstallWatchTracker()
        XCTAssertTrue(tracker.update([app()], complete: true, now: epoch).isEmpty)
        XCTAssertTrue(tracker.update([], complete: true, now: epoch, isMissing: { _ in true }, relocated: { _ in nil }).isEmpty)
        XCTAssertTrue(tracker.update([], complete: true, now: epoch.addingTimeInterval(29), isMissing: { _ in true }, relocated: { _ in nil }).isEmpty)
        XCTAssertEqual(tracker.update([], complete: true, now: epoch.addingTimeInterval(30), isMissing: { _ in true }, relocated: { _ in nil }), [app()])
        XCTAssertTrue(tracker.update([], complete: true, now: epoch.addingTimeInterval(60), isMissing: { _ in true }, relocated: { _ in nil }).isEmpty)
    }
    func testWatcherIgnoresUpgradeRenameDuplicateAndUnreadableInventory() {
        for replacement in [app(), app("/Applications/Renamed.app"), app("/Applications/Other/Fixture.app")] {
            var tracker = UninstallWatchTracker()
            _ = tracker.update([app()], complete: true, now: epoch)
            _ = tracker.update([], complete: true, now: epoch, isMissing: { _ in true }, relocated: { _ in nil })
            XCTAssertTrue(tracker.update([replacement], complete: true, now: epoch.addingTimeInterval(60), isMissing: { _ in true }, relocated: { _ in nil }).isEmpty)
        }
        var tracker = UninstallWatchTracker()
        _ = tracker.update([app()], complete: true, now: epoch)
        XCTAssertTrue(tracker.update([], complete: false, now: epoch.addingTimeInterval(60), grace: 0, isMissing: { _ in true }).isEmpty)
        XCTAssertTrue(tracker.update([], complete: true, now: epoch.addingTimeInterval(120), grace: 0, isMissing: { _ in false }).isEmpty)
    }
    func testDeletingDuplicateCopiesProducesOnePrompt() {
        var tracker = UninstallWatchTracker()
        _ = tracker.update([app(), app("/Applications/Copy.app")], complete: true, now: epoch)
        XCTAssertEqual(tracker.update([], complete: true, now: epoch, grace: 0, isMissing: { _ in true }, relocated: { _ in nil }).count, 1)
    }
    func testM3GPUKeysAreNotCountedAsCPU() {
        XCTAssertTrue(TemperatureReading(id: "Tf14", celsius: 50).isGPU)
        XCTAssertFalse(TemperatureReading(id: "Tf04", celsius: 50).isGPU)
        let values = [TemperatureReading(id: "Tf14", celsius: 50), TemperatureReading(id: "Tf16", celsius: 80)]
        XCTAssertEqual(TemperatureReading.summary(values, gpu: true), "50.0 °C")
        XCTAssertFalse(values[1].isCPU)
    }
    func testWatcherDistinguishesMoveFromTrash() {
        for (path, count) in [("/tmp/Fixture.app", 0), ("/Users/fixture/.Trash/Fixture.app", 1)] {
            var tracker = UninstallWatchTracker()
            _ = tracker.update([app()], complete: true, now: epoch)
            XCTAssertEqual(tracker.update([], complete: true, now: epoch, grace: 0,
                isMissing: { $0.path == "/Applications/Fixture.app" }, relocated: { _ in URL(fileURLWithPath: path) }).count, count)
        }
    }
    func testWatcherInventoryAndQueueUseOnlyLocalFixture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Applications/Fixture.app")
        try FileManager.default.createDirectory(at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.fixture.app", "CFBundleName": "Fixture"], format: .xml, options: 0)
        try plist.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        let inventory = UninstallWatchInventory.scan(roots: [root.appendingPathComponent("Applications")])
        XCTAssertTrue(inventory.complete)
        XCTAssertEqual(inventory.applications.count, 1)
        XCTAssertEqual(inventory.applications.first?.name, "Fixture")
        let store = root.appendingPathComponent("Queue")
        let event = UninstallWatchEvent(application: try XCTUnwrap(inventory.applications.first))
        try UninstallWatchStore.write(event, directory: store)
        XCTAssertEqual(UninstallWatchStore.events(directory: store).map(\.id), [event.id])
        try UninstallWatchStore.remove(event, directory: store)
        XCTAssertTrue(UninstallWatchStore.events(directory: store).isEmpty)
    }
    func testWatchableRejectsOwnAppSystemAppsAndOutsidePaths() {
        XCTAssertTrue(UninstallWatchInventory.isWatchable(app()))
        XCTAssertFalse(UninstallWatchInventory.isWatchable(app(id: "com.wondercraft.WonderBox")))
        XCTAssertFalse(UninstallWatchInventory.isWatchable(app(id: "com.apple.Safari")))
        XCTAssertFalse(UninstallWatchInventory.isWatchable(app("/ApplicationsOther/Fixture.app")))
        XCTAssertFalse(UninstallWatchInventory.isWatchable(app("/Applications/../tmp/Fixture.app")))
    }
    @MainActor
    func testStorageMutationLockIsSharedWithExternalUninstall() {
        let model = AppModel()
        XCTAssertTrue(model.beginExternalUninstall())
        XCTAssertTrue(model.isCleaningStorage)
        XCTAssertFalse(model.beginExternalUninstall())
        model.finishExternalUninstall()
        XCTAssertFalse(model.isCleaningStorage)
        XCTAssertTrue(model.beginExternalUninstall())
        model.finishExternalUninstall()
    }
    func testAutomaticCleanupTriggerBoundaries() {
        var policy = AutomaticCleanupPolicy(enabled: true, trigger: .size, thresholdMB: 1024, intervalHours: 24)
        XCTAssertFalse(policy.shouldClean(bytes: policy.thresholdBytes - 1, lastRun: epoch, now: epoch))
        XCTAssertTrue(policy.shouldClean(bytes: policy.thresholdBytes, lastRun: epoch, now: epoch))
        policy.trigger = .interval
        XCTAssertFalse(policy.shouldClean(bytes: 1, lastRun: epoch, now: epoch.addingTimeInterval(86399)))
        XCTAssertTrue(policy.shouldClean(bytes: 1, lastRun: epoch, now: epoch.addingTimeInterval(86400)))
        XCTAssertFalse(policy.shouldClean(bytes: 0, lastRun: epoch, now: epoch.addingTimeInterval(86400)))
        policy.trigger = .either
        XCTAssertTrue(policy.shouldClean(bytes: policy.thresholdBytes, lastRun: epoch, now: epoch))
        policy.enabled = false
        XCTAssertFalse(policy.shouldClean(bytes: policy.thresholdBytes, lastRun: epoch, now: epoch.addingTimeInterval(86400)))
    }
    @MainActor
    func testAutomaticSettingsPersistenceAndFirstUseOptIn() throws {
        let suite = "WonderBoxTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AutomaticCleanupController(defaults: defaults)
        XCTAssertFalse(controller.policy.enabled)
        XCTAssertTrue(controller.consumeFirstUsePrompt())
        XCTAssertFalse(controller.consumeFirstUsePrompt())
        controller.policy.enabled = true
        controller.policy.thresholdMB = 5120
        controller.policy.intervalHours = 168
        controller.policy.trigger = .interval
        let restored = AutomaticCleanupController(defaults: defaults)
        XCTAssertEqual(restored.policy, controller.policy)
        XCTAssertFalse(restored.consumeFirstUsePrompt())
        controller.policy.enabled = false
        XCTAssertFalse(AutomaticCleanupController(defaults: defaults).policy.enabled)
    }
    func testAutomaticCleanupOnlyAcceptsIdentifiedIdleCacheItems() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let owner = CacheApplicationIdentity(id: "org.fixture.app", name: "Fixture", bundleURL: nil, aliases: ["fixture"])
        var item = CleanupItem(url: home.appendingPathComponent("Library/Caches/org.fixture.app"), size: 1024, isSelected: true)
        item.application = owner
        let cache = CleanupCategory(kind: .caches, size: 1024, itemCount: 1, isSelected: true, locations: [item.url], items: [item], accessMessage: nil)
        XCTAssertEqual(StorageCleaner.automaticCacheCategories(from: [cache], runningApplications: []).count, 1)
        XCTAssertTrue(StorageCleaner.automaticCacheCategories(from: [cache], runningApplications: ["fixture"]).isEmpty)
        XCTAssertTrue(StorageCleaner.automaticCacheCategories(from: [cache], runningApplications: ["org.fixture.app.helper"]).isEmpty)
        var unknown = cache; unknown.items[0].application = nil
        XCTAssertTrue(StorageCleaner.automaticCacheCategories(from: [unknown], runningApplications: []).isEmpty)
        for kind in [CleanupKind.trash, .installers, .wechatCaches, .wecomCaches, .logs, .systemCaches, .applicationLeftovers, .deviceBackups] {
            let other = CleanupCategory(kind: kind, size: 1024, itemCount: 1, isSelected: true, locations: [item.url], items: [item], accessMessage: nil)
            XCTAssertTrue(StorageCleaner.automaticCacheCategories(from: [other], runningApplications: []).isEmpty)
        }
    }
    @MainActor
    func testReleaseOneViewsRenderOffscreen() async throws {
        guard ProcessInfo.processInfo.environment["WONDERBOX_RENDER_PREVIEWS"] == "1" else { return }
        let model = AppModel()
        await model.refreshFans()
        let cases: [(String, AnyView, NSSize)] = [
            ("compact-window", AnyView(MenuBarContentView(preventer: model.sleepPreventer, optimizer: model.memoryOptimizer).environmentObject(model).environmentObject(DockPresenceController())), NSSize(width: 360, height: 600)),
            ("fan", AnyView(FanView().environmentObject(model)), NSSize(width: 1050, height: 1200)),
            ("background-settings", AnyView(VStack { UninstallWatcherSettings(controller: model.uninstallWatcher); AutomaticCleanupSettings(controller: model.automaticCleanup) }.padding(24)), NSSize(width: 760, height: 660)),
            ("external-uninstall", AnyView(ExternalUninstallSheet(event: UninstallWatchEvent(application: app()), controller: model.uninstallWatcher).environmentObject(model)), NSSize(width: 748, height: 568))
        ]
        for (name, view, size) in cases {
            let host = NSHostingView(rootView: view.background(Color.appBackground).preferredColorScheme(.light))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host; host.frame = NSRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: URL(fileURLWithPath: "/tmp/wonderbox-1.0-\(name).png")) }
            }
            window.contentView = nil
        }
    }
}
