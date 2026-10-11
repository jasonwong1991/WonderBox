import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import WonderBox

final class RelatedFileSelectionTests: XCTestCase {
    func testEmptyAndAllSelectedListsDoNotWarn() {
        for files in [[], [file("cache", 10, selected: true), file("preferences", 20, selected: true)]] {
            let summary = RelatedFileSelectionSummary(files: files)
            XCTAssertNil(summary.warning)
            XCTAssertEqual(summary.omittedCount, 0)
            XCTAssertEqual(summary.confirmTitle, String(localized: "Move to Trash"))
            XCTAssertEqual(summary.cancelTitle, String(localized: "Cancel"))
            XCTAssertFalse(summary.confirmationMessage(removesBundle: true).contains("\n\n"))
        }
    }

    func testPartialSelectionShowsOnlyOmittedCountAndBytesWithoutChangingSelection() throws {
        let files = [file("cache", 80_000, selected: true), file("group", 4_000, selected: false), file("autosaves", 8_000, selected: false)]
        let original = files
        let summary = RelatedFileSelectionSummary(files: files)
        XCTAssertEqual(summary.omittedCount, 2)
        XCTAssertEqual(summary.omittedSize, 12_000)
        XCTAssertTrue(summary.isSizeComplete)
        XCTAssertEqual(summary.sizeText, AppFormatters.bytes(12_000))
        XCTAssertEqual(summary.confirmTitle, String(localized: "Move Selected Items to Trash"))
        XCTAssertEqual(summary.cancelTitle, String(localized: "Review Selection"))
        let message = summary.confirmationMessage(removesBundle: true)
        XCTAssertTrue(message.hasSuffix(try XCTUnwrap(summary.warning)))
        XCTAssertTrue(message.contains("\n\n"))
        XCTAssertEqual(files, original) // constructing/presenting/cancelling is read-only
        XCTAssertEqual(files.filter(\.isSelected).map(\.url), [original[0].url])
    }

    func testUnmeasuredItemsAreNotPresentedAsZeroBytes() {
        let files = [file("cache", 0, selected: false, complete: false, measured: false)]
        let summary = RelatedFileSelectionSummary(files: files)
        XCTAssertEqual(summary.omittedCount, 1)
        XCTAssertEqual(summary.sizeText, String(localized: "Not measured"))
        XCTAssertFalse(summary.hasMeasuredSize)
        XCTAssertFalse(summary.isSizeComplete)
        XCTAssertNotNil(summary.warning)
    }

    func testPartialSizesAreExplicitLowerBoundsIncludingUnknownItems() {
        let files = [file("large", 50_000, selected: false, complete: false), file("unknown", 0, selected: false, complete: false, measured: false)]
        let summary = RelatedFileSelectionSummary(files: files)
        XCTAssertEqual(summary.omittedSize, 50_000)
        XCTAssertEqual(summary.omittedCount, 2)
        XCTAssertEqual(summary.sizeText, "≥ " + AppFormatters.bytes(50_000))
        XCTAssertFalse(summary.isSizeComplete)
    }

    func testMeasuredEmptyFolderIsDifferentFromUnknownSize() {
        let summary = RelatedFileSelectionSummary(files: [file("empty", 0, selected: false)])
        XCTAssertEqual(summary.sizeText, AppFormatters.bytes(0))
        XCTAssertTrue(summary.hasMeasuredSize)
        XCTAssertTrue(summary.isSizeComplete)
    }

    func testTrashedApplicationConfirmationStillWarnsAboutKeptItems() throws {
        let summary = RelatedFileSelectionSummary(files: [file("preferences", 1024, selected: false)])
        let message = summary.confirmationMessage(removesBundle: false)
        XCTAssertTrue(message.hasPrefix(String(localized: "Only the selected related files will be moved to the Trash. The app already in the Trash will be kept.")))
        XCTAssertTrue(message.hasSuffix(try XCTUnwrap(summary.warning)))
    }

    func testNestedAndDuplicatePathsDoNotInflateWarning() {
        let root = file("data", 100, selected: false)
        let child = file("data/cache", 10, selected: false)
        let selectedRoot = file("selected", 300, selected: true)
        let selectedChild = file("selected/cache", 200, selected: false)
        let summary = RelatedFileSelectionSummary(files: [root, child, root, selectedRoot, selectedChild])
        XCTAssertEqual(summary.omittedCount, 1)
        XCTAssertEqual(summary.omittedSize, 100)
    }

