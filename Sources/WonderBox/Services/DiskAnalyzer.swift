import Darwin
import Foundation

struct DiskScanItem: Identifiable, Equatable, Sendable {
    var id: URL { url }
    let url: URL
    var size: UInt64
    let isDirectory: Bool
    let modifiedAt: Date?
    var isSizeEstimated = true
}

enum DiskScanUpdate: Sendable {
    case contents([DiskScanItem])
    case sizes([URL: UInt64])
    case failed(String)
    case finished
}

/// Cancellation must cross GCD worker boundaries, where Task.isCancelled isn't inherited.
final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

private final class DiskSizeProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [URL: UInt64] = [:]
    private var lastFlush = Date()
    private let continuation: AsyncStream<DiskScanUpdate>.Continuation
    init(_ continuation: AsyncStream<DiskScanUpdate>.Continuation) { self.continuation = continuation }

    func record(_ url: URL, size: UInt64) {
        lock.lock()
        pending[url] = size
        let flush = pending.count >= 16 || Date().timeIntervalSince(lastFlush) >= 0.12
        let batch = flush ? pending : [:]
        if flush { pending.removeAll(); lastFlush = Date() }
        lock.unlock()
        if !batch.isEmpty { continuation.yield(.sizes(batch)) }
    }

    func finish() {
        lock.lock()
        let batch = pending
        pending.removeAll()
        lock.unlock()
        if !batch.isEmpty { continuation.yield(.sizes(batch)) }
    }
}

enum DiskAnalyzer {
    static let excludedDirectoryNames: Set<String> = ["CloudStorage", "Mobile Documents", "OneDrive*", "Dropbox*", "Google Drive*"]

    /// Fast metadata only: no recursion, Spotlight lookup or process launch before showing the rows.
    static func list(_ directory: URL, isCancelled: () -> Bool = { Task.isCancelled }) throws -> [DiskScanItem] {
        guard let stream = opendir(directory.path) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES) }
        defer { closedir(stream) }
        var items: [DiskScanItem] = []
        while let entry = readdir(stream) {
            guard !isCancelled() else { throw CancellationError() }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard !name.hasPrefix("."), !isCloudDirectory(name) else { continue }
            let url = directory.appendingPathComponent(name, isDirectory: entry.pointee.d_type == UInt8(DT_DIR))
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { continue }
            let isDirectory = info.st_mode & S_IFMT == S_IFDIR
            items.append(DiskScanItem(
                url: url, size: isDirectory ? 0 : UInt64(max(0, info.st_blocks)) * 512,
                isDirectory: isDirectory,
                modifiedAt: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000),
                isSizeEstimated: !isDirectory
            ))
        }
        return items
    }

    /// Four bounded workers, incremental results, and cancellable du processes. A large folder never
    /// delays listing or navigation, and a timeout remains “Not sized” instead of an invented 4 KB.
    static func updates(_ directory: URL) -> AsyncStream<DiskScanUpdate> {
        AsyncStream { continuation in
            let cancellation = ScanCancellation()
            let worker = Task.detached(priority: .utility) {
                defer { continuation.finish() }
                do {
                    let items = try list(directory, isCancelled: { cancellation.isCancelled })
                    guard !cancellation.isCancelled else { return }
                    continuation.yield(.contents(items))
                    let targets = items.filter(\.isDirectory).map(\.url)
                    let indexLock = NSLock()
                    var next = 0
                    let progress = DiskSizeProgress(continuation)
                    DispatchQueue.concurrentPerform(iterations: min(4, targets.count)) { _ in
                        while !cancellation.isCancelled {
                            indexLock.lock()
                            let index = next
                            next += 1
                            indexLock.unlock()
                            guard index < targets.count else { return }
                            let url = targets[index]
                            let sizes = DirectorySizeEstimator.estimate([url], timeout: 2, ignoringNames: excludedDirectoryNames,
                                                                       isCancelled: { cancellation.isCancelled }, requireSuccessfulExit: true)
                            if let size = sizes[url.standardizedFileURL.path], !cancellation.isCancelled {
                                progress.record(url, size: size)
                            }
                        }
                    }
                    progress.finish()
                    if !cancellation.isCancelled { continuation.yield(.finished) }
                } catch is CancellationError { return }
                catch { if !cancellation.isCancelled { continuation.yield(.failed(error.localizedDescription)) } }
            }
            continuation.onTermination = { _ in cancellation.cancel(); worker.cancel() }
        }
    }

    // Synchronous entry point for callers that need a completed snapshot, not the interactive browser.
    static func scan(_ directory: URL) -> [DiskScanItem] {
        guard var items = try? list(directory) else { return [] }
        let estimates = DirectorySizeEstimator.estimate(items.filter(\.isDirectory).map(\.url), timeout: 2, ignoringNames: excludedDirectoryNames)
        for index in items.indices {
            if let size = estimates[items[index].url.standardizedFileURL.path] {
                items[index].size = size
                items[index].isSizeEstimated = true
            }
        }
        return items
    }

    private static func isCloudDirectory(_ name: String) -> Bool {
        let lower = name.lowercased()
        return name == "CloudStorage" || name == "Mobile Documents" || lower.contains("onedrive") || lower.contains("dropbox") || lower.contains("google drive")
    }

    static func moveToTrash(_ urls: [URL], inside root: URL) -> (removed: Int, failed: Int) {
        let rootPath = root.standardizedFileURL.path
        var removed = 0
        var failed = 0
        for url in urls {
            let candidate = url.standardizedFileURL
            guard candidate.path.hasPrefix(rootPath + "/"), candidate.path != rootPath else {
                failed += 1
                continue
            }
            do {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: candidate, resultingItemURL: &resultingURL)
                removed += 1
            } catch {
                failed += 1
            }
        }
        return (removed, failed)
    }
}
