import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./Navigator.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Coordinates use AppKit's bottom-left origin (y up).
func draw(_ S: CGFloat) {
    func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
    }

    // --- Folder ---
    // Back tab (peeks above the body)
    let tab = rr(0.14*S, 0.55*S, 0.32*S, 0.17*S, 0.035*S)
    NSColor(srgbRed: 0.84, green: 0.59, blue: 0.16, alpha: 1).setFill(); tab.fill()

    // Folder back body (gold gradient)
    let body = rr(0.10*S, 0.19*S, 0.80*S, 0.43*S, 0.055*S)
    NSGraphicsContext.saveGraphicsState(); body.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.96, green: 0.74, blue: 0.27, alpha: 1),
                        NSColor(srgbRed: 0.88, green: 0.65, blue: 0.19, alpha: 1)])!.draw(in: body.bounds, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Front flap (SOLID light gold so the apple's "bites" blend seamlessly)
    let flapColor = NSColor(srgbRed: 0.97, green: 0.81, blue: 0.41, alpha: 1)
    let flap = rr(0.10*S, 0.17*S, 0.80*S, 0.35*S, 0.055*S)
    flapColor.setFill(); flap.fill()

    // --- Apple on the folder ---
    let cx = 0.50*S, cy = 0.345*S, rA = 0.125*S

    // Stem + leaf (drawn first so the apple body slightly overlaps their base)
    let stem = rr(cx - 0.013*S, cy + rA - 0.015*S, 0.026*S, 0.075*S, 0.012*S)
    NSColor(srgbRed: 0.42, green: 0.26, blue: 0.12, alpha: 1).setFill(); stem.fill()
    NSGraphicsContext.saveGraphicsState()
    let lt = NSAffineTransform()
    lt.translateX(by: cx + 0.02*S, yBy: cy + rA + 0.015*S)
    lt.rotate(byDegrees: -32); lt.concat()
    let leaf = NSBezierPath(ovalIn: CGRect(x: 0, y: -0.028*S, width: 0.115*S, height: 0.056*S))
    NSColor(srgbRed: 0.30, green: 0.68, blue: 0.33, alpha: 1).setFill(); leaf.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Apple body (red gradient)
    let apple = NSBezierPath(ovalIn: CGRect(x: cx - rA, y: cy - rA, width: 2*rA, height: 2*rA))
    NSGraphicsContext.saveGraphicsState(); apple.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.92, green: 0.29, blue: 0.25, alpha: 1),
                        NSColor(srgbRed: 0.76, green: 0.17, blue: 0.15, alpha: 1)])!.draw(in: apple.bounds, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Two bites — flap-colored circles centered on the apple's left & right edges
    let rB = 0.066*S
    flapColor.setFill()
    NSBezierPath(ovalIn: CGRect(x: cx + rA - rB, y: cy - rB, width: 2*rB, height: 2*rB)).fill()  // right bite
    NSBezierPath(ovalIn: CGRect(x: cx - rA - rB, y: cy - rB, width: 2*rB, height: 2*rB)).fill()  // left bite
}

func writePNG(size: Int, path: String) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

let specs: [(String, Int)] = [
    ("icon_16x16.png",16), ("icon_16x16@2x.png",32),
    ("icon_32x32.png",32), ("icon_32x32@2x.png",64),
    ("icon_128x128.png",128), ("icon_128x128@2x.png",256),
    ("icon_256x256.png",256), ("icon_256x256@2x.png",512),
    ("icon_512x512.png",512), ("icon_512x512@2x.png",1024),
]
for (name, px) in specs { writePNG(size: px, path: "\(outDir)/\(name)") }
print("wrote iconset to \(outDir)")
