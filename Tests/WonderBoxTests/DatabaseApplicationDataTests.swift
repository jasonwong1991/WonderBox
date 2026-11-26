import Foundation
import XCTest
@testable import WonderBox

final class DatabaseApplicationDataTests: XCTestCase {
    func testNavicatPremiumNestedDataIsDiscoveredWithoutSelectingSharedParents() throws {
        for id in ["com.navicat.NavicatPremium", "com.prect.NavicatPremium15", "com.prect.NavicatPremium16"] {
            let home = try fixture()
            let app = application(home, name: "Renamed Database Client", id: id)
            let product = try directory(home, "Library/Application Support/PremiumSoft CyberTech/Navicat CC/Navicat Premium")
            let profiles = try directory(product, "Profiles")
            let siblings = try ["Common", "Navicat for MySQL", "Navicat Premium Lite", "Navicat Premium Backup"].map {
                try directory(product.deletingLastPathComponent(), $0)
            }
            let scan = scan(app, home: home)
            XCTAssertEqual(scan.files.map(\.url), [product], id)
            XCTAssertTrue(Set(scan.files.map(\.url)).isDisjoint(with: siblings))
            XCTAssertFalse(scan.files.contains { $0.url == profiles || $0.url == product.deletingLastPathComponent() })
            XCTAssertEqual(scan.files.first?.association, .vendorSubfolder)
            XCTAssertEqual(scan.files.first?.isSelected, false)
        }
    }

    func testDataGripVersionedDirectoriesIncludeOldVersionsButNotOtherProductsOrLookalikes() throws {
        let home = try fixture()
        let app = application(home, name: "Renamed IDE", id: "com.jetbrains.datagrip")
        let roots = ["Application Support", "Caches", "Logs"]
        let expected = try roots.flatMap { root in
            try ["DataGrip", "DataGrip2024.3", "DataGrip2025.1", "DataGrip2026.3.1"].map {
                try directory(home, "Library/" + root + "/JetBrains/" + $0)
            }
        }
        let unrelated = try roots.flatMap { root in
            try ["IntelliJIdea2026.3", "PyCharm2026.3", "DataGripProjects", "DataGrip2026.3-backup", "DataGrip2026.3Other",
                 "DataGrip2026", "DataGrip20x6.3", "DataGrip2026.", "DataGrip2026.3.1.2"].map {
                try directory(home, "Library/" + root + "/JetBrains/" + $0)
            }
        }
        let documents = try directory(home, "DataGripProjects/project/.idea")
        let scan = scan(app, home: home)
        XCTAssertEqual(Set(scan.files.map(\.url)), Set(expected))
        XCTAssertTrue(Set(scan.files.map(\.url)).isDisjoint(with: unrelated + [documents]))
        XCTAssertTrue(scan.files.allSatisfy { $0.association == .vendorSubfolder && !$0.isSelected })
    }

    func testProductNamesAndSimilarBundleIdentifiersDoNotActivateDocumentedLayouts() throws {
        let home = try fixture()
        _ = try directory(home, "Library/Application Support/PremiumSoft CyberTech/Navicat CC/Navicat Premium")
        _ = try directory(home, "Library/Application Support/JetBrains/DataGrip2026.3")
        for id in ["org.fixture.database", "com.navicat.NavicatPremiumTools", "com.navicat.NavicatPremium15",
                   "com.prect.NavicatPremium", "com.prect.NavicatPremium15.helper", "com.jetbrains.datagrip.helper"] {
            let app = application(home, name: "Navicat Premium", id: id)
            XCTAssertTrue(scan(app, home: home).files.isEmpty, id)
        }
        XCTAssertTrue(scan(application(home, name: "DataGrip", id: "org.fixture.database"), home: home).files.isEmpty)
    }

    func testDocumentedLayoutsOnlyListTheirKnownParentAndNeverEnterProductData() throws {
        let home = try fixture()
        let navicat = try directory(home, "Library/Application Support/PremiumSoft CyberTech/Navicat CC/Navicat Premium")
        let datagrip = try directory(home, "Library/Application Support/JetBrains/DataGrip2026.3")
        let unrelated = try directory(home, "Library/Application Support/Unrelated Vendor")
        for (id, expected) in [("com.navicat.NavicatPremium", navicat), ("com.jetbrains.datagrip", datagrip)] {
            var listed: [URL] = []
            let scan = scan(application(home, name: "Client", id: id), home: home, list: { url in
                listed.append(url)
                XCTAssertFalse([navicat, datagrip, unrelated].contains(url), "Do not enumerate app data or unrelated vendors")
                return try RelatedFileScanner.children(url)
            })
            XCTAssertEqual(scan.files.map(\.url), [expected])
            XCTAssertTrue(listed.allSatisfy { url in listed.filter { $0 == url }.count == 1 }, "Reuse directory listings")
        }
    }

