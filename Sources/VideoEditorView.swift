import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

private let editBackground = Color(white: 0.075)
private let editPanel = Color(white: 0.06)
private let editLine = Color.white.opacity(0.08)
private let editAccent = Color(red: 0.04, green: 0.61, blue: 0.96)

enum EditInspectorTarget: String, CaseIterable {
    case footage = "Video", picture = "Picture", graphics = "Overlay", transition = "Transition", audio = "Audio"
    var symbol: String { switch self { case .footage: return "film"; case .picture: return "photo"; case .graphics: return "square.3.layers.3d"; case .transition: return "sparkles"; case .audio: return "waveform" } }
}
struct EditPlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView { let view = AVPlayerView(); view.controlsStyle = .none; view.videoGravity = .resizeAspect; view.player = player; return view }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
}
struct VideoEditorView: View {
    @ObservedObject var studio: StudioModel
    @ObservedObject var model: VideoEditorModel
    @State private var zoom = 32.0
    @State private var timelineWidth = 850.0
    @State private var browser = "Layers"
    @State private var target = EditInspectorTarget.footage
    private func clip<T>(_ key: WritableKeyPath<EditClip, T>, fallback: T) -> Binding<T> {
        Binding(get: { model.selected?[keyPath: key] ?? fallback }, set: { value in model.changeClip { $0[keyPath: key] = value } })
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                sidebar.frame(width: 205)
                Divider().overlay(editLine)
                VStack(spacing: 0) {
                    canvas.frame(maxHeight: .infinity)
                    Divider().overlay(editLine)
                    timeline.frame(height: 280)
                }.frame(maxWidth: .infinity)
                Divider().overlay(editLine)
                inspector.frame(width: 255)
            }.frame(maxHeight: .infinity)
        }.background(editBackground).foregroundStyle(.white).preferredColorScheme(.dark)
            .frame(minWidth: 1080, minHeight: 700)
            .onReceive(studio.$project) { model.updateBroadcast($0) }
            .sheet(isPresented: $model.animationLibraryOpen) { AnimationLibraryView(model: model, library: model.animations) }
            .sheet(isPresented: $studio.overlayEditorOpen) { OverlayEditor(model: studio, initialTab: "Components") }
            .sheet(isPresented: $studio.recordingSavedOpen) { RecordingSavedView(model: studio) }
            .alert("Could not complete this edit", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private var header: some View {
        HStack(spacing: 14) {
            Button { studio.closeVideoEditor() } label: { Image(systemName: "chevron.left").frame(width: 24, height: 28) }.help("Back to studio · draft stays saved").disabled(model.isExporting || model.importing)
            TextField("Broadcast name", text: $model.document.name).font(.system(size: 13, weight: .medium)).textFieldStyle(.plain).frame(maxWidth: 360).disabled(model.isExporting)
            Spacer()
            if model.importing { ProgressView().controlSize(.small); Text("Importing…").font(.system(size: 11)) }
            Image(systemName: "checkmark.icloud").foregroundStyle(.secondary).help("Draft saves automatically on this Mac")
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo || model.isExporting).help("Undo · ⌘Z").keyboardShortcut("z")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.canRedo || model.isExporting).help("Redo · ⇧⌘Z").keyboardShortcut("z", modifiers: [.command, .shift])
            Button { model.export(defaultFolder: studio.recordingDirectory) } label: { Label(model.isExporting ? "Exporting…" : "Export", systemImage: "square.and.arrow.up").padding(.horizontal, 13).padding(.vertical, 7).background(.white).foregroundStyle(.black).clipShape(RoundedRectangle(cornerRadius: 6)) }.disabled(model.isExporting || model.importing || model.document.clips.isEmpty)
        }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 15).frame(height: 52).background(editPanel).overlay(alignment: .bottom) { editLine.frame(height: 1) }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(["Layers", "Assets"], id: \.self) { name in Button { browser = name } label: { Text(name).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 6).background(browser == name ? Color.white.opacity(0.08) : .clear).clipShape(RoundedRectangle(cornerRadius: 5)) } }
                Spacer(minLength: 0)
            }.buttonStyle(.plain).padding(10)
            Divider().overlay(editLine)
            if browser == "Layers" { layerList } else { assetList }
            Spacer(minLength: 0)
            Button { model.importMedia(.video); browser = "Assets" } label: { Label("Import footage", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).padding(12) }.buttonStyle(.plain).disabled(model.importing || model.isExporting)
            Text("Your originals stay untouched.").font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 12)
        }.background(editPanel)
    }
    private var layerList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.document.clips.enumerated()), id: \.element.id) { index, shot in
                    VStack(alignment: .leading, spacing: 1) {
                        Button { model.select(shot.id); target = .footage } label: {
                            HStack(spacing: 8) { Image(systemName: model.selection == shot.id ? "chevron.down" : "chevron.right").font(.system(size: 8)); Image(systemName: "rectangle.on.rectangle").foregroundStyle(editAccent); Text("Shot \(index + 1)").fontWeight(.medium); Spacer(); Text(shortTime(shot.duration)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary) }.padding(.vertical, 9).padding(.horizontal, 10)
                        }.buttonStyle(.plain)
                        if model.selection == shot.id {
                            ForEach(EditInspectorTarget.allCases, id: \.self) { layer in
                                Button { target = layer } label: {
                                    HStack(spacing: 8) { Image(systemName: layer.symbol).foregroundStyle(target == layer ? editAccent : .secondary).frame(width: 15); Text(layerName(layer, shot: shot)).lineLimit(1); Spacer(minLength: 0) }.padding(.leading, 29).padding(.trailing, 9).frame(height: 31).background(target == layer ? Color.white.opacity(0.07) : .clear).clipShape(RoundedRectangle(cornerRadius: 4))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                if model.document.clips.isEmpty { Text("Import a video to create your first shot.").foregroundStyle(.secondary).padding(14) }
            }.font(.system(size: 11)).padding(7)
        }
    }
    private func layerName(_ layer: EditInspectorTarget, shot: EditClip) -> String {
        switch layer { case .footage: return model.document.media.first(where: { $0.id == shot.mediaID })?.name ?? "Video"; case .picture: return shot.layout == .presenter ? "Add a picture" : shot.layout.rawValue; case .graphics: return shot.graphics ? "Broadcast overlay" : "Overlay hidden"; case .transition: return shot.transition == .cut ? "Add a transition" : shot.transition.rawValue; case .audio: return "Source audio" }
    }
    private var assetList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                Button { model.animationLibraryOpen = true } label: { Label("Animation library", systemImage: "sparkles.tv").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).padding(.vertical, 8).disabled(model.isExporting)
                ForEach(model.document.media) { media in
                    HStack(spacing: 9) {
                        ZStack { Color.white.opacity(0.05); if let image = model.thumbnails[media.id] { Image(nsImage: image).resizable().scaledToFit() } else { Image(systemName: media.kind == .image ? "photo" : "film").foregroundStyle(.secondary) } }.frame(width: 60, height: 40).clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 4) { Text(media.name).font(.system(size: 10, weight: .medium)).lineLimit(2); Text(media.kind == .image ? "Image" : shortTime(media.duration)).font(.system(size: 9)).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle()).contextMenu {
                        if media.kind == .video { Button("Add to timeline") { model.addExistingMedia(media.id) } }
                        if media.kind != .animation { Button("Use as picture") { model.changeClip { $0.secondaryID = media.id; $0.layout = .replacement; $0.secondaryFill = media.kind == .video }; target = .picture; browser = "Layers" } }
                    }.onTapGesture { if media.kind == .video { model.addExistingMedia(media.id) } else if media.kind == .image { model.changeClip { $0.secondaryID = media.id; $0.layout = .replacement }; target = .picture; browser = "Layers" } }
                }
            }.font(.system(size: 11)).padding(12).disabled(model.isExporting)
        }
    }
    private var canvas: some View {
        VStack(spacing: 0) {
            HStack { Text("Preview"); Spacer(); Text("16:9").foregroundStyle(.secondary) }.font(.system(size: 10)).padding(.horizontal, 18).frame(height: 30)
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    ZStack {
                        EditPlayerView(player: model.player)
                        if let image = model.presentationStill ?? (model.playing ? nil : model.pausedFrame) { Image(nsImage: image).resizable().scaledToFit() }
                        if model.preparing { ProgressView("Preparing video…").font(.system(size: 11)).padding(14).background(editPanel.opacity(0.95)).clipShape(RoundedRectangle(cornerRadius: 6)) }
                        else if model.document.clips.isEmpty { VStack(spacing: 12) { Image(systemName: "film.stack").font(.system(size: 27, weight: .light)); Text("Start with a video").font(.system(size: 17)); Button("Import footage…") { model.importMedia(.video) } }.foregroundStyle(.secondary) }
                        else if let failure = model.previewFailure { VStack(spacing: 10) { Text("Preview couldn’t load").fontWeight(.medium); Text(failure).font(.system(size: 11)); Button("Retry") { model.scheduleRebuild() } }.padding(24).background(editPanel).clipShape(RoundedRectangle(cornerRadius: 7)) }
                    }.aspectRatio(16 / 9, contentMode: .fit).background(.black).frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 10).padding(.bottom, 22)
                    canvasTools.padding(.bottom, 8)
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
    private var canvasTools: some View {
        HStack(spacing: 4) {
            tool("Select", "cursorarrow", selected: target == .footage) { target = .footage }
            tool("Split", "scissors") { model.split(); target = .footage }.keyboardShortcut("b", modifiers: [.command])
            Divider().frame(height: 21).padding(.horizontal, 3)
            tool("Picture", "photo") { target = .picture }
            tool("Split screen", "rectangle.split.2x1") { target = .picture; model.changeClip { $0.layout = .split } }
            tool("Overlay", "square.3.layers.3d") { target = .graphics }
            tool("Transition", "sparkles") { target = .transition }
            Divider().frame(height: 21).padding(.horizontal, 3)
            tool(model.playing ? "Pause" : "Play", model.playing ? "pause.fill" : "play.fill") { model.togglePlayback() }.keyboardShortcut(.space, modifiers: [])
        }.padding(6).background(Color(white: 0.15)).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08))).shadow(color: .black.opacity(0.2), radius: 8, y: 3).disabled(model.isExporting || model.importing)
    }
    private func tool(_ name: String, _ symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: 35, height: 32).background(selected ? editAccent : .clear).clipShape(RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain).help(name).accessibilityLabel(name)
    }
    private var inspector: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: target.symbol); Text(model.selected == nil ? "Project" : target.rawValue).fontWeight(.medium); Spacer() }.font(.system(size: 12)).padding(15).frame(height: 46)
            Divider().overlay(editLine)
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    if let selected = model.selected {
                        switch target {
                        case .footage: footageControls(selected)
                        case .picture: pictureControls(selected)
                        case .graphics: graphicsControls(selected)
                        case .transition: transitionControls(selected)
                        case .audio: audioControls(selected)
                        }
                    } else { Text("Select a shot in Layers or click a video clip on the timeline.").foregroundStyle(.secondary).lineSpacing(4) }
                }.font(.system(size: 11)).padding(15).frame(maxWidth: .infinity, alignment: .leading).disabled(model.isExporting || model.importing)
            }
            Spacer(minLength: 0)
            if model.isExporting { VStack(spacing: 10) { ProgressView(value: model.exportProgress); HStack { Text("Exporting \(Int(model.exportProgress * 100))%"); Spacer(); Button("Cancel") { model.cancelExport() } } }.font(.system(size: 11)).padding(15) }
            Text(model.status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading).padding(15)
        }.background(editPanel)
    }
    private func footageControls(_ selected: EditClip) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(model.document.media.first(where: { $0.id == selected.mediaID })?.name ?? "Video").font(.system(size: 12, weight: .medium)).lineLimit(2)
            Text("Trim this shot").foregroundStyle(.secondary)
            HStack { timeField("Start", value: selected.start) { model.trim(start: $0) }; timeField("End", value: selected.end) { model.trim(end: $0) } }
            Text("Duration · " + shortTime(selected.duration)).foregroundStyle(.secondary)
            HStack { Button("Set start here") { model.setIn() }; Button("Set end here") { model.setOut() } }.controlSize(.small)
            Divider()
            Toggle("Mirror video", isOn: clip(\.mirror, fallback: false)).toggleStyle(.switch).controlSize(.mini)
            Text("Playback speed").foregroundStyle(.secondary)
            Picker("Speed", selection: Binding(get: { selected.safeSpeed }, set: { model.setSpeed($0) })) { ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) } }.labelsHidden()
            cropControls
            Button("Duplicate shot") { model.duplicate() }.controlSize(.small).keyboardShortcut("d", modifiers: [.command])
            Text("Move this shot").foregroundStyle(.secondary)
            HStack { Button { model.move(-1) } label: { Label("Earlier", systemImage: "arrow.left") }; Button { model.move(1) } label: { Label("Later", systemImage: "arrow.right") } }.controlSize(.small)
            Divider()
            Button { model.delete() } label: { Label("Remove shot", systemImage: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary)
            Text("Drag the clip’s edges to trim. Drag its middle to reorder. ⌘B splits at the playhead.").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4)
        }
    }
    private func timeField(_ label: String, value: Double, change: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(label).font(.system(size: 10)).foregroundStyle(.secondary); TextField(label, value: Binding(get: { value }, set: change), format: .number.precision(.fractionLength(2))).textFieldStyle(.roundedBorder).monospacedDigit() }
    }
    private func pictureControls(_ selected: EditClip) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Layout").foregroundStyle(.secondary)
            Picker("Layout", selection: clip(\.layout, fallback: .presenter)) { ForEach(EditLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden()
            if selected.layout == .presenter { Text("The original video fills the camera area.").foregroundStyle(.secondary).lineSpacing(4) }
            else {
                Text("Supporting media").foregroundStyle(.secondary)
                Picker("Supporting media", selection: clip(\.secondaryID, fallback: nil)) { Text("Choose a file…").tag(Optional<UUID>.none); ForEach(model.document.media.filter { $0.kind != .animation }) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden()
                HStack { Button("Add image…") { model.importMedia(.image, secondary: true) }; Button("Add video…") { model.importMedia(.video, secondary: true) } }.controlSize(.small)
                if let id = selected.secondaryID, let image = model.thumbnails[id] { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 115).clipShape(RoundedRectangle(cornerRadius: 5)) }
                if selected.layout == .split {
                    Text("Split position").foregroundStyle(.secondary)
                    Slider(value: optionalNumber(\.splitRatio, fallback: 0.5), in: 0.25...0.75)
                }
                if selected.layout == .split || selected.layout == .inset { Toggle("Swap sides", isOn: optionalBool(\.swapSides)).toggleStyle(.switch).controlSize(.mini) }
                Toggle("Fill and crop", isOn: clip(\.secondaryFill, fallback: false)).toggleStyle(.switch).controlSize(.mini)
                Toggle("Use supporting audio", isOn: clip(\.secondaryAudio, fallback: false)).toggleStyle(.switch).controlSize(.mini)
                Text(selected.secondaryID == nil ? "Add an image or video to complete this layout." : "Short supporting videos loop to fill the shot.").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4)
            }
        }
    }
    private func graphicsControls(_ selected: EditClip) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            Toggle("Show overlay", isOn: clip(\.graphics, fallback: true)).toggleStyle(.switch).controlSize(.mini)
            if selected.graphics {
                Text("Design").foregroundStyle(.secondary)
                Picker("Design", selection: Binding(get: { selected.overlayID ?? model.document.broadcast.selectedOverlayID ?? BroadcastGraphics.document(model.document.broadcast).id }, set: { id in model.changeClip { $0.overlayID = id } })) { ForEach(model.document.broadcast.overlayLibrary ?? []) { Text($0.name).tag($0.id) } }.labelsHidden()
                Button { studio.editOverlays() } label: { Label("Edit overlay…", systemImage: "slider.horizontal.3") }.controlSize(.small)
                Divider()
                Toggle("Show topics sidebar", isOn: clip(\.topics, fallback: true)).toggleStyle(.switch).controlSize(.mini)
                if selected.topics { Text("Active headline").foregroundStyle(.secondary); Picker("Headline", selection: clip(\.section, fallback: 0)) { ForEach(Array(model.document.broadcast.sections.enumerated()), id: \.element.id) { index, section in Text(section.title).tag(index) } }.labelsHidden() }
                Text("Hide topics for a wider picture. Overlay text, logos and dates stay editable.").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4)
            }
        }
    }
    private func transitionControls(_ selected: EditClip) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Between shots").foregroundStyle(.secondary)
            Picker("Transition", selection: clip(\.transition, fallback: .cut)) { ForEach(EditTransition.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden()
            if selected.transition == .library {
                Text(model.document.media.first(where: { $0.id == selected.animationID })?.name ?? "Choose your animation").foregroundStyle(.secondary)
                Button("Animation library…") { model.animationLibraryOpen = true }
                timeField("Source start", value: selected.animationStart ?? 0) { value in model.changeClip { $0.animationStart = max(0, value) } }
                timeField("Start in shot", value: selected.animationOffset ?? 0) { value in model.changeClip { $0.animationOffset = min(max(0, value), max(0, selected.duration - 1.0 / 30)) } }
                Text("Opacity").foregroundStyle(.secondary); Slider(value: optionalNumber(\.animationOpacity, fallback: 1), in: 0...1)
                Text("Animation volume").foregroundStyle(.secondary); Slider(value: optionalNumber(\.animationVolume, fallback: 1), in: 0...1)
                Button("Remove animation") { model.clearAnimation() }
            }
            else if selected.transition != .cut { Text("Duration").foregroundStyle(.secondary); HStack { Slider(value: clip(\.transitionDuration, fallback: 0.8), in: 0.2...3, step: 0.1); Text(String(format: "%.1fs", selected.transitionDuration)).monospacedDigit() } }
            if selected.transition != .cut {
                Button { model.previewTransition() } label: { Label("Preview transition", systemImage: "play.fill") }.disabled(model.preparing)
                if selected.transition == .library { timeField("Play for", value: selected.transitionDuration) { value in model.changeClip { $0.transitionDuration = max(1.0 / 30, value) } } }
            }
            Divider()
            Button { model.animationLibraryOpen = true } label: { Label("Import MOV / MP4…", systemImage: "plus") }.controlSize(.small)
            Text("The transition plays into this shot. Split the video where you want a transition, then select the incoming shot.").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4)
        }
    }
    private func audioControls(_ selected: EditClip) -> some View {
        VStack(alignment: .leading, spacing: 17) { Text("Source volume").foregroundStyle(.secondary); HStack { Image(systemName: selected.volume == 0 ? "speaker.slash" : "speaker.wave.2"); Slider(value: clip(\.volume, fallback: 1), in: 0...1); Text("\(Int(selected.volume * 100))%").monospacedDigit() }; Button(selected.volume == 0 ? "Unmute" : "Mute") { model.changeClip { $0.volume = selected.volume == 0 ? 1 : 0 } }.controlSize(.small); Text("Animation audio mixes automatically and lowers the source volume while it plays.").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4) }
    }
    private func optionalNumber(_ key: WritableKeyPath<EditClip, Double?>, fallback: Double) -> Binding<Double> { Binding(get: { model.selected?[keyPath: key] ?? fallback }, set: { value in model.changeClip { $0[keyPath: key] = value } }) }
    private func optionalBool(_ key: WritableKeyPath<EditClip, Bool?>) -> Binding<Bool> { Binding(get: { model.selected?[keyPath: key] ?? false }, set: { value in model.changeClip { $0[keyPath: key] = value } }) }
    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Framing").foregroundStyle(.secondary)
            HStack { Text("Zoom"); Slider(value: optionalNumber(\.zoom, fallback: 1), in: 1...3) }
            HStack { Text("Horizontal"); Slider(value: optionalNumber(\.panX, fallback: 0), in: -1...1) }
            HStack { Text("Vertical"); Slider(value: optionalNumber(\.panY, fallback: 0), in: -1...1) }
            Button("Reset framing") { model.changeClip { $0.zoom = nil; $0.panX = nil; $0.panY = nil } }.controlSize(.small)
        }
    }
    private var timeline: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { model.togglePlayback() } label: { Image(systemName: model.playing ? "pause.circle" : "play.circle").font(.system(size: 18)) }.disabled(model.preparing)
                Button { model.stepFrame(-1) } label: { Image(systemName: "backward.frame") }.help("Previous frame").keyboardShortcut(.leftArrow, modifiers: [])
                Button { model.stepFrame(1) } label: { Image(systemName: "forward.frame") }.help("Next frame").keyboardShortcut(.rightArrow, modifiers: [])
                Text(VideoEditorModel.time(model.position)).font(.system(size: 11, weight: .medium, design: .monospaced))
                Text("/ " + VideoEditorModel.time(model.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("Fit") { fitTimeline() }.font(.system(size: 10)); Slider(value: $zoom, in: 1...600).frame(width: 80)
            }.buttonStyle(.plain).padding(.horizontal, 14).frame(height: 40).disabled(model.isExporting)
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    let width = max(Double(geometry.size.width) - 24, model.duration * zoom)
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 12) {
                            ruler(width: width)
                            HStack(spacing: 0) { ForEach(Array(model.document.clips.enumerated()), id: \.element.id) { index, item in
                                EditTimelineClip(model: model, clip: item, index: index, zoom: zoom, accent: editAccent) { target = .footage }.frame(width: max(1, item.duration * zoom), height: 42)
                            } }
                            HStack(spacing: 0) { ForEach(model.document.clips) { item in layerClip(item, layer: .graphics).frame(width: max(1, item.duration * zoom), height: 28) } }
                            if model.document.clips.contains(where: { $0.layout != .presenter }) { HStack(spacing: 0) { ForEach(model.document.clips) { item in layerClip(item, layer: .picture).frame(width: max(1, item.duration * zoom), height: 28) } } }
                            if model.document.clips.contains(where: { $0.transition != .cut }) { HStack(spacing: 0) { ForEach(model.document.clips) { item in layerClip(item, layer: .transition).frame(width: max(1, item.duration * zoom), height: 28) } } }
                        }.frame(width: width, alignment: .leading)
                        Rectangle().fill(editAccent).frame(width: 1, height: 195).offset(x: min(width, model.position * zoom), y: 0).allowsHitTesting(false)
                        Text(shortTime(model.position)).font(.system(size: 9, weight: .medium, design: .monospaced)).padding(.horizontal, 5).padding(.vertical, 3).background(editAccent).clipShape(RoundedRectangle(cornerRadius: 4)).offset(x: max(0, min(width - 42, model.position * zoom - 18)), y: 2).allowsHitTesting(false)
                    }.padding(.horizontal, 12).padding(.bottom, 12)
                }.onAppear { timelineWidth = max(1, Double(geometry.size.width) - 24); fitTimeline() }.onChange(of: geometry.size.width) { _, width in timelineWidth = max(1, Double(width) - 24) }
            }
        }.background(Color(white: 0.06))
    }
    private func fitTimeline() { zoom = min(600, max(1, timelineWidth / max(0.1, model.duration))) }
    private func ruler(width: Double) -> some View {
        Canvas { context, size in
            let step = zoom > 60 ? 1 : zoom > 20 ? 5 : zoom > 5 ? 10 : 60
            for second in stride(from: 0, through: Int(max(model.duration, width / zoom)), by: step) {
                let x = Double(second) * zoom
                context.draw(Text("\(second)s").font(.system(size: 9)).foregroundColor(.gray), at: CGPoint(x: x + 3, y: 16), anchor: .topLeading)
                var path = Path(); path.move(to: CGPoint(x: x, y: 3)); path.addLine(to: CGPoint(x: x, y: 9)); context.stroke(path, with: .color(.gray.opacity(0.5)), lineWidth: 1)
            }
        }.frame(width: width, height: 33).contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in model.seek(value.location.x / zoom) }).accessibilityLabel("Timeline. Drag to move the playhead.")
    }
    private func layerClip(_ item: EditClip, layer: EditInspectorTarget) -> some View {
        let visible = layer == .graphics ? item.graphics : layer == .picture ? item.layout != .presenter : item.transition != .cut
        let color = layer == .graphics ? Color.white : editAccent
        if layer == .transition { return AnyView(transitionBar(item)) }
        return AnyView(HStack(spacing: 6) { if visible { Image(systemName: layer.symbol); Text(layer == .graphics ? "Overlay" : layer == .picture ? item.layout.rawValue : item.transition.rawValue).lineLimit(1) }; Spacer(minLength: 0) }.font(.system(size: 9)).padding(.horizontal, 7).background(visible ? color.opacity(0.08) : .clear).clipShape(RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(visible ? color.opacity(0.3) : .clear)).padding(.trailing, 3).clipped().onTapGesture { model.select(item.id); target = layer })
    }
    private func transitionBar(_ item: EditClip) -> some View {
        let offset = item.transition == .library ? min(max(0, item.animationOffset ?? 0), max(0, item.duration - 1.0 / 30)) : 0
        let media = model.document.media.first(where: { $0.id == item.animationID })
        let length = item.transition == .cut ? 0 : item.transition == .library ? min(item.duration - offset, item.transitionDuration, max(0, (media?.duration ?? item.transitionDuration) - (item.animationStart ?? 0))) : min(item.duration, item.transitionDuration / 2)
        return HStack(spacing: 0) {
            Color.clear.frame(width: max(0, offset * zoom))
            if length > 0 {
                HStack(spacing: 5) { Image(systemName: "sparkles"); Text(item.transition == .library ? media?.name ?? "Choose animation" : item.transition.rawValue).lineLimit(1) }.font(.system(size: 9)).padding(.horizontal, 6).frame(width: max(20, length * zoom), alignment: .leading).background(editAccent.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(editAccent.opacity(0.5))).clipped()
                    .onTapGesture { model.select(item.id); model.seek(model.document.start(of: item.id) + offset); target = .transition }
                    .gesture(DragGesture(minimumDistance: 5).onEnded { value in if item.transition == .library { model.selection = item.id; model.changeClip { $0.animationOffset = min(max(0, offset + value.translation.width / zoom), max(0, item.duration - 1.0 / 30)) }; model.seek(model.document.start(of: item.id) + (model.selected?.animationOffset ?? 0)); target = .transition } })
            }
            Spacer(minLength: 0)
        }.frame(height: 28).clipped().contentShape(Rectangle()).onTapGesture { model.select(item.id); target = .transition }
    }
    private func shortTime(_ seconds: Double) -> String { String(format: "%.2fs", seconds) }
}
private struct EditTimelineClip: View {
    @ObservedObject var model: VideoEditorModel
    let clip: EditClip
    let index: Int
    let zoom: Double
    let accent: Color
    var selected: () -> Void
    @State private var trimDelta = 0.0
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                LinearGradient(colors: [accent.opacity(0.16), accent.opacity(0.025)], startPoint: .top, endPoint: .bottom)
                HStack(spacing: 7) { Image(systemName: "film"); Text("Shot \(index + 1)").fontWeight(.medium); Spacer(minLength: 0) }.font(.system(size: 10)).padding(.horizontal, 12).lineLimit(1)
                if abs(trimDelta) > 0.01 { Text(String(format: "%+.2fs", trimDelta)).font(.system(size: 9, design: .monospaced)).padding(4).background(Color.black.opacity(0.7)).clipShape(RoundedRectangle(cornerRadius: 3)).frame(maxWidth: .infinity, alignment: .center) }
                if model.selection == clip.id { HStack { handle(start: true); Spacer(minLength: 0); handle(start: false) } }
            }.clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(model.selection == clip.id ? accent : accent.opacity(0.5), lineWidth: model.selection == clip.id ? 2 : 1)).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3).onEnded { value in
                    guard !model.isExporting else { return }
                    model.selection = clip.id
                    let destinationTime = max(0, min(model.duration - 0.001, model.document.start(of: clip.id) + clip.duration / 2 + value.translation.width / zoom))
                    if let destination = model.document.clip(at: destinationTime), let target = model.document.clips.firstIndex(where: { $0.id == destination.id }) { model.moveClip(clip.id, to: target) }
                    selected()
                })
                .contextMenu { Button("Duplicate shot") { model.selection = clip.id; model.duplicate() }; Button("Split at playhead") { model.split() }; Button("Remove shot") { model.selection = clip.id; model.delete() } }
                .onTapGesture(coordinateSpace: .local) { point in model.selection = clip.id; model.seek(model.document.start(of: clip.id) + min(clip.duration, max(0, point.x / zoom))); selected() }
                .contextMenu { Button("Split at playhead") { model.split() }; Button("Remove shot") { model.selection = clip.id; model.delete() }; Button("Move earlier") { model.selection = clip.id; model.move(-1) }; Button("Move later") { model.selection = clip.id; model.move(1) } }
                .accessibilityLabel("Shot \(index + 1). Click to select and scrub, drag to reorder.")
        }.padding(.trailing, 3)
    }
    private func handle(start: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(accent).frame(width: 3, height: 18).frame(width: 12, height: 42).contentShape(Rectangle()).highPriorityGesture(DragGesture(minimumDistance: 1).onChanged { value in trimDelta = value.translation.width / zoom }.onEnded { value in
            guard !model.isExporting else { return }; model.selection = clip.id
            let delta = (value.translation.width / zoom * 30).rounded() / 30
            if start { model.trim(start: clip.start + delta) } else { model.trim(end: clip.end + delta) }
            trimDelta = 0; selected()
        }).help(start ? "Drag to trim the start" : "Drag to trim the end")
    }
}
struct AnimationLibraryView: View {
    @ObservedObject var model: VideoEditorModel
    @ObservedObject var library: AnimationLibrary
    @State private var importing = false
    @State private var message: String?
    @State private var previewPlayer = AVPlayer()
    @State private var previewing = false
    @State private var animationThumbnails: [UUID: NSImage] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("Animation library").font(.system(size: 24, weight: .semibold)); Text("Reusable MOV and MP4 stingers, with their audio.").font(.system(size: 12)).foregroundStyle(.secondary) }; Spacer(); Button("Done") { model.animationLibraryOpen = false } }
            HStack { Button { importFiles() } label: { Label("Import animations…", systemImage: "plus") }; if importing { ProgressView().controlSize(.small) }; Spacer(); Text("\(library.items.count) animations").foregroundStyle(.secondary) }
            Text("Transparent ProRes MOVs play over the picture. Opaque animations cover it. Select an animation to play at the beginning of the selected timeline clip.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            if previewing { EditPlayerView(player: previewPlayer).aspectRatio(16 / 9, contentMode: .fit).frame(height: 160).background(.black).clipShape(RoundedRectangle(cornerRadius: 6)) }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(library.items) { item in
                        HStack(spacing: 15) {
                            Button {
                                previewPlayer.replaceCurrentItem(with: AVPlayerItem(url: EditStorage.animations.appendingPathComponent(item.fileName))); previewPlayer.play(); previewing = true
                            } label: {
                                ZStack { Color.white.opacity(0.06); if let image = animationThumbnails[item.id] { Image(nsImage: image).resizable().scaledToFit() }; Image(systemName: "play.circle.fill").font(.system(size: 20)).shadow(radius: 2) }.frame(width: 85, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).help("Preview animation")
                            VStack(alignment: .leading, spacing: 7) {
                                TextField("Animation name", text: Binding(get: { library.items.first(where: { $0.id == item.id })?.name ?? "" }, set: { name in do { try library.rename(item.id, name: name) } catch { message = error.localizedDescription } })).textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                                Text(VideoEditorModel.time(item.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Use transition") { model.applyAnimation(item) }.disabled(model.selected == nil || model.importing)
                            Button { do { try library.remove(item.id) } catch { message = error.localizedDescription } } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }.padding(13).background(Color.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    if library.items.isEmpty { VStack(spacing: 12) { Image(systemName: "sparkles.tv").font(.system(size: 36, weight: .ultraLight)); Text("Your broadcast transitions belong here"); Text("Import one clip or a whole collection.").font(.system(size: 12)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 70) }
                }
            }
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
        }.padding(26).frame(width: 720, height: 650).background(editBackground).foregroundStyle(.white).preferredColorScheme(.dark)
            .onAppear { model.player.pause(); model.playing = false }
            .onDisappear { previewPlayer.pause(); previewPlayer.replaceCurrentItem(with: nil) }
            .task(id: library.items.map(\.id)) {
                for item in library.items where animationThumbnails[item.id] == nil {
                    let url = EditStorage.animations.appendingPathComponent(item.fileName)
                    let data = await Task.detached { () -> Data? in
                        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 180, height: 100)
                        guard let image = try? generator.copyCGImage(at: CMTime(seconds: min(0.2, item.duration / 2), preferredTimescale: 600), actualTime: nil) else { return nil }
                        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                    }.value
                    if Task.isCancelled { return }; animationThumbnails[item.id] = data.flatMap(NSImage.init(data:))
                }
            }
    }
    private func importFiles() {
        StudioFileDialog.media(multiple: true, message: "Choose MOV or MP4 broadcast animations") { urls in
            importing = true
            Task { do { try await library.importFiles(urls) } catch { message = error.localizedDescription }; importing = false }
        }
    }
}
