// Draws the TPrinter app icon (1024×1024 PNG): a white thermal label printer on a vivid blue tile,
// printing a barcode label out of its slot, with the green "ready" LED.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Rounded only on top (label paper coming out of the slot).
func topRounded(_ rect: CGRect, _ r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: rect.minX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
    p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
    p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r), control: CGPoint(x: rect.maxX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    p.closeSubpath()
    return p
}

// macOS icon grid: 824×824 rounded square centred in 1024, radius ≈ 185.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = rounded(tile, 185)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x0B1240, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(color(0x3450E0)); ctx.fillPath()
ctx.restoreGState()

// Tile: vivid blue → indigo, with a soft light from the top left.
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(gradient([color(0x5B8CFF), color(0x3A55E8), color(0x2A2FB8)], [0, 0.55, 1]),
                       start: CGPoint(x: 180, y: 924), end: CGPoint(x: 844, y: 100), options: [])
ctx.drawRadialGradient(gradient([color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)], [0, 1]),
                       startCenter: CGPoint(x: 260, y: 860), startRadius: 0,
                       endCenter: CGPoint(x: 260, y: 860), endRadius: 560, options: [])

// Soft floor shadow under the printer.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: color(0x0B1240, 0.45))
ctx.setFillColor(color(0x0B1240, 0.35))
ctx.fillEllipse(in: CGRect(x: 230, y: 214, width: 564, height: 70))
ctx.restoreGState()

// --- Label coming out of the top slot (drawn first; the printer's top edge covers its base).
let paper = CGRect(x: 322, y: 540, width: 380, height: 318)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x0B1240, 0.35))
ctx.addPath(topRounded(paper, 36)); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
// Faint die-cut line: the next label starts just above the slot.
ctx.setFillColor(color(0xDCE3F2))
ctx.fill(CGRect(x: 322, y: 596, width: 380, height: 6))

// Printed content: bold title, a text line, barcode.
ctx.setFillColor(color(0x111827))
ctx.addPath(rounded(CGRect(x: 360, y: 790, width: 210, height: 30), 8)); ctx.fillPath()
ctx.setFillColor(color(0x9AA3B5))
ctx.addPath(rounded(CGRect(x: 360, y: 758, width: 140, height: 16), 6)); ctx.fillPath()
ctx.setFillColor(color(0x111827))
let pattern: [CGFloat] = [12, 6, 6, 6, 18, 6, 6, 12, 6, 6, 12, 12, 6, 6, 18, 6, 6, 12]
var x: CGFloat = 360
var i = 0
while x < 664 {
    let w = min(pattern[i % pattern.count], 664 - x)
    if i % 2 == 0 { ctx.fill(CGRect(x: x, y: 628, width: w, height: 104)) }
    x += w
    i += 1
}

// --- Printer body: white shell with a soft top-to-bottom shade.
let body = CGRect(x: 212, y: 262, width: 600, height: 318)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: color(0x0B1240, 0.45))
ctx.addPath(rounded(body, 96)); ctx.setFillColor(color(0xF3F6FC)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(rounded(body, 96)); ctx.clip()
ctx.drawLinearGradient(gradient([color(0xFFFFFF), color(0xEEF2FA), color(0xD4DBEA)], [0, 0.45, 1]),
                       start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
// Top lid: slightly darker band with the paper slot.
ctx.setFillColor(color(0xDFE5F2))
ctx.fill(CGRect(x: body.minX, y: 500, width: body.width, height: body.maxY - 500))
ctx.setFillColor(color(0xC9D1E3))
ctx.fill(CGRect(x: body.minX, y: 496, width: body.width, height: 4))
ctx.restoreGState()

// Paper slot (dark), with the label running into it.
ctx.addPath(rounded(CGRect(x: 304, y: 530, width: 416, height: 30), 15)); ctx.setFillColor(color(0x1B2233)); ctx.fillPath()
ctx.setFillColor(color(0xFFFFFF))
ctx.fill(CGRect(x: 322, y: 545, width: 380, height: 15))

// Front: a darker window strip and the feed button.
let window = CGRect(x: 262, y: 344, width: 330, height: 90)
ctx.addPath(rounded(window, 30)); ctx.setFillColor(color(0x2B3756)); ctx.fillPath()
ctx.saveGState()
ctx.addPath(rounded(window, 30)); ctx.clip()
ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.20), color(0xFFFFFF, 0)], [0, 1]),
                       start: CGPoint(x: 0, y: window.maxY), end: CGPoint(x: 0, y: window.midY), options: [])
ctx.restoreGState()
// Three little "print head" dots in the window.
ctx.setFillColor(color(0x7FA2FF, 0.9))
for dx in [0, 34, 68] as [CGFloat] { ctx.fillEllipse(in: CGRect(x: 296 + dx, y: 377, width: 20, height: 20)) }
// Feed button.
ctx.addPath(rounded(CGRect(x: 628, y: 352, width: 130, height: 64), 32)); ctx.setFillColor(color(0xCBD3E4)); ctx.fillPath()
ctx.addPath(rounded(CGRect(x: 636, y: 360, width: 114, height: 48), 24)); ctx.setFillColor(color(0xE7ECF6)); ctx.fillPath()

// Green "ready" LED with glow, on the lid.
let led = CGRect(x: 738, y: 527, width: 36, height: 36)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 26, color: color(0x22E08A, 0.95))
ctx.setFillColor(color(0x22C97A)); ctx.fillEllipse(in: led)
ctx.restoreGState()
ctx.setFillColor(color(0xFFFFFF, 0.55)); ctx.fillEllipse(in: CGRect(x: 746, y: 543, width: 11, height: 11))

// Glassy highlight across the top of the tile.
ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)], [0, 1]),
                       start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 640), options: [])
ctx.restoreGState()

// Thin inner rim so the tile reads crisply on dark docks.
ctx.addPath(rounded(tile.insetBy(dx: 1.5, dy: 1.5), 183.5))
ctx.setStrokeColor(color(0xFFFFFF, 0.18)); ctx.setLineWidth(3); ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