    func testLinkedLayoutParentsAndLeavesAreNotFollowed() throws {
        for linkedComponent in ["PremiumSoft CyberTech", "PremiumSoft CyberTech/Navicat CC", "PremiumSoft CyberTech/Navicat CC/Navicat Premium"] {
            let home = try fixture()
            let support = try directory(home, "Library/Application Support")
            let link = support.appendingPathComponent(linkedComponent)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            let outside = try directory(home, "outside")
            _ = try directory(outside, "Navicat CC/Navicat Premium")
            _ = try directory(outside, "Navicat Premium")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            XCTAssertTrue(scan(application(home, name: "Client", id: "com.navicat.NavicatPremium"), home: home).files.isEmpty)
        }
        let home = try fixture()
        let support = try directory(home, "Library/Application Support")
        let outside = try directory(home, "outside/DataGrip2026.3").deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("JetBrains"), withDestinationURL: outside)
        XCTAssertTrue(scan(application(home, name: "Client", id: "com.jetbrains.datagrip"), home: home).files.isEmpty)
    }

    func testUnreadableKnownParentReportsAnIncompleteScanWithoutInventingVersionDirectories() throws {
        let home = try fixture()
        let parent = try directory(home, "Library/Application Support/JetBrains")
        let scan = scan(application(home, name: "Client", id: "com.jetbrains.datagrip"), home: home, list: { url in
            if url == parent { throw CocoaError(.fileReadNoPermission) }
            return try RelatedFileScanner.children(url)
        })
        XCTAssertTrue(scan.files.isEmpty)
        XCTAssertTrue(scan.inaccessibleLocations.contains(parent))
        XCTAssertNotNil(scan.accessMessage)
    }

    func testOptInUninstallRemovesDetectedDataAndRetainsSiblingProducts() throws {
        let home = try fixture()
        let app = application(home, name: "DataGrip", id: "com.jetbrains.datagrip")
        _ = try directory(home, "Applications/DataGrip.app")
        let data = try directory(home, "Library/Application Support/JetBrains/DataGrip2026.3")
        let sibling = try directory(home, "Library/Application Support/JetBrains/PyCharm2026.3")
        var files = scan(app, home: home).files
        XCTAssertEqual(files.map(\.url), [data])
        for index in files.indices { files[index].isSelected = true }
        var removed: [URL] = []
        let outcome = ApplicationScanner.uninstall(application: app, relatedFiles: files, home: home) { url in
            // Check each deletion target against this disposable fixture's expected roots.
            XCTAssertTrue([app.url, data].contains(url))
            guard [app.url, data].contains(url) else { throw CocoaError(.fileWriteInvalidFileName) }
            removed.append(url)
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertEqual(Set(removed), [app.url, data])
        XCTAssertEqual(outcome.trashed, 2)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertEqual(FilePresence.check(data), .missing)
        XCTAssertEqual(FilePresence.check(sibling), .present)
        XCTAssertEqual(FilePresence.check(sibling.deletingLastPathComponent()), .present)
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wonderbox-database-data-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            guard url.deletingLastPathComponent() == FileManager.default.temporaryDirectory.standardizedFileURL,
                  url.lastPathComponent.hasPrefix("wonderbox-database-data-") else { return }
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func application(_ home: URL, name: String, id: String) -> InstalledApplication {
        .init(url: home.appendingPathComponent("Applications/" + name + ".app"), name: name, bundleIdentifier: id,
              version: nil, size: 0, installedAt: nil, lastUsedAt: nil)
    }

    private func directory(_ root: URL, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: url.path).standardizedFileURL
    }

    private func scan(_ app: InstalledApplication, home: URL,
                      list: (URL) throws -> [URL] = RelatedFileScanner.children) -> RelatedFileScan {
        RelatedFileScanner.scan(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [],
                                list: list, inspectContents: false, measure: ApplicationDataSize.shallow)
    }
}
