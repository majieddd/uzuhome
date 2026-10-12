// Renders uzu Home's icon: an indigo vortex (uzu, 渦, is Japanese for "whirlpool") on the dark tile TensorFold Home and
// StrataHome use.
//   swift tools/make_icon.swift assets/icon-1024.png
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// the tile (Apple's icon grid: 824 px body, 185 px corners), the night palette's background
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSGradient(colors: [color(0x1D2226), color(0x0E1113)])!.draw(in: tile, angle: -90)
ctx.restoreGState()
color(0xFFFFFF, 0.06).setStroke()
tile.lineWidth = 4
tile.stroke()

// the vortex: three arms, each a spiral from the rim to the eye, drawn as tapering strokes from dark to light indigo
let center = NSPoint(x: size / 2, y: size / 2)
let arms = 3
let turns: CGFloat = 0.95
let outer: CGFloat = 300, inner: CGFloat = 34
let steps = 220
let shades: [UInt32] = [0x4F46E5, 0x6366F1, 0x818CF8, 0xA5B4FC]
for arm in 0..<arms {
    let phase = CGFloat(arm) * 2 * .pi / CGFloat(arms)
    var points: [NSPoint] = []
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)               // 0 at the rim, 1 at the eye
        let r = outer * pow(inner / outer, t)               // logarithmic: tighter towards the middle
        let a = phase + t * turns * 2 * .pi
        points.append(NSPoint(x: center.x + r * cos(a), y: center.y + r * sin(a)))
    }
    for i in 1..<points.count {
        let t = CGFloat(i) / CGFloat(points.count)
        let seg = NSBezierPath()
        seg.move(to: points[i - 1])
        seg.line(to: points[i])
        seg.lineWidth = 92 * (1 - t) + 14 * t
        seg.lineCapStyle = .round
        // blend smoothly through the shades, dark at the rim to light at the eye
        let x = t * CGFloat(shades.count - 1)
        let k = min(shades.count - 2, Int(x))
        color(shades[k]).blended(withFraction: x - CGFloat(k), of: color(shades[k + 1]))!.setStroke()
        seg.stroke()
    }
}
// the eye
let eye = NSBezierPath(ovalIn: NSRect(x: center.x - 30, y: center.y - 30, width: 60, height: 60))
color(0xE0E7FF).setFill()
eye.fill()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
