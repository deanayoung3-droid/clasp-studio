import AppKit
import CoreImage

struct HeadlineTicker: @unchecked Sendable {
    let current: CIImage
    let previous: CIImage?
    let zone: CGRect
    let epoch: Double
    init(current: String, previous: String?, zone: CGRect, style: OverlayComponentStyle, epoch: Double, color: NSColor = .white) {
        self.zone = zone; self.epoch = epoch
        func artwork(_ value: String) -> CIImage {
            CIImage(cgImage: BroadcastGraphics.image { ctx in
                ctx.saveGState(); ctx.clip(to: zone)
                BroadcastGraphics.text(value, at: zone, size: 39 * style.safeScale, weight: .semibold, color: color, fit: true, alignment: style.alignment.native)
                ctx.restoreGState()
            }!)
        }
        self.current = artwork(current)
        self.previous = previous.flatMap { $0 == current ? nil : artwork($0) }
    }
    func frame(at time: Double) -> CIImage {
        guard let previous else { return current.cropped(to: zone) }
        let progress = min(1, max(0, (time - epoch) / 0.6))
        let ease = progress * progress * (3 - 2 * progress)
        let incoming = current.transformed(by: CGAffineTransform(translationX: 0, y: (ease - 1) * zone.height))
        let outgoing = previous.transformed(by: CGAffineTransform(translationX: 0, y: ease * zone.height))
        return incoming.composited(over: outgoing).cropped(to: zone)
    }
}
extension BroadcastGraphics {
    static let legalNetworkBrand: CGImage? = Bundle.main.url(forResource: "LegalNetworkBrand", withExtension: "png").flatMap { NSImage(contentsOf: $0)?.studioCGImage }
    static func networkBrand(_ ctx: CGContext, project: StudioProject, doc: OverlayDocument, in rect: CGRect) {
        if let custom = doc.programLogoData.flatMap({ NSImage(data: $0)?.studioCGImage }) { drawLogo(ctx, custom, in: rect); return }
        if doc.brandName == "Clasp Legal", doc.brandSubtitle == "News Network", doc.brandLogoData == nil, let exact = legalNetworkBrand {
            // Outlined logo and lettering are the original SVG paths, rendered once.
            drawLogo(ctx, exact, in: rect); return
        }
        let logo = doc.brandLogoData.flatMap { NSImage(data: $0)?.studioCGImage } ?? brandImage(project)?.studioCGImage
        if let logo { drawLogo(ctx, logo, in: CGRect(x: rect.minX, y: rect.midY - 23, width: 48, height: 46), tint: doc.brandLogoData == nil ? .white : nil) }
        text(doc.brandName, at: CGRect(x: rect.minX + 69, y: rect.midY, width: rect.width - 69, height: 31), size: 24, color: .white, fit: true)
        text(doc.brandSubtitle, at: CGRect(x: rect.minX + 69, y: rect.midY - 30, width: rect.width - 69, height: 30), size: 23, color: .white, fit: true)
    }
    static func tickerOverlay(_ project: StudioProject, doc: OverlayDocument, at date: Date) -> CGImage? {
        image { ctx in
            // Original SVG: clear #292929 at y=1265, opaque #282828 at
            // 99.5192% of its 411px band. The camera remains visible through it.
            let top = 720 - 1265 * 720 / 1677.0
            let band = CGRect(x: 0, y: 0, width: 1280, height: top)
            let colors = [NSColor(studioHex: "292929").withAlphaComponent(0).cgColor, NSColor(studioHex: "282828").cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.995192]) {
                ctx.saveGState(); ctx.clip(to: band)
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: top - 411 * 720 / 1677.0), options: [.drawsAfterEndLocation]); ctx.restoreGState()
            }
            networkBrand(ctx, project: project, doc: doc, in: doc.zone(.programBrand))
            fill(ctx, CGRect(x: 301, y: 95, width: 0.8, height: 83), .white.withAlphaComponent(0.45))
            if doc.showDate { text(doc.dateText(in: project.overlayTimeZone, compact: true) + " " + clockLabels(at: date, timeZoneID: project.overlayTimeZone).time, at: doc.zone(.date), size: 11, weight: .medium, color: .white, fit: true) }
            if !doc.showHeadlines { text(doc.title, at: doc.textZone(.title), size: CGFloat(doc.titleSize) * doc.style(.title).safeScale, color: .white, fit: true, alignment: doc.style(.title).alignment.native) }
            if doc.showPresenter { text(doc.presenter + "   " + doc.handle, at: doc.zone(.presenter), size: 12, color: .white.withAlphaComponent(0.8), fit: true) }
            if doc.showLive { let rect = doc.zone(.live); rounded(ctx, rect, 24, .black.withAlphaComponent(0.55)); text(doc.liveLabel, at: rect.insetBy(dx: 40, dy: 0), size: 15, color: .white, fit: true) }
            if doc.showPresentedBy { let rect = doc.zone(.presentedBy); rounded(ctx, rect, 12, .black.withAlphaComponent(0.55)); text(doc.presentedBy + "   " + doc.brandName, at: rect.insetBy(dx: 16, dy: 0), size: 15, color: .white, fit: true) }
        }
    }
    static func glassFrostMask(_ doc: OverlayDocument) -> CGImage? {
        image { ctx in
            rounded(ctx, CGRect(x: 23, y: 78, width: 927, height: 133), 14, .white)
            if doc.showHeadlines { rounded(ctx, doc.zone(.headlines), 12, .white) }
            if doc.showLive { rounded(ctx, doc.zone(.live), 24, .white) }
            if doc.showPresentedBy { rounded(ctx, doc.zone(.presentedBy), 14, .white) }
            if doc.showSponsors { rounded(ctx, CGRect(x: 0, y: -5, width: 1280, height: 66), 16, .white) }
        }
    }
}
