import Foundation
import WonderSupport

/// Discovery publishes before the bounded size pass; checkbox changes never wait
/// for sizing and never get overwritten by its late reply.
@MainActor
final class ExternalUninstallReview: ObservableObject {
    @Published var files: [RelatedFile] = []
    @Published private(set) var isScanning = false
    @Published private(set) var cookieAccessRestricted = false
    private var hasLoaded = false
    @Published private(set) var isMeasuring = false
    @Published var message: String?
    private let event: UninstallWatchEvent
    private let cache = RelatedFileScanCache()
    private let discovery: @Sendable (UninstallWatchEvent, RelatedFileScanCache) -> RelatedFileScan
    private let measure: @Sendable ([RelatedFile], RelatedFileScanCache) -> RelatedFileScan
    private var scanID = UUID()
    private var discoveryTask: Task<RelatedFileScan, Never>?
    private var sizingTask: Task<Void, Never>?
    private var sizingWorker: Task<RelatedFileScan, Never>?
    private var identities: [URL: RemovalFileIdentity] = [:]

    init(event: UninstallWatchEvent,
         discovery: @escaping @Sendable (UninstallWatchEvent, RelatedFileScanCache) -> RelatedFileScan = { event, cache in
             ApplicationScanner.relatedFileScan(for: UninstallWatcherController.application(for: event, cache: cache), cache: cache, mode: .discovery)
         }, measure: @escaping @Sendable ([RelatedFile], RelatedFileScanCache) -> RelatedFileScan = { files, cache in
             RelatedFileSizeScanner.measure(files, policy: .quick, cache: cache)
         }) {
        self.event = event; self.discovery = discovery; self.measure = measure
    }
    deinit { discoveryTask?.cancel(); sizingTask?.cancel(); sizingWorker?.cancel() }

    var selectedCount: Int { files.filter(\.isSelected).count }
    var selectedSizeText: String {
        let selected = files.filter(\.isSelected)
        guard selected.contains(where: \.hasMeasuredSize) else { return String(localized: "Not measured") }
        return (selected.allSatisfy(\.isSizeComplete) ? "" : "≥ ") + AppFormatters.bytes(selected.reduce(0) { ApplicationStorageUsage.add($0, $1.size) })
    }
    func selectAll(_ selected: Bool) {
        for index in files.indices { files[index].isSelected = selected }
    }
    func stopSizing() {
        sizingTask?.cancel(); sizingWorker?.cancel()
        sizingTask = nil; sizingWorker = nil; isMeasuring = false
    }
    func cancel() {
        scanID = UUID(); discoveryTask?.cancel(); discoveryTask = nil
        stopSizing(); isScanning = false
    }
    func loadIfNeeded() async { if !hasLoaded { await scan() } }
    func scan() async {
        cancel()
        let id = UUID(); scanID = id
        let previous = files
        cache.invalidateFileAccess()
        isScanning = true
        let event = event, cache = cache, discovery = discovery
        let worker = Task.detached(priority: .userInitiated) { discovery(event, cache) }
        discoveryTask = worker
        let result = await worker.value
        guard scanID == id, !Task.isCancelled else { return }
        discoveryTask = nil
        files = previous.isEmpty ? result.files : RelatedFileScanner.remainingFiles(previous: files, scanned: result.files)
        identities = Dictionary(files.compactMap { file in RemovalFileIdentity(file.url).map { (file.url, $0) } }, uniquingKeysWith: { _, last in last })
        hasLoaded = true
        cookieAccessRestricted = result.inaccessibleLocations.contains { UninstallFileAccess.isCookieLocation($0) }
        message = result.accessMessage
        if files.isEmpty { message = String(localized: "No related files were found. You can close this window or grant Full Disk Access and rescan.") }
        isScanning = false
        guard files.contains(where: { !$0.isSizeComplete }) else { return }
        isMeasuring = true
        let pending = files, measure = measure
        let sizes = Task.detached(priority: .utility) { measure(pending, cache) }
        sizingWorker = sizes
        sizingTask = Task { [weak self] in
            let measured = await sizes.value
            guard let self, !Task.isCancelled, self.scanID == id else { return }
            let values = Dictionary(measured.files.map { ($0.url, $0) }, uniquingKeysWith: { _, last in last })
            self.files = self.files.map { file in
                guard var value = values[file.url] else { return file }
                value.isSelected = file.isSelected; value.association = file.association
                return value
            }
            self.isMeasuring = false; self.sizingWorker = nil; self.sizingTask = nil
        }
    }
    func waitForSizes() async { await sizingTask?.value }

    func validatedSelection() -> [URL] {
        stopSizing()
        return files.filter { $0.isSelected && identities[$0.url]?.stillMatches($0.url) == true }.map(\.url)
    }
    func retainRemaining() {
        files.removeAll { FilePresence.check($0.url) == .missing }
    }
}
