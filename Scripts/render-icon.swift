// Renders the ChargeGuard app icon (1024×1024 master + every macOS size) with CoreGraphics.
//   swift Scripts/render-icon.swift Resources/App/Assets.xcassets/AppIcon.appiconset
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon() {
    // macOS icon grid: 824 pt squircle centered in the 1024 canvas, with a soft drop shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x0F766E).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Background: emerald (top) to deep teal (bottom), plus a faint top sheen.
    NSGradient(colors: [color(0x34D399), color(0x10B981), color(0x0F766E)],
               atLocations: [0, 0.45, 1], colorSpace: .sRGB)!.draw(in: tilePath, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    NSGradient(colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)])!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Shield.
    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: 512, y: 805))
    shield.curve(to: NSPoint(x: 752, y: 725), controlPoint1: NSPoint(x: 600, y: 765), controlPoint2: NSPoint(x: 680, y: 735))
    shield.line(to: NSPoint(x: 752, y: 520))
    shield.curve(to: NSPoint(x: 512, y: 215), controlPoint1: NSPoint(x: 752, y: 365), controlPoint2: NSPoint(x: 640, y: 265))
    shield.curve(to: NSPoint(x: 272, y: 520), controlPoint1: NSPoint(x: 384, y: 265), controlPoint2: NSPoint(x: 272, y: 365))
    shield.line(to: NSPoint(x: 272, y: 725))
    shield.curve(to: NSPoint(x: 512, y: 805), controlPoint1: NSPoint(x: 344, y: 735), controlPoint2: NSPoint(x: 424, y: 765))
    shield.close()

    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0x064E3B, 0.45)
    glow.shadowBlurRadius = 24
    glow.shadowOffset = NSSize(width: 0, height: -10)
    glow.set()
    color(0xFFFFFF).setFill()
    shield.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0xFFFFFF), color(0xDDF7EC)])!.draw(in: shield, angle: -90)

    // Vertical battery inside the shield, charged to 80 %.
    let ink = color(0x0F766E)
    let stroke: CGFloat = 26
    let body = NSRect(x: 437, y: 325, width: 150, height: 300)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 34, yRadius: 34)
    bodyPath.lineWidth = stroke
    ink.setStroke()
    bodyPath.stroke()
    ink.setFill()
    NSBezierPath(roundedRect: NSRect(x: 482, y: 625 + stroke / 2 - 4, width: 60, height: 34), xRadius: 12, yRadius: 12).fill()

    let inner = body.insetBy(dx: stroke / 2 + 14, dy: stroke / 2 + 14)
    let level = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height * 0.8)
    NSGradient(colors: [color(0x6EE7B7), color(0x10B981)])!
        .draw(in: NSBezierPath(roundedRect: level, xRadius: 16, yRadius: 16), angle: -90)

    // Lightning bolt, dark teal so it reads on both the fill and the empty part.
    let bolt = NSBezierPath()
    bolt.move(to: NSPoint(x: 548, y: 592))
    bolt.line(to: NSPoint(x: 458, y: 462))
    bolt.line(to: NSPoint(x: 506, y: 462))
    bolt.line(to: NSPoint(x: 476, y: 352))
    bolt.line(to: NSPoint(x: 570, y: 494))
    bolt.line(to: NSPoint(x: 520, y: 494))
    bolt.close()
    bolt.lineJoinStyle = .round
    bolt.lineWidth = 14
    color(0xFFFFFF).setStroke()
    bolt.stroke()
    ink.setFill()
    bolt.fill()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(size: pixels).write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(outDir.path)")
