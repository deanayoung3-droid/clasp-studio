import Foundation
import AppKit
import AVFoundation
import CoreImage
import MetalKit
import Speech
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

// Integration checks run through the shipping capture/compositor/encoder code.
enum StudioTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }; print("PASS: \(message)") }
    static func cameraCheck() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { print("Live camera check needs camera permission; no permission request made."); return }
        let cameras = CaptureEngine.devices(.video)
        print("Camera devices: " + cameras.map { "\($0.localizedName) [\($0.deviceType.rawValue)]" }.joined(separator: ", "))
        guard let camera = cameras.first else { print("No camera available for a live check."); return }
        let engine = CaptureEngine(); var frames = 0; var delays: [Double] = []; var failure: String?
        engine.onFrame = { _ in frames += 1 }
        engine.onFrameTiming = { delays.append($0) }
        engine.onStatus = { _, _, error in failure = error }
        engine.update(RenderSettings(overlay: BroadcastGraphics.overlay(StudioProject(), section: ""), mirror: true))
        engine.connect(cameraID: camera.uniqueID, microphoneID: "")
        RunLoop.current.run(until: Date().addingTimeInterval(6))
        engine.disconnect()
        engine.queue.sync {
            print("Live frames delivered in 6 seconds: \(frames)")
            if !delays.isEmpty { let sorted = delays.sorted(); print(String(format: "Capture-to-composition median: %.1f ms; p95: %.1f ms", sorted[sorted.count / 2] * 1000, sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000)) }
            if let failure { print("Camera check error: " + failure) }
        }
    }
    static func motionPreview(_ url: URL) {
        var project = StudioProject(); project.overlayLibrary = OverlayDocument.presets(project)
        if let index = CommandLine.arguments.firstIndex(of: "--template"), CommandLine.arguments.indices.contains(index + 1), let doc = project.overlayLibrary?.first(where: { $0.template.rawValue == CommandLine.arguments[index + 1] }) { project.selectedOverlayID = doc.id }
        let renderer = BroadcastFrameRenderer(BroadcastGraphics.renderSettings(project, activeIndex: 0, epoch: 0))
        let tickerRenderer = BroadcastFrameRenderer(BroadcastGraphics.renderSettings(project, activeIndex: 1, epoch: 0, previousSection: 0, tickerEpoch: 2))
        let context = CIContext(), source = CIImage(cgImage: BroadcastGraphics.demoBackground!)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 42, nil) else { exit(1) }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<42 { autoreleasepool {
            let time = Double(i) / 10
            var program = (BroadcastGraphics.document(project).template == .ticker && i >= 20 ? tickerRenderer : renderer).compose(source, at: time)
            if CommandLine.arguments.contains("--transition-preview") {
                let background = CIImage(color: time < 2 ? CIColor(red: 0.18, green: 0.23, blue: 0.3) : CIColor(red: 0.34, green: 0.29, blue: 0.24)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
                program = BroadcastTransition.frame(progress: (time - 1.6) / 0.8).composited(over: background)
            }
            let frame = program.transformed(by: CGAffineTransform(scaleX: 0.75, y: 0.75))
            if let image = context.createCGImage(frame, from: CGRect(x: 0, y: 0, width: 960, height: 540)) {
                CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
            }
        } }
        check(CGImageDestinationFinalize(destination), "Animated broadcast preview exported")
    }
    static func pixels(_ image: CIImage, rect: CGRect, context: CIContext) -> Data {
        let row = Int(rect.width) * 4
        var bytes = [UInt8](repeating: 0, count: row * Int(rect.height))
        bytes.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: row, bounds: rect, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) }
        return Data(bytes)
    }
    static func run() {
        let completion = DispatchSemaphore(value: 0)
        Task.detached { await runAsync(); completion.signal() }
        while completion.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }
    static func runAsync() async {
        check(ScriptParser.parse("  \n\n").isEmpty, "Empty scripts are rejected")
        let sections = ScriptParser.parse("# Opening\r\nHello world\r\n\r\n## Next\r\nGoodbye now")
        check(sections.count == 2 && sections[1].title == "Next" && sections[0].words.count == 2, "Markdown and Windows line endings parse correctly")
        check(ScriptParser.parse("One paragraph.\n\nAnother paragraph.").count == 2, "Plain text splits into sections")
        check(ScriptParser.parse(ScriptParser.markdown(sections)).map(\.body) == sections.map(\.body), "Script editing round trips")
        check(sections[0].duration(wpm: 0).isFinite, "Reading pace is bounded")
        var project = StudioProject(); project.sections = sections
        let decoded = try! JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(project))
        check(decoded.sections == sections, "Project persistence round trips")
        check(BroadcastGraphics.overlay(project, section: "Opening")?.width == 1280, "Broadcast graphics render at recording resolution")
        project.graphics = false
        check(BroadcastGraphics.overlay(project, section: "Opening") == nil, "Clean camera mode removes all graphics")
        let path = CommandLine.arguments.drop(while: { $0 != "--test-output" }).dropFirst().first ?? NSTemporaryDirectory() + "ClaspStudio-Test.mov"
        let url = URL(fileURLWithPath: path); try? FileManager.default.removeItem(at: url)
        let engine = CaptureEngine(); let finished = DispatchSemaphore(value: 0)
        var failure: String?
        engine.onRecordingFinished = { output, error in failure = error; if output == nil && error == nil { failure = "Missing recording" }; finished.signal() }
        project.graphics = true
        engine.update(BroadcastGraphics.renderSettings(project, activeIndex: 0, epoch: ProcessInfo.processInfo.systemUptime))
        engine.startRecording(to: url, syntheticAudio: true)
        for i in 0..<60 {
            engine.queue.sync {
                var pixel: CVPixelBuffer?
                CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixel)
                guard let pixel else { fatalError("Pixel buffer") }
                let image = CIImage(color: CIColor(red: Double(i) / 120 + 0.1, green: 0.17, blue: 0.22)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
                CIContext().render(image, to: pixel)
                var format: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format)
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: Int64(i), timescale: 30), decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
                engine.processVideo(sample!)
                if let audio = audioSample(index: i) { engine.processAudio(audio) }
            }
            try? await Task.sleep(nanoseconds: 34_000_000)
        }
        engine.stopRecording()
        check(finished.wait(timeout: .now() + 20) == .success, "Recording finalizes")
        check(failure == nil, "Recording has no encoder error: \(failure ?? "none")")
        let asset = AVURLAsset(url: url)
        let videoTracks = try! await asset.loadTracks(withMediaType: .video)
        let audioTracks = try! await asset.loadTracks(withMediaType: .audio)
        let duration = try! await asset.load(.duration)
        check(videoTracks.count == 1, "MOV contains a video track")
        check(audioTracks.count == 1, "MOV contains an AAC microphone track")
        check(duration.seconds > 1.8, "Video and audio have expected duration")
        let generator = AVAssetImageGenerator(asset: asset)
        do {
            let (frame, _) = try await generator.image(at: CMTime(value: 1, timescale: 1))
            check(frame.width == 1280 && frame.height == 720, "Saved video is 1280 × 720")
            let data = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])!
            try data.write(to: url.deletingPathExtension().appendingPathExtension("png"))
            let (earlier, _) = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
            let (later, _) = try await generator.image(at: CMTime(seconds: 1.7, preferredTimescale: 600))
            let context = CIContext()
            check(pixels(CIImage(cgImage: earlier), rect: SponsorCarousel.rect, context: context) != pixels(CIImage(cgImage: later), rect: SponsorCarousel.rect, context: context), "The saved movie includes the moving sponsor carousel")
        } catch { check(false, "Recorded frame decodes: \(error)") }
        let noFrame = CaptureEngine()
        let noFrameDone = DispatchSemaphore(value: 0)
        let emptyURL = url.deletingPathExtension().appendingPathExtension("empty.mov")
        try? FileManager.default.removeItem(at: emptyURL)
        var emptyError: String?
        noFrame.onRecordingFinished = { _, error in emptyError = error; noFrameDone.signal() }
        noFrame.startRecording(to: emptyURL)
        noFrame.stopRecording()
        check(noFrameDone.wait(timeout: .now() + 5) == .success && emptyError != nil, "Stopping before the first frame reports an error safely")
        check(!FileManager.default.fileExists(atPath: emptyURL.path), "An empty recording leaves no corrupt movie")
        let importURL = url.deletingPathExtension().appendingPathExtension("txt")
        try! "# Unicode\nHello café — 世界".write(to: importURL, atomically: true, encoding: .utf8)
        check(try! ScriptParser.load(importURL).contains("世界"), "UTF-8 script files import correctly")
        let rtfURL = url.deletingPathExtension().appendingPathExtension("rtf")
        let attributed = NSAttributedString(string: "A rich text script.")
        let rtf = try! attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try! rtf.write(to: rtfURL)
        check(try! ScriptParser.load(rtfURL) == attributed.string, "RTF script files import correctly")
        let nativeOnlyEngine = CaptureEngine()
        nativeOnlyEngine.update(RenderSettings(overlay: nil, mirror: false))
        nativeOnlyEngine.queue.sync {
            let original = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
            let frame = nativeOnlyEngine.compose(original)
            check(frame.extent == CGRect(x: 0, y: 0, width: 1280, height: 720), "Native camera frames retain 16:9 framing without a segmentation pass")
            let pixel = NSBitmapImageRep(cgImage: CIContext().createCGImage(frame, from: frame.extent)!).colorAt(x: 600, y: 300)!.usingColorSpace(.deviceRGB)!
            check(abs(pixel.greenComponent - 0.4) < 0.03, "Native camera/background pixels pass through unchanged")
        }
        check(BroadcastGraphics.bundledLogo?.studioCGImage?.width == 72, "The supplied Clasp logo is bundled with the app")
        var legacy = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        for key in ["primaryLogoData", "edgeFeather", "edgeCleanup", "sponsorNames", "overlayTimeZone"] { legacy.removeValue(forKey: key) }
        let migrated = try! JSONDecoder().decode(StudioProject.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(migrated.sections == project.sections && migrated.edgeFeather == nil, "Existing projects remain readable after removing custom backgrounds")
        let template = BroadcastGraphics.broadcastTemplate!
        check(template.width == 1280 && template.height == 720, "The supplied SVG is cached at video resolution")
        let templatePixels = NSBitmapImageRep(cgImage: template)
        check(templatePixels.colorAt(x: 100, y: 100)!.alphaComponent == 0, "The supplied broadcast template leaves the camera area transparent")
        let graphicPixels = NSBitmapImageRep(cgImage: BroadcastGraphics.overlay(project, section: "Opening")!)
        let band = graphicPixels.colorAt(x: 1200, y: 555)!.usingColorSpace(.deviceRGB)!
        check(band.blueComponent > band.redComponent + 0.2, "The SVG's blue presenter band replaces the former monochrome overlay")
        let openingCard = graphicPixels.colorAt(x: 1240, y: 110)!.usingColorSpace(.deviceRGB)!
        check(openingCard.blueComponent > openingCard.redComponent + 0.2, "The active script headline receives the blue highlight")
        check(graphicPixels.colorAt(x: 500, y: 300)!.alphaComponent == 0, "Dynamic headlines preserve the transparent camera opening")
        let clockDate = ISO8601DateFormatter().date(from: "2026-10-01T07:41:00Z")!
        let pacificClock = BroadcastGraphics.clockLabels(at: clockDate, timeZoneID: "America/Los_Angeles")
        let easternClock = BroadcastGraphics.clockLabels(at: clockDate, timeZoneID: "America/New_York")
        check(pacificClock.time == "12:41 AM" && pacificClock.zone == "PACIFIC", "Broadcast clock displays Pacific local time")
        check(easternClock.time == "3:41 AM" && easternClock.zone == "EASTERN", "Broadcast clock supports Eastern time")
        check(BroadcastGraphics.sponsorSlots(migrated).map(\.name) == ["Filevine", "Dropbox"], "Existing projects receive the requested default sponsors")
        var sponsorProject = project; sponsorProject.sponsorNames = ["Dropbox"]
        check(BroadcastGraphics.sponsorSlots(sponsorProject).map(\.name) == ["Dropbox"], "Sponsor selection controls the ribbon")
        await MainActor.run {
            let model = StudioModel(persist: false)
            model.project.sections = [ScriptSection(title: "One", body: "First section."), ScriptSection(title: "Two", body: "Last section.")]
            check(model.prompterMode == .voice, "Voice following is the default mode")
            model.prompterMode = .timed; model.prompterRunning = true
            for _ in 0..<51 { model.tick() }
            check(model.activeSection == 1, "Prompter automatically advances to the next section")
            for _ in 0..<51 { model.tick() }
            check(!model.prompterRunning && model.activeSection == 1, "Prompter stops safely at the end of the script")
            check(model.project.background == .original && model.project.backgroundData == nil, "Only Apple-managed backgrounds remain enabled")
            check(model.sectionWords == model.section?.words, "Teleprompter reads a cached script token list")
            model.restart()
            check(model.activeSection == 0 && model.sectionElapsed == 0, "Script restarts at the first section")
        }
        let voiceSections = [ScriptSection(title: "Opening", body: "Welcome to this week in law. We are discussing important court decisions today."), ScriptSection(title: "Next", body: "The second story concerns insurance coverage. Thank you for watching.")]
        var matching = SpeechScriptMatcher(sections: voiceSections)
        check(matching.update("Welcome to this")?.word == 3, "Voice follows matching spoken words")
        let held = matching.cursor
        check(matching.update("Welcome to this") == nil && matching.cursor == held, "Repeated partial results do not advance the script")
        check(matching.update("unrelated weather forecast sunny skies") == nil && matching.cursor == held, "Off-script speech holds the teleprompter in place")
        check(matching.update("this week in law")?.word == 6, "Voice resumes after an off-script aside")
        matching.resetTranscript()
        check(matching.update("we are discussing um important court decisions today")?.section == 1, "Fillers are tolerated and matching crosses section boundaries")
        check(matching.update("the second story concerns insurance coverage thank you for watching")?.finished == true, "Voice following reaches the end of the script")
        var skipped = SpeechScriptMatcher(sections: [ScriptSection(title: "Skip", body: "Today we discuss the major new court ruling together.")])
        check(skipped.update("today we discuss major new court ruling")?.word == 8, "A small omitted phrase does not stall matching")
        var distant = SpeechScriptMatcher(sections: [ScriptSection(title: "Window", body: "Start here " + Array(repeating: "filler", count: 60).joined(separator: " ") + " distant final phrase")])
        check(distant.update("distant final phrase") == nil && distant.cursor == 0, "Voice does not jump far ahead on an unrelated match")
        var revised = SpeechScriptMatcher(sections: [ScriptSection(title: "Revision", body: "The court issued a new ruling today.")])
        _ = revised.update("the coat")
        check(revised.update("the court issued")?.word == 3, "Corrected partial recognition recovers matching")
        check(revised.update("the court") == nil && revised.cursor == 3, "Shortened recognition revisions never rewind")
        var repeated = SpeechScriptMatcher(sections: [ScriptSection(title: "Repeat", body: "Thank you very much. Thank you very much. Goodbye now.")])
        check(repeated.update("thank you very much")?.word == 4, "Repeated phrases match the nearest script position")
        check(repeated.update("thank you very much thank you very much")?.word == 8, "A newly spoken repeated phrase advances only once")
        check(SpeechScriptMatcher.normalize("I'm reading 25 café updates") == SpeechScriptMatcher.normalize("I’m reading twenty five cafe updates"), "Punctuation, accents and spoken numbers normalize for matching")
        var emptyMatcher = SpeechScriptMatcher(sections: [])
        check(emptyMatcher.update("hello world") == nil, "Empty scripts are safe in voice mode")
        var oneWord = SpeechScriptMatcher(sections: [ScriptSection(title: "One", body: "Goodbye")])
        check(oneWord.update("goodbye")?.finished == true, "A single final word completes safely")
        await MainActor.run {
            let model = StudioModel(persist: false); model.project.sections = voiceSections
            model.prompterMode = .voice; model.prompterRunning = true
            for _ in 0..<100 { model.tick() }
            check(model.currentWord == 0 && model.activeSection == 0, "Voice mode never scrolls on a timer during silence")
            model.followTranscript("welcome to this week in law we are discussing important court decisions today")
            check(model.activeSection == 1 && model.currentWord == 0 && model.prompterRunning, "Matched speech updates the active overlay section and cue")
            model.followTranscript("the second story concerns insurance coverage thank you for watching")
            check(!model.prompterRunning && model.progress == 1, "Voice mode stops at completion without wrapping")
            model.restart()
            check(model.activeSection == 0 && model.currentWord == 0 && !model.prompterRunning, "Restart resets the voice cue and pauses listening")
            model.prompterRunning = true; model.followTranscript("welcome to this")
            model.next()
            check(!model.prompterRunning && model.currentWord == 0, "Manual section changes pause voice matching at the chosen cue")
            model.prompterMode = .timed; model.prompterRunning = true; model.tick()
            check(model.sectionElapsed > 0, "Timed scrolling remains available after voice mode")
        }
        check(Bundle.main.object(forInfoDictionaryKey: "NSCameraUseContinuityCameraDeviceType") as? Bool == true, "Continuity Camera discovery is explicitly enabled")
        let recordingFolder = url.deletingLastPathComponent().appendingPathComponent("recording-flow-test", isDirectory: true)
        let firstDestination = try! await StudioModel.recordingURL(in: recordingFolder, at: clockDate)
        let secondDestination = try! await StudioModel.recordingURL(in: recordingFolder, at: clockDate)
        check(firstDestination != secondDestination && firstDestination.pathExtension == "mov", "Immediate recording uses unique movie paths without overwriting takes")
        let flow = await MainActor.run { () -> StudioModel in
            let model = StudioModel(persist: false)
            check(model.recordingDirectory.lastPathComponent == "Clasp Studio", "Recordings default to the Clasp Studio folder in Movies")
            model.project.recordingFolder = recordingFolder.path; model.connected = true; model.prompterMode = .timed
            model.startRecording()
            check(model.preparingRecording && model.recordingFocus, "Start recording immediately opens the focused preview and teleprompter")
            return model
        }
        for index in 0..<20 {
            flow.engine.queue.sync { flow.engine.processVideo(videoSample(index: index)!) }
            try? await Task.sleep(nanoseconds: 35_000_000)
        }
        await MainActor.run {
            check(flow.recording && flow.recordingFocus && flow.prompterRunning, "The first recorded frame starts the timer and script cueing")
            check(flow.previewSurface.currentFrame() != nil, "Live preview receives composed Core Image frames without CPU image conversion")
            flow.stopRecording()
        }
        for _ in 0..<100 {
            if await MainActor.run(body: { !flow.busy }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let recordedFlowURL = await MainActor.run { () -> URL? in
            check(!flow.busy && !flow.recordingFocus && !flow.prompterRunning, "Stopping saves the take, exits recording focus and pauses the script")
            check(flow.videoEditor != nil && flow.alert == nil && !flow.recordingSavedOpen && flow.lastRecording == nil, "Stopping opens a draft editor before final export")
            guard let editor = flow.videoEditor, let source = editor.document.media.first else { return nil }
            return EditStorage.source(source, in: editor.folder)
        }
        if let recordedFlowURL {
            let tracks = try! await AVURLAsset(url: recordedFlowURL).loadTracks(withMediaType: .video)
            check(tracks.count == 1, "The immediate-recording flow creates a playable clean-source track")
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: recordedFlowURL))
            let (clean, _) = try! await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600))
            let pixels = NSBitmapImageRep(cgImage: clean)
            let corner = pixels.colorAt(x: 1100, y: 300)!.usingColorSpace(.deviceRGB)!
            let center = pixels.colorAt(x: 640, y: 300)!.usingColorSpace(.deviceRGB)!
            check(abs(corner.blueComponent - center.blueComponent) < 0.01 && abs(corner.greenComponent - center.greenComponent) < 0.01 && corner.redComponent < 0.4, "New drafts retain camera pixels where the editable topic sidebar used to be")
            await editorChecks(source: recordedFlowURL, animation: url, directory: url.deletingLastPathComponent())
            await MainActor.run { flow.closeVideoEditor() }
        }
        let failedFlow = await MainActor.run { () -> StudioModel in
            let model = StudioModel(persist: false); model.project.recordingFolder = recordingFolder.path; model.connected = true; model.prompterMode = .timed
            model.startRecording(); model.stopRecording(); return model
        }
        for _ in 0..<40 {
            if await MainActor.run(body: { !failedFlow.busy }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await MainActor.run {
            check(!failedFlow.busy && !failedFlow.recordingFocus && !failedFlow.recordingSavedOpen && failedFlow.alert != nil, "A no-frame recording failure returns to the studio instead of getting stuck")
        }
        await recordingRetakeChecks()
        await MainActor.run {
            let model = StudioModel(persist: false)
            model.connecting = true // Simulate an already pending device connection without OS prompts.
            model.startRecording()
            check(model.busy && model.preparingRecording && model.recordingFocus, "Recording requested during camera setup gives immediate focus and feedback")
            model.stopRecording()
            check(!model.busy && !model.recordingFocus && !model.connecting, "Cancel during camera setup resets all pending recording state")
            check(model.sessionEvents.contains(where: { $0.contains("Start recording clicked") }), "Session status captures the recording action for diagnosis")
        }
        await MainActor.run {
            let window = FullScreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            let coordinator = RecordingWindowBridge.Coordinator()
            coordinator.update(window: window, focus: true)
            coordinator.update(window: window, focus: true)
            check(window.fullScreenRequests == 1, "Recording focus requests full screen once, including before the first frame")
            coordinator.update(window: window, focus: false)
            check(window.fullScreenRequests == 2, "Leaving recording focus restores the original window state")
            let alreadyFull = FullScreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            alreadyFull.simulatedFullScreen = true
            let preserved = RecordingWindowBridge.Coordinator()
            preserved.update(window: alreadyFull, focus: true); preserved.update(window: alreadyFull, focus: false)
            check(alreadyFull.fullScreenRequests == 0, "An already full-screen window stays full screen after recording")
            let attachment = WindowAttachmentView(); var attached = false
            attachment.onWindow = { _ in attached = true }; window.contentView = attachment
            check(attached, "The recording bridge observes its actual window attachment")
        }
        updateSignatureChecks()
        await MainActor.run {
            let name = "Clasp-update-consent-test-" + UUID().uuidString
            let preferences = UserDefaults(suiteName: name)!
            defer { preferences.removePersistentDomain(forName: name) }
            let updater = AppUpdater(preferences: preferences)
            updater.ready = true
            check(updater.shouldInstallOnQuit, "A prepared automatic update can install on quit")
            updater.postponeInstallation()
            check(!updater.shouldInstallOnQuit, "Choosing Later prevents the prepared update from installing on quit")
            let reopened = AppUpdater(preferences: preferences); reopened.ready = true
            check(!reopened.shouldInstallOnQuit, "A deferred update still requires approval after restarting the app")
            check(!reopened.approveInstallation(build: 1) && !reopened.shouldInstallOnQuit, "Approval cannot install a different update than the one offered")
            check(reopened.approveInstallation(build: 0) && reopened.shouldInstallOnQuit, "Explicit approval enables installation of the offered update")
            reopened.working = true
            check(!reopened.approveInstallation(), "Installation cannot restart the app while its download is in progress")
        }
        await libraryChecks()
        let profiling = CaptureEngine()
        profiling.update(BroadcastGraphics.renderSettings(StudioProject(), activeIndex: 0, epoch: ProcessInfo.processInfo.systemUptime))
        profiling.queue.sync {
            let renderer = CIContext(options: [.cacheIntermediates: false])
            let sample = videoSample(index: 0)!
            let source = CIImage(cvPixelBuffer: CMSampleBufferGetImageBuffer(sample)!)
            var output: CVPixelBuffer?
            CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &output)
            renderer.render(profiling.compose(source), to: output!) // Warm the GPU.
            let started = ProcessInfo.processInfo.systemUptime
            for _ in 0..<120 { autoreleasepool { renderer.render(profiling.compose(source), to: output!) } }
            print(String(format: "Compositor benchmark (120 synthetic 720p frames, animated overlay): %.2f ms/frame", (ProcessInfo.processInfo.systemUptime - started) * 1000 / 120))
        }
        let liveSpeechPermission = SFSpeechRecognizer.authorizationStatus()
        print("Speech runtime permission: \(liveSpeechPermission.rawValue). Matcher checks use supplied transcripts; live microphone recognition still requires a desktop check.")
        if let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue() {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 128, height: 72, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            let texture = device.makeTexture(descriptor: descriptor)!
            let gpu = CameraGPUContext(commands: commands)
            let rect = CGRect(x: 0, y: 0, width: 128, height: 72)
            let colorFrame = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 36, width: 128, height: 36)).composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: rect))
            let command = commands.makeCommandBuffer()!
            try! gpu.render(colorFrame, to: texture, command: command)
            await withCheckedContinuation { continuation in
                command.addCompletedHandler { _ in continuation.resume() }; command.commit()
            }
            check(command.status == .completed, "The shipping GPU preview renderer completes Metal work")
            var pixels = [UInt8](repeating: 0, count: 128 * 72 * 4)
            pixels.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 128 * 4, from: MTLRegionMake2D(0, 0, 128, 72), mipmapLevel: 0) }
            check(pixels[2] > 240 && pixels[0] < 10 && pixels[(72 - 1) * 128 * 4] > 240, "GPU preview preserves upright camera and overlay orientation")
        } else if ProcessInfo.processInfo.environment["CI"] == "true" { print("SKIP: Live Metal verification requires a desktop GPU; already covered by local checks.") } else { check(false, "Metal is available for preview verification") }
        print("ALL CHECKS PASSED")
    }
    static func updateSignatureChecks() {
        let checked = Date(timeIntervalSince1970: 10000)
        check(!AppUpdater.checkIsDue(lastChecked: checked, now: checked.addingTimeInterval(3599)) && AppUpdater.checkIsDue(lastChecked: checked, now: checked.addingTimeInterval(3600)) && AppUpdater.checkIsDue(lastChecked: checked, now: checked.addingTimeInterval(7200)), "Hourly updates wait one hour and catch up after a sleeping Mac wakes")
        let key = Curve25519.Signing.PrivateKey(), zip = Data("A signed archive".utf8)
        let manifest = UpdateManifest(repository: UpdateVerification.repository, version: "1.7.1", build: 1001, asset: "Clasp-Studio.zip", size: zip.count, sha256: SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined())
        let body = try! JSONEncoder().encode(manifest), signature = try! key.signature(for: body)
        let verified = try! UpdateVerification.verify(body, signature: signature, publicKey: key.publicKey.rawRepresentation)
        check(verified.build == 1001, "GitHub updates require a valid Ed25519 release signature")
        check((try? UpdateVerification.verify(Data("tampered".utf8), signature: signature, publicKey: key.publicKey.rawRepresentation)) == nil, "A modified update manifest is rejected")
        check((try? UpdateVerification.verify(body, signature: signature, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)) == nil, "An update signed with another key is rejected")
        do { try UpdateVerification.verifyArchive(zip, manifest: verified); check(true, "The signed archive checksum and size are verified") } catch { check(false, "The signed archive checksum and size are verified") }
        do { try UpdateVerification.verifyArchive(Data("different".utf8), manifest: verified); check(false, "A changed archive is rejected") } catch { check(true, "A changed archive is rejected") }
        var wrongRepo = manifest; wrongRepo.repository = "someone/else"
        let wrongBody = try! JSONEncoder().encode(wrongRepo)
        check((try? UpdateVerification.verify(wrongBody, signature: key.signature(for: wrongBody), publicKey: key.publicKey.rawRepresentation)) == nil, "The updater only accepts its configured repository")
        check(Bundle.main.url(forAuxiliaryExecutable: "ClaspUpdateInstaller") != nil, "The update installation helper is bundled")
        let assetJSON = Data("{\"id\":1,\"name\":\"Clasp-Studio.zip\",\"size\":100,\"browser_download_url\":\"https://github.com/deanayoung3-droid/clasp-studio/releases/download/build-8/Clasp-Studio.zip\"}".utf8)
        var publicAsset = try! JSONDecoder().decode(GitHubRelease.Asset.self, from: assetJSON)
        check(GitHubTransport.publicAssetURL(publicAsset) != nil, "Public GitHub release assets can download without a token or GitHub CLI")
        for invalid in ["http://github.com/deanayoung3-droid/clasp-studio/releases/download/build-8/Clasp-Studio.zip", "https://github.com/another/repo/releases/download/build-8/Clasp-Studio.zip", "https://example.com/deanayoung3-droid/clasp-studio/releases/download/build-8/Clasp-Studio.zip", "https://github.com/deanayoung3-droid/clasp-studio/releases/download/build-8/different.zip"] {
            publicAsset.browser_download_url = URL(string: invalid)
            check(GitHubTransport.publicAssetURL(publicAsset) == nil, "Public updater rejects an untrusted release download URL")
        }
    }
    static func libraryChecks() async {
        let context = CIContext(), source = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        var project = StudioProject(); project.overlayLibrary = OverlayDocument.presets(project)
        for doc in project.overlayLibrary! {
            project.selectedOverlayID = doc.id
            let artwork = doc.template.artwork!
            let center = doc.template.cameraRect
            let rep = NSBitmapImageRep(cgImage: artwork)
            check(rep.colorAt(x: Int(center.midX), y: Int(720 - center.midY))!.alphaComponent == 0, "\(doc.name) removes the sample photograph completely")
            let renderer = BroadcastFrameRenderer(BroadcastGraphics.renderSettings(project, activeIndex: 0, epoch: 0))
            let frame = renderer.compose(source, at: 0)
            let composed = NSBitmapImageRep(cgImage: context.createCGImage(frame, from: frame.extent)!)
            let camera = composed.colorAt(x: Int(center.midX), y: Int(720 - center.midY))!.usingColorSpace(.deviceRGB)!
            check(abs(camera.greenComponent - 0.4) < 0.03 && abs(camera.blueComponent - 0.6) < 0.03, "\(doc.name) displays camera pixels in the photo window")
            check(composed.colorAt(x: 1250, y: 400)!.alphaComponent > 0.99, "\(doc.name) retains its headline panel beside the camera")
        }
        for var document in OverlayDocument.presets(project) {
            document.placeBadge(.live, onRight: true)
            check(document.zone(.camera).contains(document.zone(.live)) && document.zone(.camera).contains(document.zone(.presentedBy)), "\(document.name) keeps swapped badges inside the camera")
            check(!document.zone(.live).intersects(document.zone(.presentedBy)), "\(document.name) prevents badge collisions")
            document.editStyle(.title) { $0.textScale = 9; $0.padding = -20; $0.alignment = .right }
            check(document.style(.title).safeScale == 1.25 && document.style(.title).safePadding == 0, "\(document.name) clamps typography to safe bounds")
            check(document.textZone(.title).width > 0 && ([OverlayTemplate.glass, .ticker].contains(document.template) ? document.zone(.title).maxY <= 211 : document.zone(.title).maxY < document.zone(.camera).minY), "\(document.name) protects the camera from title edits")
            let saved = try! JSONDecoder().decode(OverlayDocument.self, from: JSONEncoder().encode(document))
            check(saved.componentStyles == document.componentStyles && saved.zone(.live) == document.zone(.live), "\(document.name) persists component edits")
        }
        var legacyDocument = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(project.overlayLibrary![0])) as! [String: Any]
        legacyDocument.removeValue(forKey: "componentStyles")
        let legacy = try! JSONDecoder().decode(OverlayDocument.self, from: JSONSerialization.data(withJSONObject: legacyDocument))
        check(legacy.style(.title).safeScale == 1 && legacy.style(.title).alignment == .left, "Older overlay documents adopt the default component rules")
        let invalidStyle = OverlayComponentStyle(textScale: .nan, padding: .infinity)
        check(invalidStyle.safeScale == 1 && invalidStyle.safePadding == 0, "Non-finite style values cannot invalidate component geometry")
        let carousel = SponsorCarousel(items: SponsorCatalog.defaults())!
        let periodRect = CGRect(x: 0, y: 0, width: min(carousel.period, 1280), height: 46)
        check(pixels(carousel.image, rect: periodRect, context: context) == pixels(carousel.frame(at: 0, speed: 32), rect: periodRect, context: context), "Sponsor tiling preserves logo size and a single row")
        let first = pixels(carousel.frame(at: 0, speed: 32), rect: SponsorCarousel.rect, context: context)
        let wrap = pixels(carousel.frame(at: Double(carousel.period) / 32, speed: 32), rect: SponsorCarousel.rect, context: context)
        check(first == wrap, "Sponsor carousel wraps seamlessly at a complete period")
        check(first != pixels(carousel.frame(at: 1, speed: 32), rect: SponsorCarousel.rect, context: context), "Carousel advances as time passes")
        check(carousel.offset(at: 100, speed: 0) == 0, "Zero sponsor speed holds a static strip")
        check(SponsorCarousel(items: []) == nil && SponsorCarousel(items: [SponsorItem(name: "Hidden", enabled: false)]) == nil, "Empty or disabled sponsors leave no animation layer")
        check(SponsorCarousel(items: (0..<12).map { SponsorItem(name: "Sponsor \($0)") })?.count == 12, "The carousel includes all twelve sponsors")
        let dot = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        var pulse = BroadcastAnimation(sponsors: nil, sponsorSpeed: 32, sponsorMoving: false, liveDot: dot, pulseLive: true, epoch: 0)
        let bright = pixels(pulse.frame(at: 0.4)!, rect: dot.extent, context: context)
        let dim = pixels(pulse.frame(at: 1.2)!, rect: dot.extent, context: context)
        check(bright != dim, "LIVE indicator pulses with the video frame clock")
        pulse.pulseLive = false
        check(pixels(pulse.frame(at: 0.4)!, rect: dot.extent, context: context) == pixels(pulse.frame(at: 1.2)!, rect: dot.extent, context: context), "Disabling LIVE pulse holds the indicator steady")
        await MainActor.run {
            let model = StudioModel(persist: false)
            check(model.project.overlayLibrary?.count == 6, "The library includes all six supplied designs")
            let original = model.overlay.id, next = model.project.overlayLibrary![1].id
            model.editOverlay { $0.title = "A custom episode"; $0.date = Date(timeIntervalSince1970: 1_800_000_000); $0.liveLabel = "ON AIR" }
            let edited = model.overlay
            model.selectOverlay(next); model.editOverlay { $0.title = "AI edition" }; model.selectOverlay(original)
            check(model.overlay == edited, "Switching overlays preserves title, date and LIVE edits independently")
            model.duplicateOverlay(); let copy = model.overlay.id
            model.editOverlay { $0.title = "Copy only" }; model.selectOverlay(original)
            check(model.overlay.title == edited.title && copy != original, "Duplicated overlays have independent editable settings")
            model.removeOverlay(copy)
            check(model.project.overlayLibrary?.count == 6, "Removing an overlay keeps the rest of the library")
            let sponsor = model.sponsors[0].id
            model.renameSponsor(sponsor, name: "Edited sponsor")
            check(model.sponsors[0].showName && model.sponsors[0].name == "Edited sponsor", "Renaming a bundled sponsor displays the new name with its icon")
            let logo = NSBitmapImageRep(cgImage: BroadcastGraphics.bundledLogo!.studioCGImage!).representation(using: .png, properties: [:])!
            model.updateSponsor(sponsor) { $0.logoData = logo; $0.artwork = nil; $0.showName = false }
            check(SponsorCatalog.logo(model.sponsors[0]) != nil, "Uploaded sponsor artwork replaces the preset wordmark")
            model.moveSponsor(sponsor, by: 1)
            check(model.sponsors[1].id == sponsor, "Sponsor ordering updates the carousel source")
            model.removeSponsor(sponsor); model.addSponsor()
            check(!model.sponsors.contains(where: { $0.id == sponsor }) && model.sponsors.last?.name == "New sponsor", "Sponsors can be removed and added")
            let saved = try! JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(model.project))
            check(saved.overlayLibrary == model.project.overlayLibrary && saved.sponsorItems == model.sponsors && saved.selectedOverlayID == model.project.selectedOverlayID, "Overlay library, selection and sponsor edits survive saving")
            model.editOverlay { $0.showLive = false; $0.showSponsors = false }
            let hidden = BroadcastGraphics.renderSettings(model.project, activeIndex: 0)
            check(hidden.animation?.liveDot == nil && hidden.animation?.sponsors == nil, "Visibility controls remove LIVE and sponsor layers")
            model.project.overlayLibrary = [model.overlay]
            model.removeOverlay(model.overlay.id)
            check(model.project.overlayLibrary?.count == 1, "The final overlay cannot be accidentally removed")
            model.project.overlayLibrary = []
            check(BroadcastGraphics.document(model.project).template == .law, "An empty saved library falls back safely")
        }
        await MainActor.run {
            let model = StudioModel(persist: false)
            model.connecting = true; model.recordingFocus = true; model.preparingRecording = true
            model.expireConnection(waitingForPermission: true)
            check(!model.connecting && !model.recordingFocus && !model.preparingRecording && model.alert?.contains("authorization") == true, "A stalled macOS permission wait exits connection and recording setup safely")
            model.alert = nil; model.connecting = true; model.cancelConnection()
            check(!model.connecting && model.alert == nil, "Camera connection can be canceled before authorization completes")
        }
        let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        await MainActor.run {
            AppDelegate.installBrandIcon()
            let dock = NSApplication.shared.applicationIconImage?.studioCGImage
            check(dock != nil && NSImage(named: NSImage.Name("AppIcon"))?.isValid == true, "The native icon asset is explicitly installed as the running Dock icon")
        }
        check(icon?.isValid == true && Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "AppIcon", "The Clasp logo icon is valid and registered with macOS")
    }
    static func videoSample(index: Int) -> CMSampleBuffer? {
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixel)
        guard let pixel else { return nil }
        let image = CIImage(color: CIColor(red: 0.16, green: 0.2, blue: 0.24)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        CIContext().render(image, to: pixel)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: Int64(index), timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }
    static func audioSample(index: Int) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 3200, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 3200, flags: 0, blockBufferOut: &block)
        guard let block, let format else { return nil }
        var samples = [Int16](repeating: 0, count: 1600)
        let angularFrequency: Double = 2.0 * Double.pi * 440.0 / 48000.0
        let firstSample = index * 1600
        for i in samples.indices {
            let phase = Double(firstSample + i) * angularFrequency
            samples[i] = Int16(sin(phase) * 1800.0)
        }
        _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: 3200) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1600, presentationTimeStamp: CMTime(value: Int64(index * 1600), timescale: 48000), packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }
}

// Test the window coordinator without changing the user's desktop or opening a window.
final class FullScreenTestWindow: NSWindow {
    var fullScreenRequests = 0
    var simulatedFullScreen = false
    override var styleMask: NSWindow.StyleMask {
        get { simulatedFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask }
        set { super.styleMask = newValue.subtracting(.fullScreen) }
    }
    override func toggleFullScreen(_ sender: Any?) {
        fullScreenRequests += 1; simulatedFullScreen.toggle()
    }
}
