import Foundation

enum AtomicFileExport {
    /// Stage in the destination filesystem, then rename atomically. Errors/cancellation leave an
    /// existing file untouched, and new-file metadata (including download quarantine) is retained.
    static func save(_ source: URL, to destination: URL) throws {
        guard destination.isFileURL else { throw UpdateError.destination }
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".wonderbox-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        do {
            if manager.fileExists(atPath: destination.path) {
                guard try manager.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType == .typeRegular else {
                    throw UpdateError.destination
                }
            }
            try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = staging.appendingPathComponent("download")
            try manager.copyItem(at: source, to: file)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try Task.checkCancellation()
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: file, options: .usingNewMetadataOnly)
            } else { try manager.moveItem(at: file, to: destination) }
        } catch is CancellationError { throw CancellationError() }
        catch { throw UpdateError.destination }
    }
}
