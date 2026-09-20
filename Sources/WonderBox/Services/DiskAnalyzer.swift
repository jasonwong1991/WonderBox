import Darwin
import Foundation

struct DiskScanItem: Identifiable, Equatable, Sendable {
    var id: URL { url }
    let url: URL
    let size: UInt64
    let isDirectory: Bool
    let modifiedAt: Date?
}

enum DiskAnalyzer {
    static func scan(_ directory: URL) -> [DiskScanItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let discovered = visibleChildren(of: directory)
        let children = discovered

        let isHomeRoot = directory.standardizedFileURL.path
            == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let estimationTargets = isHomeRoot
            ? children.filter { $0.lastPathComponent != "Library" }
            : children
        let estimates = DirectorySizeEstimator.estimate(
            estimationTargets,
            timeout: 12,
            ignoringNames: ["CloudStorage", "Mobile Documents"]
        )
        return children.compactMap { url in
            guard !Task.isCancelled else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let isDirectory = values?.isDirectory
                ?? ((attributes?[.type] as? FileAttributeType) == .typeDirectory)
            let estimated = estimates[url.standardizedFileURL.path] ?? 0
            let logical = UInt64(max(0, (attributes?[.size] as? NSNumber)?.intValue ?? 0))
            let size = estimated > 0
                ? estimated
                : (FileSystemScanner.indexedPhysicalSize(of: url) ?? (isDirectory == true ? 0 : FileSystemScanner.allocatedSize(of: url)))
            return DiskScanItem(
                url: url,
                size: max(size, logical),
                isDirectory: isDirectory == true && values?.isSymbolicLink != true,
                modifiedAt: values?.contentModificationDate ?? attributes?[.modificationDate] as? Date
            )
        }
    }

    private static func visibleChildren(of directory: URL) -> [URL] {
        directory.withUnsafeFileSystemRepresentation { path in
            guard let path, let stream = opendir(path) else { return [] }
            defer { closedir(stream) }
            var result: [URL] = []
            while let entry = readdir(stream) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { tuple in
                    tuple.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(cString: $0)
                    }
                }
                guard name != ".", name != "..", !name.hasPrefix(".") else { continue }
                let lowercaseName = name.lowercased()
                guard entry.pointee.d_type != UInt8(DT_LNK),
                      !lowercaseName.contains("onedrive"),
                      !lowercaseName.contains("dropbox"),
                      !lowercaseName.contains("google drive")
                else { continue }
                result.append(directory.appendingPathComponent(name))
            }
            return result
        }
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
