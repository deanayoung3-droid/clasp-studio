import SwiftUI
import AppKit

private let ink = Color(white: 0.035)
private let panel = Color(white: 0.065)
private let tile = Color(white: 0.105)
private let accent = Color(white: 0.97)
private let muted = Color(white: 0.53)
private let edge = Color.white.opacity(0.09)

struct StudioView: View {
    @ObservedObject var model: StudioModel
    @State private var leftTab = "Brand"
    @State private var inspectorOpen = false
    @State private var referenceOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scriptTab: String
    init(model: StudioModel, initialScriptTab: String = "Teleprompter") {
        self.model = model; _scriptTab = State(initialValue: initialScriptTab)
    }
    var body: some View {
        VStack(spacing: 0) {
            if model.recordingFocus { recordingHeader } else { header }
            Rectangle().fill(edge).frame(height: 1)
            HStack(alignment: .top, spacing: 20) {
                if inspectorOpen && !model.recordingFocus {
                    branding.frame(width: 222).transition(.move(edge: .leading).combined(with: .opacity))
                    Rectangle().fill(edge).frame(width: 1)
                }
                center.frame(maxWidth: .infinity, maxHeight: .infinity)
                script.frame(width: model.recordingFocus ? 420 : 336)
            }.padding(model.recordingFocus ? 18 : 24)
            if !model.recordingFocus { footer }
        }.background(ink).foregroundStyle(.white).preferredColorScheme(.dark).tint(accent)
        .frame(minWidth: 1180, minHeight: 770)
        .background { if model.allowsWindowChanges { RecordingWindowBridge(model: model).frame(width: 0, height: 0) } }
        .alert("Clasp Studio", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) { Button("OK") { model.alert = nil } } message: { Text(model.alert ?? "") }
        .onChange(of: model.recordingFocus) { _, focus in if focus { scriptTab = "Teleprompter"; inspectorOpen = false; model.editorOpen = false; model.settingsOpen = false; model.overlayEditorOpen = false } }
        .onChange(of: model.prompterMode) { _, mode in if mode == .voice { scriptTab = "Teleprompter" } }
        .sheet(isPresented: $model.draftsOpen) { VideoDraftsView(studio: model) }
        .sheet(isPresented: $model.editorOpen) { scriptEditor }
        .sheet(isPresented: $model.settingsOpen) { settings }
        .sheet(isPresented: $model.overlayEditorOpen) { OverlayEditor(model: model, initialTab: model.overlayEditorTab) }
        .sheet(isPresented: $model.recordingSavedOpen) { RecordingSavedView(model: model) }
    }
    private func identity(size: CGFloat, color: Color = .white) -> some View {
        Group {
            if let image = BroadcastGraphics.brandImage(model.project) { Image(nsImage: image).renderingMode(.template).resizable().scaledToFit().foregroundStyle(color) }
        }.frame(width: size, height: size)
    }
    private func customize(_ page: String? = nil) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            if let page { leftTab = page; inspectorOpen = true } else { inspectorOpen.toggle() }
        }
    }
    var header: some View {
        HStack(spacing: 13) {
            identity(size: 24)
            Text("Clasp").font(.system(size: 16, weight: .semibold)).tracking(-0.4)
            Rectangle().fill(edge).frame(width: 1, height: 22).padding(.horizontal, 8)
            Text(model.overlay.title).font(.system(size: 11, weight: .medium)).foregroundStyle(muted).lineLimit(1)
            Spacer()
            Button { model.importVideo() } label: { Label("Import video", systemImage: "film.stack").font(.system(size: 11, weight: .medium)) }.buttonStyle(StudioButton()).disabled(model.busy)
            Button { model.draftsOpen = true } label: { Text("Drafts").font(.system(size: 11, weight: .medium)) }.buttonStyle(StudioButton()).disabled(model.busy)
            Button { model.editOverlays() } label: { Label("Overlays", systemImage: "square.stack").font(.system(size: 11, weight: .medium)) }.buttonStyle(StudioButton())
            Button { customize() } label: { Label("Customize", systemImage: "slider.horizontal.3").font(.system(size: 11, weight: .medium)) }.buttonStyle(StudioButton()).help("Edit your broadcast headline, presenter and sponsors")
            Button { model.settingsOpen = true } label: { Image(systemName: "gearshape").frame(width: 20, height: 20) }.buttonStyle(.plain).foregroundStyle(muted).padding(.horizontal, 7).help("Studio settings").accessibilityLabel("Studio settings")
            Button {
                if model.busy { model.stopRecording() }
                else { model.startRecording() }
            } label: {
                Label(model.openingVideoEditor ? "Opening editor…" : model.finishingRecording ? "Preparing edit…" : model.preparingRecording ? "Starting…" : model.recording ? "Stop recording" : model.connecting ? "Connecting…" : "Start recording", systemImage: model.recording ? "stop.fill" : "record.circle").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10).frame(height: 24)
            }.buttonStyle(StudioButton(primary: true, recording: model.recording)).disabled(model.openingVideoEditor || model.finishingRecording || (!model.connected && model.cameras.isEmpty))
        }.padding(.horizontal, 26).frame(height: 72)
    }
    var recordingHeader: some View {
        HStack(spacing: 12) {
            if model.preparingRecording || model.finishingRecording { ProgressView().controlSize(.small).frame(width: 12) }
            else { Circle().fill(.red).frame(width: 7, height: 7) }
            Text(model.finishingRecording ? "SAVING RECORDING" : model.connecting ? "CONNECTING CAMERA" : model.preparingRecording ? "STARTING RECORDING" : "RECORDING").font(.system(size: 11, weight: .semibold)).tracking(1)
            if model.recording { Text(StudioModel.time(model.recordElapsed)).font(.system(size: 13, design: .monospaced)).foregroundStyle(muted) }
            else { Text(model.connecting ? "Allow camera and microphone access if prompted" : model.preparingRecording ? "Waiting for the first camera frame…" : "Finishing your movie…").font(.system(size: 10)).foregroundStyle(muted) }
            Spacer()
            referenceButton
            Button("Exit focus") { model.recordingFocus = false }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(muted)
            Button { model.stopRecording() } label: { Label(model.openingVideoEditor ? "Opening editor…" : model.finishingRecording ? "Preparing edit…" : model.preparingRecording ? "Cancel" : "Stop recording", systemImage: "stop.fill").font(.system(size: 12, weight: .semibold)) }.buttonStyle(StudioButton(primary: true)).disabled(model.finishingRecording)
        }.padding(.horizontal, 26).frame(height: 54)
    }
    var branding: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Your overlay").font(.system(size: 16, weight: .semibold)); Spacer(); Button { customize() } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(muted) }
            Text(model.overlay.name).font(.system(size: 12)).foregroundStyle(muted)
            if let image = model.demoImage { Image(nsImage: image).resizable().aspectRatio(model.outputAspectRatio, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 5)) }
            Button { model.editOverlays("Content") } label: { Label("Edit title, date & text", systemImage: "text.cursor").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(StudioButton())
            Button { model.editOverlays("Branding") } label: { Label("Edit logos & colors", systemImage: "paintpalette").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(StudioButton())
            Button { model.editOverlays("Sponsors") } label: { Label("Edit sponsor carousel", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(StudioButton())
            Text("Edits are saved for each overlay. Sponsor names and logos are shared across designs.").font(.system(size: 11)).foregroundStyle(muted).lineSpacing(4)
            Spacer()
        }.font(.system(size: 11))
    }
    var center: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.recordingFocus { HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your recording").font(.system(size: 18, weight: .semibold)).tracking(-0.4)
                    Text(model.recording ? "Recording · \(StudioModel.time(model.recordElapsed))" : model.connected ? "Ready when you are" : "Set up your camera to get started").font(.system(size: 11)).foregroundStyle(muted)
                }
                Spacer()
                Text(model.outputDimensions).font(.system(size: 9, weight: .medium)).foregroundStyle(muted)
            } }
            if model.recordingFocus { Spacer(minLength: 0) }
            ZStack {
                if model.connected || model.allowsWindowChanges { CameraPreviewView(surface: model.previewSurface) }
                else if let image = model.demoImage { Image(nsImage: image).resizable().aspectRatio(model.outputAspectRatio, contentMode: .fit) }
                if !model.connected && !model.recordingFocus {
                    GeometryReader { proxy in
                    let output = model.outputRect
                    let area = (model.project.graphics ? model.overlay.zone(.camera) : output).intersection(output)
                    VStack(spacing: 13) {
                        Image(systemName: "video").font(.system(size: 27, weight: .ultraLight)).foregroundStyle(Color.white.opacity(0.7))
                        Text("Bring your camera into frame").font(.system(size: 22, weight: .medium)).tracking(-0.6)
                        Text(model.cameras.isEmpty ? "Connect a webcam, then refresh your devices below." : "Your overlay is ready. Connect your camera to preview it live.").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.6)).multilineTextAlignment(.center)
                        Button(model.connecting ? "Cancel connection" : "Connect camera") { if model.connecting { model.cancelConnection() } else { model.connect() } }.buttonStyle(StudioButton(primary: true)).disabled(model.cameras.isEmpty && !model.connecting)
                    }.padding(.horizontal, 25).frame(width: proxy.size.width * area.width / output.width).position(x: proxy.size.width * (area.midX - output.minX) / output.width, y: proxy.size.height * (output.maxY - area.midY) / output.height)
                    }
                }
            }.aspectRatio(model.outputAspectRatio, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(edge))
            if !model.recordingFocus { HStack(spacing: 16) {
                referenceButton
                Button { model.openAppleEffects() } label: { Label(model.nativeBackgroundActive ? "Apple background active" : "Apple backgrounds & effects", systemImage: "sparkles").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(muted).disabled(!model.connected).help("Open macOS native video effects and backgrounds")
                Button { model.editOverlays("Sponsors") } label: { Label("Edit sponsors", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(muted)
                Spacer()
                Toggle("Show overlay", isOn: $model.project.graphics).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                Button { model.snapshot() } label: { Label("Save frame", systemImage: "camera").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(muted).help("Save the current preview as an image")
            }.frame(height: 24)
            deviceBar }
            Spacer(minLength: 0)
        }
    }
    private var referenceButton: some View {
        Button { referenceOpen.toggle() } label: {
            Label(model.project.reference?.visible == true ? "Reference on air" : "Reference image", systemImage: "photo.on.rectangle").font(.system(size: 11))
        }.buttonStyle(.plain).foregroundStyle(model.project.reference?.visible == true ? accent : muted)
            .popover(isPresented: $referenceOpen, arrowEdge: .bottom) { LiveReferenceControls(model: model).environment(\.colorScheme, .dark) }
    }
    var deviceBar: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Camera", systemImage: "video").font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
                Picker("Camera", selection: $model.cameraID) { ForEach(model.cameras, id: \.uniqueID) { Text($0.deviceType == .continuityCamera ? "\($0.localizedName) · iPhone" : $0.localizedName).tag($0.uniqueID) }; if model.cameras.isEmpty { Text("No camera found").tag("") } }.labelsHidden().disabled(model.busy).onChange(of: model.cameraID) { _, _ in model.selectDevice() }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(edge).frame(width: 1, height: 36)
            VStack(alignment: .leading, spacing: 8) {
                HStack { Label("Microphone", systemImage: "mic").font(.system(size: 10, weight: .medium)).foregroundStyle(muted); Spacer(); MicrophoneMeter(meter: model.audioMeter) }
                Picker("Microphone", selection: $model.microphoneID) { Text("No microphone").tag("none"); ForEach(model.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) } }.labelsHidden().disabled(model.busy).onChange(of: model.microphoneID) { _, _ in model.selectDevice() }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(muted).disabled(model.busy).help("Refresh camera and microphone list").accessibilityLabel("Refresh devices")
            if model.connected { Button("Disconnect") { model.disconnect() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(muted).disabled(model.busy) }
        }.pickerStyle(.menu).font(.system(size: 11)).padding(16).background(panel).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    var script: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack { Text(model.recordingFocus ? "Teleprompter" : "Your script").font(.system(size: 17, weight: .semibold)); Spacer(); Text("\(model.project.sections.count) sections").font(.system(size: 10)).foregroundStyle(muted) }
            if !model.recordingFocus { Text(model.scriptDescription).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
            HStack(spacing: 8) {
                Button { model.importScript() } label: { Label("Import script", systemImage: "arrow.down.doc").font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity) }.buttonStyle(StudioButton(primary: true)).help("Import TXT, Markdown, RTF, DOCX or PDF · ⌘O")
                Button { model.editScript() } label: { Text("Edit / paste").font(.system(size: 11, weight: .medium)) }.buttonStyle(StudioButton()).help("Paste or write a script · ⌘E")
            }
            tabs(["Sections", "Teleprompter"], selection: $scriptTab) }
            if scriptTab == "Sections" && !model.recordingFocus {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.project.sections.enumerated()), id: \.element.id) { index, section in
                                Button { model.activeSection = index } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(alignment: .top, spacing: 10) {
                                            Text(String(format: "%02d", index + 1)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(index == model.activeSection ? accent : muted).padding(.top, 2)
                                            Text(section.title).font(.system(size: 12, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                            if index == model.activeSection { Image(systemName: "checkmark").font(.system(size: 10)) }
                                        }
                                        Text(section.body).font(.system(size: 12)).lineSpacing(5).foregroundStyle(index == model.activeSection ? Color.white.opacity(0.85) : muted).lineLimit(index == model.activeSection ? 6 : 2)
                                        HStack { Text(index == model.activeSection ? "READING NOW" : "\(section.words.count) words").font(.system(size: 8, weight: .medium)).tracking(0.7); Spacer(); Text("~\(StudioModel.time(section.duration(wpm: model.project.wordsPerMinute)))").font(.system(size: 9, design: .monospaced)) }.foregroundStyle(muted)
                                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(index == model.activeSection ? Color.white.opacity(0.065) : .clear).overlay(alignment: .leading) { if index == model.activeSection { Rectangle().fill(.white).frame(width: 2) } }
                                }.buttonStyle(.plain).id(section.id)
                                Rectangle().fill(edge).frame(height: 1)
                            }
                        }
                    }.onChange(of: model.activeSection) { _, _ in if let id = model.section?.id { withAnimation { proxy.scrollTo(id, anchor: .top) } } }
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            Text(model.section?.title.uppercased() ?? "").font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(muted)
                            ForEach(0..<max(1, (model.sectionWords.count + 7) / 8), id: \.self) { line in Text(promptLine(line)).font(.system(size: model.recordingFocus ? max(28, model.prompterSize) : model.prompterSize, weight: .medium)).lineSpacing(8).fixedSize(horizontal: false, vertical: true).id(line) }
                            Color.clear.frame(height: 100)
                        }.padding(.horizontal, 4)
                    }.onChange(of: model.currentWord / 8) { _, line in if model.prompterRunning { withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(line, anchor: .center) } } }.onChange(of: model.activeSection) { _, _ in proxy.scrollTo(model.currentWord / 8, anchor: .center) }.onAppear { proxy.scrollTo(model.currentWord / 8, anchor: .center) }
                }
                if !model.recordingFocus { HStack { Image(systemName: "textformat.size").foregroundStyle(muted); Slider(value: $model.prompterSize, in: 16...34).help("Prompter text size") } }
            }
            Spacer(minLength: 0)
            Divider().overlay(edge)
            HStack(spacing: 12) {
                Button { model.previous() } label: { Image(systemName: "backward.end.fill") }.buttonStyle(StudioButton()).help("Previous section")
                Button { model.togglePrompter() } label: { Label(model.prompterRunning ? "Pause" : model.voiceStarting ? "Cancel" : model.prompterMode == .voice ? (model.connected ? "Start listening" : "Connect & listen") : "Read script", systemImage: model.prompterRunning ? "pause.fill" : model.prompterMode == .voice ? "mic.fill" : "play.fill").font(.system(size: 11, weight: .semibold)) }.buttonStyle(StudioButton(primary: true)).help("Start or pause script following")
                Button { model.next() } label: { Image(systemName: "forward.end.fill") }.buttonStyle(StudioButton()).disabled(model.activeSection + 1 >= model.project.sections.count).help("Next section")
                Spacer()
                Text("\(model.activeSection + 1) / \(model.project.sections.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
            }
            ProgressView(value: model.progress).tint(.white).frame(height: 2)
            Picker("Scroll mode", selection: $model.prompterMode) {
                ForEach(PrompterMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Teleprompter scroll mode")
            if model.prompterMode == .timed && !model.recordingFocus {
                HStack { Text("Reading pace").font(.system(size: 10)).foregroundStyle(muted); Spacer(); Text("\(Int(model.project.wordsPerMinute)) wpm").font(.system(size: 10, design: .monospaced)) }
                Slider(value: $model.project.wordsPerMinute, in: 80...220, step: 5).help("Script reading pace")
            } else if model.prompterMode == .voice {
                VStack(alignment: .leading, spacing: 5) {
                    Label(model.voiceStatus, systemImage: "waveform").font(.system(size: 10, weight: .medium))
                    Text("On-device · English · selected microphone").font(.system(size: 9)).foregroundStyle(muted)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
            }
            HStack { Button("Restart") { model.restart() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(muted); Spacer(); Text(model.prompterRunning ? (model.prompterMode == .voice ? "LISTENING" : "AUTO ADVANCING") : "PAUSED").font(.system(size: 8, weight: .medium)).tracking(0.8).foregroundStyle(muted) }
        }.padding(18).background(panel).clipShape(RoundedRectangle(cornerRadius: 6))
    }
    func promptLine(_ line: Int) -> AttributedString {
        let words = model.sectionWords; var result = AttributedString()
        for index in (line * 8)..<min(line * 8 + 8, words.count) {
            var word = AttributedString(words[index] + " ")
            word.foregroundColor = index < model.currentWord ? muted : .white.opacity(0.9)
            if index == model.currentWord { word.foregroundColor = .black; word.backgroundColor = .white }
            result += word
        }
        return result
    }
    var footer: some View {
        HStack(spacing: 9) {
            Image(systemName: model.recording ? "record.circle" : "circle.fill").font(.system(size: model.recording ? 11 : 5)).foregroundStyle(muted)
            Text(model.notice).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
            Spacer()
            if model.lastRecording != nil { Button("Show recording") { model.revealLastRecording() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.white) }
            Text("Saved locally on your Mac").font(.system(size: 8, design: .monospaced)).tracking(0.6).foregroundStyle(muted).padding(.leading, 16)
        }.padding(.horizontal, 26).frame(height: 34).overlay(alignment: .top) { Rectangle().fill(edge).frame(height: 1) }
    }
    var scriptEditor: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Edit your script").font(.system(size: 24, weight: .medium)).tracking(-0.5)
            Text("Paste your text below. Add # headings to separate sections, or leave a blank line between paragraphs.").font(.system(size: 12)).foregroundStyle(muted).lineSpacing(3)
            TextEditor(text: $model.editorText).font(.system(size: 14, design: .monospaced)).padding(12).background(tile).clipShape(RoundedRectangle(cornerRadius: 5))
            HStack { Button("Cancel") { model.editorOpen = false }.buttonStyle(StudioButton()); Button("Clear editor") { model.editorText = "" }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(muted); Spacer(); Button("Use this script") { model.applyScript() }.buttonStyle(StudioButton(primary: true)) }
        }.padding(28).frame(width: 700, height: 570).background(ink).foregroundStyle(.white)
    }
    var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Studio settings").font(.system(size: 24, weight: .medium)); Spacer(); Text("v" + StudioModel.version).font(.system(size: 11, design: .monospaced)).foregroundStyle(muted) }
            Text("Backgrounds, Portrait and Studio Light are managed by macOS. Connect your camera, then choose Apple backgrounds & effects below the preview.").font(.system(size: 12)).foregroundStyle(muted).lineSpacing(4)
            VStack(alignment: .leading, spacing: 8) {
                Text("Drafts save automatically · export when ready").font(.system(size: 12, weight: .semibold))
                Text(model.recordingDirectory.path).font(.system(size: 10)).foregroundStyle(muted).lineLimit(2)
                Button("Choose recording folder…") { model.chooseRecordingFolder() }.buttonStyle(StudioButton()).disabled(model.busy)
            }
            Toggle("Mirror camera in preview and recording", isOn: $model.project.mirror)
            Text("Records a clean camera take and your selected microphone into a saved draft. Stop recording to edit cuts, layouts and graphics, then export a 720p MP4. Apple camera effects remain part of the camera image.").font(.system(size: 12)).foregroundStyle(muted).lineSpacing(4)
            Text("Choose Reading pace for timed scrolling, or Follow my voice to match spoken words using your selected microphone. Voice mode uses on-device English recognition and holds its place when you pause or go off script.").font(.system(size: 12)).foregroundStyle(muted)
            Button("Camera & microphone privacy settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!) }.buttonStyle(StudioButton())
            UpdateSettingsView(model: model, updater: model.updater)
            DisclosureGroup("Session status") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Video: \(model.cameraReceivingFrames ? "receiving frames" : "waiting") · Audio: \(model.microphoneReceivingAudio ? "receiving samples" : "waiting")").font(.system(size: 10))
                    ScrollView { Text(model.sessionEvents.suffix(10).joined(separator: "\n")).font(.system(size: 9, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 110)
                    Button("Save session status…") { model.exportDiagnostics() }.buttonStyle(StudioButton()).font(.system(size: 10))
                    Text("Contains app events only. No audio or spoken words are saved here.").font(.system(size: 9)).foregroundStyle(muted)
                }.padding(.top, 10)
            }.font(.system(size: 11))
            HStack { Spacer(); Button("Done") { model.settingsOpen = false }.buttonStyle(StudioButton(primary: true)) }
        }.padding(28).frame(width: 470).background(ink).foregroundStyle(.white)
    }
    func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(label).font(.system(size: 10)).foregroundStyle(muted); TextField(label, text: text).textFieldStyle(.plain).font(.system(size: 11, weight: .medium)).padding(10).background(tile.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 4)) }
    }
    func tabs(_ titles: [String], selection: Binding<String>) -> some View {
        HStack(spacing: 0) { ForEach(titles, id: \.self) { title in Button { selection.wrappedValue = title } label: { Text(title).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 9).overlay(alignment: .bottom) { Rectangle().fill(selection.wrappedValue == title ? .white : edge).frame(height: selection.wrappedValue == title ? 2 : 1) } }.buttonStyle(.plain).foregroundStyle(selection.wrappedValue == title ? .white : muted) } }
    }

}
struct StudioButton: ButtonStyle {
    var primary = false
    var recording = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 10).padding(.vertical, 8).foregroundStyle(primary ? ink : .white).background(primary ? accent : tile).clipShape(RoundedRectangle(cornerRadius: 5)).opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
    }
}

private struct MicrophoneMeter: View {
    @ObservedObject var meter: MicrophoneLevel
    var body: some View { HStack(spacing: 2) { ForEach(0..<12, id: \.self) { i in Rectangle().fill(Double(i) / 12 < meter.level ? accent : Color.white.opacity(0.12)).frame(width: 3, height: 8) } } }
}
