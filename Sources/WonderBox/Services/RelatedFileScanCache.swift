import Darwin
import Foundation

/// Session-only cache, shared by the inventory and selected-app paths. Explicit refresh and
/// uninstall clear it; short TTLs and inode/mtime checks avoid stale reused directory snapshots.
final class RelatedFileScanCache: @unchecked Sendable {
    private struct Stamp: Equatable {
        let device: dev_t, inode: ino_t, seconds: Int, nanos: Int
        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            device = info.st_dev; inode = info.st_ino
            seconds = info.st_mtimespec.tv_sec; nanos = info.st_mtimespec.tv_nsec
        }
    }
    private struct Entry<Value> {
        let value: Value
        let stamp: Stamp?
        let expires: TimeInterval
        func isFresh(_ stamp: Stamp?) -> Bool { self.stamp == stamp && ProcessInfo.processInfo.systemUptime < expires }
    }
    private let lock = NSLock()
    private var listings: [String: Entry<Result<[URL], Error>>] = [:]
    private var owners: [URL: String] = [:]
    private var ownerProbes = Set<URL>()
    private var sizes: [String: Entry<AllocatedSizeMeasurement>] = [:]
    private var metadataValues: [String: Entry<[String: Any]?>] = [:]
    private var identities: [String: Entry<ApplicationRelatedIdentity>] = [:]

    func clear() {
        lock.withLock {
            listings.removeAll(); owners.removeAll(); ownerProbes.removeAll(); sizes.removeAll()
            metadataValues.removeAll(); identities.removeAll()
        }
    }

    /// Permissions can change without directory mtimes changing. Keep complete
    /// bundle identity metadata, but discard denied/partial filesystem snapshots.
    func invalidateFileAccess() {
        lock.withLock {
            listings.removeAll(); owners.removeAll(); ownerProbes.removeAll(); sizes.removeAll()
            identities = identities.filter { $0.value.value.isComplete }
            metadataValues = metadataValues.filter { $0.value.value != nil }
        }
    }

    func children(_ url: URL) throws -> [URL] {
        let key = url.standardizedFileURL.path
        let stamp = Stamp(url)
        if let cached = lock.withLock({ listings[key] }), cached.isFresh(stamp) { return try cached.value.get() }
        let result = Result { try RelatedFileScanner.children(url) }
        lock.withLock { listings[key] = Entry(value: result, stamp: stamp, expires: ProcessInfo.processInfo.systemUptime + 10) }
        return try result.get()
    }

    func containerIdentifier(_ url: URL) -> String? {
        lock.withLock {
            if ownerProbes.contains(url) { return owners[url] }
            ownerProbes.insert(url)
            owners[url] = ContainerMetadata.identifier(at: url)
            return owners[url]
        }
    }

    func measure(_ url: URL) -> AllocatedSizeMeasurement {
        if let cached = cachedMeasurement(url) { return cached }
        let result = ApplicationDataSize.measure(url)
        if !Task.isCancelled { storeMeasurement(result, at: url) }
        return result
    }

    func cachedMeasurement(_ url: URL) -> AllocatedSizeMeasurement? {
        let stamp = Stamp(url)
        guard let cached = lock.withLock({ sizes[url.standardizedFileURL.path] }), cached.isFresh(stamp) else { return nil }
        return cached.value
    }

    func storeMeasurement(_ value: AllocatedSizeMeasurement, at url: URL) {
        let stamp = Stamp(url)
        lock.withLock {
            sizes[url.standardizedFileURL.path] = Entry(value: value, stamp: stamp, expires: ProcessInfo.processInfo.systemUptime + 60)
        }
    }

    func identity(_ url: URL) -> ApplicationRelatedIdentity {
        let key = url.standardizedFileURL.path
        let info = url.appendingPathComponent("Contents/Info.plist")
        let stamp = Stamp(info)
        if let cached = lock.withLock({ identities[key] }), cached.isFresh(stamp) { return cached.value }
        let result = ApplicationIdentityScanner.inspect(url)
        if !Task.isCancelled {
            lock.withLock { identities[key] = Entry(value: result, stamp: stamp, expires: ProcessInfo.processInfo.systemUptime + 60) }
        }
        return result
    }

    func metadata(_ url: URL) -> [String: Any]? {
        let key = url.standardizedFileURL.path
        let stamp = Stamp(url)
        if let cached = lock.withLock({ metadataValues[key] }), cached.isFresh(stamp) { return cached.value }
        let result = ApplicationIdentityScanner.metadata(url)
        if !Task.isCancelled {
            lock.withLock { metadataValues[key] = Entry(value: result, stamp: stamp, expires: ProcessInfo.processInfo.systemUptime + 60) }
        }
        return result
    }
}
