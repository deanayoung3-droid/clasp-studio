import AppKit
import CoreImage

// Each library entry owns its text, date, visibility and branding. Switching
// designs never discards edits to the other entries.
enum OverlayTemplate: String, Codable, CaseIterable {
    case law = "Law", ai = "AI", aiBlue = "AIBlue", jai = "JAI", glass = "Glass"
    var name: String { switch self { case .law: return "Law · Classic"; case .ai: return "AI · Editorial"; case .aiBlue: return "AI · Blue"; case .jai: return "AI · Graphite"; case .glass: return "Law · Glass" } }
    var dark: Bool { self == .law }
    var sourceWidth: CGFloat { self == .glass ? 3034 : self == .law ? 3026 : 3008 }
    func box(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: x * 1280 / sourceWidth, y: 720 - (top + height) * 720 / (self == .glass ? 1708 : 1702), width: width * 1280 / sourceWidth, height: height * 720 / (self == .glass ? 1708 : 1702))
    }
    var cameraRect: CGRect { self == .glass ? CGRect(x: 0, y: 0, width: 1280, height: 720) : self == .law ? box(63.0371, 56.7334, 2111.74, 1197.7) : box(32, 28, 2111.74, 1197.7) }
    var artwork: CGImage? { OverlayAssets.images[rawValue] }
}
enum OverlayAssets {
    static let graphiteTexture: CGImage? = Bundle.main.url(forResource: "JAITexture", withExtension: "jpg").flatMap { NSImage(contentsOf: $0)?.studioCGImage }
    static let images: [String: CGImage] = Dictionary(uniqueKeysWithValues: OverlayTemplate.allCases.compactMap { template in
        let resource = Bundle.main.url(forResource: template.rawValue + "Overlay", withExtension: "png").flatMap { NSImage(contentsOf: $0)?.studioCGImage }
        return (resource ?? (template == .jai ? graphiteArtwork() : template == .glass ? BroadcastGraphics.image { _ in } : nil)).map { (template.rawValue, $0) }
    })
    // The supplied Graphite SVG contains vector cards, a textured brand tile and
    // a photo. Recreate the structural shapes natively; text and badges are live
    // semantic components, and the photograph never enters the shipped artwork.
    private static func graphiteArtwork() -> CGImage? {
        let t = OverlayTemplate.jai
        return BroadcastGraphics.image { ctx in
            BroadcastGraphics.fill(ctx, CGRect(x: 0, y: 0, width: 1280, height: 720), NSColor(studioHex: "E1E1E1"))
            let lower = t.box(32, 1258, 2944, 322)
            ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.12).cgColor)
            BroadcastGraphics.rounded(ctx, lower, 14.4, NSColor(studioHex: "111318")); ctx.restoreGState()
            BroadcastGraphics.fill(ctx, t.box(688, 1324, 2, 214), NSColor(studioHex: "D8C7B6"))
            let camera = t.cameraRect
            ctx.setBlendMode(.clear); ctx.addPath(CGPath(roundedRect: camera, cornerWidth: 14.4, cornerHeight: 14.4, transform: nil)); ctx.fillPath()
        }
    }
}
struct OverlayDocument: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var template: OverlayTemplate
    var title: String
    var presenter: String
    var handle: String
    var date: Date
    var headlineHeading: String
    var brandName: String
    var brandSubtitle: String
    var presentedBy = "PRESENTED BY"
    var liveLabel = "LIVE"
    var accentHex: String
    var liveDotHex: String
    var titleSize: Double
    var showDate = true
    var showPresenter = true
    var showHeadlines = true
    var showLive = true
    var pulseLive = true
    var showPresentedBy = true
    var showSponsors = true
    var brandLogoData: Data?
    var programLogoData: Data?
    var componentStyles: [String: OverlayComponentStyle]?
    static func presets(_ project: StudioProject) -> [OverlayDocument] {
        let date = ISO8601DateFormatter().date(from: "2026-10-02T12:00:00-07:00")!
        return OverlayTemplate.allCases.map { template in
            OverlayDocument(name: template.name, template: template, title: (template == .law || template == .glass) ? (project.broadcastHeadline ?? project.showTitle).components(separatedBy: " - ").first! : "THIS WEEK IN AI", presenter: project.presenter, handle: project.handle, date: date, headlineHeading: template == .glass ? "LEGAL HEADLINES" : template == .law ? "TWIL HEADLINES" : "AI HEADLINES", brandName: (template == .law || template == .glass) ? "Clasp Legal" : "Clasp", brandSubtitle: template == .glass ? "News Network" : template == .law ? "News" : "AI News", accentHex: template == .glass ? "FFFFFF" : template == .law ? "4376B9" : template == .ai ? "D5F4ED" : template == .jai ? "111318" : "E4EEFF", liveDotHex: (template == .law || template == .glass) ? "FF343B" : template == .ai ? "85CD90" : template == .jai ? "6B47F5" : "1CCAE3", titleSize: template == .law ? 44 : 60)
        }
    }
    func dateText(in timeZone: String?, compact: Bool = false) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: timeZone ?? "America/Los_Angeles")
        formatter.dateFormat = compact ? "EEE, MMM d, yyyy" : "EEEE, MMM d, yyyy"
        return formatter.string(from: date).uppercased()
    }
}
extension NSColor {
    convenience init(studioHex: String) {
        let raw = studioHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(raw, radix: 16) ?? 0x4376B9
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    var studioHex: String {
        let rgb = usingColorSpace(.deviceRGB) ?? self
        return String(format: "%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
    var studioContrastingText: NSColor { let rgb = usingColorSpace(.deviceRGB) ?? self; return rgb.redComponent * 0.299 + rgb.greenComponent * 0.587 + rgb.blueComponent * 0.114 > 0.62 ? NSColor(white: 0.06, alpha: 1) : .white }
}

struct BroadcastAnimation: @unchecked Sendable {
    var sponsors: SponsorCarousel?
    var sponsorSpeed: Double
    var sponsorMoving: Bool
    var liveDot: CIImage?
    var pulseLive: Bool
    var epoch: Double
    func frame(at time: Double) -> CIImage? {
        let elapsed = max(0, time - epoch)
        var result = sponsors?.frame(at: sponsorMoving ? elapsed : 0, speed: sponsorSpeed)
        if let liveDot {
            let alpha = pulseLive ? 0.45 + 0.55 * (sin(elapsed * .pi * 2 / 1.6) + 1) / 2 : 1
            let pulsed = liveDot.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
            result = result.map { pulsed.composited(over: $0) } ?? pulsed
        }
        return result
    }
}
// Cached Core Image layers are shared by the preview and movie writer. Only
// translations and pulse opacity change per frame; no typography is rerasterized.
struct BroadcastFrameRenderer: @unchecked Sendable {
    let settings: RenderSettings
    private let overlay: CIImage?
    private let mask: CIImage?
    init(_ settings: RenderSettings) {
        self.settings = settings; overlay = settings.overlay.map(CIImage.init(cgImage:))
        mask = settings.cameraMask.map(CIImage.init(cgImage:))
    }
    func compose(_ source: CIImage, at time: Double = ProcessInfo.processInfo.systemUptime) -> CIImage {
        let rect = settings.cameraRect
        var camera = Self.fit(source, to: rect)
        if settings.mirror { camera = camera.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0)) }
        return composePreparedCamera(camera, at: time)
    }
    func composePreparedCamera(_ prepared: CIImage, at time: Double) -> CIImage {
        var camera = prepared
        if let mask { camera = camera.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720)), kCIInputMaskImageKey: mask]) }
        var frame = overlay.map { $0.composited(over: camera) } ?? camera
        if let moving = settings.animation?.frame(at: time) { frame = moving.composited(over: frame) }
        return frame.cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
    }
    static func fit(_ image: CIImage, to rect: CGRect) -> CIImage {
        let extent = image.extent, scale = max(rect.width / image.extent.width, rect.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(translationX: rect.midX - scaled.extent.midX, y: rect.midY - scaled.extent.midY)).cropped(to: rect)
    }
}
