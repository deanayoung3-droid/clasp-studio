import AppKit
import CoreImage

struct BroadcastReferenceImage: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var png: Data
    static func load(_ url: URL) throws -> Self {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 40 * 1024 * 1024,
              let image = EditStorage.image(url, maxPixels: 1600),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), png.count <= 12 * 1024 * 1024 else { throw StudioError.message("Choose a PNG, JPEG, HEIC or TIFF image under 40 MB.") }
        return Self(name: url.deletingPathExtension().lastPathComponent, png: png)
    }
}
enum ReferenceSide: String, Codable, CaseIterable { case left = "Left", right = "Right" }
struct ReferencePresentation: Codable, Equatable {
    var imageID: UUID
    var visible = true
    var caption = ""
    var side = ReferenceSide.right
    var width = 0.36
    var safeWidth: Double { width.isFinite ? min(0.48, max(0.24, width)) : 0.36 }
}
struct RecordedReferenceCue: Equatable { var time: Double; var presentation: ReferencePresentation? }

enum ReferenceCardGraphics {
    private static let images: NSCache<NSString, NSImage> = { let cache = NSCache<NSString, NSImage>(); cache.countLimit = 16; cache.totalCostLimit = 80 * 1024 * 1024; return cache }()
    static func image(_ asset: BroadcastReferenceImage) -> CGImage? {
        let key = asset.id.uuidString as NSString
        if let image = images.object(forKey: key) { return image.studioCGImage }
        guard let image = NSImage(data: asset.png), let cg = image.studioCGImage else { return nil }
        images.setObject(image, forKey: key, cost: cg.width * cg.height * 4); return cg
    }
    static func rect(_ presentation: ReferencePresentation, camera: CGRect) -> CGRect {
        let width = min(480, max(180, camera.width * presentation.safeWidth))
        let top = camera.maxY - 84, bottom = max(camera.minY + 28, 228)
        let height = min(width * 0.625 + (presentation.caption.isEmpty ? 0 : 42), max(100, top - bottom))
        return CGRect(x: presentation.side == .left ? camera.minX + 28 : camera.maxX - width - 28, y: top - height, width: width, height: height)
    }
    static func artwork(_ project: StudioProject, camera: CGRect) -> CGImage? {
        guard let presentation = project.reference, presentation.visible,
              let asset = project.referenceImages?.first(where: { $0.id == presentation.imageID }), let image = image(asset) else { return nil }
        let card = rect(presentation, camera: camera)
        return BroadcastGraphics.image { ctx in
            let path = CGPath(roundedRect: card, cornerWidth: 12, cornerHeight: 12, transform: nil)
            ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.addPath(path); ctx.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor); ctx.fillPath(); ctx.restoreGState()
            ctx.saveGState(); ctx.addPath(path); ctx.clip()
            let captionHeight: CGFloat = presentation.caption.isEmpty ? 0 : 42
            let picture = CGRect(x: card.minX, y: card.minY + captionHeight, width: card.width, height: card.height - captionHeight)
            // The entire reference stays readable, including portrait documents.
            let scale = min(picture.width / CGFloat(image.width), picture.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            ctx.draw(image, in: CGRect(x: picture.midX - size.width / 2, y: picture.midY - size.height / 2, width: size.width, height: size.height))
            if captionHeight > 0 {
                BroadcastGraphics.fill(ctx, CGRect(x: card.minX, y: card.minY, width: card.width, height: captionHeight), NSColor(white: 0.055, alpha: 1))
                BroadcastGraphics.text(presentation.caption, at: CGRect(x: card.minX + 15, y: card.minY + 4, width: card.width - 30, height: captionHeight - 8), size: 13, weight: .medium, color: .white, fit: true)
            }
            ctx.restoreGState()
            ctx.addPath(path); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        }
    }
}

enum RecordedTimeline {
    static func clips(mediaID: UUID, duration: Double, project: StudioProject, sections: [RecordedSectionCue], references: [RecordedReferenceCue]) -> [EditClip] {
        let candidates = Array(Set([0] + sections.map(\.time) + references.map(\.time))).filter { $0.isFinite && $0 >= 0 && $0 < duration - 1.0 / 30 }.sorted()
        let cuts = candidates.reduce(into: [Double]()) { cuts, time in if cuts.isEmpty || time - cuts.last! >= 1.0 / 30 { cuts.append(time) } }
        return cuts.enumerated().compactMap { index, start in
            let end = index + 1 < cuts.count ? cuts[index + 1] : duration
            guard end - start >= 1.0 / 30 else { return nil }
            let section = sections.last(where: { $0.time <= start })?.section ?? 0
            let reference = references.last(where: { $0.time <= start })
            var clip = EditClip(mediaID: mediaID, start: start, end: end, graphics: project.graphics, mirror: project.mirror, section: section, overlayID: project.selectedOverlayID)
            clip.referenceOverride = true; clip.reference = reference?.presentation ?? (reference == nil ? project.reference : nil)
            return clip
        }
    }
}
