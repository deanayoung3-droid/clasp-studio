import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1]); try! FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let size = CGSize(width: 760, height: 500)
func label(_ string: String, _ rect: CGRect, size: CGFloat, weight: NSFont.Weight = .regular, white: CGFloat = 1, alignment: NSTextAlignment = .left) {
    let p = NSMutableParagraphStyle(); p.alignment = alignment
    (string as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(white: white, alpha: 1), .paragraphStyle: p])
}
func make(scale: Int, preview: Bool) -> CGImage {
    let c = CGContext(data: nil, width: 760 * scale, height: 500 * scale, bitsPerComponent: 8, bytesPerRow: 760 * scale * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: CGFloat(scale), y: CGFloat(scale)); c.setFillColor(NSColor(white: 0.045, alpha: 1).cgColor); c.fill(CGRect(origin: .zero, size: size))
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    let logo = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))!
    // A quiet frame keeps Finder's native icons at the center of the installation.
    c.setFillColor(NSColor(white: 0.075, alpha: 1).cgColor)
    c.addPath(CGPath(roundedRect: CGRect(x: 48, y: 100, width: 664, height: 230), cornerWidth: 18, cornerHeight: 18, transform: nil)); c.fillPath()
    c.setStrokeColor(NSColor(white: 0.17, alpha: 1).cgColor); c.setLineWidth(0.7)
    c.addPath(CGPath(roundedRect: CGRect(x: 48, y: 100, width: 664, height: 230), cornerWidth: 18, cornerHeight: 18, transform: nil)); c.strokePath()
    logo.draw(in: CGRect(x: 48, y: 392, width: 54, height: 54))
    label("Clasp Studio", CGRect(x: 116, y: 403, width: 450, height: 40), size: 30, weight: .semibold)
    label("YOUR BROADCAST STARTS HERE", CGRect(x: 116, y: 386, width: 500, height: 18), size: 9, weight: .medium, white: 0.51)
    label("Drag Clasp Studio into Applications to install.", CGRect(x: 48, y: 345, width: 664, height: 22), size: 14, white: 0.75)
    c.setStrokeColor(NSColor(white: 0.6, alpha: 1).cgColor); c.setLineWidth(1.8); c.setLineCap(.round)
    c.move(to: CGPoint(x: 347, y: 236)); c.addLine(to: CGPoint(x: 413, y: 236)); c.move(to: CGPoint(x: 404, y: 245)); c.addLine(to: CGPoint(x: 413, y: 236)); c.addLine(to: CGPoint(x: 404, y: 227)); c.strokePath()
    label("Open it from Applications. Then connect your camera.", CGRect(x: 48, y: 55, width: 664, height: 20), size: 12, white: 0.72)
    label("macOS 14+    •    Apple silicon & Intel", CGRect(x: 48, y: 24, width: 664, height: 18), size: 10, white: 0.45)
    if preview {
        logo.draw(in: CGRect(x: 158, y: 184, width: 104, height: 104))
        NSWorkspace.shared.icon(forFile: "/Applications").draw(in: CGRect(x: 498, y: 184, width: 104, height: 104))
        label("Clasp Studio", CGRect(x: 120, y: 157, width: 180, height: 24), size: 13, weight: .medium, alignment: .center)
        label("Applications", CGRect(x: 460, y: 157, width: 180, height: 24), size: 13, weight: .medium, alignment: .center)
    }
    NSGraphicsContext.restoreGraphicsState(); return c.makeImage()!
}
for scale in [1, 2] {
    let rep = NSBitmapImageRep(cgImage: make(scale: scale, preview: false))
    try! rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("Installer\(scale == 2 ? "@2x" : "").png"))
}
try! NSBitmapImageRep(cgImage: make(scale: 2, preview: true)).representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("Installer Preview.png"))
