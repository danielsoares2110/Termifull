// tools/make-icon.swift — draws the GlassTerm app icon master (1024×1024 PNG).
// Run:  swift tools/make-icon.swift build/icon-1024.png
// build.sh feeds the result to sips + iconutil to produce Resources/AppIcon.icns.
import AppKit
import Foundation

let canvas: CGFloat = 1024
let bodyRect = NSRect(x: 62, y: 62, width: 900, height: 900)
let corner: CGFloat = 230

func srgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("make-icon: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func withClip(_ path: NSBezierPath, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

guard CommandLine.arguments.count >= 2 else {
    fail("usage: swift tools/make-icon.swift <out.png>")
}
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(canvas),
                                 pixelsHigh: Int(canvas),
                                 bitsPerSample: 8,
                                 samplesPerPixel: 4,
                                 hasAlpha: true,
                                 isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0,
                                 bitsPerPixel: 0) else {
    fail("could not allocate a \(Int(canvas))×\(Int(canvas)) bitmap")
}
rep.size = NSSize(width: canvas, height: canvas)

guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    fail("could not create a CoreGraphics-backed drawing context")
}
NSGraphicsContext.current = ctx
NSGraphicsContext.saveGraphicsState()

// Transparent canvas.
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: canvas, height: canvas).fill()

// Body: rounded square, vertical indigo → violet gradient.
let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: corner, yRadius: corner)
withClip(bodyPath) {
    let base = NSGradient(starting: srgb(0x1B1B2F), ending: srgb(0x5B4B8A))
    base?.draw(in: bodyRect, angle: 90)

    // Subtle white sheen across the top half, fading down into the violet.
    let sheenRect = NSRect(x: bodyRect.minX,
                           y: bodyRect.midY - 40,
                           width: bodyRect.width,
                           height: bodyRect.height / 2 + 40)
    let sheenPath = NSBezierPath(roundedRect: sheenRect, xRadius: 200, yRadius: 200)
    withClip(sheenPath) {
        let sheen = NSGradient(starting: NSColor(white: 1, alpha: 0.0),
                               ending: NSColor(white: 1, alpha: 0.16))
        sheen?.draw(in: sheenRect, angle: 90)
    }
}

// Frosted inner plate.
let innerRect = bodyRect.insetBy(dx: 112, dy: 112)
let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: 150, yRadius: 150)
NSColor(white: 1, alpha: 0.07).setFill()
innerPath.fill()
NSColor(white: 1, alpha: 0.20).setStroke()
innerPath.lineWidth = 3
innerPath.stroke()

// Glyph: bold white ">_" in a monospaced face, optically centred.
let fontSize: CGFloat = 420
let font = NSFont(name: "Menlo-Bold", size: fontSize)
    ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)

let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.38)
shadow.shadowBlurRadius = 26
shadow.shadowOffset = NSSize(width: 0, height: -10)

let glyph = NSAttributedString(string: ">_", attributes: [
    .font: font,
    .foregroundColor: NSColor(white: 1, alpha: 0.96),
    .shadow: shadow,
])
let glyphSize = glyph.size()
glyph.draw(at: NSPoint(x: (canvas - glyphSize.width) / 2,
                       y: (canvas - glyphSize.height) / 2 - 8))

ctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.current = nil

guard let png = rep.representation(using: .png, properties: [:]) else {
    fail("PNG encoding failed")
}
do {
    try png.write(to: outURL)
} catch {
    fail("could not write \(outURL.path): \(error)")
}

print("✅ icon → \(outURL.path) (\(png.count) bytes)")
