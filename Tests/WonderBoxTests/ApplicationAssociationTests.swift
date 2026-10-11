import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import WonderBox

final class ApplicationAssociationTests: XCTestCase {
    /// The same discovery engine is exercised with unrelated identifiers, renamed/localized
    /// products, punctuation and non-Latin names. There are no per-product runtime rules.
    func testCrossProductStorageLayoutMatrix() throws {
        let products = [("Orchid Notes", "Orchid Notes", "net.fixture.notes"),
                        ("浏览工具", "BrowserKit", "org.fixture.browser"),
                        ("Studio-Edit", "Studio-Edit", "io.fixture.editor"),
                        ("Renamed Launcher", "Original Launcher", "dev.fixture.launcher"),
                        ("音频 助手", "SoundDesk", "net.fixture.sound"),
                        ("Nebula Player", "Nebula Player", "org.fixture.player")]
        for (index, product) in products.enumerated() {
            let (name, original, identifier) = product
            let home = try fixture()
            var app = application(home, name, identifier)
            app.relatedNames = [original]
            let group = "TEAM\(index).shared.documents"
            let component = "org.component\(index).helper"
            app.relatedIdentity = .init(componentIdentifiers: [component], applicationGroups: [group])
            let host = "D7E37D9D-8274-4FA7-91AF-7630EDD12345"
            let standard = try ["Library/" + original,
                                "Library/Application Support/" + identifier,
                                "Library/Caches/" + identifier,
                                "Library/Preferences/" + identifier + ".plist",
                                "Library/Preferences/ByHost/" + original + "_" + host + ".plist",
                                "Library/Logs/" + original + ".log.2",
                                "Library/Saved Application State/" + identifier + ".savedState"].map { try entry(home, $0) }
            let shared = try entry(home, "Library/Group Containers/" + group)
            let scripts = try entry(home, "Library/Application Scripts/" + group)
            let groupPrefs = try entry(home, "Library/Preferences/" + group + ".plist")
            let groupHostPrefs = try entry(home, "Library/Preferences/ByHost/" + group + "." + host + ".plist")
            let helper = try entry(home, "Library/Containers/" + component)
            let vendorLeaf = try entry(home, "Library/Application Support/Fixture Vendor/" + original)
            let systemVendorLeaf = try entry(home, "SystemLibrary/Application Support/Fixture Vendor/" + identifier)
            let unrelated = try ["Library/" + original + " Pro", "Library/Caches/" + identifier + "store",
                                 "Library/Group Containers/" + group + " Pro",
                                 "Library/Preferences/" + group + ".other.plist",
                                 "Library/Application Support/Fixture Vendor/Other App",
                                 "Library/Logs/" + original + ".log.backup"].map { try entry(home, $0) }
            let scan = scan(app, home)
            let found = Set(scan.files.map(\.url))
            XCTAssertEqual(found, Set(standard + [shared, scripts, groupPrefs, groupHostPrefs, helper, vendorLeaf, systemVendorLeaf]), name)
            XCTAssertTrue(found.isDisjoint(with: unrelated), name)
            XCTAssertFalse(found.contains(vendorLeaf.deletingLastPathComponent()), name)
            XCTAssertEqual(RelatedFileCategory.category(for: vendorLeaf), .support)
            XCTAssertEqual(RelatedFileCategory.category(for: helper), .containers)
            XCTAssertEqual(RelatedFileCategory.category(for: shared), .containers)
            for file in scan.files {
                XCTAssertEqual(file.isSelected, standard.contains(file.url), "\(name): \(file.displayPath)")
                XCTAssertEqual(file.association.requiresReview, !file.isSelected)
                if !file.isSelected { XCTAssertNotNil(file.association.detail) }
            }
            XCTAssertNil(scan.accessMessage)
        }
    }

    func testEmbeddedBundlesProvideIdentifiersNotArbitraryResourceNames() throws {
        let home = try fixture()
        let app = try bundle(home, "Applications/Localized Name.app", "net.fixture.main")
        let locations = ["Contents/Helpers/Runner.app", "Contents/XPCServices/Worker.xpc", "Contents/PlugIns/Share.appex",
                         "Contents/Library/LoginItems/Login.app", "Contents/Frameworks/Renderer.app", "Contents/Library/SystemExtensions/System.systemextension"]
        for (index, path) in locations.enumerated() { _ = try bundle(app, path, "org.other.helper\(index)") }
        _ = try bundle(app, "Contents/Resources/Unrelated.app", "org.unrelated.resource")
        let identity = ApplicationIdentityScanner.inspect(app, entitlements: { url in
            url.pathExtension == "appex" ? ["com.apple.security.application-groups": ["TEAM.shared.extension"]] : [:]
        })
        XCTAssertEqual(Set(identity.componentIdentifiers), Set((0..<locations.count).map { "org.other.helper\($0)" }))
        XCTAssertEqual(identity.applicationGroups, ["TEAM.shared.extension"])
        XCTAssertTrue(identity.isComplete)
    }

