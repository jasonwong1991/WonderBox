import AppKit
import CryptoKit
import Foundation
import SwiftUI
import XCTest
@testable import WonderBox

final class UpdateAndDiagnosticsTests: XCTestCase {
    @MainActor
    func testSettingsRefreshWaitsForUpdateCheckWithoutRequestingAutoScroll() async throws {
        let controller = try makeController(root: temporaryDirectory())
        await controller.refreshCheck()
        XCTAssertEqual(controller.status, .available)
        XCTAssertNotNil(controller.lastChecked)
        XCTAssertFalse(controller.userInitiatedCheck)
        XCTAssertFalse(controller.isBusy)
    }

    func testSemanticVersionsCompareNumericallyAndIgnoreBuildMetadata() throws {
        XCTAssertLessThan(try version("v0.9.9"), try version("0.10.0"))
        XCTAssertLessThan(try version("0.99.99"), try version("1.0.0"))
        XCTAssertEqual(try version("1.0.0+build.42"), try version("1.0.0"))
        XCTAssertLessThan(try version("1.0.0-rc.2"), try version("1.0.0-rc.11"))
        XCTAssertLessThan(try version("1.0.0-rc.11"), try version("1.0.0"))
        XCTAssertLessThan(try version("1.0.0-1"), try version("1.0.0-alpha"))
        XCTAssertLessThan(try version("1.0.0-alpha"), try version("1.0.0-alpha.1"))
    }

    func testMalformedVersionsAreRejected() {
        for text in ["", "0.4", "v0.4.0/evil", "1.0.0-", "1.0.0+", "1.0.0++build", "1.0.0-alpha..1", "1.0.0-01", "01.0.0", "1.0.0 空间", "-1.0.0", "1.0.0+路径"] {
            XCTAssertNil(AppVersion(text), text)
        }
    }

    func testReleaseSelectionNeverDowngrades() throws {
        let release = try fixtureRelease()
        XCTAssertNotNil(try release.availableUpdate(after: "0.4.0"))
        XCTAssertNil(try release.availableUpdate(after: "0.5.0"))
        XCTAssertNil(try release.availableUpdate(after: "1.0.0"))
        XCTAssertNotNil(try release.availableUpdate(after: "0.5.0-beta.1"))
    }

    func testDraftsPrereleasesAndWrongRepositoryAreRejected() throws {
        for overrides: [String: Any] in [
            ["draft": true], ["prerelease": true], ["tag_name": "v0.5.0-beta"],
            ["html_url": "https://github.com/other/repo/releases/tag/v0.5.0"], ["tag_name": "invalid"]
        ] {
            XCTAssertThrowsError(try fixtureRelease(overrides: overrides).availableUpdate(after: "0.4.0"))
        }
    }

    func testDownloadAssetRequiresExactNameTrustedURLAndSize() throws {
        for overrides: [String: Any] in [
            ["name": "Malicious.zip"], ["size": 0], ["size": UpdateSource.maximumDownloadSize + 1],
            ["browser_download_url": "http://github.com/jasonwong1991/WonderBox/releases/download/v0.5.0/WonderBox-0.5.0.zip"],
            ["browser_download_url": "https://evil.example/WonderBox-0.5.0.zip"],
            ["browser_download_url": "https://github.com/other/repo/releases/download/v0.5.0/WonderBox-0.5.0.zip"]
        ] {
            XCTAssertThrowsError(try fixtureRelease(assetOverrides: overrides).availableUpdate(after: "0.4.0"))
        }
    }

    func testSHA256DigestOrChecksumFileIsRequired() throws {
        XCTAssertThrowsError(try fixtureRelease(assetOverrides: ["digest": "sha256:invalid"]).availableUpdate(after: "0.4.0"))
        XCTAssertThrowsError(try fixtureRelease(assetOverrides: ["digest": NSNull()]).availableUpdate(after: "0.4.0"))
        let sums: [String: Any] = ["name": "SHA256SUMS", "size": 86,
            "browser_download_url": "https://github.com/jasonwong1991/WonderBox/releases/download/v0.5.0/SHA256SUMS"]
        let update = try XCTUnwrap(fixtureRelease(assetOverrides: ["digest": NSNull()], extraAssets: [sums]).availableUpdate(after: "0.4.0"))
        XCTAssertNil(update.sha256)
        XCTAssertNotNil(update.checksumURL)
    }

