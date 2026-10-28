import Darwin
import Foundation

struct AllocatedSizeMeasurement: Sendable {
    var bytes: UInt64 = 0
    var isComplete = true
    var inaccessible: [URL] = []
    var hasMeasuredSize = true
    var entriesVisited = 0
}

enum ApplicationDataSize {
    /// Include hidden files and nested packages, but never follow symlinks, cross a mount, or
    /// hydrate cloud placeholders. A budget overrun is a lower bound, not a fictitious zero.
    static func measure(_ url: URL, timeout: TimeInterval = 5, maximumEntries: Int = 100_000, pauseEvery: Int = 0,
                        isCancelled: () -> Bool = { Task.isCancelled }) -> AllocatedSizeMeasurement {
        var result = AllocatedSizeMeasurement()
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var root = stat()
        guard lstat(url.path, &root) == 0 else {
            result.isComplete = false
            if errno == EACCES || errno == EPERM { result.inaccessible = [url] }
            return result
        }
        guard root.st_mode & S_IFMT != S_IFLNK else { result.isComplete = false; return result }
        func add(_ info: stat) {
            let blocks = UInt64(max(0, info.st_blocks))
            let bytes = blocks.multipliedReportingOverflow(by: 512)
            result.bytes = ApplicationStorageUsage.add(result.bytes, bytes.overflow ? UInt64.max : bytes.partialValue)
        }
        add(root)
        guard root.st_flags & UInt32(SF_DATALESS) == 0 else { result.isComplete = false; return result }
        guard root.st_mode & S_IFMT == S_IFDIR else { return result }
        // readdir/fstatat streams one entry at a time. DirectoryEnumerator and fts can
        // eagerly create/stat a huge directory before their caller gets to cancel it.
        struct Frame { let path: String; let handle: UnsafeMutablePointer<DIR> }
        func failed(_ path: String, _ code: Int32) {
            result.isComplete = false
            if code == EACCES || code == EPERM { result.inaccessible.append(URL(fileURLWithPath: path)) }
        }
        func stream(_ fd: Int32, path: String, expected: stat) -> UnsafeMutablePointer<DIR>? {
            guard fd >= 0 else { failed(path, errno); return nil }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_dev == expected.st_dev, opened.st_ino == expected.st_ino else {
                close(fd); result.isComplete = false; return nil
            }
            guard let handle = fdopendir(fd) else { let code = errno; close(fd); failed(path, code); return nil }
            return handle
        }
        guard let first = stream(open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), path: url.path, expected: root)
        else { return result }
        var stack = [Frame(path: url.path, handle: first)]
        defer { for frame in stack { closedir(frame.handle) } }
        var hardLinks = Set<ino_t>()
        while let frame = stack.last {
            guard !isCancelled(), ProcessInfo.processInfo.systemUptime < deadline, result.entriesVisited < maximumEntries else {
                result.isComplete = false
                break
            }
            errno = 0
            guard let entry = readdir(frame.handle) else {
                if errno != 0 { failed(frame.path, errno) }
                closedir(frame.handle); stack.removeLast(); continue
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            result.entriesVisited += 1
            var info = stat()
            guard fstatat(dirfd(frame.handle), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { failed(frame.path + "/" + name, errno); continue }
            if info.st_dev != root.st_dev || info.st_flags & UInt32(SF_DATALESS) != 0 {
                result.isComplete = false; continue
            }
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK { continue }
            if type == S_IFREG, info.st_nlink > 1, !hardLinks.insert(info.st_ino).inserted { continue }
            add(info)
            if type == S_IFDIR {
                let path = frame.path + "/" + name
                if let handle = stream(openat(dirfd(frame.handle), name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), path: path, expected: info) {
                    stack.append(Frame(path: path, handle: handle))
                }
            }
            if pauseEvery > 0, result.entriesVisited % pauseEvery == 0 { usleep(5_000) }
        }
        return result
    }

    static func shallow(_ url: URL) -> AllocatedSizeMeasurement {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return AllocatedSizeMeasurement(isComplete: false, inaccessible: errno == EACCES || errno == EPERM ? [url] : [], hasMeasuredSize: false)
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            return AllocatedSizeMeasurement(isComplete: false, hasMeasuredSize: false)
        }
        return measure(url, maximumEntries: 0)
    }
}

