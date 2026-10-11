import Foundation
import XCTest
@testable import WonderBox

final class RelatedFileCoverageTests: XCTestCase {
    func testAdditionalStorageConventionsAcrossDifferentProductIdentities() throws {
        for (name, id) in [("Orchid Notes", "net.fixture.notes"), ("多媒体工具", "org.fixture.media"), ("Studio-Edit", "io.fixture.studio")] {
            let home = try fixture()
            var app = application(home, name, id)
            app.relatedIdentity = .init(dataNames: ["runtime-name"])
            let autosaves = try [id, name].map { try directory(home, "Library/Autosave Information/" + $0) }
            let xdg = try RelatedFileLocations.xdgRoots.flatMap { root in
                try [id, name, "runtime-name"].map { try directory(home, root + "/" + $0) }
            }
            let recent = try RelatedFileLocations.recentDocumentExtensions.map {
                try file(home, "Library/" + RelatedFileLocations.recentDocuments + "/" + id.lowercased() + "." + $0)
            }
            let caches = try RelatedFileLocations.sharedCacheRoots.map { try directory(home, "Library/Caches/" + $0 + "/" + name) }
            let unrelated = try ["Library/Autosave Information/" + name + " Pro", ".config/" + id + "helper", ".cache/" + name + "-backup",
                                 "Library/" + RelatedFileLocations.recentDocuments + "/" + id + ".other.sfl3",
                                 "Documents/" + name, "Desktop/" + name, "Library/Mobile Documents/" + id,
                                 "Library/Caches/SentryCrash/Other Product"].map { try directory(home, $0) }
            let scan = scan(app, home)
            XCTAssertEqual(Set(scan.files.map(\.url)), Set(autosaves + xdg + recent + caches), name)
            XCTAssertTrue(Set(scan.files.map(\.url)).isDisjoint(with: unrelated))
            for item in scan.files {
                XCTAssertEqual(item.isSelected, recent.contains(item.url), item.displayPath)
                if autosaves.contains(item.url) {
                    XCTAssertEqual(item.association, .autosaveData)
                    XCTAssertEqual(RelatedFileCategory.category(for: item.url), .autosaves)
                } else if xdg.contains(item.url) { XCTAssertEqual(item.association, .crossPlatformData) }
                else if caches.contains(item.url) { XCTAssertEqual(item.association, .vendorSubfolder) }
            }
            XCTAssertNil(scan.accessMessage)
        }
    }

    func testRecentDocumentsAcceptOnlyExactPerApplicationMetadata() throws {
        let home = try fixture()
        var app = application(home, "Product", "net.fixture.Product")
        app.relatedIdentity = .init(componentIdentifiers: ["org.fixture.helper"])
        let own = try file(home, "Library/" + RelatedFileLocations.recentDocuments + "/net.fixture.product.sfl3")
        let helper = try file(home, "Library/" + RelatedFileLocations.recentDocuments + "/org.fixture.helper.sfl2")
        _ = try file(home, "Library/" + RelatedFileLocations.recentDocuments + "/net.fixture.product.sfl3.backup")
        _ = try file(home, "Library/" + RelatedFileLocations.recentDocuments + "/net.fixture.product.editor.sfl3")
        let scan = scan(app, home)
        XCTAssertEqual(Set(scan.files.map(\.url)), [own, helper])
        XCTAssertTrue(try XCTUnwrap(scan.files.first { $0.url == own }).isSelected)
        XCTAssertEqual(scan.files.first { $0.url == helper }?.association, .embeddedComponent)
        XCTAssertFalse(try XCTUnwrap(scan.files.first { $0.url == helper }).isSelected)
    }

