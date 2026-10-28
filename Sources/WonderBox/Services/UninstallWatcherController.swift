import AppKit
import Foundation
import ServiceManagement
import WonderSupport

@MainActor
final class UninstallWatcherController: ObservableObject {
    static let identifier = "com.wondercraft.WonderBox.UninstallWatcher"
    static var isSupported: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil }
    @Published private(set) var isInstalled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?
    @Published var pendingEvent: UninstallWatchEvent?
    private let service = SMAppService.loginItem(identifier: identifier)
    private var polling: Task<Void, Never>?
    private var notificationObserver: NSObjectProtocol?
    private var isChecking = false
    private var handled = Set<UUID>()

    init() { refresh() }
    deinit {
        polling?.cancel()
        if let notificationObserver { DistributedNotificationCenter.default().removeObserver(notificationObserver) }
    }

    func refresh() {
        let status = service.status
        isInstalled = status == .enabled || status == .requiresApproval
        requiresApproval = status == .requiresApproval
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
    func consumeInstallPrompt() -> Bool {
        guard Self.isSupported, !UserDefaults.standard.bool(forKey: "uninstallWatcherPromptShown") else { return false }
        UserDefaults.standard.set(true, forKey: "uninstallWatcherPromptShown")
        return !isInstalled
    }
    func setInstalled(_ installed: Bool) async {
        guard Self.isSupported, !isWorking else { return }
        isWorking = true
        defer { isWorking = false; refresh() }
        do {
            if installed {
                try service.register()
            } else {
                try await service.unregister()
                pendingEvent = nil
                for event in UninstallWatchStore.events() { try UninstallWatchStore.remove(event) }
            }
            message = nil
        } catch { message = error.localizedDescription }
    }
    /// Explicit restart adopts the newly embedded helper without discarding pending reviews.
    func restart() async {
        guard Self.isSupported, isInstalled, !isWorking else { return }
        isWorking = true
        defer { isWorking = false; refresh() }
        do {
            try await service.unregister()
            try service.register()
            message = nil
        } catch { message = error.localizedDescription }
    }

    func start() {
        guard Self.isSupported, polling == nil else { return }
        notificationObserver = DistributedNotificationCenter.default().addObserver(forName: UninstallWatchStore.changedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.checkPendingEvents() }
        }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkPendingEvents()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    func suppress(_ application: InstalledApplication) {
        guard let id = application.bundleIdentifier else { return }
        do { try UninstallWatchStore.suppress(id) } catch { message = error.localizedDescription }
    }
    func finish(_ event: UninstallWatchEvent) {
        handled.insert(event.id)
        do { try UninstallWatchStore.remove(event) } catch { message = error.localizedDescription }
        if pendingEvent?.id == event.id { pendingEvent = nil }
        Task { await checkPendingEvents() }
    }
    func checkPendingEvents() async {
        refresh()
        guard isInstalled, !requiresApproval, pendingEvent == nil, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let events = await Task.detached(priority: .utility) { UninstallWatchStore.events() }.value
        for event in events where !handled.contains(event.id) {
            let suppressed = UninstallWatchStore.suppressions()[event.application.bundleIdentifier] != nil
            if suppressed || Date().timeIntervalSince(event.createdAt) > 7 * 86400 {
                finish(event); continue
            }
            let eligible = await Self.eligibility(event.application, requireStopped: false)
            guard pendingEvent == nil, isInstalled else { return }
            if eligible == .obsolete { finish(event); continue }
            if eligible == .deferred { continue }
            pendingEvent = event
            NSApp.activate(ignoringOtherApps: true)
            break
        }
    }
    private enum ReviewEligibility { case ready, deferred, obsolete }

    static func canReview(_ application: WatchedApplication) async -> Bool {
        await eligibility(application, requireStopped: true) == .ready
    }
    private static func eligibility(_ application: WatchedApplication, requireStopped: Bool) async -> ReviewEligibility {
        guard UninstallWatchInventory.isWatchable(application) else { return .obsolete }
        switch FilePresence.check(application.url) {
        case .present: return .obsolete
        case .inaccessible: return .deferred
        case .missing: break
        }
        if requireStopped, NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == application.bundleIdentifier }) {
            return .deferred
        }
        return await Task.detached(priority: .utility) {
            let inventory = UninstallWatchInventory.scan(captureBookmarks: false)
            guard inventory.complete else { return ReviewEligibility.deferred }
            if inventory.applications.contains(where: { $0.bundleIdentifier == application.bundleIdentifier }) { return .obsolete }
            if let relocated = application.relocatedURL, !UninstallWatchInventory.isTrash(relocated), !UninstallWatchInventory.isMissing(relocated) { return .obsolete }
            return .ready
        }.value
    }
    nonisolated static func application(for event: UninstallWatchEvent, cache: RelatedFileScanCache = RelatedFileScanCache()) -> InstalledApplication {
        let app = event.application
        // A trashed bundle can still provide component and app-group identity. A
        // permanently removed bundle uses only its captured product/bundle names.
        let identity = app.relocatedURL.flatMap { url -> ApplicationRelatedIdentity? in
            guard UninstallWatchInventory.isTrash(url), !UninstallWatchInventory.isMissing(url) else { return nil }
            return cache.identity(url)
        } ?? ApplicationRelatedIdentity(isComplete: false)
        return InstalledApplication(url: app.url, name: app.name, bundleIdentifier: app.bundleIdentifier, version: nil,
                                    size: 0, installedAt: nil, lastUsedAt: nil, relatedNames: app.relatedNames, relatedIdentity: identity)
    }
}
