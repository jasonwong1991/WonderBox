import Foundation

struct ApplicationStorageUsage: Equatable, Sendable {
    let files: [RelatedFile]
    let isComplete: Bool

    init(files: [RelatedFile], isComplete: Bool) {
        self.files = Self.uniqueRoots(files)
        self.isComplete = isComplete && self.files.allSatisfy(\.isSizeComplete)
    }

    var relatedSize: UInt64 { files.reduce(0) { Self.add($0, $1.size) } }

    /// A directory already includes its children. Keep only the outermost discovered roots.
    static func uniqueRoots(_ files: [RelatedFile]) -> [RelatedFile] {
        // Normalize once, not once per comparison. Appending '/' makes every descendant
        // contiguous with its parent even when siblings contain '-' or other punctuation.
        let sorted = files.map { (key: $0.url.standardizedFileURL.path + "/", file: $0) }.sorted {
            $0.key == $1.key ? $0.file.size > $1.file.size : $0.key < $1.key
        }
        var roots: [RelatedFile] = []
        var parent: String?
        for entry in sorted {
            if let parent, entry.key.hasPrefix(parent) { continue }
            roots.append(entry.file)
            parent = entry.key
        }
        return roots
    }

    static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }

    /// Shared data and parent/child discoveries must not inflate the list's aggregate total.
    static func combinedSize(_ applications: [InstalledApplication]) -> UInt64 {
        let roots = applications.flatMap { app in
            [RelatedFile(url: app.url, displayPath: app.url.path, size: app.size)] + (app.storageUsage?.files ?? [])
        }
        return uniqueRoots(roots).reduce(0) { add($0, $1.size) }
    }
}