    func testChecksumParserAcceptsOnlyOneExactFilename() throws {
        let hash = String(repeating: "a", count: 64)
        XCTAssertEqual(try UpdateSource.checksum(in: Data("\(hash)  WonderBox-0.5.0.zip\n".utf8), filename: "WonderBox-0.5.0.zip"), hash)
        XCTAssertEqual(try UpdateSource.checksum(in: Data("\(hash) *WonderBox-0.5.0.zip\n".utf8), filename: "WonderBox-0.5.0.zip"), hash)
        for text in ["\(hash)  Other.zip", "bad  WonderBox-0.5.0.zip", "\(hash)  ./WonderBox-0.5.0.zip",
                     "\(hash)  WonderBox-0.5.0.zip\n\(hash)  WonderBox-0.5.0.zip"] {
            XCTAssertThrowsError(try UpdateSource.checksum(in: Data(text.utf8), filename: "WonderBox-0.5.0.zip"))
        }
    }

    func testHTTPSRedirectAllowlistRejectsCredentialsAndLookalikeHosts() {
        XCTAssertTrue(UpdateSource.permitsRedirect(to: URL(string: "https://release-assets.githubusercontent.com/asset?token=signed")!))
        for text in ["http://github.com/file", "https://github.com.evil.example/file", "https://user:password@github.com/file", "https://github.com:8443/file", "https://evil.example/file"] {
            XCTAssertFalse(UpdateSource.permitsRedirect(to: URL(string: text)!))
        }
    }

    func testPublicPageFallbackAcceptsOnlyOfficialStableReleaseTags() throws {
        XCTAssertEqual(try UpdateSource.releaseTag(from: URL(string: "https://github.com/jasonwong1991/WonderBox/releases/tag/v0.5.0")!), "v0.5.0")
        for value in ["https://github.com/other/repo/releases/tag/v0.5.0", "https://github.com/jasonwong1991/WonderBox/releases/latest", "https://github.com/jasonwong1991/WonderBox/releases/tag/v0.5.0-beta.1", "https://evil.example/v0.5.0"] {
            XCTAssertThrowsError(try UpdateSource.releaseTag(from: URL(string: value)!))
        }
    }

