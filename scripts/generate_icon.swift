import AppKit
import Foundation

let output = CommandLine.arguments.dropFirst().first ?? "build/AppIcon-1024.png"
let size = NSSize(width: 1024, height: 1024)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 1024,
    pixelsHigh: 1024,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Unable to allocate icon bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high

NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()

let base = NSBezierPath(roundedRect: NSRect(x: 54, y: 54, width: 916, height: 916), xRadius: 214, yRadius: 214)
NSColor(calibratedRed: 0.075, green: 0.105, blue: 0.125, alpha: 1).setFill()
base.fill()

let tiles: [(NSRect, NSColor)] = [
    (NSRect(x: 222, y: 526, width: 252, height: 252), NSColor(calibratedRed: 0.19, green: 0.47, blue: 0.96, alpha: 1)),
    (NSRect(x: 550, y: 526, width: 252, height: 252), NSColor(calibratedRed: 0.075, green: 0.65, blue: 0.55, alpha: 1)),
    (NSRect(x: 222, y: 198, width: 252, height: 252), NSColor(calibratedRed: 0.9, green: 0.37, blue: 0.4, alpha: 1)),
    (NSRect(x: 550, y: 198, width: 252, height: 252), NSColor(calibratedRed: 0.94, green: 0.63, blue: 0.2, alpha: 1))
]
for (rect, color) in tiles {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 60, yRadius: 60).fill()
}

NSColor.white.withAlphaComponent(0.94).setFill()
NSBezierPath(ovalIn: NSRect(x: 438, y: 438, width: 148, height: 148)).fill()
NSColor(calibratedRed: 0.075, green: 0.105, blue: 0.125, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 474, y: 474, width: 76, height: 76)).fill()

NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode icon")
}
let url = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
try data.write(to: url)
