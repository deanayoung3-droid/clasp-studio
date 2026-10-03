import AppKit
import CoreImage

// Three counter-moving panels meet at the edit point and reveal the next shot.
// Artwork is cached; animation only translates layers and changes logo opacity.
enum BroadcastTransition {
    static let bounds = CGRect(x: 0, y: 0, width: 1280, height: 720)
    static let panels: [CIImage] = (0..<3).map { index in
        CIImage(cgImage: BroadcastGraphics.image { ctx in
            let rect = CGRect(x: Double(index) * 1280 / 3, y: 0, width: 1280 / 3 + 1, height: 720)
            BroadcastGraphics.fill(ctx, rect, NSColor(studioHex: index == 1 ? "191C22" : "101216"))
            BroadcastGraphics.fill(ctx, CGRect(x: rect.maxX - 2, y: 0, width: 2, height: 720), NSColor.white.withAlphaComponent(0.65))
            let path = CGMutablePath(); path.move(to: CGPoint(x: rect.minX, y: 0)); path.addLine(to: CGPoint(x: rect.maxX, y: 430)); path.addLine(to: CGPoint(x: rect.maxX, y: 720)); path.addLine(to: CGPoint(x: rect.minX, y: 290)); path.closeSubpath()
            ctx.addPath(path); ctx.setFillColor(NSColor.white.withAlphaComponent(0.025).cgColor); ctx.fillPath()
        }!)
    }
    static let brand: CIImage = CIImage(cgImage: BroadcastGraphics.image { ctx in
        if let logo = BroadcastGraphics.bundledLogo?.studioCGImage { BroadcastGraphics.drawLogo(ctx, logo, in: CGRect(x: 589, y: 341, width: 102, height: 95), tint: .white) }
        BroadcastGraphics.text("CLASP  /  LEGAL", at: CGRect(x: 440, y: 278, width: 400, height: 42), size: 26, weight: .medium, color: .white, alignment: .center)
        BroadcastGraphics.fill(ctx, CGRect(x: 601, y: 260, width: 78, height: 1), NSColor.white.withAlphaComponent(0.5))
    }!)
    static func ease(_ value: Double) -> Double { let p = min(1, max(0, value)); return p * p * (3 - 2 * p) }
    static func frame(progress: Double) -> CIImage {
        let p = min(1, max(0, progress)), incoming = p <= 0.5
        let phase = incoming ? p * 2 : (p - 0.5) * 2
        var result = CIImage(color: .clear).cropped(to: bounds)
        for index in 0..<3 {
            let delay = Double(incoming ? index : 2 - index) * 0.11
            let moved = ease((phase - delay) / (1 - delay))
            let direction = index == 1 ? -1.0 : 1.0
            let y = direction * 740 * (incoming ? 1 - moved : -moved)
            result = panels[index].transformed(by: CGAffineTransform(translationX: 0, y: y)).composited(over: result)
        }
        let alpha = incoming ? ease((phase - 0.65) / 0.35) : 1 - ease(phase / 0.3)
        if alpha > 0 { result = brand.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)]).composited(over: result) }
        return result.cropped(to: bounds)
    }
}