    func testDownloadedArchiveKeepsQuarantineProvenanceAfterSaving() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("download")
        let destination = root.appendingPathComponent("new.zip")
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: source)
        try UpdateFileStorage.markDownloadedArchive(source, sourceURL: UpdateSource.latestPageURL, originURL: UpdateSource.releasesURL)
        try AtomicFileExport.save(source, to: destination)
        XCTAssertNotNil(try (destination as NSURL).resourceValues(forKeys: [.quarantinePropertiesKey])[.quarantinePropertiesKey])
        // Overwriting a previously unquarantined download must keep the new provenance too.
        let old = root.appendingPathComponent("old.zip")
        try Data("old".utf8).write(to: old)
        try AtomicFileExport.save(source, to: old)
        XCTAssertNotNil(try (old as NSURL).resourceValues(forKeys: [.quarantinePropertiesKey])[.quarantinePropertiesKey])
    }

    func testAutomaticChecksAreThrottledEvenAfterFailedAttempts() {
        let now = Date()
        XCTAssertTrue(UpdateSource.shouldCheck(automatically: true, lastAttempt: nil, now: now))
        XCTAssertFalse(UpdateSource.shouldCheck(automatically: false, lastAttempt: nil, now: now))
        XCTAssertFalse(UpdateSource.shouldCheck(automatically: true, lastAttempt: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(UpdateSource.shouldCheck(automatically: true, lastAttempt: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(UpdateSource.shouldCheck(automatically: true, lastAttempt: now.addingTimeInterval(60), now: now))
    }

    func testStreamingArchiveVerificationAndAtomicReplacement() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("download")
        let destination = root.appendingPathComponent("WonderBox.zip")
        let content = Data([0x50, 0x4b, 0x03, 0x04]) + Data(repeating: 7, count: 800_000)
        try content.write(to: source)
        let hash = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        try UpdateFileStorage.verifyArchive(source, expectedSize: Int64(content.count), sha256: hash)
        try Data("old archive".utf8).write(to: destination)
        try AtomicFileExport.save(source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), content)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["WonderBox.zip", "download"])
    }

    func testVerificationRejectsCorruptionTruncationAndHTML() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("download")
        let content = Data([0x50, 0x4b, 0x03, 0x04, 1, 2])
        try content.write(to: source)
        XCTAssertThrowsError(try UpdateFileStorage.verifyArchive(source, expectedSize: 6, sha256: String(repeating: "0", count: 64))) { XCTAssertEqual($0 as? UpdateError, .checksumMismatch) }
        XCTAssertThrowsError(try UpdateFileStorage.verifyArchive(source, expectedSize: 7, sha256: String(repeating: "0", count: 64))) { XCTAssertEqual($0 as? UpdateError, .sizeMismatch) }
        try Data("<html>error</html>".utf8).write(to: source)
        XCTAssertThrowsError(try UpdateFileStorage.verifyArchive(source, expectedSize: 18, sha256: String(repeating: "0", count: 64))) { XCTAssertEqual($0 as? UpdateError, .invalidArchive) }
    }

    func testSaveFailurePreservesExistingFileAndCleansStaging() throws {
        let root = try temporaryDirectory()
        let destination = root.appendingPathComponent("old.zip")
        try Data("keep".utf8).write(to: destination)
        XCTAssertThrowsError(try AtomicFileExport.save(root.appendingPathComponent("missing"), to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["old.zip"])
    }

    func testAtomicExportRejectsSymlinkAndDirectoryDestinations() throws {
        let root = try temporaryDirectory()
        let outside = root.appendingPathComponent("private")
        let source = root.appendingPathComponent("source")
        try Data("keep".utf8).write(to: outside)
        try Data("archive".utf8).write(to: source)
        let link = root.appendingPathComponent("download.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try AtomicFileExport.save(source, to: link))
        XCTAssertThrowsError(try AtomicFileExport.save(source, to: root))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }

    func testRoutineCleanupProtectsOurDiagnosticsAtExecutionTime() {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        XCTAssertFalse(StorageCleaner.isSafe(logs.appendingPathComponent("WonderBox"), for: .logs))
        XCTAssertFalse(StorageCleaner.isSafe(logs.appendingPathComponent("WonderBox/events.jsonl"), for: .logs))
        XCTAssertTrue(StorageCleaner.isSafe(logs.appendingPathComponent("OtherApp/events.log"), for: .logs))
    }

    func testCancelledAtomicSaveLeavesExistingFileUntouched() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("old.zip")
        try Data("new".utf8).write(to: source)
        try Data("keep".utf8).write(to: destination)
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try AtomicFileExport.save(source, to: destination)
        }
        do { try await work.value; XCTFail("A cancelled save must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["old.zip", "source"])
    }

    func testAlreadyCancelledNetworkDownloadCompletesWithoutSaving() async throws {
        let root = try temporaryDirectory()
        let update = try XCTUnwrap(fixtureRelease().availableUpdate(after: "0.4.0"))
        let destination = root.appendingPathComponent("download.zip")
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await GitHubUpdateClient().download(update, to: destination, progress: { _ in })
        }
        do { try await work.value; XCTFail("A cancelled transfer must throw") }
        catch { XCTAssertTrue(error is CancellationError || (error as NSError).code == NSURLErrorCancelled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testControllerFindsDownloadsAndReportsVerifiedUpdate() async throws {
        let root = try temporaryDirectory()
        let controller = try makeController(root: root)
        controller.check()
        XCTAssertEqual(controller.status, .checking)
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(controller.status, .available)
        XCTAssertNotNil(controller.lastChecked)
        let destination = root.appendingPathComponent("new.zip")
        controller.download(to: destination)
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(controller.status, .downloaded)
        XCTAssertEqual(controller.downloadedURL, destination)
        XCTAssertEqual(controller.progress, 1)
    }

    @MainActor
    func testControllerCurrentReleaseHasNoDownload() async throws {
        let controller = try makeController(root: temporaryDirectory(), version: "1.0.0")
        controller.check()
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(controller.status, .current)
        XCTAssertNil(controller.update)
    }

    @MainActor
    func testControllerOfflineErrorAndCancellationDoNotSetSuccessfulCheckDate() async throws {
        let root = try temporaryDirectory()
        let offline = try makeController(root: root, mode: .offline)
        offline.check()
        await waitUntil { !offline.isBusy }
        XCTAssertEqual(offline.status, .failed)
        XCTAssertNotNil(offline.message)
        XCTAssertNil(offline.lastChecked)
        let cancel = try makeController(root: root, delay: .seconds(5))
        cancel.check()
        cancel.cancel()
        await waitUntil { !cancel.isBusy }
        XCTAssertEqual(cancel.status, .cancelled)
        XCTAssertNil(cancel.message)
        XCTAssertNil(cancel.lastChecked)
    }

    @MainActor
    func testCancelledDownloadCanBeRetriedAndDoesNotLeaveAFile() async throws {
        let root = try temporaryDirectory()
        let controller = try makeController(root: root, downloadDelay: .milliseconds(150))
        controller.check()
        await waitUntil { !controller.isBusy }
        let destination = root.appendingPathComponent("new.zip")
        controller.download(to: destination)
        controller.cancel()
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(controller.status, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNotNil(controller.update)
        controller.download(to: destination)
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(controller.status, .downloaded)
    }

    @MainActor
    func testAutomaticChecksRespectOptOutAndPersistentThrottle() async throws {
        let root = try temporaryDirectory()
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: UpdateController.automaticKey)
        let controller = try makeController(root: root, mode: .offline, defaults: defaults)
        controller.checkAutomaticallyIfNeeded()
        XCTAssertEqual(controller.status, .idle)
        defaults.set(true, forKey: UpdateController.automaticKey)
        controller.checkAutomaticallyIfNeeded()
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(controller.status, .failed)
        let nextLaunch = try makeController(root: root, defaults: defaults)
        nextLaunch.checkAutomaticallyIfNeeded()
        XCTAssertEqual(nextLaunch.status, .idle)
        nextLaunch.check()
        await waitUntil { !nextLaunch.isBusy }
        XCTAssertEqual(nextLaunch.status, .available)
    }

    func testLogRotationIsBoundedAndFilesArePrivate() throws {
        let root = try temporaryDirectory()
        let logger = DiagnosticLogger(directory: root.appendingPathComponent("logs"), fileLimit: 512, fileCount: 3)
        for count in 0..<100 { logger.record(.cleanupFinished, metrics: [.count: Int64(count)]) }
        let summary = try logger.summary()
        XCTAssertLessThanOrEqual(summary.bytes, 3 * 512)
        XCTAssertEqual(summary.files, 3)
        for url in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("logs"), includingPropertiesForKeys: nil) {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.isEmpty)
            for line in text.split(separator: "\n") { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8))) }
        }
    }

    func testConcurrentLogWritesRemainBoundedValidJSON() async throws {
        let root = try temporaryDirectory()
        let logger = DiagnosticLogger(directory: root, fileLimit: 1_024, fileCount: 4)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 { group.addTask { logger.record(.storageScanFinished, metrics: [.count: Int64(index)]) } }
        }
        XCTAssertLessThanOrEqual(try logger.summary().bytes, 4 * 1_024)
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for line in try Data(contentsOf: url).split(separator: 10) { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line))) }
        }
    }

    func testRetentionExpiresIndividualEventsInAnActiveFile() throws {
        let root = try temporaryDirectory()
        let now = Date()
        let file = root.appendingPathComponent("events.jsonl")
        let old = entry(date: now.addingTimeInterval(-8 * 86_400))
        let recent = entry(date: now.addingTimeInterval(-60))
        try Data((old + "\n" + recent + "\n").utf8).write(to: file)
        let logger = DiagnosticLogger(directory: root, clock: { now })
        XCTAssertEqual(try logger.summary().files, 1)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(String(lines[0]).contains(ISO8601DateFormatter().string(from: now.addingTimeInterval(-8 * 86_400))))
    }

    func testDisablingLoggingClearsFilesAndPreventsFutureWrites() throws {
        let root = try temporaryDirectory()
        let logger = DiagnosticLogger(directory: root)
        logger.record(.appStarted)
        XCTAssertGreaterThan(try logger.summary().bytes, 0)
        logger.setEnabled(false)
        logger.record(.cleanupFinished)
        XCTAssertEqual(try logger.summary().bytes, 0)
        logger.setEnabled(true)
        logger.record(.appStarted)
        XCTAssertGreaterThan(try logger.summary().bytes, 0)
        try logger.clear()
        XCTAssertEqual(try logger.summary().bytes, 0)
    }

    func testCorruptOversizedAndUnknownDataIsRemovedBeforeExport() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("events.jsonl")
        let now = Date()
        let sensitive = entry(date: now).dropLast() + ",\"privatePath\":\"/Users/Secret/chat.db\"}"
        try Data((sensitive + "\nnot json\n").utf8).write(to: file)
        try Data(repeating: 65, count: 600).write(to: root.appendingPathComponent("events-1.jsonl"))
        let logger = DiagnosticLogger(directory: root, fileLimit: 512, clock: { now })
        XCTAssertEqual(try logger.summary().files, 1)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("Secret"))
        XCTAssertFalse(text.contains("privatePath"))
        XCTAssertFalse(text.contains("not json"))
    }

    func testLoggerDoesNotFollowSymlinkedFilesOrDirectory() throws {
        let root = try temporaryDirectory()
        let outside = root.appendingPathComponent("private")
        try Data("do not read".utf8).write(to: outside)
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("events.jsonl"), withDestinationURL: outside)
        let logger = DiagnosticLogger(directory: logs)
        logger.record(.appStarted)
        XCTAssertGreaterThan(try logger.summary().bytes, 0)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "do not read")
        let link = root.appendingPathComponent("linkedLogs")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: logs)
        let linkedLogger = DiagnosticLogger(directory: link)
        XCTAssertThrowsError(try linkedLogger.summary())
    }

    func testExportContainsOnlyManagedLogsAndSanitizedSystemSummary() throws {
        let root = try temporaryDirectory()
        let logs = root.appendingPathComponent("logs")
        let logger = DiagnosticLogger(directory: logs)
        logger.record(.uninstallFinished, outcome: .partial, metrics: [.failed: 1])
        _ = try logger.summary()
        try Data("private document".utf8).write(to: logs.appendingPathComponent("secret.txt"))
        let destination = root.appendingPathComponent("diagnostics.zip")
        try logger.export(to: destination, version: "0.5.0", build: "5")
        let extracted = root.appendingPathComponent("extracted")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", destination.path, extracted.path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let folder = extracted.appendingPathComponent("WonderBox-Diagnostics")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["events.jsonl", "summary.json"])
        let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("summary.json"))) as? [String: Any])
        XCTAssertEqual(summary["appVersion"] as? String, "0.5.0")
        XCTAssertNil(summary["computerName"])
        XCTAssertNil(summary["userName"])
        XCTAssertEqual(summary["logLimitBytes"] as? Int, DiagnosticLogger.maximumBytes)
    }

    func testEmptyLogsCanStillExportSystemSummary() throws {
        let root = try temporaryDirectory()
        let logger = DiagnosticLogger(directory: root.appendingPathComponent("logs"), enabled: false)
        let destination = root.appendingPathComponent("diagnostics.zip")
        try logger.export(to: destination, version: "not a version /Users/Private", build: "Secret")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try logger.summary().bytes, 0)
    }

    func testReadOnlyGitHubUpdateDownloadSmoke() async throws {
        guard ProcessInfo.processInfo.environment["WONDERBOX_LIVE_UPDATE_SMOKE"] == "1" else { throw XCTSkip("Opt-in live network smoke") }
        let root = try temporaryDirectory()
        let client = GitHubUpdateClient()
        let release = try await client.latestRelease()
        let update = try XCTUnwrap(release.availableUpdate(after: "0.0.0"))
        let destination = root.appendingPathComponent(update.asset.name)
        let progress = ProgressRecorder()
        try await client.download(update, to: destination, progress: { progress.record($0) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertGreaterThan(progress.count, 0)
        print("Verified GitHub update download: \(update.version), \(update.asset.size) bytes")
    }

    @MainActor
    func testSettingsSectionsOffscreenPreview() async throws {
        guard ProcessInfo.processInfo.environment["WONDERBOX_RENDER_PREVIEWS"] == "1" else { throw XCTSkip("Opt-in UI render") }
        let root = try temporaryDirectory()
        let updater = try makeController(root: root)
        updater.check()
        await waitUntil { !updater.isBusy }
        let diagnostics = DiagnosticsController(logger: DiagnosticLogger(directory: root.appendingPathComponent("ui-logs")))
        let view = VStack(spacing: 20) {
            UpdateSettingsSection(updater: updater)
            DiagnosticsSettingsSection(diagnostics: diagnostics, version: "0.4.0", build: "4")
        }.padding(24).frame(width: 760).background(Color.appBackground)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 760), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.frame = window.contentView!.bounds
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/wonderbox-updates-diagnostics-preview.png"))
        window.contentView = nil
    }

    private func version(_ string: String) throws -> AppVersion { try XCTUnwrap(AppVersion(string)) }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wonderbox-update-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func isolatedDefaults() -> UserDefaults {
        let name = "wonderbox-update-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func entry(date: Date) -> String {
        "{\"timestamp\":\"\(ISO8601DateFormatter().string(from: date))\",\"event\":\"appStarted\",\"outcome\":\"success\",\"metrics\":{}}"
    }
    private func fixtureRelease(overrides: [String: Any] = [:], assetOverrides: [String: Any] = [:], extraAssets: [[String: Any]] = []) throws -> GitHubRelease {
        var asset: [String: Any] = ["name": "WonderBox-0.5.0.zip", "size": 100,
            "browser_download_url": "https://github.com/jasonwong1991/WonderBox/releases/download/v0.5.0/WonderBox-0.5.0.zip",
            "digest": "sha256:" + String(repeating: "a", count: 64)]
        asset.merge(assetOverrides) { _, new in new }
        var object: [String: Any] = ["tag_name": "v0.5.0", "draft": false, "prerelease": false,
            "html_url": "https://github.com/jasonwong1991/WonderBox/releases/tag/v0.5.0", "body": "Faster updates and diagnostics", "assets": [asset] + extraAssets]
        object.merge(overrides) { _, new in new }
        return try JSONDecoder().decode(GitHubRelease.self, from: JSONSerialization.data(withJSONObject: object))
    }
    @MainActor
    private func makeController(root: URL, version: String = "0.4.0", mode: StubClient.Mode = .normal,
                                delay: Duration = .milliseconds(5), downloadDelay: Duration = .milliseconds(5), defaults: UserDefaults? = nil) throws -> UpdateController {
        UpdateController(currentVersion: version, client: StubClient(release: try fixtureRelease(), mode: mode, delay: delay, downloadDelay: downloadDelay),
                         defaults: defaults ?? isolatedDefaults(), logger: DiagnosticLogger(directory: root.appendingPathComponent("logs")))
    }
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for controller")
    }
}

private struct StubClient: UpdateFetching {
    enum Mode { case normal, offline }
    let release: GitHubRelease
    let mode: Mode
    let delay: Duration
    let downloadDelay: Duration
    func latestRelease() async throws -> GitHubRelease {
        try await Task.sleep(for: delay)
        if mode == .offline { throw URLError(.notConnectedToInternet) }
        return release
    }
    func download(_ update: AvailableUpdate, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.5)
        try await Task.sleep(for: downloadDelay)
        try Data("test download".utf8).write(to: destination)
        progress(1)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return samples }
    func record(_ value: Double) { lock.lock(); defer { lock.unlock() }; samples += 1 }
}