    func testExternalPluginsRequireExactBundleOwnershipNotProductOrVendorNames() throws {
        let home = try fixture()
        var app = application(home, "Product", "net.fixture.main")
        app.relatedIdentity = .init(componentIdentifiers: ["org.fixture.preview"])
        let main = try bundle(home, "Library/Services/Unrelated Filename.service", "net.fixture.main")
        let quickLook = try bundle(home, "Library/QuickLook/Preview.qlgenerator", "org.fixture.preview")
        let audio = try bundle(home, "SystemLibrary/Audio/Plug-Ins/Components/Audio.component", "org.fixture.preview", flat: true)
        _ = try bundle(home, "Library/QuickLook/Product.qlgenerator", "net.fixture.main.other")
        _ = try bundle(home, "SystemLibrary/Spotlight/Product.mdimporter", "net.fixture.unrelated")
        let conflicting = try bundle(home, "Library/QuickLook/Conflicting.qlgenerator", "net.fixture.unrelated")
        try plist(["CFBundleIdentifier": "net.fixture.main"], conflicting.appendingPathComponent("Info.plist"))
        _ = try directory(home, "Library/PreferencePanes/Product.prefPane") // name without metadata is not evidence
        _ = try bundle(home, "SystemLibrary/Extensions/Driver.kext", "net.fixture.main")
        _ = try bundle(home, "SystemLibrary/Audio/Plug-Ins/HAL/Driver.driver", "net.fixture.main")
        let scan = scan(app, home)
        XCTAssertEqual(Set(scan.files.map(\.url)), [main, quickLook, audio])
        XCTAssertTrue(scan.files.allSatisfy { !$0.isSelected && $0.association == .externalPlugin })
        XCTAssertTrue(scan.files.allSatisfy { RelatedFileCategory.category(for: $0.url) == .plugins })
    }

    func testEmbeddedPluginIdentifiersProvideEvidenceForExternalCopies() throws {
        let home = try fixture()
        let appURL = try bundle(home, "Applications/Product.app", "net.fixture.main")
        for path in ["Contents/Library/QuickLook/Preview.qlgenerator", "Contents/Library/Spotlight/Index.mdimporter", "Contents/PlugIns/Audio.component"] {
            _ = try bundle(appURL, path, "org.fixture." + URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
        }
        let identity = ApplicationIdentityScanner.inspect(appURL, entitlements: { _ in [:] })
        XCTAssertEqual(Set(identity.componentIdentifiers), ["org.fixture.Preview", "org.fixture.Index", "org.fixture.Audio"])
        var app = application(home, "Product", "net.fixture.main")
        app.relatedIdentity = identity
        let external = try bundle(home, "Library/Spotlight/Index.mdimporter", "org.fixture.Index")
        XCTAssertEqual(scan(app, home).files.map(\.url), [external])
    }

    func testNewLocationsDoNotFollowSymlinksOrLinkedPluginMetadata() throws {
        let home = try fixture()
        let app = application(home, "Product", "net.fixture.main")
        let outside = try directory(home, "outside")
        let linkedRoot = try directory(home, ".local")
        try FileManager.default.createSymbolicLink(at: linkedRoot.appendingPathComponent("share"), withDestinationURL: outside)
        _ = try directory(outside, "Product")
        let cache = try directory(home, ".cache")
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("Product"), withDestinationURL: outside)
        let fakePlugin = try directory(home, "Library/QuickLook/Alias.qlgenerator/Contents")
        let info = try file(home, "external.plist")
        try plist(["CFBundleIdentifier": "net.fixture.main"], info)
        try FileManager.default.createSymbolicLink(at: fakePlugin.appendingPathComponent("Info.plist"), withDestinationURL: info)
        XCTAssertTrue(scan(app, home).files.isEmpty)
    }

    func testCommonSystemAndSDKRootsAreNeverAssociatedByProductName() throws {
        let home = try fixture()
        for name in ["QuickLook", "Spotlight", "Components", "Extensions", "ColorSync", "Widgets", "Autosave Information"] {
            _ = try directory(home, "Library/" + name)
            XCTAssertTrue(scan(application(home, name, "net.fixture." + name.replacingOccurrences(of: " ", with: "")), home).files.isEmpty, name)
        }
        for name in RelatedFileLocations.sharedCacheRoots {
            _ = try directory(home, "Library/Caches/" + name)
            XCTAssertTrue(scan(application(home, name, "net.fixture.main"), home).files.isEmpty, name)
        }
    }

