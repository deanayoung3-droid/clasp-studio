import SwiftUI
import AppKit
import CoreImage

extension SVGCameraWindow {
    var contentRect: CGRect {
        let w = min(1, max(0.005, width.isFinite ? width : 1)), h = min(1, max(0.005, height.isFinite ? height : 1))
        let left = min(1 - w, max(0, x.isFinite ? x : 0)), top = min(1 - h, max(0, y.isFinite ? y : 0))
        return CGRect(x: left * 1280, y: (1 - top - h) * 720, width: w * 1280, height: h * 720)
    }
}
extension OverlayComponent {
    static let svgEditable: [OverlayComponent] = [.headlines, .sponsors, .title, .date, .programBrand]
}
extension OverlayDocument {
    func defaultSVGRegion(_ component: OverlayComponent) -> SVGCameraWindow {
        let canvas = importedSVG.map(ImportedSVGGraphics.legacyArtworkRect) ?? CGRect(x: 0, y: 0, width: 1280, height: 720)
        let local: CGRect
        switch component {
        case .headlines, .title: local = CGRect(x: 0.25, y: 0.76, width: 0.72, height: 0.11)
        case .sponsors: local = CGRect(x: 0.02, y: 0.93, width: 0.96, height: 0.06)
        case .date: local = CGRect(x: 0.03, y: 0.87, width: 0.28, height: 0.05)
        default: local = CGRect(x: 0.03, y: 0.76, width: 0.25, height: 0.11)
        }
        return SVGCameraWindow(x: Double((canvas.minX + local.minX * canvas.width) / 1280), y: Double((720 - canvas.maxY + local.minY * canvas.height) / 720), width: Double(local.width * canvas.width / 1280), height: max(0.005, Double(local.height * canvas.height / 720)))
    }
}
extension StudioModel {
    func restoreSVGOverlay(_ previous: OverlayDocument) {
        guard let index = project.overlayLibrary?.firstIndex(where: { $0.id == previous.id }) else { return }
        project.overlayLibrary?[index] = previous
    }
    func setSVGRegion(_ component: OverlayComponent, _ region: SVGCameraWindow?) {
        guard !importingSVG, !busy, overlay.template == .custom else { return }
        let previous = overlay
        editOverlay { doc in
            var regions = doc.svgRegions ?? [:]
            regions[component.rawValue] = region
            // A single region shows either the script headline or the episode title.
            if region != nil, component == .headlines { regions.removeValue(forKey: OverlayComponent.title.rawValue); doc.showHeadlines = true }
            if region != nil, component == .title { regions.removeValue(forKey: OverlayComponent.headlines.rawValue) }
            if region != nil, component == .sponsors { doc.showSponsors = true }
            if region != nil, component == .date { doc.showDate = true }
            doc.svgRegions = regions
        }
        refreshImportedSVG(onFailure: { [weak self] in self?.restoreSVGOverlay(previous) })
    }
}
enum ImportedSVGEditableGraphics {
    static func apply(to settings: inout RenderSettings, project: StudioProject, doc: OverlayDocument, activeIndex: Int, previousSection: Int?, tickerEpoch: Double?, epoch: Double) {
        guard let regions = doc.svgRegions, !regions.isEmpty else { return }
        let original = settings.overlay
        settings.overlay = BroadcastGraphics.image { ctx in
            if let original { ctx.draw(original, in: CGRect(x: 0, y: 0, width: 1280, height: 720)) }
            if let region = regions[OverlayComponent.title.rawValue] {
                BroadcastGraphics.text(doc.title, at: region.contentRect, size: CGFloat(doc.titleSize) * doc.style(.title).safeScale, color: NSColor(studioHex: doc.accentHex), fit: true, alignment: doc.style(.title).alignment.native)
            }
            if let region = regions[OverlayComponent.date.rawValue], doc.showDate { BroadcastGraphics.text(doc.dateText(in: project.overlayTimeZone, compact: true), at: region.contentRect, size: min(18, region.contentRect.height * 0.5), color: NSColor(studioHex: doc.accentHex), fit: true) }
            if let region = regions[OverlayComponent.programBrand.rawValue] { BroadcastGraphics.networkBrand(ctx, project: project, doc: doc, in: region.contentRect) }
        }
        let sponsors = regions[OverlayComponent.sponsors.rawValue].flatMap { doc.showSponsors ? SponsorCarousel(items: SponsorCatalog.migrated(project), destination: $0.contentRect) : nil }
        let motionAllowed = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var animation = BroadcastAnimation(sponsors: sponsors, sponsorSpeed: project.carouselSpeed ?? 32, sponsorMoving: project.carouselMoving != false && motionAllowed, liveDot: nil, pulseLive: false, epoch: epoch)
        if let region = regions[OverlayComponent.headlines.rawValue], doc.showHeadlines {
            let current = project.sections.indices.contains(activeIndex) ? project.sections[activeIndex].title : doc.title
            let previous = previousSection.flatMap { project.sections.indices.contains($0) ? project.sections[$0].title : nil }
            animation.headlineTicker = HeadlineTicker(current: current, previous: motionAllowed ? previous : nil, zone: region.contentRect, style: doc.style(.headlines), epoch: tickerEpoch ?? -1_000_000, color: NSColor(studioHex: doc.accentHex))
        }
        settings.animation = animation
    }
}

