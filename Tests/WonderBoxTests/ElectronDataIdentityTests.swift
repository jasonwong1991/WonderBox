import Darwin
import Foundation
import XCTest
@testable import WonderBox

final class ElectronDataIdentityTests: XCTestCase {
    func testRuntimeProductNameDoesNotNeedToMatchFinderOrBundleName() throws {
        let home = try fixture()
        let url = try bundle(home, name: "Renamed Studio")
        try asar(url, files: ["package.json": json(["name": "npm-studio", "productName": "Original Studio", "main": "main.js"]), "main.js": Data("console.log('boot');".utf8)])
        let identity = ApplicationIdentityScanner.inspect(url, entitlements: { _ in [:] })
        XCTAssertEqual(identity.dataNames, ["Original Studio"])
        XCTAssertTrue(identity.legacyDataNames.isEmpty)
        let owned = try directory(home, "Library/Application Support/Original Studio")
        let unrelated = try directory(home, "Library/Application Support/npm-studio")
        let scan = try scan(url, home: home, identity: identity)
        XCTAssertEqual(scan.files.map(\.url), [owned])
        XCTAssertTrue(scan.files[0].isSelected)
        XCTAssertFalse(scan.files.contains { $0.url == unrelated })
    }

    func testExplicitMigrationPathsWorkAcrossProductsWithoutNamePrefixDeletion() throws {
        for (name, old) in [("Orchid", "Orchid Legacy"), ("Quartz", "Quartz ZEN"), ("Atlas Studio", "Atlas Studio Classic"), ("银河绘图工具", "银河绘图工具 旧版")] {
            let home = try fixture()
            let url = try bundle(home, name: name)
            let source = "const c=app.getPath('userData');function migrate(e){const old=path.join(e,'..','\(old)','profiles');fs.renameSync(old,c)}migrate(c);const unrelatedLabel='\(name) Pro';"
            try asar(url, files: ["package.json": json(["name": "fixture", "productName": name, "main": "./main/bootstrap.cjs"]), "main/bootstrap.cjs": Data(source.utf8)])
            let identity = ApplicationIdentityScanner.inspect(url, entitlements: { _ in [:] })
            XCTAssertEqual(identity.legacyDataNames, [old])
            let legacy = try directory(home, "Library/Application Support/" + old)
            let otherEdition = try directory(home, "Library/Application Support/" + name + " Pro")
            let files = try scan(url, home: home, identity: identity).files
            XCTAssertEqual(files.map(\.url), [legacy])
            XCTAssertFalse(files[0].isSelected)
            XCTAssertEqual(files[0].association, .legacyData)
            XCTAssertNotNil(files[0].association.detail)
            XCTAssertFalse(files.contains { $0.url == otherEdition })
        }
    }

    func testDependencyPackagesSourceMapsAndAssetsAreNotOwnershipEvidence() throws {
        let home = try fixture(), url = try bundle(home, name: "Orchid")
        let fakeMigration = "const c=app.getPath('userData');const p=path.join(c,'..','Orchid Other');fs.renameSync(p,c)"
        try asar(url, files: ["package.json": json(["productName": "Orchid", "main": "main.js"]), "main.js": Data("const unrelated='Orchid Pro';".utf8),
                             "node_modules/dependency/package.json": json(["productName": "Keep Other App"]),
                             "static/example.js": Data(fakeMigration.utf8), "main.js.map": Data(fakeMigration.utf8)])
        let identity = ElectronDataIdentityScanner.inspect(url, productNames: ["Orchid"])
        XCTAssertEqual(identity.names, ["Orchid"])
        XCTAssertTrue(identity.legacyNames.isEmpty)
    }

    func testStringSimilarityAloneOrNonMigrationPathsDoNotAssociateSiblingApps() {
        let samples = ["const x='Orchid ZEN';", "const c=app.getPath('userData');path.join(c,'..','Orchid Pro');",
                       "fs.renameSync(path.join(folder,'..','Orchid Pro'),target);",
                       "const c=app.getPath('userData');fs.renameSync(path.join(c,'..','Other App'),c);",
                       "const c=app.getPath('userData');fs.renameSync(path.join(c,'..','Orchidish Pro'),c);",
                       "const c=app.getPath('userData');fs.renameSync(path.join(c,'..','../Documents'),c);",
                       "const c=app.getPath('userData');fs.renameSync(path.join(c,'..','Orchid/Secret'),c);",
                       "const c=app.getPath('userData');fs.renameSync(path.join(c,'..','Orchid\\Secret'),c);"]
        for source in samples { XCTAssertTrue(ElectronDataIdentityScanner.legacyNames(in: source, productNames: ["Orchid"]).isEmpty, source) }
    }

