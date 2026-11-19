// Draws the app icon (an original design) into an .iconset folder.
// Usage: swift scripts/make-icon.swift <variant 1|2|3> <out.iconset>
import AppKit

let args = CommandLine.arguments
let variant = args.count > 1 ? args[1] : "1"
let out = URL(fileURLWithPath: args.count > 2 ? args[2] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let coral = CGColor(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

/// A sixteen-ray spark centred at the origin, `r` long, drawn with round line caps.
func spark(_ c: CGContext, r: CGFloat, width: CGFloat, color: CGColor) {
    c.saveGState()
    c.setStrokeColor(color)
    c.setLineWidth(width)
    c.setLineCap(.round)
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 8
        let len = i % 2 == 0 ? r : r * 0.86
        c.move(to: CGPoint(x: -cos(a) * len, y: -sin(a) * len))
        c.addLine(to: CGPoint(x: cos(a) * len, y: sin(a) * len))
    }
    c.strokePath()
    c.restoreGState()
}

func arrowHead(_ c: CGContext, at p: CGPoint, angle: CGFloat, size: CGFloat, color: CGColor) {
    c.saveGState()
    c.translateBy(x: p.x, y: p.y)
    c.rotate(by: angle)
    c.setFillColor(color)
    c.move(to: CGPoint(x: size, y: 0))
    c.addLine(to: CGPoint(x: -size * 0.6, y: size * 0.75))
    c.addLine(to: CGPoint(x: -size * 0.6, y: -size * 0.75))
    c.closePath()
    c.fillPath()
    c.restoreGState()
}

func draw(_ c: CGContext, size s: CGFloat) {
    // macOS icon grid: the rounded square fills about 80% of the canvas.
    let inset = s * 0.1
    let box = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let u = box.width / 140   // design units: the box is 140 wide
    c.addPath(CGPath(roundedRect: box, cornerWidth: 32 * u, cornerHeight: 32 * u, transform: nil))
    c.setFillColor(coral)
    c.fillPath()
    c.translateBy(x: box.midX, y: box.midY)
    c.scaleBy(x: u, y: -u)   // y down, like the sketch

    switch variant {
    case "2":
        c.saveGState(); c.translateBy(x: -16, y: -14)
        spark(c, r: 21, width: 5, color: white.copy(alpha: 0.55)!)
        c.restoreGState()
        c.saveGState(); c.translateBy(x: 16, y: 14)
        spark(c, r: 21, width: 5, color: white)
        c.restoreGState()
    case "3":
        c.saveGState(); c.translateBy(x: -6, y: -6)
        spark(c, r: 31.5, width: 7, color: white)
        c.restoreGState()
        c.setFillColor(white)
        c.fillEllipse(in: CGRect(x: 14, y: 14, width: 48, height: 48))
        c.setStrokeColor(coral); c.setLineWidth(4.5); c.setLineCap(.round); c.setLineJoin(.round)
        c.move(to: CGPoint(x: 26, y: 32)); c.addLine(to: CGPoint(x: 48, y: 32))
        c.move(to: CGPoint(x: 42, y: 26)); c.addLine(to: CGPoint(x: 48, y: 32)); c.addLine(to: CGPoint(x: 42, y: 38))
        c.move(to: CGPoint(x: 50, y: 44)); c.addLine(to: CGPoint(x: 28, y: 44))
        c.move(to: CGPoint(x: 34, y: 38)); c.addLine(to: CGPoint(x: 28, y: 44)); c.addLine(to: CGPoint(x: 34, y: 50))
        c.strokePath()
    default:
        spark(c, r: 25.5, width: 6, color: white)
        c.setStrokeColor(white); c.setLineWidth(7); c.setLineCap(.round)
        c.addArc(center: .zero, radius: 50, startAngle: .pi * 1.09, endAngle: .pi * 1.64, clockwise: false)
        c.strokePath()
        c.addArc(center: .zero, radius: 50, startAngle: .pi * 0.09, endAngle: .pi * 0.64, clockwise: false)
        c.strokePath()
        arrowHead(c, at: CGPoint(x: cos(.pi * 1.64) * 50, y: sin(.pi * 1.64) * 50), angle: .pi * 1.64 + .pi / 2, size: 11, color: white)
        arrowHead(c, at: CGPoint(x: cos(.pi * 0.64) * 50, y: sin(.pi * 0.64) * 50), angle: .pi * 0.64 + .pi / 2, size: 11, color: white)
    }
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(c, size: CGFloat(px))
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(name).png"))
}
