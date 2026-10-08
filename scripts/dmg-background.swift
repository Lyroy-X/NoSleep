import AppKit

// A fixed Finder canvas keeps the two icons and the installation arrow aligned.
let width = 640, height = 360
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2,
    pixelsHigh: height * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let canvas = NSRect(x: 0, y: 0, width: width, height: height)
NSColor(calibratedRed: 0.94, green: 0.97, blue: 0.98, alpha: 1).setFill()
canvas.fill()

let title = "NoSleep" as NSString
let style: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.12, green: 0.24, blue: 0.28, alpha: 1)
]
let titleSize = title.size(withAttributes: style)
title.draw(at: NSPoint(x: (CGFloat(width) - titleSize.width) / 2, y: 285), withAttributes: style)

// Finder icon centres: (155,170) and (485,170), measured from the top.
let arrow = NSBezierPath()
arrow.lineWidth = 9
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 260, y: 190))
arrow.line(to: NSPoint(x: 380, y: 190))
arrow.move(to: NSPoint(x: 354, y: 215))
arrow.line(to: NSPoint(x: 380, y: 190))
arrow.line(to: NSPoint(x: 354, y: 165))
NSColor(calibratedRed: 0.08, green: 0.47, blue: 0.53, alpha: 1).setStroke()
arrow.stroke()
NSGraphicsContext.restoreGraphicsState()

guard CommandLine.arguments.count == 2,
      let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Pass the output PNG path")
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
