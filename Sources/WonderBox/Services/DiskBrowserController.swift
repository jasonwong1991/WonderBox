import Foundation

@MainActor
final class DiskBrowserController: ObservableObject {
    @Published private(set) var items: [DiskScanItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isListing = false
    @Published private(set) var isCached = false
    @Published private(set) var error: String?

    private struct CacheEntry {
        let items: [DiskScanItem]
        let date: Date
    }
    private var cache: [String: CacheEntry] = [:]
    private var task: Task<Void, Never>?
    private var scanID = UUID()
    private let loader: (URL) -> AsyncStream<DiskScanUpdate>
    private let cacheLifetime: TimeInterval

    init(cacheLifetime: TimeInterval = 60, loader: @escaping (URL) -> AsyncStream<DiskScanUpdate> = DiskAnalyzer.updates) {
        self.loader = loader
        self.cacheLifetime = cacheLifetime
    }

    deinit { task?.cancel() }

    func scan(_ directory: URL, force: Bool = false) {
        cancel()
        let id = UUID()
        scanID = id
        let key = directory.standardizedFileURL.path
        if force { cache.removeValue(forKey: key) }
        error = nil
        if !force, let entry = cache[key], Date().timeIntervalSince(entry.date) < cacheLifetime {
            items = entry.items
            isCached = true
            return
        }
        items = []
        isCached = false
        isScanning = true
        isListing = true
        let stream = loader(directory)
        task = Task { [weak self] in
            for await update in stream {
                guard let self, !Task.isCancelled, self.scanID == id else { return }
                switch update {
                case let .contents(items): self.items = items; self.isListing = false
                case let .sizes(sizes):
                    var updated = self.items
                    for index in updated.indices {
                        if let size = sizes[updated[index].url] {
                            updated[index].size = size
                            updated[index].isSizeEstimated = true
                        }
                    }
                    self.items = updated
                case let .failed(message): self.error = message
                case .finished: self.remember(key)
                }
            }
            guard let self, self.scanID == id else { return }
            self.isScanning = false
            self.isListing = false
            self.task = nil
        }
    }

    func cancel() {
        scanID = UUID()
        task?.cancel()
        task = nil
        isScanning = false
        isListing = false
    }

    /// A move or deletion changes both descendant listings and ancestor totals.
    func invalidate(_ directory: URL) {
        let path = directory.standardizedFileURL.path
        cache = cache.filter { key, _ in key != path && !key.hasPrefix(path + "/") && !path.hasPrefix(key + "/") }
    }

    private func remember(_ key: String) {
        guard error == nil else { return }
        cache[key] = CacheEntry(items: items, date: Date())
        while cache.count > 20 || cache.values.reduce(0, { $0 + $1.items.count }) > 20_000 {
            guard let oldest = cache.min(by: { $0.value.date < $1.value.date })?.key else { break }
            cache.removeValue(forKey: oldest)
        }
    }
}
