import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import CoreImage

enum PrompterMode: String, CaseIterable {
    case timed = "Reading pace"
    case voice = "Follow my voice"
}

@MainActor final class StudioModel: ObservableObject {
    @Published var project = StudioProject() { didSet {
        if oldValue.sections != project.sections { cachedWords = project.sections.map(\.words); pausePrompter(); voiceWord = 0 }
        if recording, oldValue.reference != project.reference, let start = recordStarted { recordReferences.append(RecordedReferenceCue(time: Date().timeIntervalSince(start), presentation: project.reference)) }
        updateGraphics(); scheduleSave()
    } }
    @Published var cameraID = ""
    @Published var microphoneID = ""
    @Published var cameras: [AVCaptureDevice] = []
    @Published var microphones: [AVCaptureDevice] = []
    let previewSurface = CameraPreviewSurface()
    @Published var connected = false
    @Published var microphoneActive = false
    @Published var connecting = false
    @Published var cameraReceivingFrames = false
    @Published var microphoneReceivingAudio = false
    @Published private(set) var sessionEvents: [String] = []
    private var connectionID = UUID()
    private var connectionDeadline: Timer?
    private var audioDeadline: Timer?
    private var cachedWords: [[String]] = []
    private let demoContext = CIContext(options: [.cacheIntermediates: false])
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0" }
    var sectionWords: [String] { cachedWords.indices.contains(activeSection) ? cachedWords[activeSection] : [] }
    func log(_ event: String) {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        sessionEvents.append(formatter.string(from: Date()) + "  " + event)
        if sessionEvents.count > 60 { sessionEvents.removeFirst(sessionEvents.count - 60) }
    }
    @Published var recording = false
    @Published var preparingRecording = false
    @Published var finishingRecording = false
    let audioMeter = MicrophoneLevel()
    @Published var recordingFocus = false
    @Published var nativeBackgroundActive = false
    @Published var nativePortraitActive = false
    private var pendingRecordingStart = false
    @Published var activeSection = 0 { didSet {
        sectionElapsed = 0
        if !applyingVoicePosition { voiceWord = 0; if prompterMode == .voice { pausePrompter() } }
        if recording, let start = recordStarted { recordCues.append(RecordedSectionCue(time: Date().timeIntervalSince(start), section: activeSection)) }
        updateGraphics()
    } }
    @Published var sectionElapsed = 0.0
    @Published var recordElapsed = 0.0
    @Published var prompterRunning = false { didSet {
        if prompterRunning && prompterMode == .voice { matcher = SpeechScriptMatcher(sections: project.sections, section: activeSection, word: voiceWord) }
        else if !prompterRunning { speech.stop() }
    } }
    @Published var prompterMode = PrompterMode.voice { didSet {
        pausePrompter()
        project.voiceFollowing = prompterMode == .voice
        if oldValue == .voice { sectionElapsed = Double(voiceWord) * 60 / max(1, project.wordsPerMinute) }
        else { voiceWord = min(currentTimedWord, section?.words.count ?? 0) }
    } }
    @Published var voiceStarting = false
    @Published var voiceWord = 0
    @Published var voiceStatus = "Matches your script · pauses with you"
    private let speech = SpeechFollower()
    private var matcher = SpeechScriptMatcher(sections: [])
    private var applyingVoicePosition = false
    private var voiceStartID = UUID()
    private var pendingVoiceStart = false
    @Published var alert: String?
    @Published var notice = "Your studio is ready. Connect a camera to go live."
    @Published var lastRecording: URL?
    @Published var recordingSavedOpen = false
    @Published var videoEditor: VideoEditorModel?
    @Published var openingVideoEditor = false
    @Published var importingSVG = false
    @Published var importingReference = false
    @Published var draftsOpen = false
    private var recordingDraft: URL?
    private var recordedProject: StudioProject?
    private var recordCues: [RecordedSectionCue] = []
    private var recordReferences: [RecordedReferenceCue] = []
    @Published var editorOpen = false
    @Published var editorText = ""
    @Published var settingsOpen = false
    @Published var overlayEditorOpen = false
    @Published var overlayEditorTab = "Library"
    let animationEpoch = ProcessInfo.processInfo.systemUptime
    var overlay: OverlayDocument { BroadcastGraphics.document(project) }
    var outputRect: CGRect { BroadcastGraphics.outputRect(project) }
    var outputAspectRatio: CGFloat { outputRect.width / outputRect.height }
    var outputDimensions: String { "\(Int(outputRect.width)) × \(Int(outputRect.height))" }
    var sponsors: [SponsorItem] { SponsorCatalog.migrated(project) }
    @Published var prompterSize = 22.0
    let updater = AppUpdater()
    let engine = CaptureEngine()
    private var timer: Timer?
    private var saveTimer: Timer?
    private var frameDeadline: Timer?
    private var recordStarted: Date?
    private var overlayMinute = -1
    private let projectURL: URL
    private let persists: Bool
    private var observers: [NSObjectProtocol] = []
    var section: ScriptSection? { project.sections.indices.contains(activeSection) ? project.sections[activeSection] : nil }
    var duration: Double { section?.duration(wpm: project.wordsPerMinute) ?? 1 }
    var progress: Double { prompterMode == .voice ? Double(voiceWord) / Double(max(1, sectionWords.count)) : min(1, sectionElapsed / duration) }
    private var currentTimedWord: Int { Int(sectionElapsed * project.wordsPerMinute / 60) }
    var currentWord: Int { prompterMode == .voice ? voiceWord : currentTimedWord }
    var scriptDescription: String {
        if let name = project.scriptName { return name }
        let sample = StudioProject().sections
        return project.sections.map(\.body) == sample.map(\.body) ? "Sample script · import or paste your own" : "Your saved script"
    }
    var allowsWindowChanges: Bool { persists }
    var busy: Bool { recording || preparingRecording || finishingRecording || pendingRecordingStart || openingVideoEditor || videoEditor?.isExporting == true }
    @Published var demoImage: NSImage?
    private func updateDemo(_ settings: RenderSettings) {
        guard !connected, videoEditor == nil, let cg = BroadcastGraphics.demoBackground else { return }
        let renderer = BroadcastFrameRenderer(settings)
        let frame = renderer.cropForOutput(renderer.compose(CIImage(cgImage: cg), at: animationEpoch))
        if let image = demoContext.createCGImage(frame, from: frame.extent) { demoImage = NSImage(cgImage: image, size: frame.extent.size) }
    }
    init(persist: Bool = true) {
        persists = persist
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClaspStudio")
        projectURL = directory.appendingPathComponent("project.json")
        if persist, let data = try? Data(contentsOf: projectURL), let saved = try? JSONDecoder().decode(StudioProject.self, from: data), !saved.sections.isEmpty { project = saved }
        // Retire app-generated backgrounds, including saved images from older versions.
        project.background = .original; project.backgroundData = nil
        if project.handle == "@PAYTONYOUNG" { project.handle = "@Payt0nY" }
        if project.overlayLibrary == nil || project.overlayLibrary?.isEmpty == true { project.overlayLibrary = OverlayDocument.presets(project) }
        if (project.overlayLibraryRevision ?? 1) < 2 {
            if !project.overlayLibrary!.contains(where: { $0.template == .jai }), let graphite = OverlayDocument.presets(project).first(where: { $0.template == .jai }) { project.overlayLibrary!.append(graphite) }
            project.overlayLibraryRevision = 2
        }
        if (project.overlayLibraryRevision ?? 2) < 3 {
            if !project.overlayLibrary!.contains(where: { $0.template == .glass }), let glass = OverlayDocument.presets(project).first(where: { $0.template == .glass }) { project.overlayLibrary!.append(glass) }
            project.overlayLibraryRevision = 3
        }
        if (project.overlayLibraryRevision ?? 3) < 4 {
            if !project.overlayLibrary!.contains(where: { $0.template == .ticker }), let ticker = OverlayDocument.presets(project).first(where: { $0.template == .ticker }) { project.overlayLibrary!.append(ticker) }
            project.overlayLibraryRevision = 4
        }
        if !project.overlayLibrary!.contains(where: { $0.id == project.selectedOverlayID }) { project.selectedOverlayID = project.overlayLibrary!.first!.id }
        if project.sponsorItems == nil { project.sponsorItems = SponsorCatalog.migrated(project) }
        cachedWords = project.sections.map(\.words)
        prompterMode = project.voiceFollowing == false ? .timed : .voice
        log("Clasp Studio " + Self.version + " · Apple camera effects only")
        refreshDevices()
        engine.onFirstVideo = { [weak self] in DispatchQueue.main.async { self?.cameraReceivingFrames = true; self?.log("Camera delivering frames") } }
        engine.onFirstAudio = { [weak self] in DispatchQueue.main.async { self?.microphoneReceivingAudio = true; self?.log("Selected microphone delivering audio") } }
        engine.onFrame = { [weak previewSurface] frame in previewSurface?.submit(frame) }
        engine.onNativeEffects = { [weak self] background, portrait in DispatchQueue.main.async { self?.nativeBackgroundActive = background; self?.nativePortraitActive = portrait } }
        engine.onAudio = { [weak speech] sample in speech?.append(sample) }
        speech.onSessionReset = { [weak self] id in DispatchQueue.main.async { if self?.voiceStartID == id { self?.matcher.resetTranscript() } } }
        speech.onTranscript = { [weak self] id, text in DispatchQueue.main.async { if self?.voiceStartID == id { self?.followTranscript(text) } } }
        speech.onFailure = { [weak self] id, message in DispatchQueue.main.async {
            guard let self, self.voiceStartID == id, self.prompterMode == .voice, self.prompterRunning else { return }
            self.pausePrompter(); self.voiceStatus = "Voice unavailable · try Reading pace"; self.alert = message
        } }
        engine.onLevel = { [weak audioMeter] value in DispatchQueue.main.async { audioMeter?.level = value } }
        engine.onStatus = { [weak self] connected, audio, error in DispatchQueue.main.async {
            guard let self else { return }
            self.connectionDeadline?.invalidate()
            self.connected = connected; self.microphoneActive = audio; self.connecting = false
            self.log(connected ? "Capture session running · mic \(audio ? "connected" : "unavailable")" : "Capture session stopped")
            if !connected {
                self.previewSurface.clear(); self.cameraReceivingFrames = false; self.microphoneReceivingAudio = false
                self.pausePrompter()
                if self.pendingRecordingStart { self.cancelRecordingSetup() }
            }
            if connected, self.pendingVoiceStart {
                self.pendingVoiceStart = false; self.voiceStarting = false
                Task { await self.beginVoiceFollowing() }
            }
            if connected, self.pendingRecordingStart { self.pendingRecordingStart = false; self.beginRecording() }
            if let error { self.alert = error; self.log(error) }
            self.notice = connected ? (audio ? "Camera connected · ready to record" : "Camera connected · no microphone audio; recordings will be silent") : "Camera disconnected"
        } }
        engine.onWarning = { [weak self] message in DispatchQueue.main.async { self?.notice = message } }
        engine.onRecordingStarted = { [weak self] in DispatchQueue.main.async {
            guard let self, self.preparingRecording, !self.finishingRecording else { return }
            self.frameDeadline?.invalidate(); self.preparingRecording = false; self.recording = true; self.recordStarted = Date(); self.recordElapsed = 0; self.recordingFocus = true
            self.recordCues = [RecordedSectionCue(time: 0, section: self.activeSection)]
            self.recordReferences = [RecordedReferenceCue(time: 0, presentation: self.project.reference)]
            if !self.prompterRunning && !self.voiceStarting {
                if self.prompterMode == .timed || self.microphoneActive { self.togglePrompter() }
                else { self.voiceStatus = "No microphone audio · choose Reading pace" }
            }
            self.log("Recording started on first video frame")
            self.notice = self.microphoneActive ? "Recording your camera and microphone · edit graphics after stopping." : "Recording camera · no microphone audio."
        } }
        engine.onRecordingFinished = { [weak self] url, error in DispatchQueue.main.async {
            guard let self else { return }
            self.frameDeadline?.invalidate(); self.recording = false; self.preparingRecording = false; self.finishingRecording = false; self.recordStarted = nil; self.recordingFocus = false; self.pausePrompter()
            if let error { self.alert = error; self.notice = "Recording could not be saved."; self.log(error) }
            else if let url {
                self.notice = "Take captured · opening the editor…"; self.log("Draft recording finalized successfully")
                var recorded = self.recordedProject ?? self.project; recorded.referenceImages = self.project.referenceImages
                self.openRecordedDraft(url, folder: self.recordingDraft, project: recorded, cues: self.recordCues, references: self.recordReferences)
            }
        } }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.devicesChanged() } })
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: engine.session, queue: .main) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Task { @MainActor in self?.pausePrompter(); self?.connected = false; self?.notice = error?.localizedDescription ?? "Camera stopped. Reconnect to continue."; if self?.busy == true { self?.stopRecording() } }
        })
        updateGraphics()
        if persists { engine.startDemo() }
    }
    func refreshDevices() {
        cameras = CaptureEngine.devices(.video); microphones = CaptureEngine.devices(.audio)
        if !cameras.contains(where: { $0.uniqueID == cameraID }) { cameraID = cameras.first?.uniqueID ?? "" }
        if !microphones.contains(where: { $0.uniqueID == microphoneID }) && microphoneID != "none" { microphoneID = microphones.first?.uniqueID ?? "none" }
    }
    private func devicesChanged() {
        let oldCamera = cameraID, oldMic = microphoneID
        refreshDevices()
        if connected && (cameraID != oldCamera || microphoneID != oldMic) {
            if busy { stopRecording() }
            pausePrompter(); engine.disconnect(); connected = false; previewSurface.clear()
            notice = "A selected device was disconnected. Select your devices and reconnect."
        }
    }
    func connect() {
        guard (!busy || pendingRecordingStart), !connecting else { return }
        connecting = true; cameraReceivingFrames = false; microphoneReceivingAudio = false
        let id = UUID(); connectionID = id
        log("Connecting selected camera and microphone")
        notice = "Waiting for macOS camera and microphone access…"
        armConnectionDeadline(id, seconds: 45, waitingForPermission: true)
        Task { [self] in
            let video = await permission(.video)
            guard connectionID == id else { return }
            guard video else {
                connectionDeadline?.invalidate(); connecting = false; cancelRecordingSetup(); pausePrompter()
                alert = "Camera access is disabled. Enable Clasp Studio in System Settings → Privacy & Security → Camera, then connect again."
                log("Camera permission denied"); return
            }
            if microphoneID != "none" {
                let audio = await permission(.audio)
                guard connectionID == id else { return }
                if !audio { notice = "Microphone access is disabled. Video will record without audio."; log("Microphone permission denied") }
            }
            guard connectionID == id else { return }
            notice = "Connecting your selected camera…"
            armConnectionDeadline(id, seconds: 15, waitingForPermission: false)
            engine.connect(cameraID: cameraID, microphoneID: microphoneID == "none" ? "" : microphoneID)
        }
    }
    private func armConnectionDeadline(_ id: UUID, seconds: Double, waitingForPermission: Bool) {
        connectionDeadline?.invalidate()
        connectionDeadline = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in Task { @MainActor in
            guard let self, self.connecting, self.connectionID == id else { return }
            self.expireConnection(waitingForPermission: waitingForPermission)
        } }
    }
    func expireConnection(waitingForPermission: Bool) {
        guard connecting else { return }
        cancelConnection()
        alert = waitingForPermission ? "macOS has not completed the camera or microphone authorization. Check the permission prompt or System Settings → Privacy & Security, then connect again." : "The camera connection timed out. Close other camera apps, reconnect the camera, and try again."
        log(waitingForPermission ? "Camera/microphone authorization timed out" : "Camera connection timed out")
    }
    func cancelConnection() {
        guard connecting else { return }
        connectionID = UUID(); connectionDeadline?.invalidate(); connecting = false
        cancelRecordingSetup(); pausePrompter(); engine.disconnect()
        notice = "Connection canceled. You can connect again when ready."; log("Canceled camera connection")
    }
    private func permission(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined:
            log("Waiting for macOS \(media == .video ? "camera" : "microphone") authorization")
            return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }
    func selectDevice() { pausePrompter(); if connected { connect() } }
    func disconnect() { guard !busy else { return }; pausePrompter(); engine.disconnect() }
    private var lastGraphicsSection = 0
    private var tickerPreviousSection: Int?
    private var tickerChangeTime = -1_000_000.0
    func updateGraphics(at date: Date = Date()) {
        overlayMinute = Int(date.timeIntervalSince1970 / 60)
        if activeSection != lastGraphicsSection { tickerPreviousSection = lastGraphicsSection; lastGraphicsSection = activeSection; tickerChangeTime = ProcessInfo.processInfo.systemUptime }
        let settings = BroadcastGraphics.renderSettings(project, activeIndex: activeSection, at: date, epoch: animationEpoch, previousSection: tickerPreviousSection, tickerEpoch: tickerChangeTime)
        updateDemo(settings)
        engine.update(settings)
    }
    func scheduleSave() {
        guard persists else { return }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in Task { @MainActor in self?.save() } }
    }
    func save() {
        guard persists else { return }
        do { try FileManager.default.createDirectory(at: projectURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(project).write(to: projectURL, options: .atomic) }
        catch { notice = "Project could not be saved: \(error.localizedDescription)" }
    }
    func refreshClockIfNeeded(at date: Date = Date()) {
        if Int(date.timeIntervalSince1970 / 60) != overlayMinute { updateGraphics(at: date) }
    }
    func setSponsor(_ name: String, enabled: Bool) {
        var names = project.sponsorNames ?? ["Filevine", "Dropbox"]
        if enabled { if !names.contains(name) { names.append(name) } }
        else { names.removeAll { $0 == name } }
        project.sponsorNames = names
    }
    func tick() {
        refreshClockIfNeeded()
        if let recordStarted {
            let elapsed = Date().timeIntervalSince(recordStarted)
            if Int(elapsed) != Int(recordElapsed) { recordElapsed = elapsed }
        }
        if prompterRunning && prompterMode == .timed {
            sectionElapsed += 0.1
            if sectionElapsed >= duration {
                if activeSection + 1 < project.sections.count { activeSection += 1 }
                else { prompterRunning = false; sectionElapsed = duration }
            }
        }
    }
    func next() { if activeSection + 1 < project.sections.count { activeSection += 1 } }
    func previous() { if prompterMode == .voice { pausePrompter(); voiceWord = 0 }; if activeSection > 0 { activeSection -= 1 } else { sectionElapsed = 0 } }
    func restart() { pausePrompter(); activeSection = 0; sectionElapsed = 0; voiceWord = 0; voiceStatus = "Matches your script · pauses with you" }
    func pausePrompter() {
        audioDeadline?.invalidate()
        voiceStartID = UUID(); pendingVoiceStart = false; voiceStarting = false; prompterRunning = false
    }
    func togglePrompter() {
        if prompterRunning || voiceStarting { pausePrompter(); return }
        guard prompterMode == .voice else { prompterRunning = true; return }
        guard microphoneID != "none" else { alert = "Select a microphone below the preview to follow your voice."; return }
        if !connected {
            pendingVoiceStart = true; voiceStarting = true; voiceStatus = "Connecting microphone…"; connect()
        } else { voiceStarting = true; Task { await beginVoiceFollowing() } }
    }
    private func beginVoiceFollowing() async {
        guard prompterMode == .voice, connected, microphoneActive else {
            pausePrompter(); alert = "Voice following needs microphone audio. Select a microphone and allow microphone access, then connect again."; return
        }
        if voiceWord >= (section?.words.count ?? 0), activeSection == project.sections.count - 1 { activeSection = 0; voiceWord = 0 }
        let id = UUID(); voiceStartID = id; voiceStarting = true; voiceStatus = "Waiting for Speech Recognition permission…"; log("Requesting speech authorization")
        let authorized = await SpeechFollower.authorize()
        guard voiceStartID == id, prompterMode == .voice, connected else { return }
        voiceStarting = false
        guard authorized else {
            voiceStatus = "Speech permission needed"
            alert = "Allow Clasp Studio in System Settings → Privacy & Security → Speech Recognition to use Follow my voice. Reading pace works without this permission."; return
        }
        matcher = SpeechScriptMatcher(sections: project.sections, section: activeSection, word: voiceWord)
        prompterRunning = true; voiceStatus = "Listening · read the highlighted words"; log("Starting on-device speech recognition")
        speech.start(id: id, hints: project.sections.dropFirst(activeSection).prefix(3).map(\.body))
        audioDeadline = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in Task { @MainActor in
            guard let self, self.voiceStartID == id, self.prompterRunning, !self.microphoneReceivingAudio else { return }
            self.pausePrompter(); self.voiceStatus = "No microphone audio received"
            self.alert = "Your microphone is connected but isn't delivering audio. Check its input level, cable, and microphone permission, then reconnect it."
            self.log("Voice following received no microphone samples")
        } }
    }
    func followTranscript(_ text: String) {
        guard prompterRunning, prompterMode == .voice else { return }
        guard let position = matcher.update(text) else { if voiceStatus != "Listening · waiting for matching words" { voiceStatus = "Listening · waiting for matching words" }; return }
        applyingVoicePosition = true
        if activeSection != position.section { activeSection = position.section }
        voiceWord = position.word; applyingVoicePosition = false
        if voiceStatus != "Following your voice" { voiceStatus = "Following your voice" }
        if position.finished { pausePrompter(); voiceStatus = "Script complete" }
    }
    func importScript() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, .pdf, .rtf, UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "docx") ?? .data]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let sections = ScriptParser.parse(try ScriptParser.load(url))
            guard !sections.isEmpty else { throw StudioError.message("This script is empty. Add some text and import again.") }
            prompterRunning = false; activeSection = 0; project.sections = sections; project.scriptName = url.lastPathComponent; notice = "Imported \(sections.count) script sections from \(url.lastPathComponent)."
        } catch { alert = error.localizedDescription }
    }
    func editScript() { editorText = ScriptParser.markdown(project.sections); editorOpen = true }
    func applyScript() {
        let sections = ScriptParser.parse(editorText)
        guard !sections.isEmpty else { alert = "Add at least one paragraph to your script."; return }
        prompterRunning = false; activeSection = 0; project.sections = sections; project.scriptName = "Custom script"; editorOpen = false
    }
    func editOverlays(_ tab: String = "Library") { overlayEditorTab = tab; overlayEditorOpen = true }
    func importReferenceImage() {
        guard !importingReference, !finishingRecording, !preparingRecording else { return }
        StudioFileDialog.media(image: true, multiple: false, message: "Choose a reference image to show beside you") { [weak self] urls in
            guard let self, let url = urls.first else { return }
            self.importingReference = true
            Task {
                defer { self.importingReference = false }
                do {
                    let asset = try await Task.detached { try BroadcastReferenceImage.load(url) }.value
                    var project = self.project; var library = project.referenceImages ?? []; library.append(asset); project.referenceImages = library
                    var presentation = project.reference ?? ReferencePresentation(imageID: asset.id); presentation.imageID = asset.id; presentation.visible = true
                    project.reference = presentation; self.project = project
                    self.notice = "Reference image ready. Use On air to show or hide it."
                } catch { self.alert = error.localizedDescription }
            }
        }
    }
    func importSVGOverlay(replacing id: UUID? = nil) {
        guard !busy, !importingSVG else { return }
        StudioFileDialog.svg { [weak self] url in
            guard let self else { return }
            self.importingSVG = true
            Task {
                defer { self.importingSVG = false }
                do {
                    let data = try await Task.detached {
                        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 12 * 1024 * 1024 else { throw StudioError.message("Choose an SVG under 12 MB.") }
                        return try Data(contentsOf: url)
                    }.value
                    let artwork = try await SVGOverlayImport.render(data)
                    if let id, let index = self.project.overlayLibrary?.firstIndex(where: { $0.id == id }) {
                        self.project.overlayLibrary?[index].importedSVG = artwork
                        self.project.overlayLibrary?[index].cameraWindow = nil
                    } else {
                        var document = OverlayDocument(name: url.deletingPathExtension().lastPathComponent, template: .custom, title: "", presenter: "", handle: "", date: Date(), headlineHeading: "", brandName: "", brandSubtitle: "", accentHex: "FFFFFF", liveDotHex: "FF343B", titleSize: 39)
                        document.showDate = false; document.showPresenter = false; document.showHeadlines = false; document.showLive = false; document.showPresentedBy = false; document.showSponsors = false
                        document.importedSVG = artwork
                        var library = self.project.overlayLibrary ?? []; library.append(document)
                        self.project.overlayLibrary = library; self.project.selectedOverlayID = document.id
                        self.videoEditor?.updateBroadcast(self.project)
                        self.videoEditor?.changeClip { $0.overlayID = document.id }
                    }
                    self.notice = "SVG imported. Original artwork and gradients are ready in your overlay library."
                } catch { self.alert = error.localizedDescription }
            }
        }
    }
    func refreshImportedSVG(replacePhotos: Bool? = nil, removeCanvasFill: Bool? = nil, fit: SVGArtworkFit? = nil) {
        guard !importingSVG, !busy, let asset = overlay.importedSVG else { return }
        let id = overlay.id; importingSVG = true
        Task {
            defer { importingSVG = false }
            do {
                let rendered = try await SVGOverlayImport.render(asset.source, replacePhotos: replacePhotos ?? asset.replacePhotos, removeCanvasFill: removeCanvasFill ?? asset.removeCanvasFill, fit: fit ?? asset.fit ?? .fit)
                guard let index = project.overlayLibrary?.firstIndex(where: { $0.id == id }) else { return }
                project.overlayLibrary?[index].importedSVG = rendered
            } catch { alert = error.localizedDescription }
        }
    }
    func editOverlay(_ change: (inout OverlayDocument) -> Void) {
        var library = project.overlayLibrary ?? OverlayDocument.presets(project)
        guard let index = library.firstIndex(where: { $0.id == overlay.id }) else { return }
        change(&library[index]); project.overlayLibrary = library
    }
    func selectOverlay(_ id: UUID) { project.selectedOverlayID = id }
    func duplicateOverlay() {
        var document = overlay; document.id = UUID(); document.name += " copy"
        var library = project.overlayLibrary ?? []; library.append(document); project.overlayLibrary = library; project.selectedOverlayID = document.id
    }
    func removeOverlay(_ id: UUID) {
        guard var library = project.overlayLibrary, library.count > 1 else { return }
        library.removeAll { $0.id == id }; project.overlayLibrary = library
        if project.selectedOverlayID == id { project.selectedOverlayID = library.first!.id }
    }
    func updateSponsor(_ id: UUID, _ change: (inout SponsorItem) -> Void) {
        var items = sponsors; guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index]); project.sponsorItems = items
    }
    func renameSponsor(_ id: UUID, name: String) {
        updateSponsor(id) { item in
            item.name = name
            if let artwork = item.artwork, name != SponsorCatalog.names[artwork] { item.showName = true }
        }
    }
    func addSponsor() {
        guard sponsors.count < 12 else { alert = "You can add up to 12 sponsors."; return }
        var items = sponsors; items.append(SponsorItem(name: "New sponsor")); project.sponsorItems = items
    }
    func removeSponsor(_ id: UUID) { project.sponsorItems = sponsors.filter { $0.id != id } }
    func moveSponsor(_ id: UUID, by delta: Int) {
        var items = sponsors
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + delta) else { return }
        items.swapAt(index, index + delta); project.sponsorItems = items
    }
    private func chooseLogoData() -> Data? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let image = NSImage(contentsOf: url), let cg = image.studioCGImage else { alert = "Could not read this logo. Use PNG, JPEG, HEIC, TIFF or PDF."; return nil }
        let scale = min(1, 800 / Double(max(cg.width, cg.height)))
        guard let reduced = BroadcastGraphics.bitmap(width: max(1, Int(Double(cg.width) * scale)), height: max(1, Int(Double(cg.height) * scale)), { ctx in ctx.draw(cg, in: CGRect(x: 0, y: 0, width: Double(cg.width) * scale, height: Double(cg.height) * scale)) }) else { return nil }
        return NSBitmapImageRep(cgImage: reduced).representation(using: .png, properties: [:])
    }
    func replaceSponsorLogo(_ id: UUID) {
        guard let data = chooseLogoData() else { return }
        updateSponsor(id) { $0.logoData = data; $0.artwork = nil }
    }
    func replaceOverlayLogo(program: Bool) {
        guard let data = chooseLogoData() else { return }
        editOverlay { if program { $0.programLogoData = data } else { $0.brandLogoData = data } }
    }
    func importLogo() { addSponsor(); overlayEditorTab = "Sponsors"; overlayEditorOpen = true }
    func importBrandLogo() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url), let data = image.studioPNG else { alert = "Could not read this logo."; return }
        project.primaryLogoData = data
    }
    var recordingDirectory: URL {
        if let path = project.recordingFolder { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Clasp Studio", isDirectory: true)
    }
    static func recordingURL(in directory: URL, at date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return directory.appendingPathComponent("Clasp-\(formatter.string(from: date))-\(UUID().uuidString.prefix(6)).mov")
    }
    func chooseRecordingFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use this folder"; panel.directoryURL = recordingDirectory
        if panel.runModal() == .OK, let url = panel.url { project.recordingFolder = url.path }
    }
    func openAppleEffects() {
        guard connected else { alert = "Connect a camera to open Apple’s video effects."; return }
        project.background = .original
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }
    func startRecording() {
        guard !busy else { return }
        // Focus and feedback change on the click, even before permissions or the
        // first camera frame. Never leave the user wondering whether it worked.
        recordingFocus = true; preparingRecording = true; recordElapsed = 0
        editorOpen = false; settingsOpen = false; overlayEditorOpen = false; recordingSavedOpen = false; log("Start recording clicked")
        if !connected {
            pendingRecordingStart = true; notice = "Connecting camera to start recording…"
            connect(); return
        }
        beginRecording()
    }
    private func beginRecording() {
        do {
            let folder: URL
            if persists { folder = try EditStorage.makeDraft() }
            else { folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Clasp-test-draft-" + UUID().uuidString); try FileManager.default.createDirectory(at: folder.appendingPathComponent("Media"), withIntermediateDirectories: true) }
            recordingDraft = folder; recordedProject = project; recordCues = []; recordReferences = []
            let url = folder.appendingPathComponent("Media/source.mov")
            preparingRecording = true; notice = "Starting recording…"; log("Starting video encoder")
            engine.startRecording(to: url, cleanSource: true)
            frameDeadline?.invalidate()
            frameDeadline = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in Task { @MainActor in
                guard let self, self.preparingRecording else { return }
                self.stopRecording(); self.log("Recording timed out waiting for video")
                self.alert = "The camera did not deliver a frame. Reconnect it and try again."
            } }
        } catch {
            cancelRecordingSetup()
            alert = "Could not create a recording in \(recordingDirectory.path): \(error.localizedDescription). Choose another folder in Studio settings."
            log("Cannot create recording file: " + error.localizedDescription)
        }
    }
    private func cancelRecordingSetup() {
        pendingRecordingStart = false; preparingRecording = false; recordingFocus = false
    }
    func stopRecording() {
        guard recording || preparingRecording || pendingRecordingStart, !finishingRecording else { return }
        frameDeadline?.invalidate()
        if pendingRecordingStart {
            connectionID = UUID(); connectionDeadline?.invalidate(); connecting = false
            cancelRecordingSetup(); pausePrompter(); engine.disconnect(); notice = "Recording canceled."; log("Canceled before camera connection"); return
        }
        finishingRecording = true; recording = false; preparingRecording = false
        log("Finalizing recording"); engine.stopRecording()
    }
    private func configureEditor(_ editor: VideoEditorModel) {
        pausePrompter(); engine.disconnect(); connected = false
        editor.onExport = { [weak self] url in
            self?.lastRecording = url; self?.recordingSavedOpen = true; self?.notice = "Exported " + url.lastPathComponent
        }
        project = editor.document.broadcast; videoEditor = editor; openingVideoEditor = false
    }
    private func openRecordedDraft(_ url: URL, folder: URL?, project: StudioProject, cues: [RecordedSectionCue], references: [RecordedReferenceCue]) {
        openingVideoEditor = true
        Task {
            do {
                let length = try await EditStorage.inspect(url, kind: .video)
                let directory = folder ?? url.deletingLastPathComponent().deletingLastPathComponent()
                let media = EditMedia(name: "Original take.mov", fileName: url.lastPathComponent, kind: .video, duration: length)
                var document = VideoEditDocument(name: "Broadcast " + Date().formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()), broadcast: project, media: [media])
                document.clips = RecordedTimeline.clips(mediaID: media.id, duration: length, project: project, sections: cues, references: references)
                try EditStorage.save(document, at: directory)
                configureEditor(VideoEditorModel(document: document, folder: directory)); notice = "Your draft is ready to edit. Export when you’re happy with it."
            } catch { openingVideoEditor = false; alert = "The take is safe at \(url.path), but the editor could not open it: " + error.localizedDescription }
        }
    }
    func importVideo() {
        guard !busy, videoEditor == nil else { return }
        StudioFileDialog.media(multiple: true, message: "Import a Zoom recording or other MOV / MP4") { [weak self] urls in
            guard let self else { return }; self.importVideos(urls)
        }
    }
    private func importVideos(_ urls: [URL]) {
        guard !busy, videoEditor == nil, !urls.isEmpty else { return }
        openingVideoEditor = true
        Task {
            do {
                let folder = try EditStorage.makeDraft()
                var document = VideoEditDocument(name: urls.first?.deletingPathExtension().lastPathComponent ?? "Imported broadcast", broadcast: project)
                for url in urls {
                    let duration = try await EditStorage.inspect(url, kind: .video)
                    let media = EditMedia(name: url.lastPathComponent, fileName: UUID().uuidString + "." + url.pathExtension, kind: .video, duration: duration)
                    let destination = EditStorage.source(media, in: folder)
                    try await Task.detached { try FileManager.default.copyItem(at: url, to: destination) }.value
                    document.media.append(media); document.clips.append(EditClip(mediaID: media.id, start: 0, end: duration, overlayID: project.selectedOverlayID))
                }
                try EditStorage.save(document, at: folder); configureEditor(VideoEditorModel(document: document, folder: folder))
            } catch { openingVideoEditor = false; alert = error.localizedDescription }
        }
    }
    func openDraft(_ folder: URL) {
        guard !busy else { return }
        do {
            let document = try JSONDecoder().decode(VideoEditDocument.self, from: Data(contentsOf: folder.appendingPathComponent("edit.json")))
            videoEditor?.stop(); configureEditor(VideoEditorModel(document: document, folder: folder)); draftsOpen = false
        } catch { alert = "This draft could not be opened: " + error.localizedDescription }
    }
    func closeVideoEditor() {
        guard let editor = videoEditor, !editor.isExporting, !editor.importing else { return }
        editor.saveNow(); editor.stop(); videoEditor = nil; notice = "Draft saved. Open Drafts to continue editing."
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Clasp-session-status.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = "Clasp Studio " + Self.version + "\n" + sessionEvents.joined(separator: "\n")
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { alert = error.localizedDescription }
    }
    func revealLastRecording() {
        if let url = lastRecording { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    func snapshot() {
        let camera = previewSurface.currentFrame().flatMap { frame in CIContext().createCGImage(frame, from: frame.extent) }.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        guard let image = camera ?? demoImage, let data = image.studioPNG else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Clasp-frame.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url); notice = "Frame saved to \(url.lastPathComponent)." } catch { alert = error.localizedDescription }
    }
    static func time(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}

@MainActor final class MicrophoneLevel: ObservableObject { @Published var level = 0.0 }
