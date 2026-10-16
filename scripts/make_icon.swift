// Draws the OpenRecast app icon and writes an .icns file.
// Usage: swift scripts/make_icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Squircle-ish tile with Apple's icon grid margin.
    let inset = s * 0.1, tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x000000, 0.35))
    ctx.addPath(path); ctx.setFillColor(color(0x161513)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    // Warm glow and the dial disc on the right edge.
    let w = tile.width
    let center = CGPoint(x: tile.maxX + w * 0.12, y: tile.midY)
    let glow = CGGradient(colorsSpace: nil, colors: [color(0xE58A5C, 0.45), color(0xE58A5C, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: w * 0.75, options: [])
    let discR = w * 0.56
    ctx.setFillColor(color(0x221F1C))
    ctx.fillEllipse(in: CGRect(x: center.x - discR, y: center.y - discR, width: discR * 2, height: discR * 2))

    // Dashed orbit with the eight folders at equal steps along it, as in the app.
    let r = w * 0.42
    ctx.setStrokeColor(color(0xEDE8E0, 0.18)); ctx.setLineWidth(max(1, s * 0.004)); ctx.setLineDash(phase: 0, lengths: [s * 0.006, s * 0.018])
    ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    ctx.setLineDash(phase: 0, lengths: [])
    let tints: [UInt32] = [0xE8875A, 0xE0B04C, 0x86B98F, 0xB592DE, 0xDA5F55, 0x7BA4DB, 0xB79A78, 0x5CB8B2]
    for (i, tint) in tints.enumerated() {
        let a = ((180.0 - 55.0) + Double(i) * (110.0 / 7.0)) * .pi / 180
        let p = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
        let fw = w * 0.09, fh = fw * 0.8, c = fw * 0.1
        let base = NSColor(srgbRed: CGFloat((tint >> 16) & 0xFF) / 255, green: CGFloat((tint >> 8) & 0xFF) / 255, blue: CGFloat(tint & 0xFF) / 255, alpha: 1)
        let back = CGRect(x: p.x - fw / 2, y: p.y - fh / 2, width: fw, height: fh * 0.87)
        ctx.setFillColor((base.blended(withFraction: 0.38, of: .black) ?? base).cgColor)
        ctx.addPath(CGPath(roundedRect: back, cornerWidth: c, cornerHeight: c, transform: nil))
        ctx.addPath(CGPath(roundedRect: CGRect(x: back.minX, y: back.maxY - fh * 0.27, width: fw * 0.44, height: fh * 0.4),
                           cornerWidth: c, cornerHeight: c, transform: nil))
        ctx.fillPath()
        ctx.setFillColor((base.blended(withFraction: 0.2, of: .white) ?? base).cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: back.minX, y: back.minY, width: fw, height: fh * 0.7),
                           cornerWidth: c, cornerHeight: c, transform: nil))
        ctx.fillPath()
    }

    // Large "OR" monogram in a classical Roman serif.
    let ink = NSColor(srgbRed: 0.93, green: 0.91, blue: 0.88, alpha: 1)
    let face = { (pt: CGFloat) in NSFont(name: "BigCaslon-Medium", size: pt) ?? NSFont(name: "Didot", size: pt) ?? NSFont.systemFont(ofSize: pt) }
    let monogram = { (pt: CGFloat) in
        CTLineCreateWithAttributedString(NSAttributedString(string: "OR", attributes: [.font: face(pt), .foregroundColor: ink, .kern: -pt * 0.01]))
    }
    var pt = w * 0.4
    var line = monogram(pt)
    pt *= (w * 0.46) / CTLineGetImageBounds(line, ctx).width
    line = monogram(pt)
    let bounds = CTLineGetImageBounds(line, ctx)
    ctx.textPosition = CGPoint(x: tile.minX + w * 0.075 - bounds.minX, y: tile.midY - bounds.midY)
    CTLineDraw(line, ctx)

    // Grain.
    for _ in 0..<(size * size / 6) {
        let x = CGFloat.random(in: tile.minX...tile.maxX), y = CGFloat.random(in: tile.minY...tile.maxY)
        ctx.setFillColor(color(Bool.random() ? 0xFFFFFF : 0x000000, 0.05))
        ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
    }
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("OpenRecast-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try draw(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
