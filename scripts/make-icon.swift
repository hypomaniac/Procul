// Draws the app icon and writes Resources/AppIcon.icns.
// Run from the repo root: swift scripts/make-icon.swift
//
// The icon is drawn from scratch: a tilted remote with a ring and four
// buttons on a dark tile. It uses no system symbols.
import AppKit

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext

    // The standard macOS icon grid leaves a margin around the tile.
    let tile = NSRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: size * 0.18, yRadius: size * 0.18)
    NSGradient(
        starting: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.36, alpha: 1),
        ending: NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.13, alpha: 1))!.draw(in: tilePath, angle: -90)

    // Everything below is drawn in a frame centred on the tile and tilted.
    tilePath.addClip()
    context.translateBy(x: size / 2, y: size / 2)
    context.rotate(by: -.pi / 9)

    let width = size * 0.27
    let height = size * 0.62
    let body = NSRect(x: -width / 2, y: -height / 2, width: width, height: height)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: width * 0.3, yRadius: width * 0.3)
    NSGradient(
        starting: NSColor(calibratedWhite: 0.98, alpha: 1),
        ending: NSColor(calibratedWhite: 0.80, alpha: 1))!.draw(in: bodyPath, angle: -90)

    let ink = NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.20, alpha: 1)
    ink.setStroke()
    ink.setFill()

    // The ring.
    let ringRadius = width * 0.31
    let ringCentre = NSPoint(x: 0, y: height / 2 - width * 0.5)
    let ring = NSBezierPath(ovalIn: NSRect(
        x: ringCentre.x - ringRadius, y: ringCentre.y - ringRadius,
        width: ringRadius * 2, height: ringRadius * 2))
    ring.lineWidth = max(1, width * 0.10)
    ring.stroke()

    // Two rows of two buttons.
    let dot = width * 0.115
    for row in 0..<2 {
        for column in [-1.0, 1.0] {
            let centre = NSPoint(
                x: column * width * 0.2,
                y: ringCentre.y - ringRadius - width * 0.34 - CGFloat(row) * width * 0.38)
            NSBezierPath(ovalIn: NSRect(x: centre.x - dot, y: centre.y - dot, width: dot * 2, height: dot * 2)).fill()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = draw(CGFloat(points * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
