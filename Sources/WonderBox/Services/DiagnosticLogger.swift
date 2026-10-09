import Foundation

enum DiagnosticEvent: String, Codable {
    case appStarted, updateCheckStarted, updateCheckFinished, updateAPIFallback, updateDownloadStarted, updateDownloadFinished
    case applicationScanFinished, relatedFileScanFinished, applicationTrashAttempt, systemTrashFinished, uninstallFinished, storageScanFinished, cleanupFinished
    case diskScanFinished, diskTrashFinished, fanInitialRead, fanModeApplied, helperPreparation, helperInstallation, helperTrashFinished, memoryOptimization, systemCachesCleaned
}

enum DiagnosticOutcome: String, Codable { case success, failure, cancelled, partial, unavailable }
enum DiagnosticMetric: String, CaseIterable { case count, failed, skipped, bytes, durationMS, errorCode, httpStatus, zeroReadings, failureStage }
enum DiagnosticErrorFamily: String, Codable { case network, fileSystem, release, helper, other }

/// A deliberately narrow schema: callers cannot accidentally write paths, filenames, commands,
/// user names, tokens, localized errors or chat content. No periodic system-monitor samples.
final class DiagnosticLogger: @unchecked Sendable {
    static let enabledKey = "diagnosticLoggingEnabled"
    static let shared = DiagnosticLogger(
        directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WonderBox", isDirectory: true),
        enabled: UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    )
    static let maximumBytes = 2 * 1_024 * 1_024
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    struct Summary: Equatable, Sendable { var bytes = 0; var files = 0 }
    private struct Entry: Codable {
        let timestamp: String
        let event: DiagnosticEvent
        let outcome: DiagnosticOutcome
        let errorFamily: DiagnosticErrorFamily?
        let metrics: [String: Int64]
    }

    private let queue = DispatchQueue(label: "com.wondercraft.WonderBox.diagnostics", qos: .utility)
    private let directory: URL
    private let fileLimit: Int
    private let fileCount: Int
    private let retention: TimeInterval
    private let clock: () -> Date
    private var enabled: Bool
    private var nextRetentionCheck = Date.distantPast
    private let manager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    init(directory: URL, enabled: Bool = true, fileLimit: Int = 512 * 1_024, fileCount: Int = 4,
         retention: TimeInterval = DiagnosticLogger.retention, clock: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.enabled = enabled
        self.fileLimit = max(512, min(fileLimit, 512 * 1_024))
        self.fileCount = max(1, min(fileCount, 4))
        self.retention = retention
        self.clock = clock
        queue.async { [self] in
            if enabled { try? prune() } else { try? removeLogs() }
        }
    }

