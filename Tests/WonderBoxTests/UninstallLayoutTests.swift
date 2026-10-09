import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import WonderBox

final class UninstallLayoutTests: XCTestCase {
    @MainActor
    func testFailureRetryDismissAndNavigationKeepWindowSize() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wonderbox-layout-\(UUID().uuidString)")
        let appURL = folder.appendingPathComponent("Google 文档.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = InstalledApplication(url: appURL, name: "Google 文档",
                                       bundleIdentifier: "com.google.Chrome.app.mpnpojknpmmopombnjdcgaaiekajbnjb",
                                       version: nil, size: 2_000_000, installedAt: nil, lastUsedAt: nil)
        for language in ["en", "zh-Hans"] {
            for size in [NSSize(width: 980, height: 660), NSSize(width: 1_180, height: 760)] {
                let model = AppModel(applications: [app])
                model.selection = .applications
                model.selectedApplication = app
                _ = model.shouldOfferFullDiskAccess(suppressed: true)
                // Exercise the full navigation + split-pane hierarchy, not only an isolated banner.
                // Neither order the test window front nor activate an app / change the user's language.
                let host = NSHostingView(rootView: RootView().environmentObject(model)
                    .environment(\.locale, Locale(identifier: language)).preferredColorScheme(.light)
                    .frame(minWidth: 980, minHeight: 660))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.contentView = host
                host.frame = window.contentView!.bounds
                settle(host)
                let baselineWindow = window.frame
                let baselineHost = host.frame
                let message = language == "en"
                    ? "Moved 0 items to the Trash · 1 selected items remain. · macOS did not move some items to the Trash: The operation was denied. (NSCocoaErrorDomain 513)"
                    : "已将 0 项移入废纸篓 · 仍有 1 个已选项目未移除。 · macOS 未能将部分项目移入废纸篓：操作被拒绝。(NSCocoaErrorDomain 513)"
                for repeatCount in [1, 20] {
                    model.presentUninstallResult(message: String(repeating: message, count: repeatCount), isError: true,
                                                 needsFinderPermission: repeatCount == 20, remainingItems: [appURL])
                    settle(host)
                    XCTAssertEqual(window.frame, baselineWindow, "Failure must not resize or move the window: \(language), \(size), \(repeatCount)")
                    XCTAssertEqual(host.frame, baselineHost)
                    XCTAssertLessThanOrEqual(host.fittingSize.height, baselineHost.height)
                    XCTAssertEqual(model.selectedApplication?.id, app.id)
                    XCTAssertFalse(model.isUninstallingApplication)
                    for split in descendants(host).compactMap({ $0 as? NSSplitView }) {
                        let rect = split.convert(split.bounds, to: host)
                        XCTAssertGreaterThanOrEqual(rect.minX, -1)
                        XCTAssertLessThanOrEqual(rect.maxX, host.bounds.maxX + 1, "Columns must fit in the window")
                        XCTAssertLessThanOrEqual(rect.height, host.bounds.height + 1)
                    }
                    if repeatCount == 1, ProcessInfo.processInfo.environment["WONDERBOX_RENDER_PREVIEWS"] == "1" {
                        try snapshot(host, name: "\(language)-\(Int(size.width))")
                    }
                }
                model.dismissOperationMessage()
                settle(host)
                XCTAssertNil(model.operationMessage)
                XCTAssertFalse(model.uninstallNeedsFinderPermission)
                XCTAssertTrue(model.uninstallRemainingItems.isEmpty)
                XCTAssertEqual(window.frame, baselineWindow)
                model.selection = .settings
                settle(host)
                model.selection = .applications
                settle(host)
                XCTAssertEqual(window.frame, baselineWindow)
                XCTAssertEqual(model.selectedApplication?.id, app.id)
                print("Uninstall layout \(language) \(Int(size.width))×\(Int(size.height)): failure, repeated failure, dismiss and navigation retain window frame")
                window.contentView = nil
            }
        }
    }

    @MainActor
    func testPrivacyGuidanceHasBoundedMinimumHeight() {
        let host = NSHostingView(rootView: FinderPermissionGuidance())
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 180)
        host.layoutSubtreeIfNeeded()
        print("Guidance minimum layout: \(host.fittingSize)")
        XCTAssertLessThanOrEqual(host.fittingSize.height, 180)
    }

    func testOversizedRestoredWindowFitsItsCurrentDisplay() {
        let visible = NSRect(x: -1_920, y: 24, width: 1_920, height: 1_056)
        let broken = NSRect(x: -1_600, y: -1_000, width: 1_180, height: 1_931)
        let repaired = MainWindowFrameRecovery.frame(broken, fitting: visible)
        XCTAssertTrue(visible.contains(repaired))
        XCTAssertEqual(repaired.width, broken.width)
        XCTAssertEqual(repaired.height, visible.height)
    }

    func testNormalWindowSizeAndPositionAreNotReset() {
        let visible = NSRect(x: 0, y: 24, width: 1_440, height: 856)
        let normal = NSRect(x: 48, y: 90, width: 1_180, height: 760)
        XCTAssertEqual(MainWindowFrameRecovery.frame(normal, fitting: visible), normal)
        XCTAssertEqual(MainWindowFrameRecovery.frame(normal, fitting: .zero), normal)
    }

    @MainActor
    private func settle(_ view: NSView) {
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.035))
            view.layoutSubtreeIfNeeded()
        }
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @MainActor
    private func snapshot(_ host: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/wonderbox-uninstall-layout-\(name).png"))
    }
}
