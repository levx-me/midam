// Draws the Midam app icon: one sheet of paper with an ink opening quotation mark (a story).
// macOS 26 grid: 1024 canvas, 824 rounded-square body, continuous corners.
// usage: swift tools/make-icon.swift <work-dir>   → <work-dir>/AppIcon.iconset, Resources/AppIcon.icns
import AppKit

let work = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
let iconset = work.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let paper = NSColor(srgbRed: 0xf8 / 255, green: 0xf6 / 255, blue: 0xf1 / 255, alpha: 1)
let edge = NSColor(srgbRed: 0xcf / 255, green: 0xcb / 255, blue: 0xc2 / 255, alpha: 1)
let ink = NSColor(srgbRed: 0x2b / 255, green: 0x2a / 255, blue: 0x27 / 255, alpha: 1)

func quoteMark(cx: CGFloat, cy: CGFloat, r: CGFloat) -> NSBezierPath {
    let p = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: cx - r, y: cy + r * 0.05))
    tail.curve(to: NSPoint(x: cx + r * 0.85, y: cy + r * 2.25), controlPoint1: NSPoint(x: cx - r * 1.05, y: cy + r * 1.35), controlPoint2: NSPoint(x: cx - r * 0.1, y: cy + r * 2.15))
    tail.curve(to: NSPoint(x: cx + r * 0.05, y: cy + r * 0.95), controlPoint1: NSPoint(x: cx + r * 0.25, y: cy + r * 1.85), controlPoint2: NSPoint(x: cx - r * 0.05, y: cy + r * 1.45))
    tail.close()
    p.append(tail)
    return p
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let onePixel = 1024 / CGFloat(px) // canvas units per output pixel
    let t = NSAffineTransform()
    t.scale(by: s)
    t.concat()

    // The sheet. A hairline edge (never thinner than one pixel) keeps it legible on a light Dock.
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    paper.setFill()
    body.fill()
    edge.setStroke()
    body.lineWidth = max(4, onePixel * 1.2)
    body.stroke()

    // An opening quotation mark, two brush marks: a heavy ball, a tail lifting to the upper right ("story").
    // At 16 px the marks grow and spread so they stay two marks; at 32 px the tails get a hairline.
    let tiny = px <= 16
    ink.setFill()
    ink.setStroke()
    for cx in tiny ? [CGFloat(364), 660] : [CGFloat(400), 624] {
        let q = quoteMark(cx: cx, cy: tiny ? 410 : 432, r: tiny ? 100 : 84)
        q.fill()
        if px < 64 && !tiny {
            q.lineWidth = onePixel * 0.6
            q.lineJoinStyle = .round
            q.stroke()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try! render(size * scale).write(to: iconset.appendingPathComponent(name))
    }
}

let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
