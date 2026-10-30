import Foundation
import XCTest
@testable import WonderBox

final class InstallerArchiveTests: XCTestCase {
    func testArchiveRecognizesInstallerFilesAndBundleMetadata() {
        for entry in [
            "Setup.pkg", "Installer/Setup.PKG", "Setup.mpkg", "Images/Setup.DMG",
            "Demo.app/Contents/Info.plist", "Release/Demo.APP/Contents/Info.plist",
            "Legacy.pkg/Contents/Info.plist", "Legacy.mpkg/Contents/Info.plist"
        ] {
            XCTAssertTrue(StorageCleaner.archiveEntriesContainInstaller([entry]), entry)
        }
    }

    func testArchiveRejectsSuffixOnlyFilesAndDirectories() {
        for entry in [
            "project/service.app/src/main.swift", "docs/example.pkg/readme.txt",
            "docs/example.mpkg/readme.txt", "photos.dmg/holiday.jpg",
            "Demo.app/", "Setup.pkg/", "Setup.mpkg/", "Images.dmg/",
            "notes.app", "Demo.app/Contents/Resources/icon.png",
            "Demo.app/Info.plist", "Demo.app/Contents/Info.plist/",
            "photos/holiday.jpg", "notes.application"
        ] {
            XCTAssertFalse(StorageCleaner.archiveEntriesContainInstaller([entry]), entry)
        }
        XCTAssertFalse(StorageCleaner.archiveEntriesContainInstaller([String]()))
    }

    func testArchiveIgnoresFinderMetadataButKeepsRealInstallers() {
        let metadata = ["__MACOSX/._Setup.pkg", "__MACOSX/._Setup.dmg",
                        "__MACOSX/Demo.app/Contents/Info.plist", "._Setup.pkg"]
        XCTAssertFalse(StorageCleaner.archiveEntriesContainInstaller(metadata))
        XCTAssertTrue(StorageCleaner.archiveEntriesContainInstaller(metadata + ["Setup.pkg"]))
    }

    func testInstallerScanClassifiesRealZipArchives() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("wonderbox-installers-\(UUID())").standardizedFileURL
        defer { try? manager.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads with spaces 下载")
        try manager.createDirectory(at: downloads, withIntermediateDirectories: true)
        let oldDate = Date().addingTimeInterval(-10 * 24 * 60 * 60)

        func archive(_ name: String, entries: [String], date: Date? = nil) throws -> URL {
            let source = root.appendingPathComponent("source-\(UUID())")
            for entry in entries {
                let url = source.appendingPathComponent(entry)
                if entry.hasSuffix("/") {
                    try manager.createDirectory(at: url, withIntermediateDirectories: true)
                } else {
                    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("fixture".utf8).write(to: url)
                }
            }
            let url = downloads.appendingPathComponent(name)
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.arguments = ["-q", "-r", url.path, "."]
            zip.currentDirectoryURL = source
            zip.standardOutput = FileHandle.nullDevice
            zip.standardError = FileHandle.nullDevice
            try zip.run()
            zip.waitUntilExit()
            XCTAssertEqual(zip.terminationStatus, 0, name)
            try manager.setAttributes([.modificationDate: date ?? oldDate], ofItemAtPath: url.path)
            return url
        }

        let app = try archive("Application.ZIP", entries: ["Demo.app/Contents/Info.plist"])
        let package = try archive("Package.zip", entries: ["Installer/Setup.pkg"])
        let legacy = try archive("Legacy.zip", entries: ["Setup.mpkg/Contents/Info.plist"])
        let image = try archive("Disk image.zip", entries: ["Setup.dmg"])
        _ = try archive("Project.zip", entries: ["project/service.app/src/main.swift", "docs/example.pkg/readme.txt", "photos.dmg/holiday.jpg"])
        _ = try archive("Empty bundles.zip", entries: ["Demo.app/", "Setup.pkg/", "Images.dmg/"])
        _ = try archive("Metadata.zip", entries: ["__MACOSX/._Setup.pkg"])
        _ = try archive("Recent.zip", entries: ["Demo.app/Contents/Info.plist"], date: Date())
        let corrupt = downloads.appendingPathComponent("Corrupt.zip")
        try Data("not a zip archive".utf8).write(to: corrupt)
        try manager.setAttributes([.modificationDate: oldDate], ofItemAtPath: corrupt.path)

        XCTAssertEqual(Set(StorageCleaner.installerFiles(in: downloads)), Set([app, package, legacy, image]))
    }
}
