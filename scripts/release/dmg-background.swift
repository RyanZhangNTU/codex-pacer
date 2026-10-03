import AppKit

// A small, Retina-ready Finder background; the app and folder remain real icons.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let size = NSSize(width: 640, height: 360)
for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 640 * scale, pixelsHigh: 360 * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()

    func centered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = (text as NSString).size(withAttributes: attributes).width
        (text as NSString).draw(at: NSPoint(x: (size.width - width) / 2, y: y), withAttributes: attributes)
    }
    centered("Codex Pacer", y: 292, font: .systemFont(ofSize: 28, weight: .semibold),
             color: NSColor(calibratedWhite: 0.14, alpha: 1))
    centered("将左侧图标拖入「应用程序」", y: 255, font: .systemFont(ofSize: 16),
             color: NSColor(calibratedWhite: 0.40, alpha: 1))

    NSColor(calibratedWhite: 0.65, alpha: 1).setStroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 286, y: 165))
    arrow.line(to: NSPoint(x: 352, y: 165))
    arrow.move(to: NSPoint(x: 340, y: 178))
    arrow.line(to: NSPoint(x: 353, y: 165))
    arrow.line(to: NSPoint(x: 340, y: 152))
    arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let suffix = scale == 1 ? "" : "@2x"
    try bitmap.representation(using: .png, properties: [:])!
        .write(to: output.appendingPathComponent("background\(suffix).png"))
}
