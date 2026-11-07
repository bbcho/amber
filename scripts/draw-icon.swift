import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        let canvasScale = CGFloat(pixels) / 1024
        context.scaleBy(x: canvasScale, y: canvasScale)
        context.translateBy(x: 100, y: 100)
        let tileScale: CGFloat = 824.0 / 1024.0
        context.scaleBy(x: tileScale, y: tileScale)

        let tile = NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: 1024, height: 1024),
            xRadius: 220, yRadius: 220
        )
        let gradient = NSGradient(
            starting: NSColor(srgbRed: 1, green: 0.67, blue: 0.16, alpha: 1),
            ending: NSColor(srgbRed: 1, green: 0.82, blue: 0.42, alpha: 1)
        )!
        gradient.draw(in: tile, angle: 90)

        NSColor(srgbRed: 0.16, green: 0.08, blue: 0.02, alpha: 1).set()
        let prompt = NSBezierPath()
        prompt.move(to: NSPoint(x: 238, y: 714))
        prompt.line(to: NSPoint(x: 492, y: 512))
        prompt.line(to: NSPoint(x: 238, y: 310))
        prompt.lineWidth = 94
        prompt.lineCapStyle = .round
        prompt.lineJoinStyle = .round
        prompt.stroke()
        NSBezierPath(rect: NSRect(x: 658, y: 304, width: 126, height: 416)).fill()

        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(points)x\(points)\(suffix).png"
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: output.appendingPathComponent(name), options: .atomic)
    }
}
