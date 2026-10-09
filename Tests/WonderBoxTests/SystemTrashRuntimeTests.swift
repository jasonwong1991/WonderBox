import AppKit
import Darwin
import Foundation
import XCTest
@testable import WonderBox

/// Explicit opt-in: this test invokes macOS's real Trash UI and may request administrator access.
/// scripts/test_system_trash.sh creates only disposable, uniquely named bundles for this test.
final class SystemTrashRuntimeTests: XCTestCase {
    @MainActor
    func testRootOwnedBundlesThroughRealSystemTrash() async throws {
        guard let path = ProcessInfo.processInfo.environment["WONDERBOX_TRASH_FIXTURE"] else {
            throw XCTSkip("Requires an explicitly authorized root-owned runtime fixture")
        }
        let fixture = URL(fileURLWithPath: path).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(fixture.deletingLastPathComponent(), home.appendingPathComponent("Applications"))
        guard fixture.deletingLastPathComponent() == home.appendingPathComponent("Applications"),
              fixture.lastPathComponent.hasPrefix("WonderBox-Trash-Tests-"),
              UUID(uuidString: String(fixture.lastPathComponent.dropFirst("WonderBox-Trash-Tests-".count))) != nil,
              try String(contentsOf: fixture.appendingPathComponent("fixture-marker"), encoding: .utf8) == "WonderBox disposable Trash fixture\n"
        else { return XCTFail("Refusing an unrecognized runtime fixture") }

        let parent = fixture.appendingPathComponent("Chrome Apps.localized")
        let sources = ["测试文档.app", "Test Drive.app"].map { parent.appendingPathComponent($0) }
        var destinationsBefore = Set(try FileManager.default.contentsOfDirectory(at: home.appendingPathComponent(".Trash"), includingPropertiesForKeys: nil))
        // This set is only used to find our marker-bearing fixture destinations, never to delete data.
        destinationsBefore.formUnion(sources)
        for source in sources {
            var info = stat()
            XCTAssertEqual(lstat(source.path, &info), 0)
            guard info.st_uid == 0, info.st_mode & S_IFMT == S_IFDIR else { return XCTFail("Fixture must be a root-owned directory") }
            XCTAssertEqual(info.st_mode & 0o777, 0o755)
            XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("Contents/fixture-data"), encoding: .utf8), "WonderBox disposable Trash fixture\n")
        }

        // Prove the original API really fails for these permissions before exercising the new path.
        var failures: [URL] = []
        for source in sources {
            do {
                var destination: NSURL?
                try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
                print("Original FileManager API moved fixture: \(source.lastPathComponent)")
            } catch {
                failures.append(source)
                let nsError = error as NSError
                print("Original FileManager failure: \(nsError.domain) \(nsError.code), underlying=\(String(describing: nsError.userInfo[NSUnderlyingErrorKey]))")
            }
        }
        XCTAssertEqual(failures.count, sources.count, "Fixture must reproduce the reported FileManager permission failure")
        guard !failures.isEmpty else { return }
        let result = await SystemTrashService.trash(failures)
        print("Real system Trash result: moved=\(result.moved), remaining=\(result.failed.count), cancelled=\(result.isCancelled), error=\(String(describing: result.error))")
        XCTAssertEqual(result.moved, failures.count)
        XCTAssertTrue(result.failed.isEmpty)
        for source in sources { XCTAssertEqual(FilePresence.check(source), .missing) }

        let destinations = try FileManager.default.contentsOfDirectory(at: home.appendingPathComponent(".Trash"), includingPropertiesForKeys: nil)
            .filter { !destinationsBefore.contains($0) && $0.pathExtension == "app" }
            .filter { (try? String(contentsOf: $0.appendingPathComponent("Contents/fixture-data"), encoding: .utf8)) == "WonderBox disposable Trash fixture\n" }
        XCTAssertEqual(destinations.count, sources.count, "The exact dummy payloads must remain recoverable in Trash")
        print("Recoverable test bundles in Trash: \(destinations.map(\.lastPathComponent))")
    }
}