    func testExtraDiscoveryDoesNotEnumerateApplicationDataOrInvokeSizing() throws {
        let home = try fixture()
        let app = application(home, "Product", "net.fixture.main")
        let xdg = try directory(home, ".local/share/Product")
        let autosave = try directory(home, "Library/Autosave Information/Product")
        let sdkRoot = try directory(home, "Library/Caches/SentryCrash")
        let sdkLeaf = try directory(sdkRoot, "Product")
        let scan = RelatedFileScanner.scan(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [], list: { url in
            XCTAssertFalse([xdg, autosave, sdkRoot, sdkLeaf].contains(url), "No app-data or SDK enumeration: \(url)")
            return try RelatedFileScanner.children(url)
        }, inspectContents: false, measure: ApplicationDataSize.shallow)
        XCTAssertEqual(Set(scan.files.map(\.url)), [xdg, autosave, sdkLeaf])
        XCTAssertTrue(scan.files.allSatisfy { !$0.hasMeasuredSize })
    }

    func testPluginInspectionLimitIsBoundedAndReportedAsIncomplete() throws {
        let home = try fixture()
        let app = application(home, "Product", "net.fixture.main")
        for index in 0..<10 { _ = try bundle(home, "Library/QuickLook/P\(index).qlgenerator", "org.other.preview\(index)") }
        var reads = 0
        let scan = RelatedFileScanner.scan(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [], bundleMetadata: { url in
            reads += 1
            return ApplicationIdentityScanner.metadata(url)
        }, maximumPluginInspections: 3)
        XCTAssertLessThanOrEqual(reads, 6) // at most two bounded Info.plist layouts per plugin
        XCTAssertFalse(scan.isDiscoveryComplete)
        XCTAssertNotNil(scan.accessMessage)
        XCTAssertTrue(scan.files.isEmpty)
    }

    func testPluginMetadataCacheInvalidatesWhenThePlistChangesOrRefreshClearsIt() throws {
        let home = try fixture()
        let plugin = try bundle(home, "Library/QuickLook/Preview.qlgenerator", "org.fixture.preview")
        let info = plugin.appendingPathComponent("Contents/Info.plist")
        let cache = RelatedFileScanCache()
        XCTAssertEqual(cache.metadata(info)?["CFBundleIdentifier"] as? String, "org.fixture.preview")
        try plist(["CFBundleIdentifier": "org.fixture.changed.identifier"], info)
        XCTAssertEqual(cache.metadata(info)?["CFBundleIdentifier"] as? String, "org.fixture.changed.identifier")
        cache.clear()
        try FileManager.default.removeItem(at: info)
        XCTAssertNil(cache.metadata(info))
    }

    func testUnreadableNewStorageLocationIsNotReportedAsAnEmptyCompleteScan() throws {
        let home = try fixture()
        let config = try directory(home, ".config")
        let scan = RelatedFileScanner.scan(for: application(home, "Product", "net.fixture.main"), home: home,
                                          systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [], list: { url in
            if url == config { throw CocoaError(.fileReadNoPermission) }
            return try RelatedFileScanner.children(url)
        })
        XCTAssertTrue(scan.inaccessibleLocations.contains(config))
        XCTAssertNotNil(scan.accessMessage)
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wonderbox-coverage-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func application(_ home: URL, _ name: String, _ id: String) -> InstalledApplication {
        .init(url: home.appendingPathComponent("Applications/" + name + ".app"), name: name, bundleIdentifier: id,
              version: nil, size: 100, installedAt: nil, lastUsedAt: nil)
    }
    private func directory(_ root: URL, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: url.path).standardizedFileURL
    }
    private func file(_ root: URL, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1024).write(to: url)
        return url
    }
    private func plist(_ values: [String: Any], _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url)
    }
    private func bundle(_ root: URL, _ path: String, _ id: String, flat: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        try plist(["CFBundleIdentifier": id], url.appendingPathComponent(flat ? "Info.plist" : "Contents/Info.plist"))
        return URL(fileURLWithPath: url.path).standardizedFileURL
    }
    private func scan(_ app: InstalledApplication, _ home: URL) -> RelatedFileScan {
        RelatedFileScanner.scan(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [],
                                inspectContents: false, measure: ApplicationDataSize.shallow)
    }
}