    func testWarningSizeAdditionSaturates() {
        let summary = RelatedFileSelectionSummary(files: [file("a", .max, selected: false), file("b", 1, selected: false)])
        XCTAssertEqual(summary.omittedSize, .max)
    }

    func testPackagedChineseWarningAndConfirmationTranslations() throws {
        guard ProcessInfo.processInfo.environment["WONDERBOX_VERIFY_PACKAGE"] == "1" else { throw XCTSkip("Opt-in packaged localization verification") }
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/WonderBox.app/Contents/Resources")
        let bundle = try XCTUnwrap(Bundle(url: resources.appendingPathComponent("zh-Hans.lproj")))
        let key = "%lld related items are not selected (%@) and will be kept."
        let translated = bundle.localizedString(forKey: key, value: nil, table: nil)
        XCTAssertEqual(String(format: translated, 3, "≥ 1 GB"), "有 3 个关联项目未勾选（≥ 1 GB），将保留在原处。")
        XCTAssertEqual(bundle.localizedString(forKey: "Review Selection", value: nil, table: nil), "返回检查")
        XCTAssertEqual(bundle.localizedString(forKey: "Move Selected Items to Trash", value: nil, table: nil), "仅将已选项目移入废纸篓")
        XCTAssertEqual(bundle.localizedString(forKey: "%lld items will be kept", value: nil, table: nil), "将保留 %lld 个项目")
    }

    @MainActor
    func testKeptItemsWarningFitsBothLanguagesInCompactDetailAndPreservesSelection() async throws {
        let files = [file("cache", 50_000, selected: true), file("group", 8_000, selected: false), file("autosaves", 0, selected: false, complete: false, measured: false)]
        var app = InstalledApplication(url: URL(fileURLWithPath: "/fixture/Product.app"), name: "Fixture Product", bundleIdentifier: "net.fixture.main",
                                       version: nil, size: 50_000, installedAt: nil, lastUsedAt: nil)
        app.storageUsage = ApplicationStorageUsage(files: files, isComplete: false)
        for language in ["en", "zh-Hans"] {
            let model = AppModel(applications: [app],
                                 applicationStorageLoader: { apps in ApplicationStorageScanner.updates(apps, scan: { _ in RelatedFileScan(files: files, inaccessibleLocations: []) }) },
                                 relatedFileLoader: { _ in RelatedFileScan(files: files, inaccessibleLocations: []) },
                                 relatedSizeLoader: { files, _ in RelatedFileScan(files: files, inaccessibleLocations: []) })
            await model.selectApplication(app)
            let host = NSHostingView(rootView: ApplicationsView().environmentObject(model).environment(\.locale, Locale(identifier: language)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 610), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.frame = window.contentView!.bounds
            host.layoutSubtreeIfNeeded()
            let frame = window.frame
            let summary = RelatedFileSelectionSummary(files: model.relatedFiles)
            XCTAssertEqual(summary.omittedCount, 2)
            XCTAssertLessThanOrEqual(host.fittingSize.width, 760)
            XCTAssertLessThanOrEqual(host.fittingSize.height, 610)
            XCTAssertEqual(model.relatedFiles.map(\.isSelected), [true, false, false])
            if ProcessInfo.processInfo.environment["WONDERBOX_RENDER_PREVIEWS"] == "1" {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/wonderbox-kept-items-\(language).png"))
            }
            model.setAllRelatedFiles(true)
            host.layoutSubtreeIfNeeded()
            XCTAssertNil(RelatedFileSelectionSummary(files: model.relatedFiles).warning)
            XCTAssertEqual(window.frame, frame)
            window.contentView = nil
        }
    }

    private func file(_ path: String, _ size: UInt64, selected: Bool, complete: Bool = true, measured: Bool = true) -> RelatedFile {
        RelatedFile(url: URL(fileURLWithPath: "/fixture/" + path), displayPath: "~/" + path, size: size,
                    isSelected: selected, isSizeComplete: complete, hasMeasuredSize: measured)
    }
}
