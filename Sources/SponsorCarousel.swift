import AppKit
import CoreImage

struct SponsorItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var logoData: Data?
    var artwork: String?
    var enabled = true
    var showName = true
}
enum SponsorCatalog {
    static let names = ["Microsoft": "Microsoft 365", "Confido": "Confido Legal", "Citizens": "Citizens Private Bank", "Crabtree": "Crabtree Law, PC"]
    static let assets: [String: CGImage] = Dictionary(uniqueKeysWithValues: names.keys.flatMap { key in ["Logo", "Icon"].compactMap { suffix in
        let name = "Sponsor" + key + suffix
        return Bundle.main.url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0)?.studioCGImage }.map { (key + suffix, $0) }
    } })
    static func defaults() -> [SponsorItem] { ["Microsoft", "Confido", "Citizens", "Crabtree"].map { SponsorItem(name: names[$0]!, artwork: $0, showName: false) } }
    static func migrated(_ project: StudioProject) -> [SponsorItem] {
        if let items = project.sponsorItems { return items }
        if project.useTemplateSponsors != false { return defaults() }
        let names = project.sponsorNames ?? ["Filevine", "Dropbox"]
        var result = names.map { name in SponsorItem(name: name, logoData: project.logos.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.enabled })?.data) }
        result += project.logos.filter { logo in !names.contains(where: { $0.caseInsensitiveCompare(logo.name) == .orderedSame }) }.map { SponsorItem(name: $0.name, logoData: $0.data, enabled: $0.enabled) }
        return Array(result.prefix(12))
    }
    static func logo(_ item: SponsorItem) -> CGImage? {
        if let data = item.logoData { return NSImage(data: data)?.studioCGImage }
        return item.artwork.flatMap { assets[$0 + (item.showName ? "Icon" : "Logo")] }
    }
}
struct SponsorCarousel: @unchecked Sendable {
    static let rect = CGRect(x: 0, y: 0, width: 1280, height: 46)
    let image: CIImage
    let period: CGFloat
    let count: Int
    let destination: CGRect
    init?(items: [SponsorItem], monochrome: Bool = false, destination: CGRect = SponsorCarousel.rect) {
        self.destination = destination
        let visible = items.filter { $0.enabled && (!$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || SponsorCatalog.logo($0) != nil) }
        guard !visible.isEmpty else { return nil }
        let cells = visible.map { item -> (SponsorItem, CGImage?, CGFloat) in
            let logo = SponsorCatalog.logo(item)
            let nameWidth = item.showName || logo == nil ? (item.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .medium)]).width : 0
            let logoWidth = logo.map { min(180, CGFloat($0.width) / CGFloat($0.height) * 27) } ?? 0
            return (item, logo, min(370, max(170, logoWidth + nameWidth + (logo != nil && nameWidth > 0 ? 12 : 0) + 86)))
        }
        period = ceil(cells.reduce(0) { $0 + $1.2 }); count = visible.count
        guard let cg = BroadcastGraphics.bitmap(width: Int(period), height: 46, { ctx in
            var x: CGFloat = 0
            for (item, logo, width) in cells {
                let content = CGRect(x: x + 43, y: 7, width: width - 86, height: 32)
                if let logo {
                    let logoWidth = min(item.showName ? 35 : content.width, CGFloat(logo.width) / CGFloat(logo.height) * 27)
                    BroadcastGraphics.drawLogo(ctx, logo, in: CGRect(x: content.minX, y: 9, width: logoWidth, height: 27), tint: monochrome ? .white : nil)
                    if item.showName { BroadcastGraphics.text(item.name, at: CGRect(x: content.minX + logoWidth + 12, y: 7, width: max(1, content.width - logoWidth - 12), height: 32), size: 18, weight: .medium, fit: true) }
                } else { BroadcastGraphics.text(item.name, at: content, size: 18, weight: .medium, fit: true) }
                x += width
            }
        }) else { return nil }
        image = CIImage(cgImage: cg)
    }
    func offset(at elapsed: Double, speed: Double) -> CGFloat {
        let position = max(0, elapsed) * max(0, min(120, speed))
        return CGFloat(position.truncatingRemainder(dividingBy: Double(period)))
    }
    func frame(at elapsed: Double, speed: Double) -> CIImage {
        let tiled = image.applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: NSAffineTransform()])
        let scale = destination.height / Self.rect.height
        return tiled.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).transformed(by: CGAffineTransform(translationX: destination.minX - offset(at: elapsed, speed: speed), y: destination.minY)).cropped(to: destination)
    }
}
