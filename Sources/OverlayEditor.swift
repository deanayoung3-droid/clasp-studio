import SwiftUI
import AppKit
import CoreImage

struct OverlayEditor: View {
    @ObservedObject var model: StudioModel
    @State private var tab: String
    @State private var selected = OverlayComponent.title
    @State private var browser = "Layers"
    @State private var thumbnails: [UUID: NSImage] = [:]
    @State private var canvasPreview: NSImage?
    @State private var refreshTask: Task<Void, Never>?
    private let previewContext = CIContext()
    init(model: StudioModel, initialTab: String) { self.model = model; _tab = State(initialValue: initialTab == "Library" ? "Components" : initialTab) }
    private func value<T>(_ key: WritableKeyPath<OverlayDocument, T>) -> Binding<T> { Binding(get: { model.overlay[keyPath: key] }, set: { new in model.editOverlay { $0[keyPath: key] = new } }) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "square.3.layers.3d").foregroundStyle(.secondary)
                TextField("Overlay name", text: value(\.name)).font(.system(size: 13, weight: .medium)).textFieldStyle(.plain).frame(maxWidth: 370)
                Spacer()
                Button { model.importSVGOverlay() } label: { Label(model.importingSVG ? "Rendering…" : "Import SVG", systemImage: "plus") }.disabled(model.importingSVG || model.busy).controlSize(.small)
                Text("Changes save automatically").font(.system(size: 10)).foregroundStyle(.secondary)
                Menu { Button("Episode details") { tab = "Content" }; Button("Branding") { tab = "Branding" }; Button("Sponsors") { tab = "Sponsors" }; Divider(); Button("Duplicate design") { model.duplicateOverlay() } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                Button("Done") { model.overlayEditorOpen = false }.keyboardShortcut(.defaultAction).font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 7).background(.white).foregroundStyle(.black).clipShape(RoundedRectangle(cornerRadius: 6)).buttonStyle(.plain)
            }.padding(.horizontal, 16).frame(height: 52).background(Color(white: 0.06))
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 5) { ForEach(["Layers", "Designs"], id: \.self) { name in Button { browser = name } label: { Text(name).font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6).background(browser == name ? Color.white.opacity(0.08) : .clear).clipShape(RoundedRectangle(cornerRadius: 5)) } }; Spacer(minLength: 0) }.buttonStyle(.plain).padding(10)
                    Divider().overlay(Color.white.opacity(0.08))
                    if browser == "Designs" { library }
                    else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Image(systemName: "chevron.down").font(.system(size: 9)); Image(systemName: "rectangle.on.rectangle"); Text("Broadcast").fontWeight(.medium) }.padding(10)
                                ForEach(model.overlay.template == .custom ? [OverlayComponent.camera, .programBrand] : OverlayComponent.allCases) { component in
                                    Button { selected = component; tab = component == .sponsors ? "Sponsors" : "Components" } label: {
                                        HStack(spacing: 9) { Image(systemName: component.symbol).frame(width: 16).foregroundStyle(selected == component ? Color(red: 0.04, green: 0.61, blue: 0.96) : .secondary); Text(model.overlay.template == .custom && component == .programBrand ? "SVG artwork" : component.name).lineLimit(1); Spacer(minLength: 0); if !component.isVisible(in: model.overlay) { Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(.secondary) } }.padding(.leading, 21).padding(.trailing, 10).frame(height: 35).background(selected == component ? Color.white.opacity(0.07) : .clear).clipShape(RoundedRectangle(cornerRadius: 4))
                                    }.buttonStyle(.plain)
                                }
                            }.font(.system(size: 11)).padding(7)
                        }
                    }
                    Spacer(minLength: 0)
                    Text("Select a layer or click the canvas.").font(.system(size: 10)).foregroundStyle(.secondary).padding(13)
                }.frame(width: 195).background(Color(white: 0.06))
                Divider().overlay(Color.white.opacity(0.08))
                VStack(spacing: 0) {
                    HStack { Text("Canvas"); Spacer(); Text(model.outputDimensions).foregroundStyle(.secondary) }.font(.system(size: 10)).padding(.horizontal, 16).frame(height: 31)
                    Spacer(minLength: 12)
                    componentCanvas.padding(.horizontal, 16)
                    Spacer(minLength: 15)
                    HStack(spacing: 4) {
                        componentTool("Select", "cursorarrow", .camera)
                        if model.overlay.template == .custom { componentTool("SVG artwork", "photo", .programBrand) }
                        else {
                        componentTool("Title", "textformat", .title)
                        componentTool("LIVE", "dot.radiowaves.left.and.right", .live)
                        componentTool("Logo", "photo", .programBrand)
                        componentTool("Topics", "list.bullet.rectangle", .headlines)
                        componentTool("Sponsors", "arrow.left.arrow.right", .sponsors)
                        }
                    }.padding(6).background(Color(white: 0.15)).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08)))
                    Text("Click text or graphics to edit · Sample camera picture").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 14).padding(.bottom, 20)
                }.frame(maxWidth: .infinity).background(Color(white: 0.105))
                Divider().overlay(Color.white.opacity(0.08))
                VStack(spacing: 0) {
                    HStack { Text(model.overlay.template == .custom ? "Imported SVG" : tab == "Components" ? selected.name : tab).font(.system(size: 12, weight: .medium)); Spacer() }.padding(16).frame(height: 46)
                    Divider().overlay(Color.white.opacity(0.08))
                    if model.overlay.template == .custom { ImportedSVGInspector(model: model) }
                    else if tab == "Components" { OverlayComponentEditor(model: model, preview: canvasPreview, selected: $selected, inspectorOnly: true) }
                    else { ScrollView { Group { if tab == "Content" { content } else if tab == "Branding" { branding } else { sponsors } }.padding(16).frame(maxWidth: .infinity, alignment: .leading) } }
                }.frame(width: 265).background(Color(white: 0.06))
            }.frame(maxHeight: .infinity)
        }.frame(width: 1180, height: 780).background(Color(white: 0.075)).foregroundStyle(.white).preferredColorScheme(.dark)
        .onAppear { refreshThumbnails() }
        .onDisappear { refreshTask?.cancel() }
        .onChange(of: model.project.selectedOverlayID) { if model.overlay.template == .custom { selected = .camera; tab = "Components" }; scheduleRefresh() }
        .onChange(of: model.project.overlayLibrary) { scheduleRefresh() }
        .onChange(of: model.project.sections) { scheduleRefresh() }
        .onChange(of: model.project.sponsorItems) { scheduleRefresh() }
        .onChange(of: model.project.mirror) { scheduleRefresh() }
        .onChange(of: model.project.overlayTimeZone) { scheduleRefresh() }
    }
    private func componentTool(_ name: String, _ symbol: String, _ component: OverlayComponent) -> some View {
        Button { selected = component; tab = component == .sponsors ? "Sponsors" : "Components" } label: { Image(systemName: symbol).font(.system(size: 15)).frame(width: 35, height: 32).background(selected == component ? Color(red: 0.04, green: 0.61, blue: 0.96) : .clear).clipShape(RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain).help(name).accessibilityLabel(name)
    }
    private var componentCanvas: some View {
        GeometryReader { geometry in
            let output = model.outputRect
            let scale = geometry.size.width / output.width
            ZStack(alignment: .topLeading) {
                if let preview = canvasPreview { Image(nsImage: preview).resizable().scaledToFit() }
                else { Color(white: 0.14) }
                ForEach((model.overlay.template == .custom ? [OverlayComponent.camera] : OverlayComponent.allCases).filter { !(model.overlay.template == .law && $0 == .date) }) { component in
                    let region = model.overlay.zone(component).intersection(output)
                let rect = region.isNull ? CGRect.zero : region
                    Rectangle().fill(Color.white.opacity(0.001)).frame(width: rect.width * scale, height: rect.height * scale).position(x: (rect.midX - output.minX) * scale, y: (output.maxY - rect.midY) * scale).onTapGesture { selected = component; tab = component == .sponsors ? "Sponsors" : "Components" }.accessibilityLabel("Edit \(component.name)")
                }
                let region = model.overlay.zone(selected).intersection(output)
                let rect = region.isNull ? CGRect.zero : region
                Rectangle().stroke(Color(red: 0.04, green: 0.61, blue: 0.96), lineWidth: 1.5).frame(width: rect.width * scale, height: rect.height * scale).position(x: (rect.midX - output.minX) * scale, y: (output.maxY - rect.midY) * scale).allowsHitTesting(false)
            }.clipped()
        }.aspectRatio(model.outputAspectRatio, contentMode: .fit).background(.black).overlay(Rectangle().stroke(.white.opacity(0.08)))
    }
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            refreshThumbnails()
        }
    }
    private func refreshThumbnails() {
        guard let background = BroadcastGraphics.demoBackground else { return }
        let source = CIImage(cgImage: background)
        var images = thumbnails.filter { id, _ in model.project.overlayLibrary?.contains(where: { $0.id == id }) == true }
        for document in model.project.overlayLibrary ?? [] where images[document.id] == nil || document.id == model.overlay.id {
            var project = model.project; project.graphics = true; project.selectedOverlayID = document.id
            let renderer = BroadcastFrameRenderer(BroadcastGraphics.renderSettings(project, activeIndex: model.activeSection))
            let frame = renderer.cropForOutput(renderer.compose(source, at: 0)).transformed(by: CGAffineTransform(scaleX: 0.6, y: 0.6))
            if let image = previewContext.createCGImage(frame, from: frame.extent) {
                let native = NSImage(cgImage: image, size: frame.extent.size)
                images[document.id] = native
                if document.id == model.overlay.id { canvasPreview = native }
            }
        }
        thumbnails = images
    }
    private var library: some View {
        ScrollView {
            VStack(spacing: 15) {
                ForEach(model.project.overlayLibrary ?? []) { document in
                    Button { model.selectOverlay(document.id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            if let image = thumbnails[document.id] { Image(nsImage: image).resizable().scaledToFit().background(Color(white: 0.13)).clipShape(RoundedRectangle(cornerRadius: 5)) }
                            HStack { Text(document.name).font(.system(size: 11, weight: .medium)).lineLimit(2); Spacer(); if document.id == model.project.selectedOverlayID { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)) } }
                        }.padding(10).background(document.id == model.project.selectedOverlayID ? Color.white.opacity(0.08) : .clear).clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(document.id == model.project.selectedOverlayID ? Color.white.opacity(0.6) : Color.white.opacity(0.1)))
                    }.buttonStyle(.plain)
                }
                if (model.project.overlayLibrary?.count ?? 0) > 1 {
                    Button("Remove selected overlay") { model.removeOverlay(model.overlay.id) }.font(.system(size: 10)).foregroundStyle(.secondary).buttonStyle(.plain)
                }
            }.padding(18)
        }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            input("Title", text: value(\.title))
            HStack { DatePicker("Episode date", selection: value(\.date), displayedComponents: .date).datePickerStyle(.field); Spacer(); Toggle("Show date", isOn: value(\.showDate)).toggleStyle(.checkbox) }.font(.system(size: 12))
            HStack { input("Presenter", text: value(\.presenter)); input("Handle", text: value(\.handle)) }
            Toggle("Show presenter", isOn: value(\.showPresenter)).toggleStyle(.checkbox)
            Divider()
            input("Headline panel title", text: value(\.headlineHeading))
            Toggle("Show headline cards", isOn: value(\.showHeadlines)).toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 8) {
                Text("Card titles come from your script sections").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(Array(model.project.sections.enumerated()), id: \.element.id) { index, section in
                    HStack { Text(String(format: "%02d", index + 1)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 24); TextField("Headline", text: Binding(get: { model.project.sections.indices.contains(index) ? model.project.sections[index].title : "" }, set: { if model.project.sections.indices.contains(index) { model.project.sections[index].title = $0 } })).textFieldStyle(.roundedBorder) }
                }
            }
            Divider()
            HStack { input("LIVE label", text: value(\.liveLabel)); Toggle("Show LIVE", isOn: value(\.showLive)).toggleStyle(.checkbox); Toggle("Pulse", isOn: value(\.pulseLive)).toggleStyle(.checkbox) }
            Picker("Clock time zone", selection: Binding(get: { model.project.overlayTimeZone ?? "America/Los_Angeles" }, set: { model.project.overlayTimeZone = $0 })) { Text("Pacific").tag("America/Los_Angeles"); Text("Eastern").tag("America/New_York"); Text("Central").tag("America/Chicago"); Text("Mountain").tag("America/Denver"); Text("UTC").tag("UTC") }
            Text("The camera fills the photo area. Apple’s video effects apply before the overlay.").font(.system(size: 10)).foregroundStyle(.secondary)
        }.font(.system(size: 12))
    }
    private var branding: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { input("Brand name", text: value(\.brandName)); input("Subtitle", text: value(\.brandSubtitle)) }
            input("Presented-by label", text: value(\.presentedBy))
            Toggle("Show presented-by badge", isOn: value(\.showPresentedBy)).toggleStyle(.checkbox)
            logoRow("Brand logo", data: model.overlay.brandLogoData, program: false)
            logoRow("Program / lower-left logo", data: model.overlay.programLogoData, program: true)
            Divider()
            ColorPicker("Accent color", selection: Binding(get: { Color(nsColor: NSColor(studioHex: model.overlay.accentHex)) }, set: { color in model.editOverlay { $0.accentHex = NSColor(color).studioHex } }), supportsOpacity: false)
            ColorPicker("LIVE indicator", selection: Binding(get: { Color(nsColor: NSColor(studioHex: model.overlay.liveDotHex)) }, set: { color in model.editOverlay { $0.liveDotHex = NSColor(color).studioHex } }), supportsOpacity: false)
            HStack { Text("Title size"); Slider(value: value(\.titleSize), in: 24...70, step: 1); Text("\(Int(model.overlay.titleSize))").monospacedDigit().frame(width: 28) }
            Text("Program logos replace the complete lower-left brand block. Transparent PNG or PDF works best.").font(.system(size: 10)).foregroundStyle(.secondary)
        }.font(.system(size: 12))
    }
    private func logoRow(_ label: String, data: Data?, program: Bool) -> some View {
        HStack(spacing: 14) {
            Group { if let image = data.flatMap(NSImage.init(data:)) { Image(nsImage: image).resizable().scaledToFit() } else { Image(systemName: "photo").foregroundStyle(.secondary) } }.frame(width: 45, height: 42).padding(7).background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 7) { Text(label).font(.system(size: 12, weight: .medium)); HStack { Button("Replace…") { model.replaceOverlayLogo(program: program) }; if data != nil { Button("Reset") { model.editOverlay { if program { $0.programLogoData = nil } else { $0.brandLogoData = nil } } } } }.controlSize(.small) }
            Spacer()
        }
    }
    private var sponsors: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Toggle("Show sponsors", isOn: value(\.showSponsors)).toggleStyle(.checkbox); Spacer(); Toggle("Scroll continuously", isOn: Binding(get: { model.project.carouselMoving != false }, set: { model.project.carouselMoving = $0 })).toggleStyle(.checkbox) }
            HStack { Text("Scroll speed"); Slider(value: Binding(get: { model.project.carouselSpeed ?? 32 }, set: { model.project.carouselSpeed = $0 }), in: 10...100, step: 1); Text("\(Int(model.project.carouselSpeed ?? 32)) px/s").monospacedDigit().frame(width: 65) }
            Text("Names and logos update in the preview and recording. Use the arrows to change their order.").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(Array(model.sponsors.enumerated()), id: \.element.id) { index, sponsor in
                sponsorRow(sponsor, index: index)
            }
            HStack { Button { model.addSponsor() } label: { Label("Add sponsor", systemImage: "plus") }.disabled(model.sponsors.count >= 12); Spacer(); Text("\(model.sponsors.count) / 12").font(.system(size: 10)).foregroundStyle(.secondary) }
            Text("Sponsor changes are shared across your overlay library.").font(.system(size: 10)).foregroundStyle(.secondary)
        }.font(.system(size: 12))
    }
    private func sponsorRow(_ sponsor: SponsorItem, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Group { if let logo = SponsorCatalog.logo(sponsor) { Image(nsImage: NSImage(cgImage: logo, size: NSSize(width: logo.width, height: logo.height))).resizable().scaledToFit() } else { Image(systemName: "photo") } }.frame(width: 52, height: 28).padding(4).background(Color.black).clipShape(RoundedRectangle(cornerRadius: 4))
                TextField("Sponsor name", text: Binding(get: { model.sponsors.first(where: { $0.id == sponsor.id })?.name ?? "" }, set: { model.renameSponsor(sponsor.id, name: $0) })).textFieldStyle(.roundedBorder)
            }
            HStack { Button("Logo…") { model.replaceSponsorLogo(sponsor.id) }; Spacer(); Button { model.moveSponsor(sponsor.id, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0); Button { model.moveSponsor(sponsor.id, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index == model.sponsors.count - 1); Button { model.removeSponsor(sponsor.id) } label: { Image(systemName: "trash") } }.controlSize(.mini)
            HStack { Toggle("Visible", isOn: Binding(get: { sponsor.enabled }, set: { enabled in model.updateSponsor(sponsor.id) { $0.enabled = enabled } })); Toggle("Name", isOn: Binding(get: { sponsor.showName }, set: { visible in model.updateSponsor(sponsor.id) { $0.showName = visible } })) }.toggleStyle(.checkbox).font(.system(size: 10))
            if sponsor.logoData != nil || sponsor.artwork != nil { Button("Remove logo") { model.updateSponsor(sponsor.id) { $0.logoData = nil; $0.artwork = nil; $0.showName = true } }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary) }
        }.padding(.vertical, 10).overlay(alignment: .bottom) { Color.white.opacity(0.08).frame(height: 1) }
    }
    private func input(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(label).font(.system(size: 11)).foregroundStyle(.secondary); TextField(label, text: text).textFieldStyle(.roundedBorder).font(.system(size: 13)) }
    }
}
