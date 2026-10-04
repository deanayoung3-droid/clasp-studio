import AppKit

// Semantic zones are the contract between the editor and compositor. The camera
// opening and lower-third grid stay fixed; text fits inside its own zone.
enum OverlayComponent: String, CaseIterable, Identifiable, Codable {
    case camera, live, presentedBy, presenter, title, date, programBrand, headlines, sponsors
    var id: String { rawValue }
    var name: String {
        switch self {
        case .camera: return "Camera"
        case .live: return "LIVE & clock"
        case .presentedBy: return "Presented by"
        case .presenter: return "Presenter"
        case .title: return "Episode title"
        case .date: return "Episode date"
        case .programBrand: return "Program brand"
        case .headlines: return "Headlines"
        case .sponsors: return "Sponsor carousel"
        }
    }
    var symbol: String {
        switch self {
        case .camera: return "video"
        case .live: return "dot.radiowaves.left.and.right"
        case .presentedBy: return "seal"
        case .presenter: return "person.text.rectangle"
        case .title: return "textformat.size"
        case .date: return "calendar"
        case .programBrand: return "photo"
        case .headlines: return "list.bullet.rectangle"
        case .sponsors: return "arrow.left.arrow.right"
        }
    }
    var rule: String {
        switch self {
        case .camera: return "The camera fills the template’s photo opening. Its crop and rounded corners are protected."
        case .live, .presentedBy: return "Badges stay inside the top of the camera frame. Switching sides moves the other badge out of the way."
        case .presenter: return "Name and handle share the presenter row. Longer text shrinks to fit each column."
        case .title: return "The title stays in the lower third and shrinks to fit, keeping the camera clear."
        case .date: return "The episode date uses the selected broadcast time zone. The clock uses the current time."
        case .programBrand: return "Logos keep their original proportions and fit inside the reserved brand block."
        case .headlines: return "Cards follow script order. The current section is highlighted; up to five cards remain visible."
        case .sponsors: return "Sponsors loop along the bottom strip. Names, logos and order are shared across designs."
        }
    }
    var supportsTypography: Bool { [.title, .presenter, .headlines].contains(self) }
    func isVisible(in document: OverlayDocument) -> Bool {
        switch self {
        case .camera, .title, .programBrand: return true
        case .live: return document.showLive
        case .presentedBy: return document.showPresentedBy
        case .presenter: return document.showPresenter
        case .date: return document.showDate
        case .headlines: return document.showHeadlines
        case .sponsors: return document.showSponsors
        }
    }
}
enum OverlayTextAlignment: String, CaseIterable, Codable {
    case left = "Left", center = "Center", right = "Right"
    var native: NSTextAlignment { self == .left ? .left : self == .right ? .right : .center }
}
struct OverlayComponentStyle: Codable, Equatable {
    var textScale = 1.0
    var padding = 0.0
    var alignment = OverlayTextAlignment.left
    var rightSide: Bool? = nil
    var safeScale: CGFloat { CGFloat(textScale.isFinite ? min(1.25, max(0.75, textScale)) : 1) }
    var safePadding: CGFloat { CGFloat(padding.isFinite ? min(24, max(0, padding)) : 0) }
}
extension OverlayDocument {
    func style(_ component: OverlayComponent) -> OverlayComponentStyle {
        var style = componentStyles?[component.rawValue] ?? OverlayComponentStyle()
        style.textScale = Double(style.safeScale); style.padding = Double(style.safePadding)
        return style
    }
    mutating func editStyle(_ component: OverlayComponent, _ change: (inout OverlayComponentStyle) -> Void) {
        var styles = componentStyles ?? [:], style = self.style(component)
        change(&style); styles[component.rawValue] = style; componentStyles = styles
    }
    mutating func placeBadge(_ component: OverlayComponent, onRight: Bool) {
        guard component == .live || component == .presentedBy else { return }
        editStyle(component) { $0.rightSide = onRight }
        editStyle(component == .live ? .presentedBy : .live) { $0.rightSide = !onRight }
    }
    func zone(_ component: OverlayComponent) -> CGRect {
        let t = template
        if t == .custom { return component == .camera ? (cameraWindow ?? importedSVG?.cameraForRendering ?? SVGCameraWindow()).rect : CGRect(x: 0, y: 0, width: 1280, height: 720) }
        if t == .ticker {
            switch component {
            case .camera: return t.cameraRect
            case .programBrand: return CGRect(x: 25, y: 97, width: 256, height: 72)
            case .date: return CGRect(x: 25, y: 67, width: 290, height: 22)
            case .headlines, .title: return CGRect(x: 319, y: 94, width: 930, height: 80)
            case .presenter: return CGRect(x: 319, y: 174, width: 930, height: 24)
            case .live: return CGRect(x: style(.live).rightSide == true ? 1000 : 25, y: 635, width: 246, height: 48)
            case .presentedBy: return CGRect(x: style(.presentedBy).rightSide == false ? 25 : 948, y: 635, width: 302, height: 50)
            case .sponsors: return SponsorCarousel.rect
            }
        }
        if t == .glass {
            switch component {
            case .camera: return t.cameraRect
            case .live: return CGRect(x: style(.live).rightSide == true ? 700 : 32, y: 596, width: 246, height: 48)
            case .presentedBy: return CGRect(x: style(.presentedBy).rightSide == false ? 32 : 644, y: 638, width: 302, height: 50)
            case .presenter: return CGRect(x: 333, y: 173, width: 590, height: 32)
            case .title: return CGRect(x: 333, y: 112, width: 591, height: 61)
            case .date: return CGRect(x: 333, y: 85, width: 591, height: 27)
            case .programBrand: return CGRect(x: 35, y: 100, width: 235, height: 117)
            case .headlines: return CGRect(x: 966, y: 155, width: 296, height: 538)
            case .sponsors: return SponsorCarousel.rect
            }
        }
        switch component {
        case .camera: return t.cameraRect
        case .live, .presentedBy:
            let base = component == .live ? t.box(t == .law ? 110.777 : 79.7407, t == .law ? 105 : 76.2666, 458.339, 117) : t.box(t == .law ? 1535.95 : t == .jai ? 1509.8 : 1570.92, t == .law ? 105 : 76.2666, t == .law ? 586.824 : t == .jai ? 581.632 : 520.824, 117)
            let right = style(component).rightSide ?? (component == .presentedBy)
            let margin = t.cameraRect.width * 0.0226
            return CGRect(x: right ? t.cameraRect.maxX - margin - base.width : t.cameraRect.minX + margin, y: base.minY, width: base.width, height: base.height)
        case .presenter: return t == .law ? t.box(523.2, 1285.96, 2439.5, 82.5) : t.box(t == .jai ? 730 : 663, 1258, t == .jai ? 630 : 604, 79)
        case .title: return t == .law ? t.box(523.2, 1368.46, 2238, 191.7) : t.box(t == .jai ? 730 : 663, 1340, t == .jai ? 1425 : 1545, 172)
        case .date: return t == .law ? zone(.title) : t.box(t == .jai ? 730 : 663, 1505, t == .jai ? 1425 : 1550, 59)
        case .programBrand: return t == .law ? t.box(63.0371, 1285.96, 460.17, 274.211) : t == .jai ? t.box(32, 1259, 627, 320) : t.box(56, 1354, 553, 133)
        case .headlines: return t.box(t == .law ? 2203.14 : 2198, t == .law ? 80 : 86, t == .law ? 759.596 : 778, t == .law ? 1174 : 1121)
        case .sponsors: return SponsorCarousel.rect
        }
    }
    func textZone(_ component: OverlayComponent, defaultInset: CGFloat = 0) -> CGRect {
        zone(component).insetBy(dx: defaultInset + style(component).safePadding, dy: 0)
    }
}
