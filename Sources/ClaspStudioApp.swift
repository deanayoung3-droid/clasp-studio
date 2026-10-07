import SwiftUI
import AppKit
import AVFoundation
import CoreImage

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: StudioModel?
    @MainActor static func installBrandIcon() {
        let icon = NSImage(named: NSImage.Name("AppIcon")) ?? Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        if let icon { NSApplication.shared.applicationIconImage = icon }
    }
    func applicationDidFinishLaunching(_ notification: Notification) { Self.installBrandIcon() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.busy else {
            model?.pausePrompter(); model?.save(); model?.videoEditor?.saveNow()
            do { try model?.updater.installOnQuit() } catch { let notice = NSAlert(); notice.messageText = "Update could not be installed"; notice.informativeText = error.localizedDescription; notice.addButton(withTitle: "Quit without updating"); notice.runModal() }
            return .terminateNow
        }
        let alert = NSAlert(); alert.messageText = "Finish recording or exporting before quitting"; alert.informativeText = "Your video is still recording, preparing or exporting. Finish that operation before closing Clasp Studio."; alert.addButton(withTitle: "Keep studio open"); alert.runModal(); return .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model?.busy == true else { model?.pausePrompter(); model?.save(); model?.videoEditor?.saveNow(); return true }
        let alert = NSAlert(); alert.messageText = "Finish recording or exporting before closing"; alert.informativeText = "Stop recording and wait for the saved confirmation before closing your studio."; alert.addButton(withTitle: "Keep studio open"); alert.runModal(); return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct ClaspStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = StudioModel()
    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--render-motion"), CommandLine.arguments.indices.contains(index + 1) { StudioTests.motionPreview(URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
        if CommandLine.arguments.contains("--camera-check") { StudioTests.cameraCheck(); exit(0) }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-export-draft"), CommandLine.arguments.indices.contains(index + 2) {
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1]), output = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            var finished = false, failed = false
            Task {
                do {
                    let document = try JSONDecoder().decode(VideoEditDocument.self, from: Data(contentsOf: folder.appendingPathComponent("edit.json")))
                    let result = try await EditCompositionBuilder.build(document, folder: folder)
                    guard let session = AVAssetExportSession(asset: result.composition, presetName: AVAssetExportPreset1280x720) else { throw StudioError.message("Encoder unavailable") }
                    guard !FileManager.default.fileExists(atPath: output.path) else { throw StudioError.message("Verification output already exists") }
                    session.outputURL = output; session.outputFileType = .mp4; session.videoComposition = result.video; session.audioMix = result.audio
                    await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } }
                    guard session.status == .completed else { throw session.error ?? StudioError.message("Export failed") }
                    print("Draft export verified: \(document.duration) seconds")
                } catch { fputs("Export verification: \(error)\n", stderr); failed = true }
                finished = true
            }
            while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            exit(failed ? 1 : 0)
        }
        if CommandLine.arguments.contains("--self-test") { StudioTests.run(); exit(0) }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.indices.contains(index + 1) {
            let previewModel = StudioModel(persist: false)
            if let svgIndex = CommandLine.arguments.firstIndex(of: "--svg-preview"), CommandLine.arguments.indices.contains(svgIndex + 1) {
                var finished = false, svgError: Error?
                Task { @MainActor in
                    do {
                        let url = URL(fileURLWithPath: CommandLine.arguments[svgIndex + 1])
                        let asset = try await SVGOverlayImport.render(Data(contentsOf: url))
                        var document = previewModel.overlay; document.id = UUID(); document.name = url.deletingPathExtension().lastPathComponent; document.template = .custom; document.importedSVG = asset; document.accentHex = "FFFFFF"
                        if CommandLine.arguments.contains("--mapped-svg-preview") {
                            document.svgRegions = Dictionary(uniqueKeysWithValues: [OverlayComponent.headlines, .sponsors].map { ($0.rawValue, document.defaultSVGRegion($0)) })
                            document.showHeadlines = true; document.showSponsors = true
                            document.importedSVG = try await SVGOverlayImport.render(asset.source, editableRegions: Array(document.svgRegions!.values))
                        }
                        previewModel.project.overlayLibrary?.append(document); previewModel.project.selectedOverlayID = document.id
                    } catch { svgError = error }
                    finished = true
                }
                let deadline = Date().addingTimeInterval(20)
                while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
                if !finished || svgError != nil { fputs("SVG preview failed: \(String(describing: svgError))", stderr); exit(1) }
            }
            if let index = CommandLine.arguments.firstIndex(of: "--template"), CommandLine.arguments.indices.contains(index + 1), let document = previewModel.project.overlayLibrary?.first(where: { $0.template.rawValue == CommandLine.arguments[index + 1] }) { previewModel.selectOverlay(document.id) }
            if CommandLine.arguments.contains("--reference-preview") {
                let asset = StudioTests.referencePreviewAsset(); previewModel.project.referenceImages = [asset]
                previewModel.project.reference = ReferencePresentation(imageID: asset.id, caption: "Reference image · Case overview")
            }
            let timelinePreview = CommandLine.arguments.contains("--timeline-preview")
            var timeline: VideoEditorModel?
            if timelinePreview, let index = CommandLine.arguments.firstIndex(of: "--draft-preview"), CommandLine.arguments.indices.contains(index + 1) {
                let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                if let data = try? Data(contentsOf: folder.appendingPathComponent("edit.json")), var document = try? JSONDecoder().decode(VideoEditDocument.self, from: data) {
                    document.name = "This Week in AI · Edit"
                    document.clips = document.clips + document.clips
                    if !document.clips.isEmpty { for index in document.clips.indices { document.clips[index].id = UUID(); document.clips[index].graphics = true; document.clips[index].topics = false; document.clips[index].transition = index % 2 == 0 ? .cut : .news } }
                    previewModel.project = document.broadcast
                    let editor = VideoEditorModel(document: document, folder: folder)
                    if let clip = document.clips.first, let media = document.media.first(where: { $0.id == clip.mediaID }) {
                        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: EditStorage.source(media, in: folder))); generator.appliesPreferredTrackTransform = true
                        if let source = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                            let shot = EditShotRenderer(clip: clip, project: document.broadcast)
                            let frame = shot.renderer.cropForOutput(shot.frame(primary: CIImage(cgImage: source), secondary: nil, at: 0))
                            if let cg = CIContext().createCGImage(frame, from: frame.extent) { editor.presentationStill = NSImage(cgImage: cg, size: frame.extent.size) }
                        }
                    }
                    timeline = editor
                }
            }
            let savedPreview = CommandLine.arguments.contains("--saved-preview")
            if savedPreview { previewModel.lastRecording = URL(fileURLWithPath: "/Users/you/Movies/Clasp Studio/Clasp-2026-10-02_10-30-00.mov") }
            let editorPreview = CommandLine.arguments.contains("--editor-preview")
            let previewWidth: CGFloat = savedPreview ? 520 : editorPreview ? 1180 : 1440, previewHeight: CGFloat = savedPreview ? 340 : editorPreview ? 780 : 900
            let focusPreview = CommandLine.arguments.contains("--focus-preview")
            let voicePreview = CommandLine.arguments.contains("--voice-preview") || focusPreview
            if CommandLine.arguments.contains("--starting-preview") { previewModel.recordingFocus = true; previewModel.preparingRecording = true; previewModel.connecting = true }
            if focusPreview { previewModel.recordingFocus = true; previewModel.recording = true; previewModel.recordElapsed = 42 }
            if voicePreview { previewModel.prompterMode = .voice; previewModel.voiceWord = 6 }
            if focusPreview { previewModel.prompterRunning = true; previewModel.voiceStatus = "Following your voice" }
            let content: AnyView = timeline.map { AnyView(VideoEditorView(studio: previewModel, model: $0)) } ?? (savedPreview ? AnyView(RecordingSavedView(model: previewModel)) : editorPreview ? AnyView(OverlayEditor(model: previewModel, initialTab: CommandLine.arguments.contains("--sponsors-preview") ? "Sponsors" : "Components")) : AnyView(StudioView(model: previewModel, initialScriptTab: voicePreview ? "Teleprompter" : "Sections", initialCustomize: CommandLine.arguments.contains("--customize-preview"))))
            let view = NSHostingView(rootView: content.environment(\.colorScheme, .dark).frame(width: previewWidth, height: previewHeight))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: previewWidth, height: previewHeight), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: previewWidth, height: previewHeight)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    do {
                        let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                        try data.write(to: destination)
                        if let overlayPreview = previewModel.demoImage?.studioPNG { try overlayPreview.write(to: destination.deletingLastPathComponent().appendingPathComponent("Clasp Overlay Preview.png")) }
                        print("Native SwiftUI preview rendered; script pace: \(previewModel.project.wordsPerMinute) wpm"); exit(0) }
                    catch { fputs(error.localizedDescription, stderr); exit(1) }
                }
            }
            fputs("Could not render native preview", stderr); exit(1)
        }
    }
    var body: some Scene {
        Window("Clasp Studio", id: "studio") {
            Group {
                if let editor = model.videoEditor { VideoEditorView(studio: model, model: editor) }
                else { StudioView(model: model) }
            }.onAppear {
                delegate.model = model
                model.updater.start()
                DispatchQueue.main.async { NSApp.windows.first(where: { $0.title == "Clasp Studio" })?.delegate = delegate }
            }
        }.defaultSize(width: 1440, height: 900).windowStyle(.hiddenTitleBar).windowToolbarStyle(.unified).commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.checkForUpdates() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Import Video…") { model.importVideo() }.keyboardShortcut("i").disabled(model.busy || model.videoEditor != nil)
                Button("Open Drafts…") { model.draftsOpen = true }.disabled(model.busy || model.videoEditor != nil)
                Button("Import SVG Overlay…") { model.importSVGOverlay() }.disabled(model.busy || model.importingSVG)
                Button("Import Script…") { model.importScript() }.keyboardShortcut("o")
                Button("Edit Script…") { model.editScript() }.keyboardShortcut("e")
            }
            CommandMenu("Studio") {
                Button("Connect Camera") { model.connect() }.disabled(model.busy || model.cameras.isEmpty)
                Button("Start Recording") { model.startRecording() }.keyboardShortcut("r").disabled(model.cameras.isEmpty || model.busy || model.videoEditor != nil)
                Button("Stop Recording") { model.stopRecording() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!model.busy)
                Divider()
                Button("Play / Pause Script") { model.togglePrompter() }.keyboardShortcut("p")
                Button("Next Section") { model.next() }.keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Previous Section") { model.previous() }.keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Save Preview Frame…") { model.snapshot() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }
}
