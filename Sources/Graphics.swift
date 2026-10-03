import AppKit
import CoreImage

struct RenderSettings: @unchecked Sendable {
    var overlay: CGImage?
    var mirror = true
    var cameraRect = CGRect(x: 0, y: 0, width: 1280, height: 720)
    var cameraMask: CGImage?
    var animation: BroadcastAnimation?
    var frostMask: CGImage?
    var frostRadius: Double = 0
}
enum BroadcastGraphics {
    static let width = 1280
    static let height = 720
    static let black = NSColor(white: 0.035, alpha: 1)
    static let white = NSColor(white: 0.98, alpha: 1)
    static var bundledLogo: NSImage? {
        guard let url = Bundle.main.url(forResource: "ClaspLogo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
    static func brandImage(_ project: StudioProject) -> NSImage? { project.primaryLogoData.flatMap(NSImage.init(data:)) ?? bundledLogo }
    static func image(_ draw: (CGContext) -> Void) -> CGImage? { bitmap(width: width, height: height, draw) }
    static func bitmap(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        draw(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
    static func text(_ text: String, at rect: CGRect, size: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor = .white, condensed: Bool = false, fit: Bool = false, alignment: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail; style.alignment = alignment
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        if condensed, let face = NSFont(name: "HelveticaNeue-CondensedBold", size: size) { font = face }
        if fit {
            while (text as NSString).size(withAttributes: [.font: font]).width > rect.width && font.pointSize > size * 0.6 { font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize - 1) ?? font }
        }
        let height = ceil(font.ascender - font.descender + font.leading)
        let target = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height + 3)
        (text as NSString).draw(in: target, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
    static func fill(_ ctx: CGContext, _ rect: CGRect, _ color: NSColor) { ctx.setFillColor(color.cgColor); ctx.fill(rect) }
    static func rounded(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat, _ color: NSColor) {
        ctx.setFillColor(color.cgColor); ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.fillPath()
    }
    static func brand(_ ctx: CGContext, project: StudioProject, in rect: CGRect, color: NSColor = black) {
        if let cg = brandImage(project)?.studioCGImage { drawLogo(ctx, cg, in: rect, tint: color) }
    }
    struct SponsorSlot {
        var name: String
        var logo: CGImage?
    }
    static func sponsorSlots(_ project: StudioProject) -> [SponsorSlot] {
        let enabled = project.logos.filter(\.enabled)
        let names = (project.sponsorNames ?? ["Filevine", "Dropbox"]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let defaults = names.map { name in
            SponsorSlot(name: name, logo: enabled.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }).flatMap { NSImage(data: $0.data)?.studioCGImage })
        }
        let extra = enabled.filter { logo in !names.contains(where: { $0.caseInsensitiveCompare(logo.name) == .orderedSame }) }.compactMap { logo -> SponsorSlot? in
            guard let cg = NSImage(data: logo.data)?.studioCGImage else { return nil }
            return SponsorSlot(name: logo.name, logo: cg)
        }
        return Array((defaults + extra).prefix(6))
    }
    static func clockLabels(at date: Date, timeZoneID: String?) -> (time: String, zone: String) {
        let zone = TimeZone(identifier: timeZoneID ?? "America/Los_Angeles") ?? TimeZone(identifier: "America/Los_Angeles")!
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone; formatter.dateFormat = "h:mm a"
        let labels = ["America/Los_Angeles": "PACIFIC", "America/New_York": "EASTERN", "America/Chicago": "CENTRAL", "America/Denver": "MOUNTAIN", "UTC": "UTC"]
        return (formatter.string(from: date).uppercased(), labels[timeZoneID ?? "America/Los_Angeles"] ?? labels[zone.identifier] ?? zone.abbreviation(for: date) ?? zone.identifier)
    }
    static var broadcastTemplate: CGImage? { OverlayTemplate.law.artwork }
    static let demoBackground = studio()
    static func document(_ project: StudioProject) -> OverlayDocument {
        let library = project.overlayLibrary ?? OverlayDocument.presets(project)
        return library.first(where: { $0.id == project.selectedOverlayID }) ?? library.first ?? OverlayDocument.presets(project)[0]
    }
    static func renderSettings(_ project: StudioProject, activeIndex: Int, at date: Date = Date(), epoch: Double = 0, previousSection: Int? = nil, tickerEpoch: Double? = nil) -> RenderSettings {
        guard project.graphics else { return RenderSettings(overlay: nil, mirror: project.mirror) }
        let doc = document(project), template = doc.template
        if template == .custom { return ImportedSVGGraphics.settings(doc, mirror: project.mirror) }
        let rect = template.cameraRect
        let mask = image { ctx in rounded(ctx, rect, (template == .law || template == .glass) ? 0 : 14.4, .white) }
        let sponsors = doc.showSponsors ? SponsorCarousel(items: SponsorCatalog.migrated(project), monochrome: template == .glass) : nil
        let dot: CIImage? = doc.showLive ? liveDot(doc).map { image, origin in CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y)) } : nil
        let motionAllowed = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var animation = BroadcastAnimation(sponsors: sponsors, sponsorSpeed: project.carouselSpeed ?? 32, sponsorMoving: project.carouselMoving != false && motionAllowed, liveDot: dot, pulseLive: doc.pulseLive && motionAllowed, epoch: epoch)
        if template == .ticker, doc.showHeadlines {
            let current = project.sections.indices.contains(activeIndex) ? project.sections[activeIndex].title : doc.title
            let previous = previousSection.flatMap { project.sections.indices.contains($0) ? project.sections[$0].title : nil }
            animation.headlineTicker = HeadlineTicker(current: current, previous: previous, zone: doc.textZone(.headlines), style: doc.style(.headlines), epoch: tickerEpoch ?? -1_000_000, color: NSColor(studioHex: doc.accentHex))
        }
        let frost = template == .glass ? glassFrostMask(doc) : nil
        return RenderSettings(overlay: baseOverlay(project, doc: doc, activeIndex: activeIndex, at: date), mirror: project.mirror, cameraRect: rect, cameraMask: mask, animation: animation, frostMask: frost, frostRadius: template == .glass ? min(40, max(0, doc.frostRadius ?? 22)) : 0)
    }
    static func overlay(_ project: StudioProject, section: String, activeIndex: Int? = nil, at date: Date = Date()) -> CGImage? {
        let settings = renderSettings(project, activeIndex: activeIndex ?? project.sections.firstIndex(where: { $0.title == section }) ?? 0, at: date)
        guard let base = settings.overlay else { return nil }
        return image { ctx in
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: 1280, height: 720))
            if let animated = settings.animation?.frame(at: 0), let cg = CIContext().createCGImage(animated, from: CGRect(x: 0, y: 0, width: 1280, height: 720)) { ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1280, height: 720)) }
        }
    }
    static func liveRect(_ template: OverlayTemplate) -> CGRect { template == .law ? template.box(110.777, 105, 458.339, 117) : template.box(79.7407, 76.2666, 458.339, 117) }
    static func liveDot(_ doc: OverlayDocument) -> (CGImage, CGPoint)? {
        let rect = doc.zone(.live), color = NSColor(studioHex: doc.liveDotHex)
        return bitmap(width: 22, height: 22) { ctx in
            rounded(ctx, CGRect(x: 0, y: 0, width: 22, height: 22), 8, color.withAlphaComponent(0.18))
            ctx.setFillColor(color.cgColor); ctx.fillEllipse(in: CGRect(x: 4.5, y: 4.5, width: 13, height: 13))
        }.map { ($0, CGPoint(x: rect.minX + 9, y: rect.midY - 11)) }
    }
    private static func baseOverlay(_ project: StudioProject, doc: OverlayDocument, activeIndex: Int, at date: Date) -> CGImage? {
        if doc.template == .ticker { return tickerOverlay(project, doc: doc, at: date) }
        if doc.template == .glass { return glassOverlay(project, doc: doc, activeIndex: activeIndex, at: date) }
        return image { ctx in
            let t = doc.template, dark = t.dark, accent = NSColor(studioHex: doc.accentHex)
            let ink = NSColor(studioHex: dark ? "0C0C0C" : t == .aiBlue ? "112238" : "111919")
            let page = NSColor(studioHex: dark ? "080808" : t == .aiBlue ? "F2F7FF" : t == .jai ? "E1E1E1" : "F7F8F8")
            let surface = NSColor(studioHex: t == .aiBlue ? "F7FBFF" : t == .jai ? "FFFDF9" : "FFFFFF")
            let lower = t == .jai ? NSColor(studioHex: "111318") : surface
            let lowerInk: NSColor = t == .jai ? .white : ink
            if let artwork = t.artwork { ctx.draw(artwork, in: CGRect(x: 0, y: 0, width: 1280, height: 720)) }
            // Fill the original ticker so the baked wordmarks cannot show through.
            let ticker = SponsorCarousel.rect
            let top = NSColor(studioHex: t == .aiBlue ? "132B4D" : "252525")
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, NSColor(studioHex: t == .aiBlue ? "071A30" : "030303").cgColor] as CFArray, locations: [0, 1]) { ctx.saveGState(); ctx.clip(to: ticker); ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 46), end: .zero, options: []); ctx.restoreGState() }
            fill(ctx, CGRect(x: 0, y: 45, width: 1280, height: 1), NSColor.white.withAlphaComponent(0.12))
            let cardTop: CGFloat = dark ? 233.237 : 219, cardStep: CGFloat = dark ? 206.446 : 202
            let count = project.sections.count, start = min(max(0, activeIndex - 2), max(0, count - 5))
            for row in 0..<5 {
                let rect = dark ? t.box(2203.14, cardTop + CGFloat(row) * cardStep, 759.596, 195.415) : t.box(2198, cardTop + CGFloat(row) * cardStep, 778, 180)
                fill(ctx, rect.insetBy(dx: -0.5, dy: -0.5), dark ? page : t == .aiBlue ? surface : page)
                guard doc.showHeadlines, project.sections.indices.contains(start + row) else { continue }
                let selected = start + row == activeIndex
                rounded(ctx, rect, dark ? 10.5 : 12.7, selected ? accent : dark ? NSColor(white: 0.945, alpha: 1) : surface)
                let color = selected ? accent.studioContrastingText : ink
                let textX: CGFloat = (dark ? 15 : 58) + doc.style(.headlines).safePadding
                if !dark { text(String(format: "%02d", start + row + 1), at: CGRect(x: rect.minX + 19, y: rect.minY, width: 28, height: rect.height), size: 13, weight: .regular, color: .gray) }
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17 * doc.style(.headlines).safeScale, weight: selected ? .bold : .medium), .foregroundColor: color, .paragraphStyle: { let style = NSMutableParagraphStyle(); style.alignment = doc.style(.headlines).alignment.native; return style }()]
                let available = CGRect(x: rect.minX + textX, y: rect.minY + 10, width: rect.width - textX - 15 - doc.style(.headlines).safePadding, height: rect.height - 20)
                let title = project.sections[start + row].title as NSString
                let height = min(available.height, max(22, ceil(title.boundingRect(with: available.size, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes).height)))
                ctx.saveGState(); ctx.clip(to: available)
                title.draw(in: CGRect(x: available.minX, y: rect.midY - height / 2, width: available.width, height: height), withAttributes: attributes)
                ctx.restoreGState()
            }
            let heading = t.box(2198, dark ? 80 : 86, 778, 105)
            if !(dark && doc.showHeadlines && doc.headlineHeading == "TWIL HEADLINES") {
                fill(ctx, heading, t == .aiBlue ? surface : page)
                if doc.showHeadlines { text(doc.headlineHeading, at: heading, size: 22, weight: .bold, color: dark ? .white : ink, fit: true) }
            }
            if dark {
                let presenter = doc.zone(.presenter)
                fill(ctx, presenter, accent)
                if doc.showPresenter {
                    text(doc.presenter, at: CGRect(x: presenter.minX + 11, y: presenter.minY, width: 200, height: presenter.height), size: 16 * doc.style(.presenter).safeScale, weight: .heavy, color: accent.studioContrastingText, fit: true)
                    text("𝕏 " + doc.handle, at: CGRect(x: presenter.minX + 220, y: presenter.minY, width: 320, height: presenter.height), size: 15 * doc.style(.presenter).safeScale, color: accent.studioContrastingText.withAlphaComponent(0.6), fit: true)
                }
                let titleRect = doc.zone(.title)
                fill(ctx, titleRect, NSColor(white: 0.945, alpha: 1))
                let title = doc.title + (doc.showDate ? " - " + doc.dateText(in: project.overlayTimeZone) : "")
                text(title.uppercased(), at: doc.textZone(.title, defaultInset: 19), size: max(24, min(58, doc.titleSize)) * doc.style(.title).safeScale, weight: .heavy, color: ink, fit: true, alignment: doc.style(.title).alignment.native)
                let logoRect = doc.zone(.programBrand)
                if let custom = doc.programLogoData.flatMap({ NSImage(data: $0)?.studioCGImage }) {
                    fill(ctx, logoRect, .white); drawLogo(ctx, custom, in: logoRect.insetBy(dx: 18, dy: 18))
                } else if doc.brandLogoData != nil || doc.brandName != "Clasp Legal" || doc.brandSubtitle != "News" {
                    fill(ctx, logoRect, .white)
                    let logo = doc.brandLogoData.flatMap({ NSImage(data: $0)?.studioCGImage }) ?? brandImage(project)?.studioCGImage
                    if let logo { drawLogo(ctx, logo, in: CGRect(x: logoRect.midX - 25, y: logoRect.midY + 1, width: 50, height: 45), tint: doc.brandLogoData == nil ? ink : nil) }
                    text(doc.brandName, at: CGRect(x: logoRect.minX + 8, y: logoRect.midY - 29, width: logoRect.width - 16, height: 29), size: 23, color: ink, fit: true, alignment: .center)
                    text(doc.brandSubtitle, at: CGRect(x: logoRect.minX + 8, y: logoRect.minY + 9, width: logoRect.width - 16, height: 20), size: 11, color: .gray, fit: true, alignment: .center)
                }
            } else {
                let presenter = doc.zone(.presenter)
                fill(ctx, presenter.insetBy(dx: -1, dy: -1), lower)
                if doc.showPresenter {
                    rounded(ctx, presenter, 12, accent)
                    text(doc.presenter, at: CGRect(x: presenter.minX + 16, y: presenter.minY, width: 128, height: presenter.height), size: 14 * doc.style(.presenter).safeScale, weight: .semibold, color: accent.studioContrastingText, fit: true)
                    text(doc.handle, at: CGRect(x: presenter.minX + 150, y: presenter.minY, width: presenter.width - 166, height: presenter.height), size: 12 * doc.style(.presenter).safeScale, weight: .medium, color: accent.studioContrastingText.withAlphaComponent(0.65), fit: true)
                }
                let titleRect = doc.zone(.title), dateRect = doc.zone(.date)
                fill(ctx, titleRect.insetBy(dx: -1, dy: -1), lower); fill(ctx, dateRect, lower)
                text(doc.title.uppercased(), at: doc.textZone(.title), size: max(24, min(70, doc.titleSize)) * doc.style(.title).safeScale, weight: .heavy, color: lowerInk, fit: true, alignment: doc.style(.title).alignment.native)
                if doc.showDate { text(doc.dateText(in: project.overlayTimeZone), at: dateRect, size: 13, weight: .medium, color: .gray, fit: true) }
                let logoRect = doc.zone(.programBrand)
                fill(ctx, logoRect.insetBy(dx: -1, dy: -6), lower)
                if t == .jai, let texture = OverlayAssets.graphiteTexture { ctx.saveGState(); ctx.clip(to: logoRect); ctx.translateBy(x: logoRect.minX + logoRect.maxX, y: 0); ctx.scaleBy(x: -1, y: 1); ctx.draw(texture, in: logoRect); ctx.restoreGState() }
                if let custom = doc.programLogoData.flatMap({ NSImage(data: $0)?.studioCGImage }) { drawLogo(ctx, custom, in: logoRect.insetBy(dx: 12, dy: 12)) }
                else {
                    let brand = doc.brandLogoData.flatMap({ NSImage(data: $0)?.studioCGImage }) ?? brandImage(project)?.studioCGImage
                    if let brand { drawLogo(ctx, brand, in: CGRect(x: logoRect.minX + 3, y: logoRect.midY - 23, width: 47, height: 46), tint: doc.brandLogoData == nil ? lowerInk : nil) }
                    text(doc.brandName, at: CGRect(x: logoRect.minX + 63, y: logoRect.midY, width: logoRect.width - 64, height: 30), size: 25, weight: .regular, color: lowerInk, fit: true)
                    text(doc.brandSubtitle, at: CGRect(x: logoRect.minX + 63, y: logoRect.midY - 27, width: logoRect.width - 64, height: 27), size: 20, weight: .regular, color: lowerInk, fit: true)
                }
            }
            if doc.showLive {
                let rect = doc.zone(.live)
                rounded(ctx, rect, 10, dark ? NSColor(white: 0.06, alpha: 0.92) : NSColor(studioHex: t == .aiBlue ? "F5FAFF" : "F5F7F8"))
                text(doc.liveLabel, at: CGRect(x: rect.minX + 35, y: rect.minY, width: 51, height: rect.height), size: 15, weight: .bold, color: dark ? .white : ink, fit: true)
                fill(ctx, CGRect(x: rect.minX + 91, y: rect.midY - 9, width: 0.6, height: 18), NSColor.gray.withAlphaComponent(0.5))
                if doc.showDate { text(doc.dateText(in: project.overlayTimeZone, compact: true), at: CGRect(x: rect.minX + 103, y: rect.midY, width: rect.width - 110, height: 16), size: 8.5, color: dark ? .white : .gray, fit: true) }
                text(clockLabels(at: date, timeZoneID: project.overlayTimeZone).time, at: CGRect(x: rect.minX + 103, y: rect.midY - 16, width: rect.width - 110, height: 16), size: 9, color: dark ? .white : .gray)
            }
            if doc.showPresentedBy {
                let rect = doc.zone(.presentedBy)
                rounded(ctx, rect, 10, dark ? NSColor(white: 0.06, alpha: 0.9) : NSColor(studioHex: "F5F7F8"))
                text(doc.presentedBy, at: CGRect(x: rect.minX + 8, y: rect.minY, width: 88, height: rect.height), size: 9, weight: .medium, color: dark ? .white : .gray, fit: true)
                let logo = doc.brandLogoData.flatMap({ NSImage(data: $0)?.studioCGImage }) ?? brandImage(project)?.studioCGImage
                let badge = CGRect(x: rect.minX + 103, y: rect.minY + 8, width: rect.width - 111, height: rect.height - 16)
                rounded(ctx, badge, 6, .white)
                if let logo { drawLogo(ctx, logo, in: CGRect(x: badge.minX + 8, y: badge.minY + 7, width: 19, height: 19), tint: doc.brandLogoData == nil ? .black : nil) }
                text(doc.brandName, at: CGRect(x: badge.minX + 32, y: badge.minY, width: badge.width - 38, height: badge.height), size: 18, weight: .semibold, color: .black, fit: true)
            }
        }
    }
    static func drawLogo(_ ctx: CGContext, _ image: CGImage, in rect: CGRect, tint: NSColor? = nil) {
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        ctx.saveGState()
        if let tint { ctx.clip(to: target, mask: image); ctx.setFillColor(tint.cgColor); ctx.fill(target) }
        else { ctx.draw(image, in: target) }
        ctx.restoreGState()
    }
    static func studio() -> CGImage? {
        image { ctx in
            let colors = [NSColor(white: 0.19, alpha: 1).cgColor, NSColor(white: 0.37, alpha: 1).cgColor, NSColor(white: 0.21, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.6, 1]) { ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1280, y: 720), options: []) }
            fill(ctx, CGRect(x: 945, y: 0, width: 1, height: 720), NSColor.white.withAlphaComponent(0.12))
            fill(ctx, CGRect(x: 986, y: 0, width: 180, height: 720), NSColor.white.withAlphaComponent(0.035))
        }
    }
}
