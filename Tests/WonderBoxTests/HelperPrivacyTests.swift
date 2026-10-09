import AppKit
import Darwin
import Foundation
import SwiftUI
import XCTest
@testable import WonderSupport
@testable import WonderBox

final class HelperPrivacyTests: XCTestCase {
    func testDaemonDeclaresMainAppAssociationAndHelperHasEmbeddedIdentity() throws {
        let daemon = try plist("Sources/WonderBox/Resources/com.wondercraft.WonderBox.FanHelper.plist")
        XCTAssertEqual(daemon["AssociatedBundleIdentifiers"] as? [String], ["com.wondercraft.WonderBox"])
        let helper = try plist("Sources/WonderFanHelper/Resources/Info.plist")
        XCTAssertEqual(helper["CFBundleIdentifier"] as? String, "com.wondercraft.WonderBox.FanHelper")
        XCTAssertEqual(helper["CFBundleVersion"] as? String, PrivilegedService.protocolVersion)
        XCTAssertNotEqual(PrivilegedService.protocolVersion, "5", "Previously installed v5 daemons must be upgraded")
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("__info_plist"))
        let packaging = try String(contentsOf: root.appendingPathComponent("scripts/package_app.sh"), encoding: .utf8)
        XCTAssertLessThan(try XCTUnwrap(packaging.range(of: "configure_helper_identity.py")).lowerBound,
                          try XCTUnwrap(packaging.range(of: "codesign --force --deep")).lowerBound)
    }

    func testPrivacyDenialOpeningTrashReportsTheActualStageAndErrno() throws {
        let home = try fixture()
        let source = try app(home, "Google 文档")
        let request = TrashRequest(paths: [source.path])
        let result = PrivilegedTrash.move(request, uid: getuid(), gid: getgid(), home: home.path) { _ in
            errno = EPERM
            return nil
        }
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.failed, [source.path])
        XCTAssertEqual(result.failures, [.init(index: 0, stage: .trashDirectory, errorCode: EPERM)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let feedback = PrivilegedTrashFeedback(result)
        XCTAssertTrue(feedback.needsPrivacySettings)
        XCTAssertTrue(try XCTUnwrap(feedback.message).contains("Trash"))
    }

    func testSourceParentDenialLeavesApplicationUntouched() throws {
        let home = try fixture()
        let source = try app(home, "Google 云端硬盘")
        let trash = home.appendingPathComponent(".Trash").path
        let result = PrivilegedTrash.move(TrashRequest(paths: [source.path]), uid: getuid(), gid: getgid(), home: home.path) { path in
            if path == trash { return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            errno = EPERM
            return nil
        }
        XCTAssertEqual(result.failures, [.init(index: 0, stage: .sourceParent, errorCode: EPERM)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(PrivilegedTrashFeedback(result).needsPrivacySettings)
    }

    func testChineseNamedChromeStyleBundlesCanBeTrashedInFixture() throws {
        let home = try fixture()
        let sources = try [app(home, "Google 文档"), app(home, "Google 云端硬盘")]
        let result = PrivilegedTrash.move(TrashRequest(paths: sources.map(\.path)), uid: getuid(), gid: getgid(), home: home.path)
        XCTAssertEqual(result.moved, 2)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let wrappers = try FileManager.default.contentsOfDirectory(at: home.appendingPathComponent(".Trash"), includingPropertiesForKeys: nil)
        let names = try wrappers.flatMap { try FileManager.default.contentsOfDirectory(atPath: $0.path) }
        XCTAssertEqual(Set(names), ["Google 文档.app", "Google 云端硬盘.app"])
    }

    func testLockedBundleIsNotMisdiagnosedAsFullDiskAccess() throws {
        let home = try fixture()
        let source = try app(home, "Locked")
        guard chflags(source.path, UInt32(UF_IMMUTABLE)) == 0 else { throw XCTSkip("Filesystem does not support locked fixtures") }
        defer { _ = chflags(source.path, 0) }
        let result = PrivilegedTrash.move(TrashRequest(paths: [source.path]), uid: getuid(), gid: getgid(), home: home.path)
        XCTAssertEqual(result.failures, [.init(index: 0, stage: .lockedItem, errorCode: EPERM)])
        XCTAssertFalse(PrivilegedTrashFeedback(result).needsPrivacySettings)
        XCTAssertTrue(try XCTUnwrap(PrivilegedTrashFeedback(result).message).contains("Locked"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testUnsupportedAndSymlinkTargetsStayRejected() throws {
        let home = try fixture()
        let source = try app(home, "Keep")
        let link = source.deletingLastPathComponent().appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let unsafe = home.appendingPathComponent("Documents/file")
        let result = PrivilegedTrash.move(TrashRequest(paths: [unsafe.path, link.path]), uid: getuid(), gid: getgid(), home: home.path)
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.failures.map(\.stage), [.unsafePath, .unsafePath])
        XCTAssertEqual(result.failures.map(\.errorCode), [EINVAL, ELOOP])
        XCTAssertFalse(PrivilegedTrashFeedback(result).needsPrivacySettings)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMissingFileRetainsCorrectRequestIndexAlongsideSuccessfulMove() throws {
        let home = try fixture()
        let source = try app(home, "Move")
        let missing = source.deletingLastPathComponent().appendingPathComponent("Missing.app")
        let result = PrivilegedTrash.move(TrashRequest(paths: [source.path, missing.path]), uid: getuid(), gid: getgid(), home: home.path)
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.failed, [missing.path])
        XCTAssertEqual(result.failures, [.init(index: 1, stage: .sourceItem, errorCode: ENOENT)])
        XCTAssertFalse(PrivilegedTrashFeedback(result).needsPrivacySettings)
    }

    func testTraditionalPermissionErrorsDoNotClaimPrivacyDenial() throws {
        let feedback = PrivilegedTrashFeedback(response(stage: .sourceParent, code: EACCES))
        XCTAssertFalse(feedback.needsPrivacySettings)
        XCTAssertTrue(try XCTUnwrap(feedback.message).contains("Sharing & Permissions"))
    }

    func testCrossDeviceReadOnlyDiskFullAndUnknownErrorsHaveDifferentAdvice() throws {
        let cases: [(Int32, String)] = [(EXDEV, "across disks"), (EROFS, "read-only"), (ENOSPC, "space"), (EIO, "5")]
        for (code, text) in cases {
            let feedback = PrivilegedTrashFeedback(response(stage: .move, code: code))
            XCTAssertFalse(feedback.needsPrivacySettings)
            XCTAssertTrue(try XCTUnwrap(feedback.message).contains(text))
        }
    }

    func testResponseRoundTripAndLegacyDecoding() throws {
        let value = response(stage: .trashDirectory, code: EPERM)
        let decoded = try JSONDecoder().decode(TrashResponse.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.failures, value.failures)
        XCTAssertEqual(decoded.failed, value.failed)
        let old = try JSONDecoder().decode(TrashResponse.self, from: Data(#"{"moved":0,"failed":["/fixture/app"]}"#.utf8))
        XCTAssertTrue(old.failures.isEmpty)
        XCTAssertNotNil(PrivilegedTrashFeedback(old).message)
        XCTAssertFalse(PrivilegedTrashFeedback(old).needsPrivacySettings)
        XCTAssertNil(PrivilegedTrashFeedback(TrashResponse()).message)
    }

    func testFullReplyWithFailureDetailsFitsInNewWireLimit() throws {
        let paths = (0..<256).map { "/Applications/" + String(repeating: "x", count: 160) + "\($0).app" }
        XCTAssertLessThan(try JSONEncoder().encode(TrashRequest(paths: paths)).base64EncodedData().count + 7, 65_536)
        var value = TrashResponse()
        value.failed = paths
        value.failures = paths.indices.map { .init(index: $0, stage: .trashDirectory, errorCode: EPERM) }
        let size = try JSONEncoder().encode(value).base64EncodedData().count + 4
        XCTAssertLessThan(size, 131_072)
        let client = try String(contentsOf: root.appendingPathComponent("Sources/WonderBox/Services/PrivilegedService.swift"), encoding: .utf8)
        XCTAssertTrue(client.contains("maximumReplySize = 131_072"))
    }

    func testEmptyRequestDoesNotProbeProtectedTrash() throws {
        let home = try fixture()
        var probes = 0
        let result = PrivilegedTrash.move(TrashRequest(paths: []), uid: getuid(), gid: getgid(), home: home.path) { _ in
            probes += 1
            return nil
        }
        XCTAssertEqual(probes, 0)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testHelperDiagnosticsContainOnlyNumbersNotFilePaths() throws {
        let home = try fixture()
        let logs = home.appendingPathComponent("logs")
        let logger = DiagnosticLogger(directory: logs)
        logger.record(.helperTrashFinished, outcome: .partial, errorFamily: .fileSystem,
                      metrics: [.count: 0, .failed: 1, .errorCode: Int64(EPERM), .failureStage: Int64(TrashFailure.Stage.trashDirectory.rawValue)])
        _ = try logger.summary()
        let data = try Data(contentsOf: logs.appendingPathComponent("events.jsonl"))
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metrics = try XCTUnwrap(entry["metrics"] as? [String: Int])
        XCTAssertEqual(metrics["failureStage"], 2)
        XCTAssertEqual(metrics["errorCode"], Int(EPERM))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(home.path))
    }

    func testPackagedAppPinsItsSignedHelper() throws {
        guard ProcessInfo.processInfo.environment["WONDERBOX_VERIFY_PACKAGE"] == "1" else { throw XCTSkip("Opt-in packaged-build verification") }
        let info = try plist("build/WonderBox.app/Contents/Info.plist")
        let executables = try XCTUnwrap(info["SMPrivilegedExecutables"] as? [String: String])
        let requirement = try XCTUnwrap(executables["com.wondercraft.WonderBox.FanHelper"])
        XCTAssertTrue(requirement.contains("cdhash") || requirement.contains("anchor"), "Do not trust an identifier alone")
        let helper = root.appendingPathComponent("build/WonderBox.app/Contents/Helpers/WonderFanHelper")
        let verification = Process()
        verification.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verification.arguments = ["--verify", "--strict", "-R", "=" + requirement, helper.path]
        try verification.run(); verification.waitUntilExit()
        XCTAssertEqual(verification.terminationStatus, 0)
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        unrelated.arguments = ["--verify", "-R", "=" + requirement, "/usr/bin/true"]
        unrelated.standardError = FileHandle.nullDevice
        try unrelated.run(); unrelated.waitUntilExit()
        XCTAssertNotEqual(unrelated.terminationStatus, 0)
    }

    @MainActor
    func testPrivacyGuidanceOffscreenPreview() throws {
        guard ProcessInfo.processInfo.environment["WONDERBOX_RENDER_PREVIEWS"] == "1" else { throw XCTSkip("Opt-in UI preview") }
        let view = VStack(alignment: .leading, spacing: 14) {
            InlineMessage(text: String(localized: "Allow WonderBox to control Finder in System Settings > Privacy & Security > Automation"), isError: true)
            FinderPermissionGuidance()
        }.padding(20).frame(width: 650).background(Color.appBackground)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 230), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; host.frame = window.contentView!.bounds; host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/wonderbox-helper-privacy-preview.png"))
        window.contentView = nil
    }

    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func plist(_ path: String) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent(path)), format: nil) as? [String: Any])
    }
    private func fixture() throws -> URL {
        // Foundation canonicalizes /private/var back to /var; the privileged mover intentionally
        // rejects symlink parents, so use the kernel's real path just like the existing helper tests.
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(FileManager.default.temporaryDirectory.path, &path) != nil else { throw POSIXError(.ENOENT) }
        let base = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("wonderbox-helper-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }
    private func app(_ home: URL, _ name: String) throws -> URL {
        let url = home.appendingPathComponent("Applications/Chrome Apps.localized/\(name).app")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func response(stage: TrashFailure.Stage, code: Int32) -> TrashResponse {
        var response = TrashResponse()
        response.failed = ["/fixture/app"]
        response.failures = [.init(index: 0, stage: stage, errorCode: code)]
        return response
    }
}
