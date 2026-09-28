// Renders the Driftflow app icon, "Drift Meter": a neon voice meter whose bars lean and trail
// motion streaks as if drifting forward, on a deep night-glass tile.
// Usage: swift render_icon.swift <output.png> [size]
import AppKit
import CoreGraphics

let output = CommandLine.arguments[1]
let size = CGFloat(Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "1024")!)
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: size / 1024, y: size / 1024) // design units: 1024 canvas, y up
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                            CGFloat(hex & 0xFF) / 255, alpha])!
}
func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { color($0.0, $0.1) } as CFArray, locations: stops.map { $0.2 })!
}

// macOS 26 icon mask: an 831 pt tile centred on the 1024 canvas with ~186 pt corners (measured from
// an icon Tahoe displays unboxed). Artwork that doesn't fill exactly this shape, or spills outside
// it, gets placed in a grey tile by the system.
let tile = CGRect(x: 96.5, y: 96.5, width: 831, height: 831)
func squircle(_ r: CGRect) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: 186, cornerHeight: 186, transform: nil)
}
let shape = squircle(tile)

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

// Night-glass base: deep indigo to near-black.
ctx.drawLinearGradient(gradient([(0x1E1550, 1, 0), (0x0E0B2A, 1, 0.55), (0x07061A, 1, 1)]),
                       start: CGPoint(x: 260, y: 924), end: CGPoint(x: 760, y: 100),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]) // paint the corners too
// Neon bloom behind the meter.
ctx.drawRadialGradient(gradient([(0x7B4DFF, 0.55, 0), (0x3A1FB8, 0.22, 0.45), (0x000000, 0, 1)]),
                       startCenter: CGPoint(x: 540, y: 500), startRadius: 0,
                       endCenter: CGPoint(x: 540, y: 500), endRadius: 470, options: [])
ctx.drawRadialGradient(gradient([(0x19D3FF, 0.30, 0), (0x000000, 0, 1)]),
                       startCenter: CGPoint(x: 700, y: 700), startRadius: 0,
                       endCenter: CGPoint(x: 700, y: 700), endRadius: 360, options: [])

// Voice meter: five capsules, tallest in the middle, leaning forward as if drifting.
let heights: [CGFloat] = [250, 430, 560, 380, 220]
let barWidth: CGFloat = 78
let gap: CGFloat = 40
let lean: CGFloat = 0.16 // horizontal shift per unit of height (a forward slant)
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
let startX = 512 - totalWidth / 2 + 24
let centerY: CGFloat = 512
let barFill = gradient([(0xFF5DB1, 1, 0), (0x9B5CFF, 1, 0.5), (0x4FE7FF, 1, 1)]) // bottom → top

func capsule(x: CGFloat, height: CGFloat) -> CGPath {
    // A rounded bar sheared forward around its centre.
    let rect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
    var shear = CGAffineTransform(a: 1, b: 0, c: lean, d: 1, tx: -lean * centerY, ty: 0)
    return CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: &shear)
}

for (index, height) in heights.enumerated() {
    let x = startX + CGFloat(index) * (barWidth + gap)
    let bar = capsule(x: x, height: height)

    // Motion streaks trailing behind each bar (to the left), fading out: the "drift".
    for (offset, alpha) in [(CGFloat(-26), CGFloat(0.22)), (CGFloat(-52), CGFloat(0.08))] {
        ctx.saveGState()
        var shift = CGAffineTransform(translationX: offset, y: 0)
        guard let ghost = bar.copy(using: &shift) else { continue }
        ctx.addPath(ghost)
        ctx.clip()
        ctx.setAlpha(alpha)
        ctx.drawLinearGradient(barFill, start: CGPoint(x: 0, y: centerY - height / 2),
                               end: CGPoint(x: 0, y: centerY + height / 2), options: [])
        ctx.restoreGState()
    }

    // Outer glow of the bar.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 42, color: color(0x8A5CFF, 0.85))
    ctx.addPath(bar)
    ctx.setFillColor(color(0x9B5CFF))
    ctx.fillPath()
    ctx.restoreGState()

    // The bar itself: neon gradient.
    ctx.saveGState()
    ctx.addPath(bar)
    ctx.clip()
    ctx.drawLinearGradient(barFill, start: CGPoint(x: 0, y: centerY - height / 2),
                           end: CGPoint(x: 0, y: centerY + height / 2), options: [])
    // Glass gloss: a soft sheen across the bar, following its slant.
    ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: lean, d: 1, tx: -lean * centerY, ty: 0))
    ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.42, 0), (0xFFFFFF, 0.08, 0.5), (0xFFFFFF, 0, 1)]),
                           start: CGPoint(x: x + 8, y: 0), end: CGPoint(x: x + barWidth, y: 0), options: [])
    ctx.restoreGState()
}

// Top light on the glass tile, and a faint inner rim.
ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.16, 0), (0xFFFFFF, 0, 0.35)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 520), options: [])
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
ctx.addPath(shape)
ctx.setLineWidth(6)
ctx.setStrokeColor(color(0xFFFFFF, 0.14))
ctx.strokePath()
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