    func testNestedComponentsAreInspectedButSymlinkedComponentsAreNot() throws {
        let home = try fixture()
        let app = try bundle(home, "App.app", "net.fixture.main")
        let helper = try bundle(app, "Contents/Helpers/Helper.app", "net.fixture.helper")
        _ = try bundle(helper, "Contents/XPCServices/Nested.xpc", "org.fixture.nested")
        let outside = try bundle(home, "Outside.app", "org.fixture.outside")
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Contents/Helpers/Alias.app"), withDestinationURL: outside)
        let identity = ApplicationIdentityScanner.inspect(app, entitlements: { _ in [:] })
        XCTAssertEqual(Set(identity.componentIdentifiers), ["net.fixture.helper", "org.fixture.nested"])
    }

    func testComponentBudgetIsReportedAsIncomplete() throws {
        let home = try fixture()
        let app = try bundle(home, "App.app", "net.fixture.main")
        _ = try bundle(app, "Contents/Helpers/Helper.app", "net.fixture.helper")
        let identity = ApplicationIdentityScanner.inspect(app, maximumBundles: 1, entitlements: { _ in [:] })
        XCTAssertFalse(identity.isComplete)
        let scan = RelatedFileScan(files: [], inaccessibleLocations: [], identity: identity)
        XCTAssertNotNil(scan.accessMessage)
    }

