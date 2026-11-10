// Draws the app icon: swift scripts/make-icon.swift out.png
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(platePath)
ctx.setFillColor(NSColor(srgbRed: 0.075, green: 0.075, blue: 0.07, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

// A small treemap: (x, y, w, h) in units of the inner square, y down.
let tiles: [(Double, Double, Double, Double, UInt32)] = [
    (0.00, 0.00, 0.58, 0.60, 0xe66767), // data
    (0.58, 0.00, 0.42, 0.36, 0x9085e9), // binaries
    (0.58, 0.36, 0.42, 0.24, 0xc98500), // archives
    (0.00, 0.60, 0.34, 0.40, 0x3987e5), // video
    (0.34, 0.60, 0.30, 0.40, 0x008300), // code
    (0.64, 0.60, 0.36, 0.22, 0xd95926), // images
    (0.64, 0.82, 0.20, 0.18, 0x199e70), // audio
    (0.84, 0.82, 0.16, 0.18, 0xd55181), // documents
]
let inset = 62.0
let inner = plate.insetBy(dx: inset, dy: inset)
ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 124, cornerHeight: 124, transform: nil))
ctx.clip()
let gap = 9.0
for (x, y, w, h, hex) in tiles {
    let rect = CGRect(x: inner.minX + x * inner.width + gap / 2,
                      y: inner.maxY - (y + h) * inner.height + gap / 2,
                      width: w * inner.width - gap, height: h * inner.height - gap)
    let r = Double((hex >> 16) & 0xff) / 255, g = Double((hex >> 8) & 0xff) / 255, b = Double(hex & 0xff) / 255
    func shade(_ k: Double) -> CGColor {
        NSColor(srgbRed: min(1, r * k), green: min(1, g * k), blue: min(1, b * k), alpha: 1).cgColor
    }
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.clip()
    // Cushion: lit from the top left, falling off towards the bottom right.
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [shade(1.32), shade(1.0), shade(0.58)] as CFArray, locations: [0, 0.45, 1])!
    let centre = CGPoint(x: rect.minX + rect.width * 0.34, y: rect.maxY - rect.height * 0.30)
    ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre,
                           endRadius: hypot(rect.width, rect.height) * 0.80,
                           options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
