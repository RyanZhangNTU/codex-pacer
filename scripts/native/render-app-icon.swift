// Renders native/Resources/Pacer.svg into Pacer.icns and Pacer.png with the standard macOS icon shadow.
// Usage: swift scripts/native/render-app-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../native/Resources").standardized
guard let artwork = NSImage(contentsOf: root.appendingPathComponent("Pacer.svg")) else { fatalError("Cannot read Pacer.svg") }

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let scale = CGFloat(px) / 1024
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    shadow.shadowBlurRadius = 24 * scale
    shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
    shadow.set()
    artwork.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Pacer-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", root.appendingPathComponent("Pacer.icns").path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try render(512).write(to: root.appendingPathComponent("Pacer.png"))
print("Wrote Pacer.icns and Pacer.png")
