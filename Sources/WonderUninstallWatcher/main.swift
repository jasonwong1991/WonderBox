import AppKit
import Foundation
import OSLog
import WonderSupport

// A separate, user-approved login item. No privilege, network, deletion, or fan access.
final class WatcherDelegate: NSObject, NSApplicationDelegate {
    private var timer: DispatchSourceTimer?
    private var observer: ApplicationDirectoryObserver?
    private var pendingPoll: DispatchWorkItem?
    private var tracker = UninstallWatchTracker()
    private var cached: [WatchedApplication] = []
    private let queue = DispatchQueue(label: "WonderBox.uninstall-watch", qos: .utility)
    private var notified = Set<UUID>()
    private var undelivered: [WatchedApplication] = []
    private var retryAfter: Date = .distantPast
    private let logger = Logger(subsystem: "com.wondercraft.WonderBox.UninstallWatcher", category: "watcher")

    func applicationDidFinishLaunching(_ notification: Notification) {
        observer = ApplicationDirectoryObserver(roots: UninstallWatchInventory.roots, queue: queue) { [weak self] in
            self?.schedulePoll(after: 0.25)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Low-frequency fallback covers missed/coalesced events and newly created roots.
        timer.schedule(deadline: .now(), repeating: 30, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }
    private func schedulePoll(after delay: TimeInterval) {
        pendingPoll?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.poll() }
        pendingPoll = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
    private func poll() {
        pendingPoll?.cancel(); pendingPoll = nil
        let inventory = UninstallWatchInventory.scan(previous: cached)
        if inventory.complete { cached = inventory.applications }
        let removed = tracker.update(inventory.applications, complete: inventory.complete, grace: 8)
        if tracker.hasPendingRemovals { schedulePoll(after: 1) }
        let suppressed = UninstallWatchStore.suppressions()
        undelivered.append(contentsOf: removed)
        undelivered = undelivered.filter { app in
            guard suppressed[app.bundleIdentifier] == nil else { return false }
            do { try UninstallWatchStore.write(UninstallWatchEvent(application: app)); return false }
            catch { logger.error("Could not queue uninstall event: \(error.localizedDescription, privacy: .public)"); return true }
        }
        let events = UninstallWatchStore.events()
        let ids = Set(events.map(\.id))
        notified.formIntersection(ids)
        guard !ids.subtracting(notified).isEmpty, Date() >= retryAfter else { return }
        DistributedNotificationCenter.default().postNotificationName(UninstallWatchStore.changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
        notified.formUnion(ids)
        DispatchQueue.main.async {
            // Open the containing app, not an arbitrary URL scheme handler. The UI reads
            // the local queue and revalidates the app's absence before offering cleanup.
            let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard host.pathExtension == "app" else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([URL(string: "wonderbox://uninstall-review")!], withApplicationAt: host, configuration: configuration) { [weak self] _, error in
                guard error != nil else { return }
                self?.queue.async { [weak self] in
                    self?.notified.subtract(ids)
                    self?.retryAfter = Date().addingTimeInterval(10)
                    self?.schedulePoll(after: 10)
                }
            }
        }
    }
}

let application = NSApplication.shared
let delegate = WatcherDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
