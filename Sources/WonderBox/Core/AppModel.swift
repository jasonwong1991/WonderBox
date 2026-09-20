import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: AppSection? = .overview
    @Published private(set) var snapshot = MetricSnapshot()
    @Published private(set) var cpuHistory: [Double] = Array(repeating: 0, count: 30)
    @Published private(set) var memoryHistory: [Double] = Array(repeating: 0, count: 30)
    @Published private(set) var fans: [FanReading] = []
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
    @Published private(set) var isQuickCleaning = false
    @Published private(set) var quickActionMessage: String?
    @Published private(set) var fullDiskAccessStatus = FullDiskAccessController.currentStatus()

    let sleepPreventer = SleepPreventer()
    let memoryOptimizer = MemoryOptimizer()
    let systemInfo = SystemInformation.current

    private var monitorTask: Task<Void, Never>?
    private var previousCounters: SystemCounters?
    private var relatedFileScanID = UUID()
    private var didOfferFullDiskAccess = false

    var supportsFullDiskAccess: Bool {
        FullDiskAccessController.isSupported
    }

    init() {
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
        let previous = previousCounters
        let sample = await Task.detached(priority: .utility) {
            SystemMonitor.sample(previous: previous)
        }.value
        previousCounters = sample.counters
        snapshot = sample.snapshot
        cpuHistory.append(sample.snapshot.cpuUsage)
        memoryHistory.append(sample.snapshot.memoryFraction)
        cpuHistory = Array(cpuHistory.suffix(60))
        memoryHistory = Array(memoryHistory.suffix(60))
    }

    func refreshFans() async {
        let readings = await Task.detached(priority: .utility) {
            FanController.readFans()
        }.value
        fans = readings
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
        fanMessage = result.message
        await refreshFans()
    }

    func scanApplications() async {
        guard !isScanningApplications else { return }
        isScanningApplications = true
        operationMessage = nil
        applications = await Task.detached(priority: .utility) {
            ApplicationScanner.scanApplications()
        }.value
        isScanningApplications = false
    }

    func selectApplication(_ application: InstalledApplication?) async {
        let scanID = UUID()
        relatedFileScanID = scanID
        selectedApplication = application
        relatedFiles = []
        guard let application else {
            isScanningRelatedFiles = false
            return
        }
        isScanningRelatedFiles = true
        let result = await Task.detached(priority: .utility) {
            ApplicationScanner.relatedFiles(for: application)
        }.value
        guard relatedFileScanID == scanID else { return }
        relatedFiles = result
        isScanningRelatedFiles = false
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

    func setAllRelatedFiles(_ selected: Bool) {
        for index in relatedFiles.indices {
            relatedFiles[index].isSelected = selected
        }
    }

    func uninstallSelectedApplication() async {
        guard let selectedApplication else { return }
        let selectedRelated = relatedFiles.filter(\.isSelected)
        let result = await Task.detached(priority: .userInitiated) {
            ApplicationScanner.uninstall(application: selectedApplication, relatedFiles: selectedRelated)
        }.value
        operationMessage = result
        self.selectedApplication = nil
        relatedFiles = []
        isScanningRelatedFiles = false
        await scanApplications()
    }

    func scanStorage() async {
        guard !isScanningStorage else { return }
        isScanningStorage = true
        operationMessage = nil
        let mode = cleanupScanMode
        let running = mode == .deep ? RunningApplicationNames.current() : []
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
            let categorySelected = previousSelection[result[index].kind] ?? result[index].isSelected
            for itemIndex in result[index].items.indices {
                let url = result[index].items[itemIndex].url
                result[index].items[itemIndex].isSelected = previousItems[result[index].kind]?[url] ?? categorySelected
            }
            result[index].isSelected = result[index].items.isEmpty
                ? categorySelected
                : result[index].items.contains(where: \.isSelected)
        }
        cleanupCategories = result
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

    func cleanSelectedCategories() async {
        let selected = cleanupCategories.filter(\.isSelected)
        guard !selected.isEmpty else { return }
        let regular = selected.filter { $0.kind != .systemCaches }
        var messages: [String] = []
        if !regular.isEmpty {
            let result = await Task.detached(priority: .userInitiated) {
                StorageCleaner.clean(regular)
            }.value
            messages.append(result)
        }
        if selected.contains(where: { $0.kind == .systemCaches }) {
            messages.append(MaintenanceController.cleanSystemCaches())
        }
        operationMessage = messages.joined(separator: "；")
        await scanStorage()
    }

    func dismissOperationMessage() {
        operationMessage = nil
    }
}
