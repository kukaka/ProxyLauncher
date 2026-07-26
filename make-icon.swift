// 生成应用图标：渐变圆角矩形 + 纸飞机符号
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let margin = CGFloat(size) * 0.09
let rect = NSRect(x: margin, y: margin,
                  width: CGFloat(size) - margin * 2, height: CGFloat(size) - margin * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
path.addClip()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.19, green: 0.42, blue: 0.95, alpha: 1),
    NSColor(calibratedRed: 0.42, green: 0.22, blue: 0.90, alpha: 1),
])!
gradient.draw(in: rect, angle: -60)

if let symbol = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.42, weight: .medium)
    let img = symbol.withSymbolConfiguration(config)!
    let tinted = NSImage(size: img.size, flipped: false) { r in
        img.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
    }
    let s = tinted.size
    let scale = (rect.width * 0.52) / max(s.width, s.height)
    let w = s.width * scale, h = s.height * scale
    tinted.draw(in: NSRect(x: (CGFloat(size) - w) / 2 - CGFloat(size) * 0.01,
                           y: (CGFloat(size) - h) / 2,
                           width: w, height: h))
}

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
