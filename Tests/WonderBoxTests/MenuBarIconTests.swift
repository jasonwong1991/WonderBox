import AppKit
import SwiftUI
import XCTest
@testable import WonderBox

final class MenuBarIconTests: XCTestCase {
    func testBothStylesAreAvailableWithOriginalColorAsDefault() {
        XCTAssertEqual(MenuBarIconStyle.allCases, [.color, .monochrome])
        XCTAssertEqual(MenuBarIconStyle.defaultStyle, .color)
        for style in MenuBarIconStyle.allCases {
            XCTAssertEqual(MenuBarIconStyle(rawValue: style.rawValue), style)
            XCTAssertFalse(style.title.isEmpty)
        }
    }

    @MainActor
    func testFreshPreferenceKeepsOriginalColorIcon() throws {
        try withDefaults { defaults in
            let storage = AppStorage(wrappedValue: MenuBarIconStyle.defaultStyle, MenuBarIconStyle.storageKey, store: defaults)
            XCTAssertEqual(storage.wrappedValue, .color)
        }
    }

    @MainActor
    func testBothChoicesPersistAcrossNewBindings() throws {
        try withDefaults { defaults in
            let settings = AppStorage(wrappedValue: MenuBarIconStyle.defaultStyle, MenuBarIconStyle.storageKey, store: defaults)
            for style in [MenuBarIconStyle.monochrome, .color] {
                settings.wrappedValue = style
                XCTAssertEqual(defaults.string(forKey: MenuBarIconStyle.storageKey), style.rawValue)
                let relaunchedApp = AppStorage(wrappedValue: MenuBarIconStyle.defaultStyle, MenuBarIconStyle.storageKey, store: defaults)
                XCTAssertEqual(relaunchedApp.wrappedValue, style)
            }
        }
    }

    @MainActor
    func testUnknownPreferenceFallsBackToOriginalColor() throws {
        try withDefaults { defaults in
            defaults.set("unknown-style", forKey: MenuBarIconStyle.storageKey)
            let storage = AppStorage(wrappedValue: MenuBarIconStyle.defaultStyle, MenuBarIconStyle.storageKey, store: defaults)
            XCTAssertEqual(storage.wrappedValue, .color)
        }
    }

    @MainActor
    func testHidingMenuBarDoesNotResetIconChoice() throws {
        try withDefaults { defaults in
            let storage = AppStorage(wrappedValue: MenuBarIconStyle.defaultStyle, MenuBarIconStyle.storageKey, store: defaults)
            storage.wrappedValue = .monochrome
            for enabled in [false, true] {
                defaults.set(enabled, forKey: "showMenuBar")
                let restored = AppStorage(wrappedValue: MenuBarIconStyle.defaultStyle, MenuBarIconStyle.storageKey, store: defaults)
                XCTAssertEqual(restored.wrappedValue, .monochrome)
            }
        }
    }

    @MainActor
    func testOnlyMonochromeIsTemplateAndBothImagesAreCachedAtTheSameSize() {
        let color = MenuBarAppIcon.image(for: .color)
        let monochrome = MenuBarAppIcon.image(for: .monochrome)
        XCTAssertFalse(color.isTemplate)
        XCTAssertTrue(monochrome.isTemplate)
        XCTAssertEqual(color.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(monochrome.size, color.size)
        XCTAssertTrue(color === MenuBarAppIcon.image(for: .color))
        XCTAssertTrue(monochrome === MenuBarAppIcon.image(for: .monochrome))
        XCTAssertFalse(color === monochrome)
    }

    @MainActor
    func testSettingsPickerChangesPreferenceImmediately() throws {
        try withDefaults { defaults in
            let host = NSHostingView(rootView: SettingsView()
                .environmentObject(AppModel())
                .defaultAppStorage(defaults)
                .preferredColorScheme(.light))
            let size = NSSize(width: 820, height: 1_000)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            defer { window.contentView = nil }
            settle(host)

            let picker = try XCTUnwrap(descendants(host).compactMap { $0 as? NSSegmentedControl }.first {
                $0.segmentCount == 2 && $0.label(forSegment: 0) == MenuBarIconStyle.color.title
                    && $0.label(forSegment: 1) == MenuBarIconStyle.monochrome.title
            })
            XCTAssertEqual(picker.selectedSegment, 0)
            for (index, style) in [(1, MenuBarIconStyle.monochrome), (0, .color)] {
                picker.selectedSegment = index
                XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
                settle(host)
                XCTAssertEqual(defaults.string(forKey: MenuBarIconStyle.storageKey), style.rawValue)
            }
            if ProcessInfo.processInfo.environment["WONDERBOX_RENDER_PREVIEWS"] == "1" {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: "/tmp/wonderbox-menu-icon-settings.png"))
            }
        }
    }

    @MainActor
    func testMonochromeHasTransparentTileCutoutsWhileColorKeepsColoredTiles() throws {
        let color = try bitmap(for: .color)
        let monochrome = try bitmap(for: .monochrome)
        XCTAssertEqual(color.pixelsWide, monochrome.pixelsWide)
        XCTAssertEqual(color.pixelsHigh, monochrome.pixelsHigh)
        var colorfulPixels = 0
        var cutoutPixels = 0
        var solidMonochromePixels = 0
        for y in 0..<color.pixelsHigh {
            for x in 0..<color.pixelsWide {
                let coloredPixel = try XCTUnwrap(color.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let monoPixel = try XCTUnwrap(monochrome.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if coloredPixel.alphaComponent > 0.9 {
                    let channels = [coloredPixel.redComponent, coloredPixel.greenComponent, coloredPixel.blueComponent]
                    if channels.max()! - channels.min()! > 0.2 { colorfulPixels += 1 }
                    if monoPixel.alphaComponent < 0.1 { cutoutPixels += 1 }
                }
                if monoPixel.alphaComponent > 0.9 {
                    solidMonochromePixels += 1
                    XCTAssertLessThan(monoPixel.redComponent, 0.01)
                    XCTAssertLessThan(monoPixel.greenComponent, 0.01)
                    XCTAssertLessThan(monoPixel.blueComponent, 0.01)
                }
            }
        }
        XCTAssertGreaterThan(colorfulPixels, 0)
        XCTAssertGreaterThan(cutoutPixels, 0)
        XCTAssertGreaterThan(solidMonochromePixels, 0)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "WonderBoxTests.MenuBarIcon.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @MainActor
    private func bitmap(for style: MenuBarIconStyle) throws -> NSBitmapImageRep {
        let data = try XCTUnwrap(MenuBarAppIcon.image(for: style).tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: data))
    }

    @MainActor
    private func settle(_ view: NSView) {
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
            view.layoutSubtreeIfNeeded()
        }
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
