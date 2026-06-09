// Generates the DripWriter app icon master PNG (1024x1024).
// Usage: swiftc make-icon.swift -o /tmp/mkicon && /tmp/mkicon out.png
// Then sips to iconset sizes + iconutil -c icns (see build.sh).
import Cocoa

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}

func teardrop(cx: CGFloat, apexY: CGFloat, bottomY: CGFloat, radius R: CGFloat) -> NSBezierPath {
    let cy = bottomY - R
    let p = NSBezierPath()
    p.move(to: NSPoint(x: cx, y: apexY))
    p.curve(to: NSPoint(x: cx + R, y: cy),
            controlPoint1: NSPoint(x: cx + R*0.74, y: apexY + (cy-apexY)*0.14),
            controlPoint2: NSPoint(x: cx + R, y: cy - R*0.82))
    p.curve(to: NSPoint(x: cx, y: cy + R),
            controlPoint1: NSPoint(x: cx + R, y: cy + R*0.552),
            controlPoint2: NSPoint(x: cx + R*0.552, y: cy + R))
    p.curve(to: NSPoint(x: cx - R, y: cy),
            controlPoint1: NSPoint(x: cx - R*0.552, y: cy + R),
            controlPoint2: NSPoint(x: cx - R, y: cy + R*0.552))
    p.curve(to: NSPoint(x: cx, y: apexY),
            controlPoint1: NSPoint(x: cx - R, y: cy - R*0.82),
            controlPoint2: NSPoint(x: cx - R*0.74, y: apexY + (cy-apexY)*0.14))
    p.close()
    return p
}

func capsule(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: cx - w/2, y: cy - h/2, width: w, height: h), xRadius: h/2, yRadius: h/2)
}

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/dwicon_1024.png"

let img = NSImage(size: NSSize(width: S, height: S), flipped: true) { _ in
    let inset: CGFloat = 84
    let r = NSRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
    let bg = NSBezierPath(roundedRect: r, xRadius: 202, yRadius: 202)

    // background: bright blue at top → deep blue at bottom (explicit points, no seam)
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    let grad = NSGradient(colors: [rgb(0x60, 0xA5, 0xFA), rgb(0x14, 0x39, 0xA6)])!
    grad.draw(from: NSPoint(x: S/2, y: inset), to: NSPoint(x: S/2, y: S - inset), options: [])
    NSGraphicsContext.restoreGraphicsState()

    // crisp inner edge
    rgb(255, 255, 255, 0.10).setStroke(); bg.lineWidth = 3; bg.stroke()

    // white droplet (the "drip")
    let cx = S/2
    let drop = teardrop(cx: cx, apexY: 226, bottomY: 818, radius: 168)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = rgb(0x07, 0x16, 0x33, 0.45)
    sh.shadowBlurRadius = 34; sh.shadowOffset = NSSize(width: 0, height: -14)
    sh.set()
    rgb(0xFF, 0xFF, 0xFF).setFill(); drop.fill()
    NSGraphicsContext.restoreGraphicsState()

    // blue "text lines" inside the droplet body (the "writer")
    let ink = rgb(0x1D, 0x4E, 0xD8)
    ink.setFill()
    let bodyCy: CGFloat = 650
    capsule(cx: cx, cy: bodyCy - 60, w: 150, h: 34).fill()
    capsule(cx: cx, cy: bodyCy,       w: 210, h: 34).fill()
    capsule(cx: cx, cy: bodyCy + 60, w: 120, h: 34).fill()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: S, height: S)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: S, height: S))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