struct SVGRegionControls: View {
    @ObservedObject var model: StudioModel
    var component: OverlayComponent
    private var region: SVGCameraWindow? { model.overlay.svgRegions?[component.rawValue] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let region {
                Label("Editable on this SVG", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                Text("Drag a box around the original \(component == .sponsors ? "sponsor strip" : "content") on the preview to place it precisely. The original background stays in place.").foregroundStyle(.secondary).lineSpacing(3)
                HStack { Text("Position"); Spacer(); Text("\(Int(region.x * 100))%, \(Int(region.y * 100))%") }.monospacedDigit()
                HStack { Text("Size"); Spacer(); Text("\(Int(region.width * 100))% × \(Int(region.height * 100))%") }.monospacedDigit()
                DisclosureGroup("Precise placement") { SVGPlacementFields(model: model, component: component, region: region).id(component.rawValue + String(describing: region)) }
                Button("Restore original SVG content") { model.setSVGRegion(component, nil) }
            } else {
                Text("This content is baked into your SVG. Make it editable, then draw a box around its original position in the preview.").foregroundStyle(.secondary).lineSpacing(3)
                Button("Make \(component == .sponsors ? "sponsors" : component == .headlines ? "headlines" : component.name.lowercased()) editable") { model.setSVGRegion(component, model.overlay.defaultSVGRegion(component)) }
            }
            if model.importingSVG { ProgressView("Updating artwork…").controlSize(.small) }
        }.font(.system(size: 11)).controlSize(.small).disabled(model.importingSVG || model.busy)
    }
}

struct SVGPlacementFields: View {
    @ObservedObject var model: StudioModel
    var component: OverlayComponent
    @State private var draft: SVGCameraWindow
    init(model: StudioModel, component: OverlayComponent, region: SVGCameraWindow) {
        self.model = model; self.component = component; _draft = State(initialValue: region)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { field("Left %", \.x); field("Top %", \.y) }
            HStack { field("Width %", \.width); field("Height %", \.height) }
            Button("Apply placement") {
                let rect = draft.contentRect
                model.setSVGRegion(component, SVGCameraWindow(x: Double(rect.minX / 1280), y: Double((720 - rect.maxY) / 720), width: Double(rect.width / 1280), height: Double(rect.height / 720)))
            }
        }.padding(.top, 8)
    }
    private func field(_ label: String, _ key: WritableKeyPath<SVGCameraWindow, Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, value: Binding(get: { draft[keyPath: key] * 100 }, set: { draft[keyPath: key] = $0 / 100 }), format: .number.precision(.fractionLength(1))).textFieldStyle(.roundedBorder)
        }
    }
}
