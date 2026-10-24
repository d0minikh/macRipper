// Renders Resources/AppIcon.icns: a glass optical disc on the macOS 26 icon grid.
// Run from the project folder: swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024
// macOS icon grid: the body is 824 × 824, centered, so the system shows it without an extra frame.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

/// Apple's icon shape is a continuous-corner rounded square (a superellipse), not a plain rounded rect.
func squircle(_ rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let cx = rect.midX, cy = rect.midY, a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * copysign(pow(abs(c), 2 / exponent), c)
        let y = cy + b * copysign(pow(abs(s), 2 / exponent), s)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func circle(_ center: CGPoint, _ r: CGFloat) -> CGRect {
    CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
}

func renderMaster() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let shape = squircle(body)

    // Soft shadow under the icon body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x15132E))
    ctx.fillPath()
    ctx.restoreGState()

    // Body: deep indigo with a violet glow in the upper left.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x3A4A86), color(0x1A1840), color(0x0C0A1E)], [0, 0.55, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.drawRadialGradient(gradient([color(0x7C6CFF, 0.55), color(0x7C6CFF, 0)]),
                           startCenter: CGPoint(x: 290, y: 780), startRadius: 0,
                           endCenter: CGPoint(x: 290, y: 780), endRadius: 520, options: [])
    ctx.drawRadialGradient(gradient([color(0x00C8FF, 0.28), color(0x00C8FF, 0)]),
                           startCenter: CGPoint(x: 820, y: 210), startRadius: 0,
                           endCenter: CGPoint(x: 820, y: 210), endRadius: 460, options: [])
    ctx.restoreGState()

    // The disc: about 80 % of the body.
    let center = CGPoint(x: 512, y: 512)
    let outer: CGFloat = 334, hub: CGFloat = 104, hole: CGFloat = 40
    let disc = CGMutablePath()
    disc.addEllipse(in: circle(center, outer))
    disc.addEllipse(in: circle(center, hole))

    // Disc shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 46, color: color(0x000000, 0.5))
    ctx.addPath(disc)
    ctx.setFillColor(color(0xFFFFFF, 0.14))
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(disc)
    ctx.clip(using: .evenOdd)
    // Frosted glass base.
    ctx.setFillColor(color(0xFFFFFF, 0.08))
    ctx.fill(circle(center, outer))
    // Iridescent shimmer like the data side of a disc.
    // (Drawn as fine wedges, so the script does not depend on CGContext's conic gradient API.)
    let shimmer: [(CGFloat, CGFloat, CGFloat)] = [(0.35, 0.88, 1.0), (0.55, 0.48, 1.0), (1.0, 0.44, 0.85),
                                                 (1.0, 0.77, 0.42), (0.62, 1.0, 0.54), (0.35, 0.88, 1.0)]
    let wedges = 360
    for i in 0..<wedges {
        let t = CGFloat(i) / CGFloat(wedges) * CGFloat(shimmer.count - 1)
        let k = min(Int(t), shimmer.count - 2), f = t - CGFloat(k)
        let (r1, g1, b1) = shimmer[k], (r2, g2, b2) = shimmer[k + 1]
        ctx.setFillColor(CGColor(srgbRed: r1 + (r2 - r1) * f, green: g1 + (g2 - g1) * f, blue: b1 + (b2 - b1) * f, alpha: 0.36))
        let a0 = CGFloat(i) / CGFloat(wedges) * 2 * .pi + .pi / 3
        let a1 = CGFloat(i + 1) / CGFloat(wedges) * 2 * .pi + .pi / 3 + 0.004
        ctx.move(to: center)
        ctx.addArc(center: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        ctx.closePath()
        ctx.fillPath()
    }
    // Fine data tracks.
    ctx.setLineWidth(1.6)
    for r in stride(from: hub + 22, to: outer - 10, by: 15) {
        ctx.setStrokeColor(color(0xFFFFFF, r.truncatingRemainder(dividingBy: 2) < 1 ? 0.09 : 0.05))
        ctx.strokeEllipse(in: circle(center, r))
    }
    // Light falling in from the top: brighter upper half, darker lower edge.
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.42), color(0xFFFFFF, 0.04), color(0x000000, 0.18)], [0, 0.55, 1]),
                           start: CGPoint(x: 512, y: center.y + outer), end: CGPoint(x: 512, y: center.y - outer), options: [])
    // Specular highlight in the upper left.
    ctx.drawRadialGradient(gradient([color(0xFFFFFF, 0.55), color(0xFFFFFF, 0)]),
                           startCenter: CGPoint(x: 400, y: 690), startRadius: 0,
                           endCenter: CGPoint(x: 400, y: 690), endRadius: 230, options: [])
    // Clear center hub with its own glass ring.
    ctx.setFillColor(color(0x0C0A1E, 0.35))
    ctx.fillEllipse(in: circle(center, hub))
    ctx.restoreGState()
    // The hub's own sheen, clipped to the hub ring only.
    ctx.saveGState()
    let hubRing = CGMutablePath()
    hubRing.addEllipse(in: circle(center, hub))
    hubRing.addEllipse(in: circle(center, hole))
    ctx.addPath(hubRing)
    ctx.clip(using: .evenOdd)
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.32), color(0xFFFFFF, 0.04)]),
                           start: CGPoint(x: 512, y: center.y + hub), end: CGPoint(x: 512, y: center.y - hub),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Glass edges: bright on top, fading towards the bottom.
    func rim(_ r: CGFloat, width: CGFloat, top: CGFloat, bottom: CGFloat) {
        ctx.saveGState()
        ctx.setLineWidth(width)
        ctx.addEllipse(in: circle(center, r))
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient([color(0xFFFFFF, top), color(0xFFFFFF, bottom)]),
                               start: CGPoint(x: 512, y: center.y + r), end: CGPoint(x: 512, y: center.y - r), options: [])
        ctx.restoreGState()
    }
    rim(outer - 3, width: 6, top: 0.9, bottom: 0.18)
    rim(hub, width: 4, top: 0.75, bottom: 0.15)
    rim(hole + 2, width: 3, top: 0.2, bottom: 0.6)

    // Glass sheen over the whole icon and a hairline highlight along its upper edge.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setLineWidth(3)
    ctx.addPath(squircle(body.insetBy(dx: 1.5, dy: 1.5)))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.45), color(0xFFFFFF, 0.06)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func png(_ image: CGImage, size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let master = renderMaster()
let out = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(master, size: base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(master, size: base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("Iconset written; convert with: iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns")
