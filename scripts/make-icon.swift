import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let s = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: s); transform.concat()
        NSColor(calibratedRed: 0.94, green: 0.925, blue: 0.89, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 66, y: 66, width: 892, height: 892), xRadius: 205, yRadius: 205).fill()
        NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.18, alpha: 1).setStroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: 512, y: 535), radius: 228, startAngle: 135, endAngle: 45, clockwise: false)
        arc.lineWidth = 64; arc.lineCapStyle = .round; arc.stroke()
        let stem = NSBezierPath(); stem.move(to: NSPoint(x: 512, y: 800)); stem.line(to: NSPoint(x: 512, y: 542))
        stem.lineWidth = 64; stem.lineCapStyle = .round; stem.stroke()
        NSColor(calibratedRed: 0.23, green: 0.49, blue: 0.32, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 386, y: 189, width: 252, height: 24), xRadius: 12, yRadius: 12).fill()
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
    }
}