    func record(_ event: DiagnosticEvent, outcome: DiagnosticOutcome = .success,
                errorFamily: DiagnosticErrorFamily? = nil, metrics: [DiagnosticMetric: Int64] = [:]) {
        let date = clock()
        queue.async { [self] in
            guard enabled else { return }
            do {
                try prepareDirectory()
                try prune()
                let entry = Entry(timestamp: ISO8601DateFormatter().string(from: date), event: event, outcome: outcome,
                                  errorFamily: errorFamily, metrics: Dictionary(uniqueKeysWithValues: metrics.map { ($0.key.rawValue, $0.value) }))
                var data = try encoder.encode(entry)
                data.append(10)
                guard data.count <= fileLimit else { return }
                if try size(of: file(0)) + data.count > fileLimit { try rotate() }
                if !manager.fileExists(atPath: file(0).path) {
                    guard manager.createFile(atPath: file(0).path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
                }
                guard try isRegularFile(file(0)) else { return }
                let handle = try FileHandle(forWritingTo: file(0))
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                nextRetentionCheck = min(nextRetentionCheck, date.addingTimeInterval(retention))
            } catch {
                // Logging must never interrupt the user's operation, including on a full disk.
            }
        }
    }

    func setEnabled(_ value: Bool) {
        queue.async { [self] in
            enabled = value
            if !value { try? removeLogs() }
        }
    }

    func clear() throws { try queue.sync { try removeLogs() } }

    /// Also acts as a barrier for queued writes, useful for exports and tests.
    func summary() throws -> Summary {
        try queue.sync {
            try prune(force: true)
            return try (0..<fileCount).reduce(into: Summary()) { result, index in
                let count = try size(of: file(index))
                if count > 0 { result.bytes += count; result.files += 1 }
            }
        }
    }

    /// Snapshot only our fixed, regular log files. Never enumerate the user's filesystem into an export.
    func export(to destination: URL, version: String, build: String) throws {
        let temporary = manager.temporaryDirectory.appendingPathComponent("WonderBox-diagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: temporary) }
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let snapshot = temporary.appendingPathComponent("WonderBox-Diagnostics", isDirectory: true)
        try manager.createDirectory(at: snapshot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try queue.sync {
            try prune(force: true)
            for index in (0..<fileCount).reversed() where try size(of: file(index)) > 0 {
                try manager.copyItem(at: file(index), to: snapshot.appendingPathComponent(file(index).lastPathComponent))
            }
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "appVersion": AppVersion(version) == nil ? "unknown" : String(version.prefix(80)),
            "build": build.allSatisfy({ $0.isASCII && $0.isNumber }) ? String(build.prefix(20)) : "unknown",
            "macOS": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "architecture": architecture,
            "exportedAt": ISO8601DateFormatter().string(from: clock()),
            "logLimitBytes": fileLimit * fileCount,
            "retentionDays": Int(retention / 86_400),
            "contents": "Operation outcomes and numeric error codes only. No paths, filenames, usernames, tokens or file contents."
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: snapshot.appendingPathComponent("summary.json"), options: .atomic)
        let archive = temporary.appendingPathComponent("diagnostics.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", snapshot.path, archive.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        try AtomicFileExport.save(archive, to: destination)
    }

    private func file(_ index: Int) -> URL {
        directory.appendingPathComponent(index == 0 ? "events.jsonl" : "events-\(index).jsonl")
    }

    private func prepareDirectory() throws {
        if manager.fileExists(atPath: directory.path) {
            let attributes = try manager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileWriteNoPermission) }
        } else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func isRegularFile(_ url: URL) throws -> Bool {
        try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular
    }

    private func size(of url: URL) throws -> Int {
        guard manager.fileExists(atPath: url.path), try isRegularFile(url) else { return 0 }
        return (try manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    private func prune(force: Bool = false) throws {
        guard manager.fileExists(atPath: directory.path) else { return }
        try prepareDirectory()
        let now = clock()
        let cutoff = now.addingTimeInterval(-retention)
        let inspectEntries = force || now >= nextRetentionCheck
        if inspectEntries { nextRetentionCheck = now.addingTimeInterval(retention) }
        let formatter = ISO8601DateFormatter()
        let allowedMetrics = Set(DiagnosticMetric.allCases.map(\.rawValue))
        for index in 0..<fileCount {
            let url = file(index)
            guard manager.fileExists(atPath: url.path) else { continue }
            let attributes = try manager.attributesOfItem(atPath: url.path)
            let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let date = attributes[.modificationDate] as? Date ?? .distantPast
            if attributes[.type] as? FileAttributeType != .typeRegular || bytes > fileLimit || date < cutoff {
                try manager.removeItem(at: url)
            } else {
                if inspectEntries {
                    // Enforce retention per event, including a log file still receiving writes.
                    // Re-encode the allowlisted schema before export; ignore corrupt/unknown entries.
                    let original = try Data(contentsOf: url)
                    var retained = Data()
                    for line in original.split(separator: 10) {
                        guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(line)),
                              let timestamp = formatter.date(from: entry.timestamp), timestamp > cutoff, timestamp <= now else { continue }
                        let clean = Entry(timestamp: formatter.string(from: timestamp), event: entry.event, outcome: entry.outcome,
                                          errorFamily: entry.errorFamily, metrics: entry.metrics.filter { allowedMetrics.contains($0.key) })
                        retained.append(try encoder.encode(clean))
                        retained.append(10)
                        nextRetentionCheck = min(nextRetentionCheck, timestamp.addingTimeInterval(retention))
                    }
                    if retained.isEmpty { try manager.removeItem(at: url); continue }
                    if retained != original { try retained.write(to: url, options: .atomic) }
                }
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }

    private func rotate() throws {
        for index in (0..<fileCount).reversed() {
            let source = file(index)
            guard manager.fileExists(atPath: source.path) else { continue }
            if index == fileCount - 1 { try manager.removeItem(at: source) }
            else { try manager.moveItem(at: source, to: file(index + 1)) }
        }
    }

    private func removeLogs() throws {
        guard manager.fileExists(atPath: directory.path) else { return }
        try prepareDirectory()
        for index in 0..<fileCount where manager.fileExists(atPath: file(index).path) {
            try manager.removeItem(at: file(index))
        }
    }
}
