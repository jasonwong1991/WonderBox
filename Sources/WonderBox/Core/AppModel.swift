import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: AppSection? = .overview
    @Published private(set) var snapshot = MetricSnapshot()
    @Published private(set) var processorHistory = ProcessorHistory()
    @Published private(set) var isRefreshingMetrics = false
    @Published private(set) var cpuHistory: [Double] = Array(repeating: 0, count: 30)
    @Published private(set) var gpuHistory: [Double] = Array(repeating: 0, count: 30)
    @Published private(set) var memoryHistory: [Double] = Array(repeating: 0, count: 30)
    @Published private(set) var temperatures: [TemperatureReading] = []
    @Published private(set) var fans: [FanReading] = []
    @Published private(set) var isRefreshingFans = false
    @Published private(set) var hasReadFans = false
    @Published private(set) var fanMessage: String?
    @Published private(set) var isMonitoring = false
    @Published private(set) var applications: [InstalledApplication] = [] {
        didSet { applicationPresentationVersion &+= 1 }
    }
    @Published private(set) var isScanningApplications = false
    @Published private(set) var isMeasuringApplicationSizes = false
    @Published private(set) var measuredApplicationCount = 0
    @Published private(set) var applicationMeasurementCount = 0
    @Published var applicationSearch = ""
    @Published var applicationSort: ApplicationSort = .name {
        didSet {
            guard oldValue != applicationSort else { return }
            applicationSortAscending = applicationSort == .name
        }
    }
    @Published var applicationSortAscending = true
    @Published var applicationFilter: ApplicationFilter = .all
    @Published var selectedApplication: InstalledApplication?
    @Published private(set) var relatedFiles: [RelatedFile] = []
    @Published private(set) var isScanningRelatedFiles = false
    @Published private(set) var isMeasuringRelatedSizes = false
    @Published private(set) var relatedFileScanMessage: String?
    @Published private(set) var isUninstallingApplication = false
    @Published var cleanupScanMode: CleanupScanMode = .standard
    @Published private(set) var cleanupCategories: [CleanupCategory] = CleanupKind.kinds(for: .standard).map {
        CleanupCategory(
            kind: $0,
            size: 0,
            itemCount: 0,
            isSelected: $0.isSelectedByDefault,
            locations: [],
            items: [],
            accessMessage: nil
        )
    }
    @Published private(set) var isScanningStorage = false
    @Published private(set) var operationMessage: String?
    @Published private(set) var uninstallMessageIsError = false
    @Published private(set) var uninstallNeedsFinderPermission = false
    @Published private(set) var uninstallNeedsFullDiskAccess = false
    @Published private(set) var uninstallRemainingItems: [URL] = []
    @Published private(set) var isCleaningStorage = false
    @Published private(set) var quickCleanEstimate: UInt64?
    @Published private(set) var quickCleanEstimateDate: Date?
    @Published private(set) var isEstimatingQuickClean = false
    @Published private(set) var isQuickCleaning = false
    @Published private(set) var quickActionMessage: String?
    @Published private(set) var fullDiskAccessStatus = FullDiskAccessController.currentStatus()

    let sleepPreventer = SleepPreventer()
    let memoryOptimizer = MemoryOptimizer()
    let processorMonitor = ProcessorMonitor()
    let sectionRefresh = SectionRefreshController()
    let systemInfo = SystemInformation.current
    let updater = UpdateController()
    let diagnostics = DiagnosticsController()
    let automaticCleanup = AutomaticCleanupController()
    let uninstallWatcher = UninstallWatcherController()

    private var monitorTask: Task<Void, Never>?
    private var metricsRefreshTask: Task<Void, Never>?
    private var previousCounters: SystemCounters?
    private var relatedFileScanID = UUID()
    private var applicationSizeTask: Task<Void, Never>?
    private var applicationSizeScanID = UUID()
    private var applicationInventoryScanID = UUID()
    private var applicationInventoryWorker: Task<[InstalledApplication], Never>?
    private var applicationWorkEnabled = true
    private var needsApplicationInventoryRefresh = false
    private var foregroundSizeOverrides = Set<URL>()
    private let relatedScanCache: RelatedFileScanCache
    private var relatedFileWorker: Task<RelatedFileScan, Never>?
    private var relatedSizeWorker: Task<RelatedFileScan, Never>?
    private var relatedSizeTask: Task<Void, Never>?
    private var relatedSizeScanID = UUID()
    private var relatedDiscoveryScan: RelatedFileScan?
    private var applicationPresentationVersion = 0
    private var cachedApplicationPresentation: ApplicationPresentation?
    private let applicationStorageLoader: @Sendable ([InstalledApplication]) -> AsyncStream<ApplicationStorageUpdate>
    private let applicationInventoryLoader: @Sendable () -> [InstalledApplication]
    private let relatedFileLoader: @Sendable (InstalledApplication) -> RelatedFileScan
    private let relatedSizeLoader: @Sendable ([RelatedFile], ApplicationSizePolicy) -> RelatedFileScan
    private var didOfferFullDiskAccess = false
    private var didStartServices = false

    var supportsFullDiskAccess: Bool {
        FullDiskAccessController.isSupported
    }

    init(applications: [InstalledApplication] = [],
         applicationInventoryLoader: @escaping @Sendable () -> [InstalledApplication] = { ApplicationScanner.scanApplications() },
         applicationStorageLoader: (@Sendable ([InstalledApplication]) -> AsyncStream<ApplicationStorageUpdate>)? = nil,
         relatedFileLoader: (@Sendable (InstalledApplication) -> RelatedFileScan)? = nil,
         relatedSizeLoader: (@Sendable ([RelatedFile], ApplicationSizePolicy) -> RelatedFileScan)? = nil) {
        let cache = RelatedFileScanCache()
        self.relatedScanCache = cache
        self.applications = applications
        self.applicationInventoryLoader = applicationInventoryLoader
        self.applicationStorageLoader = applicationStorageLoader ?? { ApplicationStorageScanner.updates($0, cache: cache) }
        self.relatedFileLoader = relatedFileLoader ?? { ApplicationScanner.relatedFileScan(for: $0, cache: cache, mode: .discovery) }
        self.relatedSizeLoader = relatedSizeLoader ?? { RelatedFileSizeScanner.measure($0, policy: $1, cache: cache) }
        guard let flagIndex = CommandLine.arguments.firstIndex(of: "--section"),
              CommandLine.arguments.indices.contains(flagIndex + 1),
              let requested = AppSection(rawValue: CommandLine.arguments[flagIndex + 1])
        else { return }
        selection = requested
    }

    private struct ApplicationPresentation {
        let version: Int, search: String, sort: ApplicationSort, ascending: Bool, filter: ApplicationFilter
        let applications: [InstalledApplication]
        let total: UInt64
        let isComplete: Bool
    }

    private func applicationPresentation() -> ApplicationPresentation {
        if let cached = cachedApplicationPresentation, cached.version == applicationPresentationVersion,
           cached.search == applicationSearch, cached.sort == applicationSort,
           cached.ascending == applicationSortAscending, cached.filter == applicationFilter { return cached }
        let searched: [InstalledApplication]
        if applicationSearch.isEmpty {
            searched = applications
        } else {
            searched = applications.filter {
                $0.name.localizedCaseInsensitiveContains(applicationSearch) ||
                ($0.bundleIdentifier?.localizedCaseInsensitiveContains(applicationSearch) ?? false)
            }
        }
        let filtered = ApplicationOrganizer.filter(searched, by: applicationFilter)
        let sorted = ApplicationOrganizer.sort(filtered, by: applicationSort, ascending: applicationSortAscending)
        let value = ApplicationPresentation(version: applicationPresentationVersion, search: applicationSearch, sort: applicationSort,
                                            ascending: applicationSortAscending, filter: applicationFilter, applications: sorted,
                                            total: ApplicationStorageUsage.combinedSize(sorted),
                                            isComplete: sorted.allSatisfy { $0.isBundleSizeComplete && $0.storageUsage?.isComplete == true })
        cachedApplicationPresentation = value
        return value
    }

    var filteredApplications: [InstalledApplication] { applicationPresentation().applications }

    var filteredApplicationSize: UInt64 {
        applicationPresentation().total
    }

    var filteredApplicationSizeIsComplete: Bool {
        applicationPresentation().isComplete
    }

    var selectedCleanupSize: UInt64 {
        cleanupCategories.reduce(0) { $0 + $1.selectedSize }
    }

    var selectedCleanupItemCount: Int {
        cleanupCategories.reduce(0) { $0 + $1.selectedItemCount }
    }

    func startApplicationServices() {
        if !didStartServices {
            didStartServices = true
            DiagnosticLogger.shared.record(.appStarted)
            uninstallWatcher.start()
            automaticCleanup.start { [weak self] policy, lastRun in
                await self?.performAutomaticCleanup(policy: policy, lastRun: lastRun)
            }
        }
        updater.checkAutomaticallyIfNeeded()
    }

    func startMonitoring() {
        guard monitorTask == nil else { return }
        isMonitoring = true
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshMetrics()
                switch self.selection {
                case .fan: await self.refreshFans()
                case .memory: await self.memoryOptimizer.refreshApplications()
                case .cpu, .gpu: await self.processorMonitor.refresh()
                default: break
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        isMonitoring = false
    }

    func refreshMetrics() async {
        if let metricsRefreshTask { await metricsRefreshTask.value; return }
        isRefreshingMetrics = true
        let task = Task { await sampleMetrics() }
        metricsRefreshTask = task
        defer { metricsRefreshTask = nil; isRefreshingMetrics = false }
        await task.value
    }

    private func sampleMetrics() async {
        let previous = previousCounters
        let sample = await Task.detached(priority: .utility) {
            SystemMonitor.sample(previous: previous)
        }.value
        previousCounters = sample.counters
        snapshot = sample.snapshot
        processorHistory.append(sample.snapshot)
        cpuHistory.append(sample.snapshot.cpuUsage)
        gpuHistory.append(sample.snapshot.gpuUsage ?? 0)
        memoryHistory.append(sample.snapshot.memoryFraction)
        cpuHistory = Array(cpuHistory.suffix(60))
        gpuHistory = Array(gpuHistory.suffix(60))
        memoryHistory = Array(memoryHistory.suffix(60))
    }

    func refreshFans() async {
        guard !isRefreshingFans else { return }
        isRefreshingFans = true
        defer { isRefreshingFans = false; hasReadFans = true }
        let isInitial = !hasReadFans
        fans = await Task.detached(priority: .utility) {
            FanController.initialReadings(retry: isInitial)
        }.value
        temperatures = await Task.detached(priority: .utility) {
            TemperatureMonitor.sample(rediscover: isInitial)
        }.value
        if isInitial {
            DiagnosticLogger.shared.record(.fanInitialRead, outcome: fans.isEmpty ? .unavailable : .success,
                                           metrics: [.count: Int64(fans.count), .zeroReadings: Int64(fans.filter { $0.currentRPM == 0 }.count)])
        }
    }

    func refreshFullDiskAccessStatus() {
        fullDiskAccessStatus = FullDiskAccessController.currentStatus()
    }

    func shouldOfferFullDiskAccess(suppressed: Bool) -> Bool {
        refreshFullDiskAccessStatus()
        guard supportsFullDiskAccess, !didOfferFullDiskAccess else { return false }
        didOfferFullDiskAccess = true
        return !suppressed && fullDiskAccessStatus != .authorized
    }

    func openFullDiskAccessSettings() {
        FullDiskAccessController.openSystemSettings()
    }

    func optimizeMemory() async {
        quickActionMessage = nil
        await memoryOptimizer.optimize()
        await refreshMetrics()
    }

    func quickClean() async {
        guard !isQuickCleaning, !isScanningStorage, !isCleaningStorage, !isEstimatingQuickClean, !isUninstallingApplication else { return }
        isQuickCleaning = true
        isScanningStorage = true
        quickActionMessage = nil
        memoryOptimizer.dismissMessage()
        let running = RunningApplicationNames.current()
        let categories = await Task.detached(priority: .utility) {
            StorageCleaner.scan(mode: .standard, runningApplications: running)
        }.value
        let quickCleanCategories = StorageCleaner.quickCleanCategories(from: categories)
        let currentRunning = RunningApplicationNames.current()
        let result = await Task.detached(priority: .userInitiated) {
            StorageCleaner.clean(quickCleanCategories, runningApplications: currentRunning)
        }.value
        quickActionMessage = result
        isScanningStorage = false
        isQuickCleaning = false
        quickCleanEstimate = nil
        quickCleanEstimateDate = nil
        await refreshQuickCleanEstimate(force: true)
    }

    func refreshQuickCleanEstimate(force: Bool = false) async {
        guard !isEstimatingQuickClean, !isScanningStorage, !isCleaningStorage, !isQuickCleaning, !isUninstallingApplication else { return }
        if !force, let date = quickCleanEstimateDate, Date().timeIntervalSince(date) < 300 { return }
        isEstimatingQuickClean = true
        defer { isEstimatingQuickClean = false }
        let running = RunningApplicationNames.current()
        let categories = await Task.detached(priority: .utility) {
            StorageCleaner.scan(mode: .standard, runningApplications: running)
        }.value
        updateQuickCleanEstimate(categories)
    }

    private func updateQuickCleanEstimate(_ categories: [CleanupCategory]) {
        quickCleanEstimate = StorageCleaner.quickCleanCategories(from: categories).reduce(0) { $0 + $1.selectedSize }
        quickCleanEstimateDate = Date()
    }

    private func performAutomaticCleanup(policy: AutomaticCleanupPolicy, lastRun: Date) async -> String? {
        guard !isScanningStorage, !isCleaningStorage, !isQuickCleaning, !isEstimatingQuickClean,
              !isUninstallingApplication else { return nil }
        isCleaningStorage = true
        defer { isCleaningStorage = false }
        let running = RunningApplicationNames.current(includeBackground: true)
        let categories = await Task.detached(priority: .utility) {
            StorageCleaner.automaticCacheScan(runningApplications: running)
        }.value
        guard automaticCleanup.policy == policy, !Task.isCancelled,
              policy.shouldClean(bytes: categories.reduce(0) { $0 + $1.selectedSize }, lastRun: lastRun, now: Date()) else { return nil }
        var outcome = StorageCleanupResult()
        var attempted = false
        for category in categories {
            for item in category.items {
                guard automaticCleanup.policy == policy, !Task.isCancelled else { break }
                // Re-check foreground/background applications between items, not just before the scan.
                var single = category; single.items = [item]; single.locations = [item.url]
                let eligible = StorageCleaner.automaticCacheCategories(from: [single], runningApplications: RunningApplicationNames.current(includeBackground: true))
                guard !eligible.isEmpty else { continue }
                let running = RunningApplicationNames.current(includeBackground: true)
                attempted = true
                outcome.append(await Task.detached(priority: .utility) {
                    StorageCleaner.cleanResult(eligible, runningApplications: running)
                }.value)
            }
        }
        quickCleanEstimate = nil; quickCleanEstimateDate = nil
        return attempted ? outcome.message : nil
    }

    func beginExternalUninstall() -> Bool {
        guard !isCleaningStorage, !isScanningStorage, !isQuickCleaning, !isEstimatingQuickClean, !isUninstallingApplication else { return false }
        isCleaningStorage = true
        return true
    }

    func finishExternalUninstall() {
        isCleaningStorage = false
        quickCleanEstimate = nil; quickCleanEstimateDate = nil
        relatedScanCache.clear()
    }

    func dismissQuickActionMessage() {
        quickActionMessage = nil
        memoryOptimizer.dismissMessage()
    }

    func applyFan(mode: FanMode, customRPM: Double) async {
        fanMessage = nil
        let result = await FanController.apply(mode: mode, customRPM: customRPM, fans: fans)
        DiagnosticLogger.shared.record(.fanModeApplied, outcome: result.succeeded ? .success : .failure, errorFamily: result.succeeded ? nil : .helper)
        fanMessage = result.message
        await refreshFans()
    }

    func scanApplications() async {
        guard !isScanningApplications, applicationWorkEnabled else { return }
        cancelApplicationWork()
        isScanningApplications = true
        let id = UUID(); applicationInventoryScanID = id
        relatedScanCache.clear()
        let started = Date()
        operationMessage = nil
        let loader = applicationInventoryLoader
        let worker = Task.detached(priority: .utility) { loader() }
        applicationInventoryWorker = worker
        let result = await worker.value
        guard applicationInventoryScanID == id, applicationWorkEnabled else { return }
        applicationInventoryWorker = nil
        applications = result
        needsApplicationInventoryRefresh = false
        isScanningApplications = false
        measureApplicationSizes()
        DiagnosticLogger.shared.record(.applicationScanFinished, metrics: [.count: Int64(applications.count), .durationMS: Int64(Date().timeIntervalSince(started) * 1_000)])
    }

    func measureApplicationSizes() {
        guard applicationWorkEnabled, !isMeasuringApplicationSizes, !isUninstallingApplication, !isMeasuringRelatedSizes, !isScanningRelatedFiles else { return }
        let pending = applications.filter { $0.storageUsage == nil }
        guard !pending.isEmpty else { return }
        let id = UUID()
        applicationSizeScanID = id
        foregroundSizeOverrides.removeAll()
        measuredApplicationCount = 0
        applicationMeasurementCount = pending.count
        isMeasuringApplicationSizes = true
        let stream = applicationStorageLoader(pending)
        applicationSizeTask = Task { [weak self] in
            var batch: [ApplicationStorageUpdate] = []
            var lastPublished = ProcessInfo.processInfo.systemUptime
            for await update in stream {
                guard let self, !Task.isCancelled, self.applicationSizeScanID == id else { return }
                batch.append(update)
                if batch.count >= 16 || ProcessInfo.processInfo.systemUptime - lastPublished >= 0.25 {
                    self.applyStorageUpdates(batch)
                    self.measuredApplicationCount += batch.count
                    batch.removeAll(keepingCapacity: true)
                    lastPublished = ProcessInfo.processInfo.systemUptime
                }
            }
            guard let self, self.applicationSizeScanID == id else { return }
            if !batch.isEmpty { self.applyStorageUpdates(batch); self.measuredApplicationCount += batch.count }
            self.isMeasuringApplicationSizes = false
            self.applicationSizeTask = nil
        }
    }

    func cancelApplicationSizeScan() {
        applicationSizeScanID = UUID()
        applicationSizeTask?.cancel()
        applicationSizeTask = nil
        isMeasuringApplicationSizes = false
    }

    func waitForApplicationSizes() async { await applicationSizeTask?.value }

    private func applyStorageUpdates(_ updates: [ApplicationStorageUpdate]) {
        let values = Dictionary(updates.filter { !foregroundSizeOverrides.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        guard !values.isEmpty else { return }
        applications = applications.map { app in
            guard let update = values[app.id] else { return app }
            var app = app; app.storageUsage = update.usage
            if let size = update.bundleMeasurement { app.size = size.bytes; app.isBundleSizeComplete = size.isComplete }
            if let identity = update.identity { app.relatedIdentity = identity }
            return app
        }
    }

    func cancelRelatedSizeCalculation() {
        relatedSizeScanID = UUID()
        relatedSizeWorker?.cancel(); relatedSizeTask?.cancel()
        relatedSizeWorker = nil; relatedSizeTask = nil; isMeasuringRelatedSizes = false
    }

    func cancelApplicationWork() {
        applicationInventoryScanID = UUID()
        applicationInventoryWorker?.cancel(); applicationInventoryWorker = nil; isScanningApplications = false
        cancelApplicationSizeScan()
        cancelRelatedSizeCalculation()
        relatedFileScanID = UUID()
        relatedFileWorker?.cancel(); relatedFileWorker = nil; isScanningRelatedFiles = false
    }

    func beginApplicationWork() {
        applicationWorkEnabled = true
        guard !isUninstallingApplication else { return }
        if applications.isEmpty || needsApplicationInventoryRefresh { Task { await scanApplications() } }
        else { resumeApplicationMeasurement() }
    }

    func suspendApplicationWork() {
        applicationWorkEnabled = false
        cancelApplicationWork()
    }

    func resumeApplicationMeasurement() {
        if selectedApplication != nil, relatedFiles.contains(where: { !$0.isSizeComplete }) {
            measureSelectedRelatedSizes(policy: .quick)
        } else { measureApplicationSizes() }
    }

    func measureSelectedRelatedSizes(policy: ApplicationSizePolicy = .full) {
        guard applicationWorkEnabled, let application = selectedApplication, !isScanningRelatedFiles, !isUninstallingApplication,
              !isMeasuringRelatedSizes, !relatedFiles.isEmpty else { return }
        cancelApplicationSizeScan()
        let scanID = UUID(); relatedSizeScanID = scanID
        let files = relatedFiles, loader = relatedSizeLoader
        isMeasuringRelatedSizes = true
        let worker = Task.detached(priority: .utility) { loader(files, policy) }
        relatedSizeWorker = worker
        relatedSizeTask = Task { [weak self] in
            let result = await worker.value
            guard let self, !Task.isCancelled, self.relatedSizeScanID == scanID, self.selectedApplication?.id == application.id else { return }
            let sizes = Dictionary(result.files.map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { _, last in last })
            // Only update size fields. Checkbox edits made while scanning stay untouched.
            self.relatedFiles = self.relatedFiles.map { file in
                guard let size = sizes[file.url.standardizedFileURL.path] else { return file }
                var value = size; value.isSelected = file.isSelected; value.association = file.association
                return value
            }
            var scan = self.relatedDiscoveryScan ?? result
            scan.files = self.relatedFiles
            scan.inaccessibleLocations = Array(Set(scan.inaccessibleLocations + result.inaccessibleLocations))
            self.relatedFileScanMessage = scan.accessMessage
            self.applyStorageUsage(ApplicationStorageUsage(files: self.relatedFiles, isComplete: scan.accessMessage == nil), to: application.id, foreground: true)
            self.isMeasuringRelatedSizes = false; self.relatedSizeWorker = nil; self.relatedSizeTask = nil
            self.measureApplicationSizes()
        }
    }

    func waitForRelatedSizes() async { await relatedSizeTask?.value }

    private func applyStorageUsage(_ usage: ApplicationStorageUsage, to id: URL, foreground: Bool = false, identity: ApplicationRelatedIdentity? = nil) {
        if foreground { foregroundSizeOverrides.insert(id) }
        if let index = applications.firstIndex(where: { $0.id == id }) {
            applications[index].storageUsage = usage
            if let identity { applications[index].relatedIdentity = identity }
        }
        if var selected = selectedApplication, selected.id == id {
            selected.storageUsage = usage
            if let identity { selected.relatedIdentity = identity }
            selectedApplication = selected
        }
    }

    func refreshApplicationInventory() async {
        guard !isUninstallingApplication, !isScanningApplications, !isScanningRelatedFiles else { return }
        let selected = selectedApplication
        let previous = relatedFiles
        await scanApplications()
        guard let selected, selectedApplication?.id == selected.id, !isUninstallingApplication else { return }
        let refreshed = applications.first { $0.id == selected.id } ?? selected
        await selectApplication(refreshed)
        guard selectedApplication?.id == selected.id else { return }
        relatedFiles = RelatedFileScanner.remainingFiles(previous: previous, scanned: relatedFiles)
    }

    func selectApplication(_ application: InstalledApplication?) async {
        guard !isUninstallingApplication else { return }
        cancelApplicationWork()
        let scanID = UUID()
        relatedFileScanID = scanID
        selectedApplication = application
        relatedFiles = []
        relatedFileScanMessage = nil
        guard let application else {
            isScanningRelatedFiles = false
            return
        }
        isScanningRelatedFiles = true
        let loader = relatedFileLoader, cache = relatedScanCache
        let worker = Task.detached(priority: .userInitiated) {
            var scan = loader(application)
            if !application.isBundleSizeComplete, !Task.isCancelled {
                let size = cache.cachedMeasurement(application.url)
                    ?? ApplicationDataSize.measure(application.url, timeout: 0.06, maximumEntries: 1_500)
                if !Task.isCancelled { cache.storeMeasurement(size, at: application.url) }
                scan.bundleMeasurement = size
            }
            return scan
        }
        relatedFileWorker = worker
        let result = await worker.value
        guard relatedFileScanID == scanID else { return }
        relatedFileWorker = nil
        relatedDiscoveryScan = result
        if let size = result.bundleMeasurement {
            if let index = applications.firstIndex(where: { $0.id == application.id }) {
                applications[index].size = size.bytes; applications[index].isBundleSizeComplete = size.isComplete
            }
            selectedApplication?.size = size.bytes; selectedApplication?.isBundleSizeComplete = size.isComplete
        }
        relatedFiles = result.files
        applyStorageUsage(ApplicationStorageUsage(files: result.files, isComplete: result.accessMessage == nil), to: application.id, foreground: true, identity: result.identity)
        relatedFileScanMessage = result.accessMessage
        isScanningRelatedFiles = false
        DiagnosticLogger.shared.record(.relatedFileScanFinished, outcome: result.accessMessage == nil ? .success : .partial,
                                       metrics: [.count: Int64(result.files.count), .failed: Int64(result.inaccessibleLocations.count)])
        if result.files.contains(where: { !$0.isSizeComplete }) { measureSelectedRelatedSizes(policy: .quick) }
        else { measureApplicationSizes() }
    }

    func addApplication(at url: URL) async {
        guard let application = await Task.detached(priority: .userInitiated, operation: {
            ApplicationScanner.application(from: url)
        }).value else { return }
        if !applications.contains(where: { $0.url == application.url }) {
            applications.append(application)
        }
        await selectApplication(application)
    }

    func setRelatedFile(_ file: RelatedFile, selected: Bool) {
        guard let index = relatedFiles.firstIndex(where: { $0.id == file.id }) else { return }
        relatedFiles[index].isSelected = selected
    }

    func setRelatedFiles(_ files: [RelatedFile], selected: Bool) {
        let ids = Set(files.map(\.id))
        for index in relatedFiles.indices where ids.contains(relatedFiles[index].id) {
            relatedFiles[index].isSelected = selected
        }
    }

    func setAllRelatedFiles(_ selected: Bool) {
        for index in relatedFiles.indices {
            relatedFiles[index].isSelected = selected
        }
    }

    func uninstallSelectedApplication() async {
        guard let selectedApplication, !isUninstallingApplication, !isScanningRelatedFiles else { return }
        guard !isCleaningStorage, !isScanningStorage, !isQuickCleaning, !isEstimatingQuickClean, !isUninstallingApplication else {
            presentUninstallResult(message: String(localized: "Another cleanup is in progress. Try again shortly."), isError: true, needsFinderPermission: false)
            return
        }
        uninstallNeedsFinderPermission = false
        uninstallNeedsFullDiskAccess = false
        // Otherwise an app can recreate its container immediately after it was removed.
        uninstallRemainingItems = []
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleURL?.standardizedFileURL == selectedApplication.url.standardizedFileURL ||
            (selectedApplication.bundleIdentifier != nil && $0.bundleIdentifier == selectedApplication.bundleIdentifier)
        }) {
            presentUninstallResult(message: String(localized: "Quit \(selectedApplication.name) before removing its files, then try again."),
                                   isError: true, needsFinderPermission: false)
            return
        }
        uninstallWatcher.suppress(selectedApplication)
        isUninstallingApplication = true
        needsApplicationInventoryRefresh = true
        cancelApplicationWork()
        relatedScanCache.clear()
        defer { isUninstallingApplication = false; resumeApplicationMeasurement() }
        relatedFileScanID = UUID()
        let previousRelated = relatedFiles
        let selectedRelated = relatedFiles.filter(\.isSelected)
        let targets = (ApplicationScanner.needsBundleRemoval(selectedApplication.url) ? [selectedApplication.url] : []) + selectedRelated.map(\.url)
        let outcome = await SystemTrashService.remove(targets)
        let removed = outcome.moved
        var removalMessage = outcome.message
        var needsFinderPermission = outcome.needsFinderPermission
        let needsFullDiskAccess = outcome.needsFullDiskAccess
        // Keep the bundle identity even if its original URL has moved, so failures are retryable.
        let verification = await Task.detached(priority: .utility) {
            let scan = ApplicationScanner.relatedFileScan(for: selectedApplication, mode: .discovery)
            return (scan, RelatedFileScanner.remainingFiles(previous: previousRelated, scanned: scan.files),
                    ApplicationScanner.needsBundleRemoval(selectedApplication.url))
        }.value
        let failed = verification.1.filter(\.isSelected).count + (verification.2 ? 1 : 0)
        let incomplete = verification.0.accessMessage != nil
        if failed == 0 { removalMessage = nil; needsFinderPermission = false }
        DiagnosticLogger.shared.record(.uninstallFinished, outcome: failed == 0 && !incomplete ? .success : .partial,
                                       metrics: [.count: Int64(removed), .failed: Int64(failed)])
        self.selectedApplication = failed > 0 || !verification.1.isEmpty || incomplete ? selectedApplication : nil
        relatedFiles = verification.1
        relatedDiscoveryScan = verification.0
        relatedFileScanMessage = verification.0.accessMessage
        isScanningRelatedFiles = false
        // Only this app changed. Avoid rewalking/sizing every installed application
        // before showing the result; an explicit Rescan still refreshes the inventory.
        if !verification.2 { applications.removeAll { $0.id == selectedApplication.id } }
        needsApplicationInventoryRefresh = false
        if let selected = self.selectedApplication {
            applyStorageUsage(ApplicationStorageUsage(files: verification.1, isComplete: !incomplete), to: selected.id, foreground: true)
        }
        var messages = [String(localized: "Moved \(removed) items to the Trash")]
        if failed > 0 { messages.append(String(localized: "\(failed) selected items remain.")) }
        if let removalMessage { messages.append(removalMessage) }
        if !verification.1.isEmpty { messages.append(String(localized: "Remaining files are listed below. New discoveries are unchecked; review them before removal.")) }
        if incomplete { messages.append(verification.0.accessMessage!) }
        presentUninstallResult(message: messages.joined(separator: " · "), isError: failed > 0 || incomplete,
                               needsFinderPermission: needsFinderPermission, needsFullDiskAccess: needsFullDiskAccess && failed > 0,
                               remainingItems: (verification.2 ? [selectedApplication.url] : []) + verification.1.filter(\.isSelected).map(\.url))
    }

    /// A single presentation path also lets layout tests exercise real failure UI without deleting files.
    func presentUninstallResult(message: String, isError: Bool, needsFinderPermission: Bool, needsFullDiskAccess: Bool = false, remainingItems: [URL] = []) {
        uninstallMessageIsError = isError
        uninstallNeedsFinderPermission = needsFinderPermission
        uninstallNeedsFullDiskAccess = needsFullDiskAccess
        uninstallRemainingItems = remainingItems
        operationMessage = message
    }

    func scanStorage() async {
        guard !isScanningStorage, !isCleaningStorage, !isEstimatingQuickClean else { return }
        isScanningStorage = true
        let started = Date()
        operationMessage = nil
        let mode = cleanupScanMode
        let running = RunningApplicationNames.current()
        let previousSelection = Dictionary(uniqueKeysWithValues: cleanupCategories.map { ($0.kind, $0.isSelected) })
        let previousItems = Dictionary(uniqueKeysWithValues: cleanupCategories.map { category in
            (category.kind, Dictionary(uniqueKeysWithValues: category.items.map { ($0.url, $0.isSelected) }))
        })
        var result = await Task.detached(priority: .utility) {
            StorageCleaner.scan(mode: mode, runningApplications: running)
        }.value
        guard mode == cleanupScanMode else {
            isScanningStorage = false
            return
        }
        updateQuickCleanEstimate(result)
        for index in result.indices {
            let categorySelected = result[index].accessMessage == nil && (previousSelection[result[index].kind] ?? result[index].isSelected)
            for itemIndex in result[index].items.indices {
                let url = result[index].items[itemIndex].url
                result[index].items[itemIndex].isSelected = result[index].accessMessage == nil && (previousItems[result[index].kind]?[url] ?? categorySelected)
            }
            result[index].isSelected = result[index].items.isEmpty
                ? categorySelected
                : result[index].items.contains(where: \.isSelected)
        }
        cleanupCategories = result
        DiagnosticLogger.shared.record(.storageScanFinished, metrics: [.count: Int64(result.reduce(0) { $0 + $1.itemCount }), .durationMS: Int64(Date().timeIntervalSince(started) * 1_000)])
        if let trashIssue = result.first(where: { $0.kind == .trash })?.accessMessage {
            operationMessage = trashIssue
        }
        isScanningStorage = false
    }

    func setCleanupScanMode(_ mode: CleanupScanMode) async {
        guard mode != cleanupScanMode, !isScanningStorage, !isCleaningStorage, !isEstimatingQuickClean else { return }
        cleanupScanMode = mode
        cleanupCategories = CleanupKind.kinds(for: mode).map {
            CleanupCategory(
                kind: $0,
                size: 0,
                itemCount: 0,
                isSelected: $0.isSelectedByDefault,
                locations: [],
                items: [],
                accessMessage: nil
            )
        }
        await scanStorage()
    }

    func setCleanupCategory(_ category: CleanupCategory, selected: Bool) {
        guard let index = cleanupCategories.firstIndex(where: { $0.id == category.id }) else { return }
        cleanupCategories[index].isSelected = selected
        for itemIndex in cleanupCategories[index].items.indices {
            cleanupCategories[index].items[itemIndex].isSelected = selected
        }
    }

    func setCleanupItem(kind: CleanupKind, item: CleanupItem, selected: Bool) {
        guard let categoryIndex = cleanupCategories.firstIndex(where: { $0.kind == kind }),
              let itemIndex = cleanupCategories[categoryIndex].items.firstIndex(where: { $0.id == item.id })
        else { return }
        cleanupCategories[categoryIndex].items[itemIndex].isSelected = selected
        cleanupCategories[categoryIndex].isSelected = cleanupCategories[categoryIndex].items.contains(where: \.isSelected)
    }

    func applyCleanupSelection(kind: CleanupKind, selection: Set<URL>, displayedItems: Set<URL>) {
        guard let index = cleanupCategories.firstIndex(where: { $0.kind == kind }) else { return }
        cleanupCategories[index].applySelection(selection, displayedItems: displayedItems)
    }

    func cleanSelectedCategories() async {
        guard !isCleaningStorage, !isScanningStorage, !isQuickCleaning, !isEstimatingQuickClean, !isUninstallingApplication else { return }
        isCleaningStorage = true
        let selected = cleanupCategories.filter(\.isSelected)
        guard !selected.isEmpty else { isCleaningStorage = false; return }
        let regular = selected.filter { $0.kind != .systemCaches }
        let running = RunningApplicationNames.current()
        var messages: [String] = []
        if !regular.isEmpty {
            let result = await Task.detached(priority: .userInitiated) {
                StorageCleaner.clean(regular, runningApplications: running)
            }.value
            messages.append(result)
        }
        if selected.contains(where: { $0.kind == .systemCaches }) {
            messages.append(MaintenanceController.cleanSystemCaches())
        }
        isCleaningStorage = false
        await scanStorage()
        operationMessage = messages.joined(separator: "；")
    }

    func dismissOperationMessage() {
        operationMessage = nil
        uninstallMessageIsError = false
        uninstallNeedsFinderPermission = false
        uninstallNeedsFullDiskAccess = false
        uninstallRemainingItems = []
    }
}