    func testLoosePackagesAndUnpackedAsarMetadataRemainBounded() throws {
        let home = try fixture(), url = try bundle(home, name: "Orchid")
        let resources = url.appendingPathComponent("Contents/Resources")
        try write(json(["name": "orchid-runtime", "main": "./bootstrap.js"]), resources.appendingPathComponent("app/package.json"))
        try write(Data("const c=app.getPath('userData');fs.renameSync(path.join(c,'..','Orchid Classic'),c);".utf8), resources.appendingPathComponent("app/bootstrap.js"))
        XCTAssertEqual(ElectronDataIdentityScanner.inspect(url, productNames: ["Orchid"]).names, ["orchid-runtime"])
        XCTAssertEqual(ElectronDataIdentityScanner.inspect(url, productNames: ["Orchid"]).legacyNames, ["Orchid Classic"])
        // app.asar is the loaded package when both packed and loose versions are present.
        let pkg = try json(["productName": "Orchid Packed", "main": "main.js"])
        try asar(url, files: ["main.js": Data("console.log('packed');".utf8)], extra: ["package.json": ["size": pkg.count, "unpacked": true]])
        try write(pkg, resources.appendingPathComponent("app.asar.unpacked/package.json"))
        XCTAssertEqual(ElectronDataIdentityScanner.inspect(url, productNames: ["Orchid"]).names, ["Orchid Packed"])
    }