    func testSignedEntitlementsUseTheSignatureNotLoosePlistsAndRejectDamagedCode() throws {
        let home = try fixture()
        let app = try bundle(home, "Signed.app", "net.fixture.signed", extra: ["CFBundleExecutable": "Fixture"])
        let executable = app.appendingPathComponent("Contents/MacOS/Fixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let entitlements = home.appendingPathComponent("Fixture.entitlements")
        try plist(["com.apple.security.application-groups": ["TEAM.shared.fixture"]], entitlements)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--entitlements", entitlements.path, app.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(ApplicationIdentityScanner.inspect(app).applicationGroups, ["TEAM.shared.fixture"])
        // A loose entitlements file is not evidence and does not override the code signature.
        try plist(["com.apple.security.application-groups": ["TEAM.not.in.signature"]], entitlements)
        XCTAssertEqual(ApplicationIdentityScanner.inspect(app).applicationGroups, ["TEAM.shared.fixture"])
        try Data("damaged executable".utf8).write(to: executable)
        XCTAssertTrue(ApplicationIdentityScanner.signedEntitlements(app).isEmpty)
    }

    func testUUIDGroupOwnerCanDifferCompletelyFromMainBundleIdentifier() throws {
        let home = try fixture()
        var app = application(home, "Main", "net.fixture.main")
        app.relatedIdentity = .init(applicationGroups: ["TEAM.shared.database"])
        let group = try entry(home, "Library/Group Containers/0AD4A345-352E-45E0-BD04-EA894C807A0E")
        try plist(["MCMMetadataIdentifier": "TEAM.shared.database"], group.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        let other = try entry(home, "Library/Group Containers/OTHER")
        try plist(["MCMMetadataIdentifier": "TEAM.shared.database.other"], other.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        let scan = scan(app, home)
        XCTAssertEqual(scan.files.map(\.url), [group])
        XCTAssertEqual(scan.files.first?.association, .applicationGroup)
        XCTAssertEqual(scan.files.first?.isSelected, false)
    }

    func testMainIdentifierGroupMatchAlsoRequiresReview() throws {
        let home = try fixture()
        let app = application(home, "Main", "net.fixture.main")
        _ = try entry(home, "Library/Group Containers/TEAM.net.fixture.main")
        let file = try XCTUnwrap(scan(app, home).files.first)
        XCTAssertEqual(file.association, .applicationGroup)
        XCTAssertFalse(file.isSelected)
    }

    func testStartupItemsFollowLiteralProgramPathsNotLabelsOrUnrelatedArguments() throws {
        let home = try fixture()
        let app = application(home, "Main", "net.fixture.main")
        let executable = app.url.appendingPathComponent("Contents/MacOS/Main").path
        let owned = home.appendingPathComponent("Library/LaunchAgents/unrelated.label.plist")
        let ownedDaemon = home.appendingPathComponent("SystemLibrary/LaunchDaemons/another.label.plist")
        try plist(["ProgramArguments": [executable, "--background"]], owned)
        try plist(["Program": executable], ownedDaemon)
        try plist(["ProgramArguments": ["/bin/sh", executable]], home.appendingPathComponent("Library/LaunchAgents/shell.plist"))
        try plist(["ProgramArguments": [app.url.path + "store/Contents/MacOS/Main"]], home.appendingPathComponent("Library/LaunchAgents/similar.plist"))
        try plist(["Program": "/usr/bin/true", "ProgramArguments": [executable]], home.appendingPathComponent("Library/LaunchAgents/program-wins.plist"))
        try plist(["ProgramArguments": [app.url.path + "/../Other.app/Contents/MacOS/Other"]], home.appendingPathComponent("Library/LaunchAgents/traversal.plist"))
        let scan = scan(app, home)
        XCTAssertEqual(Set(scan.files.map(\.url)), Set([owned, ownedDaemon]))
        XCTAssertTrue(scan.files.allSatisfy { $0.association == .launchItem && $0.isSelected })
    }

    func testDeclaredPrivilegedHelperUsesExactIdentityWithoutSelectingSiblingTools() throws {
        let home = try fixture()
        let appURL = try bundle(home, "Main.app", "net.fixture.main", extra: ["SMPrivilegedExecutables": ["org.fixture.shared.helper": "identifier org.fixture.shared.helper"]])
        var app = application(home, "Main", "net.fixture.main")
        app.relatedIdentity = ApplicationIdentityScanner.inspect(appURL, entitlements: { _ in [:] })
        let helper = try entry(home, "SystemLibrary/PrivilegedHelperTools/org.fixture.shared.helper")
        let daemon = try entry(home, "SystemLibrary/LaunchDaemons/org.fixture.shared.helper.plist")
        _ = try entry(home, "SystemLibrary/PrivilegedHelperTools/org.fixture.shared.helper.other")
        let scan = scan(app, home)
        XCTAssertEqual(Set(scan.files.map(\.url)), Set([helper, daemon]))
        XCTAssertTrue(scan.files.allSatisfy { $0.association == .declaredHelper && !$0.isSelected })
    }

    func testSignatureAndComponentIdentifiersCannotEscapeLibraryRoots() throws {
        let home = try fixture()
        var app = application(home, "Main", "net.fixture.main")
        app.relatedIdentity = .init(componentIdentifiers: ["../../keep", ".secret", "com..bad", "A/B"],
                                    applicationGroups: ["../../keep", "Group Containers", ".hidden", "TEAM.shared\0bad"],
                                    declaredHelperIdentifiers: ["../keep"])
        let outside = try entry(home, "keep")
        let scan = scan(app, home)
        XCTAssertTrue(scan.files.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testSymlinkedVendorAndByHostParentsAreNotFollowed() throws {
        let home = try fixture()
        let app = application(home, "Main", "net.fixture.main")
        let outside = try entry(home, "outside")
        _ = try entry(outside, "Main")
        _ = try entry(outside, "Main_D7E37D9D-8274-4FA7-91AF-7630EDD12345.plist")
        let support = try entry(home, "Library/Application Support")
        let preferences = try entry(home, "Library/Preferences")
        try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("Vendor"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: preferences.appendingPathComponent("ByHost"), withDestinationURL: outside)
        XCTAssertTrue(scan(app, home).files.isEmpty)
    }

    func testUnreadableUnrelatedVendorDoesNotCreateAnAppPermissionError() throws {
        let home = try fixture()
        let app = application(home, "Main", "net.fixture.main")
        let known = try entry(home, "Library/Application Support/Main")
        let unrelated = try entry(home, "Library/Application Support/Unrelated Vendor")
        let scan = RelatedFileScanner.scan(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [], list: { url in
            if url.standardizedFileURL == unrelated { throw CocoaError(.fileReadNoPermission) }
            return try RelatedFileScanner.children(url)
        })
        XCTAssertEqual(scan.files.map(\.url), [known])
        XCTAssertNil(scan.accessMessage)
    }

    func testSharedDataIsDiscoveredForBothAppsCountedOnceAndNotRemovedByDefault() throws {
        let home = try fixture()
        var first = application(home, "One", "net.fixture.one"), second = application(home, "Two", "net.fixture.two")
        for app in [first, second] { _ = try bundle(home, "Applications/\(app.name).app", app.bundleIdentifier!) }
        let shared = try entry(home, "Library/Group Containers/TEAM.shared.database")
        try Data(repeating: 5, count: 32_768).write(to: shared.appendingPathComponent("database"))
        first.relatedIdentity = .init(applicationGroups: ["TEAM.shared.database"])
        second.relatedIdentity = first.relatedIdentity
        let files = scan(first, home).files
        first.storageUsage = ApplicationStorageUsage(files: files, isComplete: true)
        second.storageUsage = ApplicationStorageUsage(files: scan(second, home).files, isComplete: true)
        XCTAssertEqual(first.storageUsage?.relatedSize, second.storageUsage?.relatedSize)
        XCTAssertEqual(ApplicationStorageUsage.combinedSize([first, second]), first.size + second.size + first.storageUsage!.relatedSize)
        let outcome = ApplicationScanner.uninstall(application: first, relatedFiles: files, home: home) { url in
            XCTAssertEqual(url, first.url)
            try FileManager.default.removeItem(at: url) // disposable fixture only
        }
        XCTAssertEqual(outcome.trashed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.appendingPathComponent("database").path))
    }

    @MainActor
    func testForegroundScanRetainsEvidenceForVerificationAfterBundleRemoval() async throws {
        let home = try fixture()
        let app = application(home, "Main", "net.fixture.main")
        let identity = ApplicationRelatedIdentity(componentIdentifiers: ["org.fixture.helper"], applicationGroups: ["TEAM.shared.database"])
        let model = AppModel(applications: [app], relatedFileLoader: { _ in RelatedFileScan(files: [], inaccessibleLocations: [], identity: identity) })
        await model.selectApplication(app)
        XCTAssertEqual(model.selectedApplication?.relatedIdentity, identity)
        XCTAssertEqual(model.applications.first?.relatedIdentity, identity)
    }

    func testBackgroundScanUsesSameEvidenceAndPreservesIt() async throws {
        let home = try fixture()
        var app = application(home, "Main", "net.fixture.main")
        app.relatedIdentity = .init(applicationGroups: ["TEAM.shared.database"])
        _ = try entry(home, "Library/Group Containers/TEAM.shared.database")
        let expected = scan(app, home)
        var updates: [ApplicationStorageUpdate] = []
        for await update in ApplicationStorageScanner.updates([app], scan: { app in
            RelatedFileScanner.scan(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [])
        }) { updates.append(update) }
        XCTAssertEqual(updates.first?.usage.files, expected.files)
        XCTAssertEqual(updates.first?.identity, app.relatedIdentity)
        XCTAssertEqual(updates.first?.usage.relatedSize, expected.files.reduce(0) { $0 + $1.size })
    }

    @MainActor
    func testReviewLabelsFitTheCompactUninstallerWithoutResizingTheWindow() async throws {
        let home = try fixture()
        var app = application(home, "多组件应用", "net.fixture.main")
        _ = try bundle(home, "Applications/多组件应用.app", "net.fixture.main")
        let group = try entry(home, "Library/Group Containers/TEAM.shared.database")
        let vendor = try entry(home, "Library/Application Support/Fixture Vendor/多组件应用")
        let helper = try entry(home, "Library/Containers/org.fixture.helper")
        let files = [(group, RelatedFileAssociation.applicationGroup), (vendor, .vendorSubfolder), (helper, .embeddedComponent)].map { url, association in
            RelatedFile(url: url, displayPath: url.path.replacingOccurrences(of: home.path, with: "~"), size: 5_000_000,
                        isSelected: false, association: association)
        }
        app.storageUsage = ApplicationStorageUsage(files: files, isComplete: true)
        let model = AppModel(applications: [app], relatedFileLoader: { _ in RelatedFileScan(files: files, inaccessibleLocations: []) })
        await model.selectApplication(app)
        let host = NSHostingView(rootView: ApplicationsView().environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 610), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; host.frame = window.contentView!.bounds; host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.height, 610)
        XCTAssertLessThanOrEqual(host.fittingSize.width, 760)
        XCTAssertTrue(model.relatedFiles.allSatisfy { !$0.isSelected && $0.association.detail != nil })
        if ProcessInfo.processInfo.environment["WONDERBOX_RENDER_PREVIEWS"] == "1" {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/wonderbox-association-review-preview.png"))
        }
        window.contentView = nil
    }

    private func fixture() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("wonderbox-association-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }
    private func application(_ home: URL, _ name: String, _ id: String) -> InstalledApplication {
        .init(url: home.appendingPathComponent("Applications/" + name + ".app"), name: name, bundleIdentifier: id,
              version: nil, size: 100, installedAt: nil, lastUsedAt: nil)
    }
    private func entry(_ root: URL, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        if ["plist", "log", "2"].contains(url.pathExtension) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 8_192).write(to: url)
        } else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return URL(fileURLWithPath: url.path).standardizedFileURL
    }
    private func plist(_ values: [String: Any], _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url)
    }
    private func bundle(_ root: URL, _ path: String, _ id: String, extra: [String: Any] = [:]) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        try plist(["CFBundleIdentifier": id, "CFBundlePackageType": "APPL", "CFBundleName": "Fixture"].merging(extra) { _, new in new }, url.appendingPathComponent("Contents/Info.plist"))
        return url
    }
    private func scan(_ app: InstalledApplication, _ home: URL) -> RelatedFileScan {
        RelatedFileScanner.scan(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [])
    }
}
