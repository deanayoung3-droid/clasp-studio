import SwiftUI
import AppKit

struct OverlayComponentEditor: View {
    @ObservedObject var model: StudioModel
    var preview: NSImage?
    @Binding var selected: OverlayComponent
    var inspectorOnly = false
    private func value<T>(_ key: WritableKeyPath<OverlayDocument, T>) -> Binding<T> {
        Binding(get: { model.overlay[keyPath: key] }, set: { new in model.editOverlay { $0[keyPath: key] = new } })
    }
    private func style<T>(_ key: WritableKeyPath<OverlayComponentStyle, T>) -> Binding<T> {
        Binding(get: { model.overlay.style(selected)[keyPath: key] }, set: { new in model.editOverlay { $0.editStyle(selected) { $0[keyPath: key] = new } } })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inspector
                if selected.supportsTypography {
                    Divider()
                    Text("Typography").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack { Text("Scale"); Slider(value: style(\.textScale), in: 0.75...1.25, step: 0.05); Text("\(Int(model.overlay.style(selected).textScale * 100))%").monospacedDigit().frame(width: 36) }
                    if selected != .presenter {
                        Picker("Alignment", selection: style(\.alignment)) { ForEach(OverlayTextAlignment.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                        HStack { Text("Inset"); Slider(value: style(\.padding), in: 0...24, step: 1) }
                    }
                    Button("Reset text style") { model.editOverlay { $0.editStyle(selected) { $0.textScale = 1; $0.padding = 0; $0.alignment = .left } } }.controlSize(.small)
                }
                Text(model.overlay.template == .ticker && selected == .headlines ? "The current script heading scrolls upward beside the SVG brand. Edit the headings below or hide them to show the episode title." : selected.rule).font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
            }.font(.system(size: 11)).padding(17).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var canvas: some View {
        GeometryReader { geometry in
            let output = model.outputRect
            let scale = geometry.size.width / output.width
            ZStack(alignment: .topLeading) {
                if let preview { Image(nsImage: preview).resizable().scaledToFit() }
                else { Rectangle().fill(Color(white: 0.14)) }
                ForEach(OverlayComponent.allCases.filter { !(model.overlay.template == .law && $0 == .date) }) { component in
                    let region = model.overlay.zone(component).intersection(output)
                let rect = region.isNull ? CGRect.zero : region
                    Button { selected = component } label: {
                        Rectangle().fill(Color.white.opacity(0.001))
                    }.buttonStyle(.plain)
                        .frame(width: rect.width * scale, height: rect.height * scale)
                        .position(x: (rect.midX - output.minX) * scale, y: (output.maxY - rect.midY) * scale)
                        .accessibilityLabel("Edit \(component.name)")
                }
                let region = model.overlay.zone(selected).intersection(output)
                let rect = region.isNull ? CGRect.zero : region
                RoundedRectangle(cornerRadius: selected == .camera ? 7 : 3)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .shadow(color: .black.opacity(0.8), radius: 1)
                    .frame(width: rect.width * scale, height: rect.height * scale)
                    .position(x: (rect.midX - output.minX) * scale, y: (output.maxY - rect.midY) * scale).allowsHitTesting(false)
            }.clipShape(RoundedRectangle(cornerRadius: 7))
        }.aspectRatio(model.outputAspectRatio, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.12)))
            .accessibilityLabel("Overlay component canvas. Uses a sample camera image.")
    }
    @ViewBuilder private var inspector: some View {
        switch selected {
        case .camera:
            Toggle("Mirror camera", isOn: Binding(get: { model.project.mirror }, set: { model.project.mirror = $0 })).toggleStyle(.checkbox)
            Label("Live feed replaces the supplied photograph", systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Choose your camera in the studio device controls. Use the macOS camera menu for Apple video effects.").font(.system(size: 11)).foregroundStyle(.secondary)
        case .title:
            input("Episode title", value(\.title))
            if model.overlay.template == .ticker { Text("Script headlines replace this title while Show headlines is enabled.").font(.system(size: 11)).foregroundStyle(.secondary) }
            HStack { Text("Base size"); Slider(value: value(\.titleSize), in: 24...70, step: 1); Text("\(Int(model.overlay.titleSize))").monospacedDigit() }
        case .presenter:
            Toggle("Show presenter", isOn: value(\.showPresenter)).toggleStyle(.checkbox)
            input("Name", value(\.presenter)); input("Handle", value(\.handle))
        case .date:
            Toggle("Show date", isOn: value(\.showDate)).toggleStyle(.checkbox)
            DatePicker("Episode date", selection: value(\.date), displayedComponents: .date).datePickerStyle(.field)
            zonePicker
        case .live:
            Toggle("Show LIVE & clock", isOn: value(\.showLive)).toggleStyle(.checkbox)
            input("Label", value(\.liveLabel))
            Toggle("Pulse indicator", isOn: value(\.pulseLive)).toggleStyle(.checkbox)
            ColorPicker("Indicator", selection: Binding(get: { Color(nsColor: NSColor(studioHex: model.overlay.liveDotHex)) }, set: { color in model.editOverlay { $0.liveDotHex = NSColor(color).studioHex } }), supportsOpacity: false)
            badgePlacement
            zonePicker
        case .presentedBy:
            Toggle("Show badge", isOn: value(\.showPresentedBy)).toggleStyle(.checkbox)
            input("Label", value(\.presentedBy)); input("Brand", value(\.brandName))
            logo(program: false)
            badgePlacement
        case .programBrand:
            input("Brand", value(\.brandName)); input("Subtitle", value(\.brandSubtitle))
            logo(program: true)
            logo(program: false)
        case .headlines:
            if model.overlay.template == .glass {
                Text("Frosted panels").font(.system(size: 12, weight: .medium))
                HStack { Text("Blur"); Slider(value: Binding(get: { model.overlay.frostRadius ?? 22 }, set: { value in model.editOverlay { $0.frostRadius = value } }), in: 0...40) }
                HStack { Text("Tint"); Slider(value: Binding(get: { model.overlay.frostOpacity ?? 0.55 }, set: { value in model.editOverlay { $0.frostOpacity = value } }), in: 0.15...0.9) }
            }
            if model.overlay.template == .ticker { Text("One headline scrolls upward as the script changes sections.").font(.system(size: 11)).foregroundStyle(.secondary) }
            Toggle("Show headlines", isOn: value(\.showHeadlines)).toggleStyle(.checkbox)
            if model.overlay.template != .ticker { input("Panel heading", value(\.headlineHeading)) }
            ColorPicker(model.overlay.template == .ticker ? "Headline color" : "Active card", selection: Binding(get: { Color(nsColor: NSColor(studioHex: model.overlay.accentHex)) }, set: { color in model.editOverlay { $0.accentHex = NSColor(color).studioHex } }), supportsOpacity: false)
            ForEach(model.project.sections) { section in
                input(section.id == model.section?.id ? "Current section" : "Headline", Binding(get: { model.project.sections.first(where: { $0.id == section.id })?.title ?? "" }, set: { title in if let index = model.project.sections.firstIndex(where: { $0.id == section.id }) { model.project.sections[index].title = title } }))
            }
        case .sponsors:
            Toggle("Show sponsors", isOn: value(\.showSponsors)).toggleStyle(.checkbox)
            Toggle("Scroll continuously", isOn: Binding(get: { model.project.carouselMoving != false }, set: { model.project.carouselMoving = $0 })).toggleStyle(.checkbox)
            HStack { Text("Speed"); Slider(value: Binding(get: { model.project.carouselSpeed ?? 32 }, set: { model.project.carouselSpeed = $0 }), in: 10...100, step: 1) }
            Text("Use the Sponsors tab to replace logos, rename sponsors and reorder the carousel.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var badgePlacement: some View {
        Picker("Position", selection: Binding(get: { model.overlay.style(selected).rightSide ?? (selected == .presentedBy) }, set: { right in model.editOverlay { $0.placeBadge(selected, onRight: right) } })) {
            Text("Top left").tag(false); Text("Top right").tag(true)
        }.pickerStyle(.segmented)
    }
    private var zonePicker: some View {
        Picker("Time zone", selection: Binding(get: { model.project.overlayTimeZone ?? "America/Los_Angeles" }, set: { model.project.overlayTimeZone = $0 })) {
            Text("Pacific").tag("America/Los_Angeles"); Text("Eastern").tag("America/New_York"); Text("Central").tag("America/Chicago"); Text("Mountain").tag("America/Denver"); Text("UTC").tag("UTC")
        }
    }
    private func input(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(label).font(.system(size: 10)).foregroundStyle(.secondary); TextField(label, text: text).textFieldStyle(.roundedBorder) }
    }
    private func logo(program: Bool) -> some View {
        let data = program ? model.overlay.programLogoData : model.overlay.brandLogoData
        return VStack(alignment: .leading, spacing: 8) {
            Text(program ? "Program logo" : "Brand logo").font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                if let image = data.flatMap(NSImage.init(data:)) { Image(nsImage: image).resizable().scaledToFit().frame(width: 45, height: 34) }
                Button("Replace…") { model.replaceOverlayLogo(program: program) }
                if data != nil { Button("Reset") { model.editOverlay { if program { $0.programLogoData = nil } else { $0.brandLogoData = nil } } } }
            }.controlSize(.small)
        }
    }
}