    func testGenericNpmModuleNamesAndNonElectronResourcesAreNotAliases() throws {
        let home = try fixture(), url = try bundle(home, name: "Orchid")
        for name in ["app", "electron", "main", "../../Documents", "Keychains", " ", "foo\0bar"] {
            try asar(url, files: ["package.json": json(["name": name]), "index.js": Data()])
            XCTAssertTrue(ElectronDataIdentityScanner.inspect(url, productNames: ["Orchid"]).names.isEmpty, name)
        }
        try FileManager.default.removeItem(at: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"))
        try asar(url, files: ["package.json": json(["productName": "Keep Other App"]), "index.js": Data()])
        XCTAssertTrue(ElectronDataIdentityScanner.inspect(url, productNames: ["Orchid"]).names.isEmpty)
    }

    func testOnlyDeclaredSafeMainEntriesAreReadAndOversizedSourcesAreSkipped() throws {
        let home = try fixture(), url = try bundle(home, name: "Orchid")
        let source = Data("const c=app.getPath('userData');fs.renameSync(path.join(c,'..','Orchid Legacy'),c);".utf8)
        for main in ["../outside.js", "/outside.js", "main/../main.js", "main\\outside.js"] {
            try asar(url, files: ["package.json": json(["productName": "Orchid", "main": main]), "main.js": source])
            XCTAssertTrue(ElectronDataIdentityScanner.inspect(url, productNames: ["Orchid"]).legacyNames.isEmpty)
        }
        var big = source
        big.append(Data(repeating: 32, count: ElectronDataIdentityScanner.maximumSourceBytes))
        try asar(url, files: ["package.json": json(["productName": "Orchid", "main": "main.js"]), "main.js": big])
        let identity = ElectronDataIdentityScanner.inspect(url, productNames: ["Orchid"])
        XCTAssertTrue(identity.legacyNames.isEmpty)
        XCTAssertLessThan(identity.bytesRead, ElectronDataIdentityScanner.maximumSourceBytes)
    }

    func testMalformedOffsetsLinksAndOversizedHeadersAreIgnored() throws {
        let home = try fixture(), url = try bundle(home, name: "Orchid")
        for entry: [String: Any] in [["size": 128, "offset": "18446744073709551615"], ["size": 128, "offset": "-1"],
                                    ["size": -1, "offset": "0"], ["size": 3.5, "offset": "0"], ["size": true, "offset": "0"],
                                    ["size": 1_000_000, "offset": "0"], ["size": 10, "offset": "0", "link": "../outside.json"]] {
            try asar(url, files: [:], extra: ["package.json": entry])
            XCTAssertTrue(ElectronDataIdentityScanner.inspect(url, productNames: ["Orchid"]).names.isEmpty)
        }
        var bad = word(4); bad.append(word(UInt32(ElectronDataIdentityScanner.maximumHeaderBytes + 1)))
        try write(bad, url.appendingPathComponent("Contents/Resources/app.asar"))
        XCTAssertTrue(ElectronDataIdentityScanner.inspect(url, productNames: ["Orchid"]).names.isEmpty)
    }

    func testSymlinkedArchivesUnpackedFilesAndResourceParentsAreNotFollowed() throws {
        let home = try fixture(), url = try bundle(home, name: "Orchid")
        let outside = home.appendingPathComponent("outside.json")
        let pkg = try json(["productName": "Keep Other App"])
        try write(pkg, outside)
        try asar(url, files: [:], extra: ["package.json": ["size": pkg.count, "unpacked": true]])
        let unpacked = try directory(url, "Contents/Resources/app.asar.unpacked")
        try FileManager.default.createSymbolicLink(at: unpacked.appendingPathComponent("package.json"), withDestinationURL: outside)
        XCTAssertTrue(ElectronDataIdentityScanner.inspect(url, productNames: ["Orchid"]).names.isEmpty)
        try FileManager.default.removeItem(at: url.appendingPathComponent("Contents/Resources/app.asar"))
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("Contents/Resources/app.asar"), withDestinationURL: outside)
        XCTAssertTrue(ElectronDataIdentityScanner.inspect(url, productNames: ["Orchid"]).names.isEmpty)
        try FileManager.default.removeItem(at: url.appendingPathComponent("Contents/Resources"))
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("Contents/Resources"), withDestinationURL: home)
        XCTAssertTrue(ElectronDataIdentityScanner.inspect(url, productNames: ["Orchid"]).names.isEmpty)
    }

    func testLargeArchiveIsNotUnpackedOrReadInFull() throws {
        let home = try fixture(), url = try bundle(home, name: "Orchid")
        try asar(url, files: ["package.json": json(["productName": "Orchid", "main": "main.js"]), "main.js": Data()])
        let archive = url.appendingPathComponent("Contents/Resources/app.asar")
        let fd = open(archive.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, off_t(8 * 1_024 * 1_024 * 1_024)), 0); close(fd)
        let result = ElectronDataIdentityScanner.inspect(url, productNames: ["Orchid"])
        XCTAssertEqual(result.names, ["Orchid"])
        XCTAssertLessThan(result.bytesRead, 4_096)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path + ".unpacked"))
    }

    func testEvidenceSurvivesBundleRemovalAndLegacyDataIsNotTrashedWithoutSelection() throws {
        let home = try fixture(), url = try bundle(home, name: "Orchid")
        try asar(url, files: ["package.json": json(["productName": "Orchid", "main": "main.js"]),
                             "main.js": Data("const c=app.getPath('userData');fs.renameSync(path.join(c,'..','Orchid ZEN'),c);".utf8)])
        let identity = ApplicationIdentityScanner.inspect(url, entitlements: { _ in [:] })
        let legacy = try directory(home, "Library/Application Support/Orchid ZEN")
        let application = try installed(url, identity)
        let files = try scan(url, home: home, identity: identity).files
        var moved: [URL] = []
        let outcome = ApplicationScanner.uninstall(application: application, relatedFiles: files, home: home) { source in
            moved.append(source)
            try FileManager.default.removeItem(at: source) // disposable fixture only
        }
        XCTAssertEqual(outcome.trashed, 1)
        XCTAssertEqual(moved, [url])
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        let remaining = RelatedFileScanner.scan(for: application, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [], inspectContents: false, measure: ApplicationDataSize.shallow)
        XCTAssertEqual(remaining.files.map(\.url), [legacy])
        XCTAssertEqual(remaining.files.first?.association, .legacyData)
    }

    func testReadOnlyXMindScreenshotReproductionAndMetadataCost() throws {
        guard ProcessInfo.processInfo.environment["WONDERBOX_ELECTRON_SMOKE"] == "1" else { throw XCTSkip("Opt-in read-only XMind sample") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".Trash/XMind.app")
        guard FilePresence.check(url) == .present else { throw XCTSkip("Local XMind sample is absent") }
        let started = ProcessInfo.processInfo.systemUptime
        let evidence = ElectronDataIdentityScanner.inspect(url, productNames: ["XMind"])
        XCTAssertEqual(evidence.names, ["XMind"])
        XCTAssertTrue(evidence.legacyNames.contains("XMind ZEN"))
        XCTAssertLessThan(evidence.bytesRead, 4 * 1_024 * 1_024)
        let parseTime = ProcessInfo.processInfo.systemUptime - started
        let cache = RelatedFileScanCache()
        let app = try XCTUnwrap(ApplicationScanner.application(from: url))
        let scan = ApplicationScanner.relatedFileScan(for: app, cache: cache, mode: .discovery)
        let expected = home.appendingPathComponent("Library/Application Support/XMind ZEN")
        let legacy = try XCTUnwrap(scan.files.first { $0.url.path == expected.path })
        XCTAssertEqual(legacy.association, .legacyData)
        XCTAssertFalse(legacy.isSelected)
        XCTAssertTrue(scan.identity?.legacyDataNames.contains("XMind ZEN") == true)
        print("Read-only XMind: screenshot directory found; metadata \(evidence.bytesRead) bytes / \(Int(parseTime * 1000)) ms; no files changed")
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wonderbox-electron-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func directory(_ root: URL, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: url.path).standardizedFileURL
    }
    private func write(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    private func json(_ values: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) }
    private func word(_ value: UInt32) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    private func bundle(_ home: URL, name: String) throws -> URL {
        let url = home.appendingPathComponent("Applications/" + name + ".app")
        _ = try directory(url, "Contents/Frameworks/Electron Framework.framework")
        try write(PropertyListSerialization.data(fromPropertyList: ["CFBundleName": name, "CFBundleIdentifier": "net.fixture.product", "CFBundlePackageType": "APPL"], format: .xml, options: 0), url.appendingPathComponent("Contents/Info.plist"))
        return URL(fileURLWithPath: url.path).standardizedFileURL
    }
    private func installed(_ url: URL, _ identity: ApplicationRelatedIdentity) throws -> InstalledApplication {
        let name = try XCTUnwrap(ApplicationIdentityScanner.metadata(url.appendingPathComponent("Contents/Info.plist"))?["CFBundleName"] as? String)
        return .init(url: url, name: name, bundleIdentifier: "net.fixture.product", version: nil, size: 100, installedAt: nil, lastUsedAt: nil, relatedIdentity: identity)
    }
    private func scan(_ url: URL, home: URL, identity: ApplicationRelatedIdentity) throws -> RelatedFileScan {
        let app = try installed(url, identity)
        return RelatedFileScanner.scan(for: app, home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"), temporaryDirectories: [], inspectContents: false, measure: ApplicationDataSize.shallow)
    }
    private func asar(_ url: URL, files: [String: Data], extra: [String: [String: Any]] = [:]) throws {
        var payload = Data(), nodes: [String: Any] = [:]
        func insert(_ path: ArraySlice<String>, node: [String: Any], into tree: inout [String: Any]) {
            guard let first = path.first else { return }
            if path.count == 1 { tree[first] = node; return }
            var folder = (tree[first] as? [String: Any])?["files"] as? [String: Any] ?? [:]
            insert(path.dropFirst(), node: node, into: &folder)
            tree[first] = ["files": folder]
        }
        for key in files.keys.sorted() {
            let data = files[key]!
            insert(Array(key.split(separator: "/").map(String.init))[...], node: ["size": data.count, "offset": String(payload.count)], into: &nodes)
            payload.append(data)
        }
        for (key, node) in extra { insert(Array(key.split(separator: "/").map(String.init))[...], node: node, into: &nodes) }
        let headerJSON = try json(["files": nodes])
        let padding = (4 - headerJSON.count % 4) % 4
        var header = word(UInt32(4 + headerJSON.count + padding))
        header.append(word(UInt32(headerJSON.count))); header.append(headerJSON); header.append(Data(repeating: 0, count: padding))
        var archive = word(4); archive.append(word(UInt32(header.count))); archive.append(header); archive.append(payload)
        try write(archive, url.appendingPathComponent("Contents/Resources/app.asar"))
    }
}
