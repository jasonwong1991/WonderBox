import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class UpdateController: ObservableObject {
    enum Status: Equatable { case idle, checking, current, available, downloading, downloaded, cancelled, failed }
    static let automaticKey = "automaticallyCheckForUpdates"
    static var isSupported: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil }
    private static let attemptKey = "lastUpdateCheckAttempt"
    private static let successKey = "lastSuccessfulUpdateCheck"
    @Published private(set) var status: Status = .idle
    @Published private(set) var update: AvailableUpdate?
    @Published private(set) var progress = 0.0
    @Published private(set) var message: String?
    @Published private(set) var downloadedURL: URL?
    @Published private(set) var lastChecked: Date?
    private(set) var userInitiatedCheck = false
    let currentVersion: String
    let buildVersion: String
    private let client: any UpdateFetching
    private let defaults: UserDefaults
    private let logger: DiagnosticLogger
    private let clock: () -> Date
    private var task: Task<Void, Never>?
    private var operationID = UUID()

    var isBusy: Bool { status == .checking || status == .downloading }

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.5.0",
         buildVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "5",
         client: any UpdateFetching = GitHubUpdateClient(), defaults: UserDefaults = .standard,
         logger: DiagnosticLogger = .shared, clock: @escaping () -> Date = Date.init) {
        self.currentVersion = currentVersion
        self.buildVersion = buildVersion
        self.client = client
        self.defaults = defaults
        self.logger = logger
        self.clock = clock
        lastChecked = defaults.object(forKey: Self.successKey) as? Date
    }

    deinit { task?.cancel() }

    func checkAutomaticallyIfNeeded() {
        guard Self.isSupported, UpdateSource.shouldCheck(automatically: defaults.object(forKey: Self.automaticKey) as? Bool ?? true,
                                      lastAttempt: defaults.object(forKey: Self.attemptKey) as? Date, now: clock()) else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool = true) {
        guard Self.isSupported, !isBusy else { return }
        userInitiatedCheck = userInitiated
        status = .checking
        message = nil
        let id = UUID()
        operationID = id
        defaults.set(clock(), forKey: Self.attemptKey)
        logger.record(.updateCheckStarted)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await client.latestRelease()
                let found = try release.availableUpdate(after: currentVersion)
                try Task.checkCancellation()
                guard operationID == id else { return }
                update = found
                downloadedURL = nil
                status = found == nil ? .current : .available
                lastChecked = clock()
                defaults.set(lastChecked, forKey: Self.successKey)
                logger.record(.updateCheckFinished)
            } catch {
                guard operationID == id else { return }
                handle(error, event: .updateCheckFinished)
            }
            if operationID == id { task = nil }
        }
    }

    /// A whole-settings refresh waits for the check, without scrolling the page or interrupting a download.
    func refreshCheck() async {
        guard Self.isSupported, status != .downloading else { return }
        if status != .checking { check(userInitiated: false) }
        await task?.value
    }

    func chooseDownloadLocation() {
        guard let update, !isBusy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = update.asset.name
        panel.canCreateDirectories = true
        panel.title = String(localized: "Download Update")
        panel.prompt = String(localized: "Download")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.download(to: url)
        }
    }

    func download(to destination: URL) {
        guard Self.isSupported, let update, !isBusy else { return }
        status = .downloading
        progress = 0
        message = nil
        downloadedURL = nil
        let id = UUID()
        operationID = id
        logger.record(.updateDownloadStarted)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.download(update, to: destination) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.operationID == id, self.status == .downloading else { return }
                        self.progress = min(1, max(0, value))
                    }
                }
                // After the atomic save commits, a late cancel must not misreport the saved file.
                guard operationID == id else { return }
                downloadedURL = destination
                progress = 1
                status = .downloaded
                logger.record(.updateDownloadFinished, metrics: [.bytes: update.asset.size])
            } catch {
                guard operationID == id else { return }
                handle(error, event: .updateDownloadFinished)
            }
            if operationID == id { task = nil }
        }
    }

    func cancel() { task?.cancel() }
    func revealDownload() {
        if let url = downloadedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    func openReleasePage() { NSWorkspace.shared.open(update?.releaseURL ?? UpdateSource.releasesURL) }

    private func handle(_ error: Error, event: DiagnosticEvent) {
        let nsError = error as NSError
        if error is CancellationError || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
            status = .cancelled
            logger.record(event, outcome: .cancelled)
            return
        }
        status = .failed
        if let failure = error as? UpdateError {
            message = failure.message
            var metrics: [DiagnosticMetric: Int64] = [.errorCode: failure.diagnosticCode]
            if case let .http(code) = failure { metrics[.httpStatus] = Int64(code) }
            logger.record(event, outcome: .failure, errorFamily: .release, metrics: metrics)
        } else if nsError.domain == NSURLErrorDomain {
            message = nsError.code == NSURLErrorNotConnectedToInternet
                ? String(localized: "You are offline. Connect to the internet and try again.")
                : String(localized: "The connection failed. Try again or open GitHub Releases.")
            logger.record(event, outcome: .failure, errorFamily: .network, metrics: [.errorCode: Int64(nsError.code)])
        } else {
            message = String(localized: "The download could not be saved. Choose another location.")
            logger.record(event, outcome: .failure, errorFamily: .fileSystem, metrics: [.errorCode: Int64(nsError.code)])
        }
    }
}
