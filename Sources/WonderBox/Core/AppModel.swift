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
    @Published private(set) var fans: [FanReading] = []
    @Published private(set) var isRefreshingFans = false
    @Published private(set) var hasReadFans = false
    @Published private(set) var fanMessage: String?
    @Published private(set) var isMonitoring = false
    @Published private(set) var applications: [InstalledApplication] = []
    @Published private(set) var isScanningApplications = false
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
    @Published private(set) var uninstallRemainingItems: [URL] = []
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

    private var monitorTask: Task<Void, Never>?
    private var metricsRefreshTask: Task<Void, Never>?
    private var previousCounters: SystemCounters?
    private var relatedFileScanID = UUID()
    private var didOfferFullDiskAccess = false
    private var didStartServices = false

    var supportsFullDiskAccess: Bool {
        FullDiskAccessController.isSupported
    }

    init(applications: [InstalledApplication] = []) {
        self.applications = applications
        guard let flagIndex = CommandLine.arguments.firstIndex(of: "--section"),
              CommandLine.arguments.indices.contains(flagIndex + 1),
              let requested = AppSection(rawValue: CommandLine.arguments[flagIndex + 1])
        else { return }
        selection = requested
    }

    var filteredApplications: [InstalledApplication] {
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
        return ApplicationOrganizer.sort(filtered, by: applicationSort, ascending: applicationSortAscending)
    }

    var filteredApplicationSize: UInt64 {
        filteredApplications.reduce(0) { $0 + $1.size }
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
        guard !isQuickCleaning, !isScanningStorage else { return }
        isQuickCleaning = true
        isScanningStorage = true
        quickActionMessage = nil
        memoryOptimizer.dismissMessage()
        let categories = await Task.detached(priority: .utility) {
            StorageCleaner.scan(mode: .standard)
        }.value
        let quickCleanCategories = StorageCleaner.quickCleanCategories(from: categories)
        let result = await Task.detached(priority: .userInitiated) {
            StorageCleaner.clean(quickCleanCategories)
        }.value
        quickActionMessage = result
        isScanningStorage = false
        isQuickCleaning = false
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
        guard !isScanningApplications else { return }
        isScanningApplications = true
        let started = Date()
        operationMessage = nil
        applications = await Task.detached(priority: .utility) {
            ApplicationScanner.scanApplications()
        }.value
        isScanningApplications = false
        DiagnosticLogger.shared.record(.applicationScanFinished, metrics: [.count: Int64(applications.count), .durationMS: Int64(Date().timeIntervalSince(started) * 1_000)])
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
        let result = await Task.detached(priority: .utility) {
            ApplicationScanner.relatedFileScan(for: application)
        }.value
        guard relatedFileScanID == scanID else { return }
        relatedFiles = result.files
        relatedFileScanMessage = result.accessMessage
        isScanningRelatedFiles = false
        DiagnosticLogger.shared.record(.relatedFileScanFinished, outcome: result.inaccessibleLocations.isEmpty ? .success : .partial,
                                       metrics: [.count: Int64(result.files.count), .failed: Int64(result.inaccessibleLocations.count)])
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
        uninstallNeedsFinderPermission = false
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
        isUninstallingApplication = true
        defer { isUninstallingApplication = false }
        relatedFileScanID = UUID()
        let previousRelated = relatedFiles
        let selectedRelated = relatedFiles.filter(\.isSelected)
        let outcome = await Task.detached(priority: .userInitiated) {
            ApplicationScanner.uninstall(application: selectedApplication, relatedFiles: selectedRelated)
        }.value
        var removed = outcome.trashed
        var removalMessage: String?
        var needsFinderPermission = false
        if !outcome.failed.isEmpty {
            let result = await SystemTrashService.trash(outcome.failed)
            removed += result.moved
            removalMessage = result.message
            needsFinderPermission = result.needsFinderPermission
        }
        // Keep the bundle identity even if its original URL has moved, so failures are retryable.
        let verification = await Task.detached(priority: .utility) {
            let scan = ApplicationScanner.relatedFileScan(for: selectedApplication)
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
        relatedFileScanMessage = verification.0.accessMessage
        isScanningRelatedFiles = false
        // The rescan clears the previous message; report this result afterwards so it stays visible.
        await scanApplications()
        var messages = [String(localized: "Moved \(removed) items to the Trash")]
        if failed > 0 { messages.append(String(localized: "\(failed) selected items remain.")) }
        if let removalMessage { messages.append(removalMessage) }
        if !verification.1.isEmpty { messages.append(String(localized: "Remaining files are listed below. New discoveries are unchecked; review them before removal.")) }
        if incomplete { messages.append(verification.0.accessMessage!) }
        presentUninstallResult(message: messages.joined(separator: " · "), isError: failed > 0 || incomplete,
                               needsFinderPermission: needsFinderPermission,
                               remainingItems: (verification.2 ? [selectedApplication.url] : []) + verification.1.filter(\.isSelected).map(\.url))
    }

    /// A single presentation path also lets layout tests exercise real failure UI without deleting files.
    func presentUninstallResult(message: String, isError: Bool, needsFinderPermission: Bool, remainingItems: [URL] = []) {
        uninstallMessageIsError = isError
        uninstallNeedsFinderPermission = needsFinderPermission
        uninstallRemainingItems = remainingItems
        operationMessage = message
    }

    func scanStorage() async {
        guard !isScanningStorage else { return }
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
        guard mode != cleanupScanMode, !isScanningStorage else { return }
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
        let selected = cleanupCategories.filter(\.isSelected)
        guard !selected.isEmpty else { return }
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
        await scanStorage()
        operationMessage = messages.joined(separator: "；")
    }

    func dismissOperationMessage() {
        operationMessage = nil
        uninstallMessageIsError = false
        uninstallNeedsFinderPermission = false
        uninstallRemainingItems = []
    }
}
