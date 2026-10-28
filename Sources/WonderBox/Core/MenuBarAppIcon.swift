import AppKit

enum MenuBarAppIcon {
    private static let colorImage = makeImage(style: .color)
    private static let monochromeImage = makeImage(style: .monochrome)

    static func image(for style: MenuBarIconStyle) -> NSImage {
        switch style {
        case .color: colorImage
        case .monochrome: monochromeImage
        }
    }

    private static func makeImage(style: MenuBarIconStyle) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }

            let background = NSColor(calibratedRed: 0.075, green: 0.105, blue: 0.125, alpha: 1)
            let tiles: [(NSRect, NSColor)] = [
                (NSRect(x: 3.5, y: 9.5, width: 5, height: 5), NSColor(calibratedRed: 0.19, green: 0.47, blue: 0.96, alpha: 1)),
                (NSRect(x: 9.5, y: 9.5, width: 5, height: 5), NSColor(calibratedRed: 0.075, green: 0.65, blue: 0.55, alpha: 1)),
                (NSRect(x: 3.5, y: 3.5, width: 5, height: 5), NSColor(calibratedRed: 0.9, green: 0.37, blue: 0.4, alpha: 1)),
                (NSRect(x: 9.5, y: 3.5, width: 5, height: 5), NSColor(calibratedRed: 0.94, green: 0.63, blue: 0.2, alpha: 1))
            ]

            (style == .monochrome ? NSColor.black : background).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 17, height: 17), xRadius: 4, yRadius: 4).fill()

            if style == .monochrome {
                // Cut transparent holes so macOS can tint the silhouette in either menu bar appearance.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
            }
            for (tile, color) in tiles {
                if style == .color { color.setFill() }
                NSBezierPath(roundedRect: tile, xRadius: 1.4, yRadius: 1.4).fill()
            }
            if style == .color { NSColor.white.withAlphaComponent(0.95).setFill() }
            NSBezierPath(ovalIn: NSRect(x: 7.25, y: 7.25, width: 3.5, height: 3.5)).fill()

            NSGraphicsContext.current?.compositingOperation = .sourceOver
            (style == .monochrome ? NSColor.black : background).setFill()
            NSBezierPath(ovalIn: NSRect(x: 8.25, y: 8.25, width: 1.5, height: 1.5)).fill()
            return true
        }
        image.isTemplate = style == .monochrome
        return image
    }
}
