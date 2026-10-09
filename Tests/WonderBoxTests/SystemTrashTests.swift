import AppKit
import Darwin
import Foundation
import XCTest
@testable import WonderBox

final class SystemTrashTests: XCTestCase {
    @MainActor
    func testEmptyMissingAndNonFileRequestsDoNotStartSystemOperation() async {
        var calls = 0
        let result = await SystemTrashService.trash([URL(string: "https://example.invalid")!, url("gone")], recycle: { _ in
            calls += 1
            return .init()
        }, presence: { _ in .missing })
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(result.moved, 0)
        XCTAssertTrue(result.failed.isEmpty)
    }

    @MainActor
    func testFailedItemsAreRetriedInOneBatchWithoutDuplicates() async {
        let first = url("Google 文档.app"), second = url("Google 云端硬盘.app")
        var calls = 0
        var completed = false
        let result = await SystemTrashService.trash([first, first, second], recycle: { requested in
            calls += 1
            XCTAssertEqual(requested, [first, second])
            completed = true
            return .init(submitted: [first, second])
        }, presence: { _ in completed ? .missing : .present })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.moved, 2)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertNil(result.message)
    }

    @MainActor
    func testClaimedMoveWithoutSourceRemovalIsNotSuccess() async {
        let source = url("Keep.app")
        let result = await SystemTrashService.trash([source], recycle: { _ in
            .init(submitted: [source])
        }, presence: { _ in .present })
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.failed, [source])
        XCTAssertNotNil(result.message)
    }

    @MainActor
    func testInaccessibleSourceIsNotCountedAsRemoved() async {
        let source = url("Private.app")
        let result = await SystemTrashService.trash([source], recycle: { _ in
            .init(submitted: [source])
        }, presence: { _ in .inaccessible })
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.failed, [source])
    }

    @MainActor
    func testDisappearanceWithoutSystemConfirmationDoesNotInflateMovedCount() async {
        let source = url("Gone.app")
        var completed = false
        let result = await SystemTrashService.trash([source], recycle: { _ in
            completed = true
            return .init()
        }, presence: { _ in completed ? .missing : .present })
        XCTAssertEqual(result.moved, 0)
        XCTAssertTrue(result.failed.isEmpty)
    }

    @MainActor
    func testPartialSuccessAndCancellationArePreservedWithoutAnotherAttempt() async {
        let first = url("Move.app"), second = url("Keep.app")
        var completed = false
        var calls = 0
        let result = await SystemTrashService.trash([first, second], recycle: { _ in
            calls += 1
            completed = true
            return .init(submitted: [first, second], error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }, presence: { item in completed && item == first ? .missing : .present })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.failed, [second])
        XCTAssertTrue(result.isCancelled)
        XCTAssertTrue(result.message?.contains("cancelled") == true)
    }

    func testCancellationIncludesUnderlyingFinderErrorButNotOtherDomains() {
        let cancellation = NSError(domain: NSOSStatusErrorDomain, code: -128)
        XCTAssertTrue(SystemTrashService.isCancellation(cancellation))
        XCTAssertTrue(SystemTrashService.isCancellation(NSError(domain: NSCocoaErrorDomain, code: 513,
                                                               userInfo: [NSUnderlyingErrorKey: cancellation])))
        XCTAssertFalse(SystemTrashService.isCancellation(NSError(domain: NSPOSIXErrorDomain, code: -128)))
        XCTAssertFalse(SystemTrashService.isCancellation(NSError(domain: NSCocoaErrorDomain, code: 513)))
    }

    @MainActor
    func testFinderAutomationDenialHasSpecificAdviceAndDoesNotRepeat() async {
        var calls = 0
        let result = await SystemTrashService.trash([url("Keep.app")], recycle: { _ in
            calls += 1
            return .init(error: NSError(domain: NSOSStatusErrorDomain, code: -1743))
        }, presence: { _ in .present })
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(result.needsFinderPermission)
        XCTAssertTrue(result.message?.contains("Automation") == true)
        XCTAssertFalse(result.message?.contains("Full Disk Access") == true)
    }

    @MainActor
    func testFinderTimeoutDoesNotAutomaticallyRepeatAnUncertainMove() async {
        var calls = 0
        let result = await SystemTrashService.trash([url("Keep.app")], recycle: { _ in
            calls += 1
            return .init(error: NSError(domain: NSOSStatusErrorDomain, code: -1712))
        }, presence: { _ in .present })
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(result.needsFinderPermission)
        XCTAssertTrue(result.message?.contains("may still be moving") == true)
    }

    func testPathsArePassedAsAppleEventDataRatherThanScriptSource() throws {
        let sources = [url("A \"quote\"; do shell script 'touch NEVER'\n文件.app"), url("Test Drive.app")]
        let event = SystemTrashService.makeEvent(sources)
        let arguments = try XCTUnwrap(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
        let paths = try XCTUnwrap(arguments.atIndex(1))
        XCTAssertEqual(paths.numberOfItems, 2)
        XCTAssertEqual(paths.atIndex(1)?.stringValue, sources[0].path)
        XCTAssertEqual(paths.atIndex(2)?.stringValue, sources[1].path)
    }

    @MainActor
    func testForegroundRemovalYieldsOnceAndRequestsFinderActivation() throws {
        var yields = 0
        let source = url("Root Owned.app")
        let event = SystemTrashService.prepareEvent([source], isApplicationActive: true) { yields += 1 }
        let arguments = try XCTUnwrap(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
        XCTAssertEqual(yields, 1)
        XCTAssertEqual(arguments.numberOfItems, 2)
        XCTAssertEqual(arguments.atIndex(1)?.atIndex(1)?.stringValue, source.path)
        XCTAssertEqual(arguments.atIndex(2)?.booleanValue, true)
    }

    @MainActor
    func testBackgroundRemovalDoesNotStealFocusFromAnotherApp() throws {
        let event = SystemTrashService.prepareEvent([url("Root Owned.app")], isApplicationActive: false) {
            XCTFail("Do not yield another app's foreground session")
        }
        let arguments = try XCTUnwrap(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
        XCTAssertEqual(arguments.atIndex(2)?.booleanValue, false)
    }

    @MainActor
    func testFinderScriptActivatesBeforeDeleteAndDoesNotActivateOnCompletion() throws {
        let source = SystemTrashService.finderScript
        let activate = try XCTUnwrap(source.range(of: "if shouldActivateFinder then activate"))
        let deletion = try XCTUnwrap(source.range(of: "delete targets"))
        XCTAssertLessThan(activate.upperBound, deletion.lowerBound)
        XCTAssertFalse(source[deletion.upperBound...].contains("activate"))
        let script = try XCTUnwrap(NSAppleScript(source: source))
        var error: NSDictionary?
        // Compile only: do not activate Finder or trigger authentication in the unit suite.
        XCTAssertTrue(script.compileAndReturnError(&error), "\(String(describing: error))")
    }

    func testFinderReplyTracksOnlySubmittedFilesAndRejectsMalformedResponse() {
        let first = url("Moved.app"), second = url("Keep.app")
        let reply = NSAppleEventDescriptor.list()
        reply.insert(NSAppleEventDescriptor(boolean: true), at: 1)
        reply.insert(NSAppleEventDescriptor(int32: -128), at: 2)
        reply.insert(NSAppleEventDescriptor(string: "User cancelled"), at: 3)
        let decoded = SystemTrashService.decode(reply, requested: [first, second])
        XCTAssertEqual(decoded.submitted, [first, second])
        XCTAssertEqual(decoded.error?.code, -128)
        XCTAssertTrue(SystemTrashService.decode(nil, requested: [first]).submitted.isEmpty)
        XCTAssertNotNil(SystemTrashService.decode(nil, requested: [first]).error)
        reply.insert(NSAppleEventDescriptor(string: "not an acknowledgement"), at: 1)
        XCTAssertNotNil(SystemTrashService.decode(reply, requested: [first]).error)
    }

    @MainActor
    func testRealAppleScriptBooleanEncodingIsAcceptedWithoutFinderAccess() throws {
        // AppleScript encodes literal true as typeTrue, not the typeBoolean initializer used by mocks.
        let script = try XCTUnwrap(NSAppleScript(source: "return {true, 0, \"\"}"))
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        XCTAssertNil(error)
        let source = url("Move.app")
        let reply = SystemTrashService.decode(descriptor, requested: [source])
        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.submitted, [source])
    }

    @MainActor
    func testActualSystemErrorIsReportedWithoutGuessingFullDiskAccess() async {
        let source = url("Keep.app")
        let error = NSError(domain: NSCocoaErrorDomain, code: 513,
                            userInfo: [NSLocalizedDescriptionKey: "Fixture operation was denied"])
        let result = await SystemTrashService.trash([source], recycle: { _ in .init(error: error) }, presence: { _ in .present })
        XCTAssertEqual(result.failed, [source])
        XCTAssertFalse(result.isCancelled)
        XCTAssertTrue(result.message?.contains("Fixture operation was denied") == true)
        XCTAssertTrue(result.message?.contains("NSCocoaErrorDomain 513") == true)
        XCTAssertFalse(result.message?.contains("Full Disk Access") == true)
        XCTAssertFalse(result.message?.contains("background service") == true)
    }

    @MainActor
    func testOnlyFailedItemsEnterSystemFallback() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wonderbox-fallback-\(UUID().uuidString)")
        let first = folder.appendingPathComponent("Normal.app"), second = folder.appendingPathComponent("Protected.cache")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: second)
        defer { try? FileManager.default.removeItem(at: folder) }
        let application = InstalledApplication(url: first, name: "Normal", bundleIdentifier: "fixture.normal", version: nil,
                                               size: 0, installedAt: nil, lastUsedAt: nil)
        let related = RelatedFile(url: second, displayPath: second.path, size: 5, isSelected: true)
        let firstStage = ApplicationScanner.uninstall(application: application, relatedFiles: [related], home: folder) { item in
            if item == second { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: item, to: folder.appendingPathComponent("moved"))
        }
        XCTAssertEqual(firstStage.trashed, 1)
        XCTAssertEqual(firstStage.failed, [second])
        let result = await SystemTrashService.trash(firstStage.failed, recycle: { items in
            XCTAssertEqual(items, [second])
            let destination = folder.appendingPathComponent("moved-cache")
            do {
                try FileManager.default.moveItem(at: second, to: destination)
                return .init(submitted: [second])
            } catch {
                XCTFail("Fixture move failed: \(error)")
                return .init(error: error as NSError)
            }
        })
        XCTAssertEqual(result.moved, 1)
        XCTAssertTrue(result.failed.isEmpty)
    }

    @MainActor
    func testDismissClearsRemainingItemsAndObsoletePermissionActions() {
        let model = AppModel()
        let items = [url("Keep.app")]
        model.presentUninstallResult(message: "System operation failed", isError: true, needsFinderPermission: false, remainingItems: items)
        XCTAssertEqual(model.uninstallRemainingItems, items)
        XCTAssertFalse(model.uninstallNeedsFinderPermission)
        model.dismissOperationMessage()
        XCTAssertTrue(model.uninstallRemainingItems.isEmpty)
        XCTAssertNil(model.operationMessage)
    }

    func testUninstallDoesNotInstallOrRequestTheRootDaemonForTrash() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = try String(contentsOf: root.appendingPathComponent("Sources/WonderBox/Core/AppModel.swift"), encoding: .utf8)
        XCTAssertFalse(model.contains("PrivilegedService.trash("))
        XCTAssertTrue(model.contains("SystemTrashService.trash(outcome.failed)"))
        let view = try String(contentsOf: root.appendingPathComponent("Sources/WonderBox/Views/ApplicationsView.swift"), encoding: .utf8)
        XCTAssertFalse(view.contains("Button(\"Details…\")"))
        XCTAssertFalse(view.contains("Button(\"Show Background Service…\")"))
    }

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/fixture/Applications").appendingPathComponent(name) }
}
