// Renders the ClipDesk app icon (1024×1024 PNG) with AppKit drawing.
// Usage: swift scripts/generate-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create drawing context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

// Coordinates below are in a top-left system for readability.
func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
    NSRect(x: x, y: size - y - height, width: width, height: height)
}

// Background tile following the macOS icon grid (824pt body, 100pt margins).
let tileRect = rect(100, 92, 824, 824)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 186, yRadius: 186)
NSGraphicsContext.saveGraphicsState()
let tileShadow = NSShadow()
tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
tileShadow.shadowBlurRadius = 28
tileShadow.shadowOffset = NSSize(width: 0, height: -12)
tileShadow.set()
color(0x2C7CF6).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [color(0x4C9BFF), color(0x1D66E5)])?.draw(in: tile, angle: -90)

// Soft top highlight.
NSGraphicsContext.saveGraphicsState()
tile.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])?
    .draw(in: rect(100, 92, 824, 420), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Clipboard board.
let board = NSBezierPath(roundedRect: rect(282, 252, 460, 568), xRadius: 64, yRadius: 64)
NSGraphicsContext.saveGraphicsState()
let boardShadow = NSShadow()
boardShadow.shadowColor = color(0x0B3B91, alpha: 0.35)
boardShadow.shadowBlurRadius = 30
boardShadow.shadowOffset = NSSize(width: 0, height: -14)
boardShadow.set()
NSColor.white.setFill()
board.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [NSColor.white, color(0xEEF3FB)])?.draw(in: board, angle: -90)

// Clip.
let clipOuter = NSBezierPath(roundedRect: rect(392, 198, 240, 112), xRadius: 40, yRadius: 40)
NSGraphicsContext.saveGraphicsState()
let clipShadow = NSShadow()
clipShadow.shadowColor = color(0x0B3B91, alpha: 0.3)
clipShadow.shadowBlurRadius = 12
clipShadow.shadowOffset = NSSize(width: 0, height: -5)
clipShadow.set()
color(0x1F4FA8).setFill()
clipOuter.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [color(0x335FB8), color(0x173F8C)])?.draw(in: clipOuter, angle: -90)
color(0xEEF3FB).setFill()
NSBezierPath(ovalIn: rect(488, 224, 48, 48)).fill()

// List rows: bullet + line, with the first row highlighted in the accent blue.
let rows: [(y: CGFloat, width: CGFloat, accent: Bool)] = [
    (382, 250, true), (472, 210, false), (562, 240, false), (652, 170, false),
]
for row in rows {
    let fill = row.accent ? color(0x2C7CF6) : color(0xB9CBE6)
    fill.setFill()
    NSBezierPath(ovalIn: rect(342, row.y, 36, 36)).fill()
    NSBezierPath(roundedRect: rect(404, row.y + 4, row.width, 28), xRadius: 14, yRadius: 14).fill()
}

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