enum ApplicationSizePolicy: Sendable {
    case quick, full
    var timeout: TimeInterval { self == .quick ? 0.06 : .infinity }
    var maximumEntries: Int { self == .quick ? 1_500 : .max }
}

enum RelatedFileSizeScanner {
    /// One budget for the whole app, not five seconds for EACH related directory.
    static func measure(_ files: [RelatedFile], policy: ApplicationSizePolicy, cache: RelatedFileScanCache) -> RelatedFileScan {
        let deadline = ProcessInfo.processInfo.systemUptime + policy.timeout
        var remaining = policy.maximumEntries
        var result = files
        var inaccessible = Set<URL>()
        for index in result.indices {
            if Task.isCancelled { break }
            let url = result[index].url
            let value: AllocatedSizeMeasurement
            if let cached = cache.cachedMeasurement(url), cached.isComplete || policy == .quick {
                value = cached
            } else if policy == .quick && result[index].isSizeComplete && result[index].hasMeasuredSize {
                continue
            } else if remaining > 0, ProcessInfo.processInfo.systemUptime < deadline {
                value = ApplicationDataSize.measure(url, timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime),
                                                    maximumEntries: remaining, pauseEvery: policy == .full ? 256 : 0)
                remaining = max(0, remaining - value.entriesVisited)
                if !Task.isCancelled { cache.storeMeasurement(value, at: url) }
            } else { continue }
            inaccessible.formUnion(value.inaccessible)
            result[index] = RelatedFile(url: url, displayPath: result[index].displayPath, size: value.bytes,
                                       isSelected: result[index].isSelected, isSizeComplete: value.isComplete,
                                       hasMeasuredSize: value.hasMeasuredSize, association: result[index].association)
        }
        return RelatedFileScan(files: result, inaccessibleLocations: inaccessible.sorted { $0.path < $1.path })
    }
}

struct ApplicationStorageUpdate: Sendable {
    let id: URL
    let usage: ApplicationStorageUsage
    var identity: ApplicationRelatedIdentity? = nil
    var bundleMeasurement: AllocatedSizeMeasurement? = nil
}

enum ApplicationStorageScanner {
    /// One budgeted utility worker avoids simultaneous directory walks. No stored
    /// paths, names or sizes are written to logs or persisted on disk.
    static func updates(_ applications: [InstalledApplication], cache: RelatedFileScanCache = RelatedFileScanCache(),
                        scan suppliedScan: (@Sendable (InstalledApplication) -> RelatedFileScan)? = nil) -> AsyncStream<ApplicationStorageUpdate> {
        let scan: @Sendable (InstalledApplication) -> RelatedFileScan = suppliedScan ?? { ApplicationScanner.relatedFileScan(for: $0, cache: cache) }
        return AsyncStream { continuation in
            let worker = Task.detached(priority: .utility) {
                for app in applications {
                    guard !Task.isCancelled else { break }
                    let bundleSize = app.isBundleSizeComplete ? nil : cache.cachedMeasurement(app.url)
                        ?? ApplicationDataSize.measure(app.url, timeout: 0.06, maximumEntries: 1_500)
                    if let bundleSize, !Task.isCancelled { cache.storeMeasurement(bundleSize, at: app.url) }
                    let result = autoreleasepool { scan(app) }
                    guard !Task.isCancelled else { break }
                    continuation.yield(ApplicationStorageUpdate(id: app.id, usage: ApplicationStorageUsage(files: result.files, isComplete: result.accessMessage == nil), identity: result.identity, bundleMeasurement: bundleSize))
                    // Leave breathing room for Finder, UI interaction and other system IO.
                    try? await Task.sleep(for: .milliseconds(15))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
}
