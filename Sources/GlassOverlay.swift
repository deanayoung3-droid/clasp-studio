import AppKit

extension BroadcastGraphics {
    // This supplied SVG is a flattened screenshot. Rebuild its glass panels as
    // semantic native artwork; none of its photograph is shipped in the app.
    static func glassOverlay(_ project: StudioProject, doc: OverlayDocument, activeIndex: Int, at date: Date) -> CGImage? {
        image { ctx in
            func panel(_ rect: CGRect, selected: Bool = false, radius: CGFloat = 14) {
                rounded(ctx, rect, radius, NSColor(white: selected ? 0.6 : 0.08, alpha: selected ? 0.3 : 0.36))
                let path = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil)
                ctx.addPath(path); ctx.setStrokeColor(NSColor.white.withAlphaComponent(selected ? 0.85 : 0.25).cgColor); ctx.setLineWidth(selected ? 1.3 : 0.7); ctx.strokePath()
            }
            let logo = doc.brandLogoData.flatMap { NSImage(data: $0)?.studioCGImage } ?? brandImage(project)?.studioCGImage
            if let logo { drawLogo(ctx, logo, in: CGRect(x: 48, y: 659, width: 29, height: 31), tint: doc.brandLogoData == nil ? .white : nil) }
            fill(ctx, CGRect(x: 90, y: 661, width: 0.7, height: 27), NSColor.white.withAlphaComponent(0.5))
            text(doc.brandName + " " + doc.brandSubtitle, at: CGRect(x: 105, y: 653, width: 480, height: 38), size: 17, weight: .regular, color: .white, fit: true)
            if doc.showLive {
                let rect = doc.zone(.live); panel(rect, radius: 24)
                text(doc.liveLabel, at: CGRect(x: rect.minX + 40, y: rect.minY, width: 51, height: rect.height), size: 15, weight: .bold, color: .white, fit: true)
                fill(ctx, CGRect(x: rect.minX + 98, y: rect.minY + 12, width: 0.6, height: 24), NSColor.white.withAlphaComponent(0.5))
                if doc.showDate { text(doc.dateText(in: project.overlayTimeZone, compact: true), at: CGRect(x: rect.minX + 116, y: rect.midY, width: rect.width - 125, height: 16), size: 10, color: .white.withAlphaComponent(0.85), fit: true) }
                text(clockLabels(at: date, timeZoneID: project.overlayTimeZone).time, at: CGRect(x: rect.minX + 116, y: rect.midY - 16, width: rect.width - 125, height: 16), size: 10, color: .white.withAlphaComponent(0.85), fit: true)
            }
            if doc.showPresentedBy {
                let rect = doc.zone(.presentedBy); panel(rect)
                text(doc.presentedBy, at: CGRect(x: rect.minX + 18, y: rect.minY, width: 112, height: rect.height), size: 10, weight: .medium, color: .white.withAlphaComponent(0.85), fit: true)
                fill(ctx, CGRect(x: rect.minX + 132, y: rect.minY + 14, width: 0.6, height: 24), NSColor.white.withAlphaComponent(0.5))
                if let logo { drawLogo(ctx, logo, in: CGRect(x: rect.minX + 149, y: rect.minY + 15, width: 23, height: 24), tint: doc.brandLogoData == nil ? .white : nil) }
                text(doc.brandName, at: CGRect(x: rect.minX + 180, y: rect.minY, width: rect.width - 194, height: rect.height), size: 23, weight: .semibold, color: .white, fit: true)
            }
            if doc.showHeadlines {
                panel(doc.zone(.headlines), radius: 12)
                text(doc.headlineHeading, at: CGRect(x: 987, y: 642, width: 260, height: 39), size: 20, weight: .bold, color: .white, fit: true)
                let start = min(max(0, activeIndex - 2), max(0, project.sections.count - 5))
                for row in 0..<5 where project.sections.indices.contains(start + row) {
                    let section = project.sections[start + row], current = start + row == activeIndex
                    let rect = CGRect(x: 977, y: 549 - Double(row) * 94, width: 274, height: 78)
                    panel(rect, selected: current, radius: 12)
                    text(String(format: "%02d", start + row + 1), at: CGRect(x: rect.minX + 17, y: rect.minY, width: 36, height: rect.height), size: 16, color: .white.withAlphaComponent(0.8), fit: true)
                    fill(ctx, CGRect(x: rect.minX + 65, y: rect.minY + 16, width: 0.6, height: 45), NSColor.white.withAlphaComponent(0.45))
                    let inset = doc.style(.headlines).safePadding
                    text(section.title, at: CGRect(x: rect.minX + 82 + inset, y: rect.midY, width: rect.width - 97 - inset * 2, height: 30), size: 17 * doc.style(.headlines).safeScale, weight: current ? .semibold : .medium, color: .white, fit: true, alignment: doc.style(.headlines).alignment.native)
                    text(String(section.body.prefix(85)), at: CGRect(x: rect.minX + 82 + inset, y: rect.midY - 25, width: rect.width - 97 - inset * 2, height: 25), size: 11, color: .white.withAlphaComponent(0.55), fit: true)
                }
            }
            panel(CGRect(x: 23, y: 78, width: 927, height: 133), radius: 14)
            fill(ctx, CGRect(x: 289, y: 99, width: 0.7, height: 94), NSColor.white.withAlphaComponent(0.55))
            let brand = doc.zone(.programBrand)
            if let custom = doc.programLogoData.flatMap({ NSImage(data: $0)?.studioCGImage }) { drawLogo(ctx, custom, in: brand.insetBy(dx: 12, dy: 12)) }
            else {
                if let logo { drawLogo(ctx, logo, in: CGRect(x: 43, y: 132, width: 42, height: 43), tint: doc.brandLogoData == nil ? .white : nil) }
                text(doc.brandName, at: CGRect(x: 99, y: 147, width: 167, height: 32), size: 25, color: .white, fit: true)
                text(doc.brandSubtitle, at: CGRect(x: 99, y: 122, width: 167, height: 30), size: 22, color: .white, fit: true)
            }
            if doc.showPresenter {
                let rect = doc.zone(.presenter)
                text(doc.presenter, at: CGRect(x: rect.minX, y: rect.minY, width: 150, height: rect.height), size: 13 * doc.style(.presenter).safeScale, weight: .semibold, color: .white, fit: true)
                fill(ctx, CGRect(x: rect.minX + 156, y: rect.minY + 9, width: 0.6, height: 15), NSColor.white.withAlphaComponent(0.6))
                text(doc.handle, at: CGRect(x: rect.minX + 170, y: rect.minY, width: 265, height: rect.height), size: 13 * doc.style(.presenter).safeScale, color: .white.withAlphaComponent(0.6), fit: true)
            }
            text(doc.title.uppercased(), at: doc.textZone(.title), size: CGFloat(max(24, min(70, doc.titleSize))) * doc.style(.title).safeScale, weight: .heavy, color: .white, fit: true, alignment: doc.style(.title).alignment.native)
            if doc.showDate { text(doc.dateText(in: project.overlayTimeZone), at: doc.zone(.date), size: 12, weight: .medium, color: .white.withAlphaComponent(0.9), fit: true) }
            if doc.showSponsors { panel(CGRect(x: 0, y: -5, width: 1280, height: 66), radius: 16) }
        }
    }
}
