import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers
import Combine

@MainActor final class VideoEditorModel: ObservableObject {
    @Published var document: VideoEditDocument { didSet {
        scheduleSave()
        if document.clips != oldValue.clips || document.media != oldValue.media || (try? JSONEncoder().encode(document.broadcast)) != (try? JSONEncoder().encode(oldValue.broadcast)) { scheduleRebuild() }
    } }
    let folder: URL
    let player = AVPlayer()
    let animations = AnimationLibrary()
    @Published var selection: UUID?
    @Published var position = 0.0
    @Published var playing = false
    @Published var preparing = false
    @Published var importing = false
    @Published var isExporting = false
    @Published var exportProgress: Float = 0
    @Published var error: String?
    @Published var status = "Draft saved · original media stays intact"
    @Published var presentationStill: NSImage?
    @Published var previewFailure: String?
    @Published var pausedFrame: NSImage?
    private var frameTask: Task<Void, Never>?
    private var frameGeneration = 0
    private var seekGeneration = 0
    private var seeking = false
    private var playerStatusObserver: NSKeyValueObservation?
    @Published var thumbnails: [UUID: NSImage] = [:]
    @Published var animationLibraryOpen = false
    @Published var canUndo = false
    @Published var canRedo = false
    var onExport: ((URL) -> Void)?
    private var previous: [VideoEditDocument] = [], next: [VideoEditDocument] = []
    private var rebuildTask: Task<Void, Never>?, saveTask: Task<Void, Never>?
    private var timeObserver: Any?, finishObserver: NSObjectProtocol?
    private var exportSession: AVAssetExportSession?
    private var cancelRequested = false
    private var generation = 0
    private var result: EditCompositionResult?
    var duration: Double { document.duration }
    var selected: EditClip? { document.clips.first(where: { $0.id == selection }) }
    init(document: VideoEditDocument, folder: URL) {
        self.document = document; self.folder = folder; selection = document.clips.first?.id
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in Task { @MainActor in guard let self, self.playing, !self.preparing, !self.seeking else { return }; self.position = time.seconds.isFinite ? time.seconds : 0 } }
        finishObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in Task { @MainActor in guard let self, notification.object as? AVPlayerItem === self.player.currentItem else { return }; self.playing = false; self.requestPausedFrame() } }
        scheduleRebuild(); Task { await refreshThumbnails() }
    }
    func stop() { player.pause(); playing = false; frameTask?.cancel(); rebuildTask?.cancel(); saveTask?.cancel(); try? EditStorage.save(document, at: folder); if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }; if let finishObserver { NotificationCenter.default.removeObserver(finishObserver); self.finishObserver = nil } }
    func saveNow() { do { try EditStorage.save(document, at: folder) } catch { self.error = "The draft could not be saved: " + error.localizedDescription } }
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }; self?.saveNow() }
    }
    func updateBroadcast(_ project: StudioProject) {
        guard !isExporting else { return }
        guard (try? JSONEncoder().encode(document.broadcast)) != (try? JSONEncoder().encode(project)) else { return }
        document.broadcast = project
    }
    private func remember() { previous.append(document); if previous.count > 50 { previous.removeFirst() }; next.removeAll(); updateHistory() }
    private func updateHistory() { canUndo = !previous.isEmpty; canRedo = !next.isEmpty }
    func undo() { guard !isExporting, let value = previous.popLast() else { return }; next.append(document); document = value; selection = document.clips.first?.id; updateHistory() }
    func redo() { guard !isExporting, let value = next.popLast() else { return }; previous.append(document); document = value; selection = document.clips.first?.id; updateHistory() }
    func changeClip(_ change: (inout EditClip) -> Void) {
        guard !isExporting, let index = document.clips.firstIndex(where: { $0.id == selection }) else { return }
        remember(); var copy = document; change(&copy.clips[index]); document = copy
    }
    func trim(start: Double? = nil, end: Double? = nil) {
        guard let clip = selected, let source = document.media.first(where: { $0.id == clip.mediaID }) else { return }
        changeClip { value in
            if let start { value.start = min(value.end - 1.0 / 30, max(0, start)) }
            if let end { value.end = max(value.start + 1.0 / 30, min(source.duration, end)) }
        }
        seek(document.start(of: clip.id))
    }
    func setIn() { guard let clip = document.clip(at: position) else { return }; selection = clip.id; trim(start: clip.start + (position - document.start(of: clip.id)) * clip.safeSpeed) }
    func setOut() { guard let clip = document.clip(at: position) else { return }; selection = clip.id; trim(end: clip.start + (position - document.start(of: clip.id)) * clip.safeSpeed) }
    func split() {
        guard !isExporting else { return }
        var copy = document
        guard let right = copy.split(at: position) else { status = "Move the playhead inside a clip to split it."; return }
        remember(); document = copy; selection = right; status = "Clip split · select either part to trim or remove it"
    }
    func delete() { guard !isExporting, let id = selection else { return }; remember(); document.clips.removeAll { $0.id == id }; selection = document.clips.first?.id; seek(min(position, max(0, duration - 0.01))) }
    func move(_ offset: Int) {
        guard !isExporting, let index = document.clips.firstIndex(where: { $0.id == selection }) else { return }
        let destination = index + offset; guard document.clips.indices.contains(destination) else { return }
        remember(); document.clips.swapAt(index, destination); if let selection { seek(document.start(of: selection)) }
    }
    func moveClip(_ id: UUID, to destination: Int) {
        guard !isExporting, let index = document.clips.firstIndex(where: { $0.id == id }), document.clips.indices.contains(destination), index != destination else { return }
        remember(); var copy = document; let item = copy.clips.remove(at: index); copy.clips.insert(item, at: destination); document = copy; selection = id; seek(document.start(of: id))
    }
    func select(_ id: UUID) { selection = id; seek(document.start(of: id)) }
    func seek(_ seconds: Double) {
        position = max(0, min(max(0, duration - 1.0 / 600), seconds)); seekGeneration += 1
        let token = seekGeneration; seeking = true
        player.seek(to: EditCompositionBuilder.time(position), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in Task { @MainActor in guard let self, token == self.seekGeneration else { return }; self.seeking = false } }
        requestPausedFrame()
    }
    func requestPausedFrame() {
        frameTask?.cancel(); frameGeneration += 1
        guard !playing, !preparing, let result else { return }
        let token = frameGeneration, compositionToken = generation
        let time = floor(min(position, max(0, duration - 1.0 / 30)) * 30) / 30
        frameTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 45_000_000)
                let generator = AVAssetImageGenerator(asset: result.composition)
                generator.videoComposition = result.video; generator.maximumSize = CGSize(width: 1280, height: 720)
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
                let (image, _) = try await withTaskCancellationHandler(operation: { try await generator.image(at: EditCompositionBuilder.time(time)) }, onCancel: { generator.cancelAllCGImageGeneration() })
                guard let self, !Task.isCancelled, token == self.frameGeneration, compositionToken == self.generation else { return }
                self.pausedFrame = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            } catch { /* A canceled scrub keeps the last frame until the newest seek completes. */ }
        }
    }
    func stepFrame(_ direction: Int) { player.pause(); playing = false; seek(position + Double(direction) / 30) }
    func duplicate() {
        guard !isExporting, let selected, let index = document.clips.firstIndex(where: { $0.id == selected.id }) else { return }
        remember(); var copy = document, clone = selected; clone.id = UUID(); copy.clips.insert(clone, at: index + 1); document = copy; selection = clone.id; seek(document.start(of: clone.id))
    }
    func setSpeed(_ speed: Double) { changeClip { $0.speed = min(4, max(0.25, speed)) }; if let selected { seek(document.start(of: selected.id)) } }
    func previewTransition() { guard let selected else { return }; seek(document.start(of: selected.id) + max(0, selected.animationOffset ?? 0)); togglePlayback() }
    func clearAnimation() { changeClip { $0.animationID = nil; $0.transition = .cut; $0.animationStart = nil; $0.animationOffset = nil } }

    func togglePlayback() {
        guard !preparing, !isExporting, result != nil else { return }
        if playing { player.pause(); playing = false; requestPausedFrame() }
        else { if position >= duration - 0.03 { seek(0) }; player.play(); playing = true }
    }
    func scheduleRebuild() {
        guard !isExporting else { return }
        previewFailure = nil
        generation += 1; let token = generation
        rebuildTask?.cancel(); player.pause(); playing = false; preparing = true
        let copy = document, directory = folder
        rebuildTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                let buildTask = Task.detached(priority: .userInitiated) { try await EditCompositionBuilder.build(copy, folder: directory, preview: true) }
                let result = try await withTaskCancellationHandler(operation: { try await buildTask.value }, onCancel: { buildTask.cancel() })
                guard let self, !Task.isCancelled, token == self.generation else { return }
                self.result = result
                let item = result.playerItem()
                self.playerStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    if item.status == .readyToPlay { Task { @MainActor in guard let self, token == self.generation else { return }; self.seek(self.position) } }
                    if item.status == .failed { Task { @MainActor in guard let self, token == self.generation else { return }; self.previewFailure = item.error?.localizedDescription ?? "The video could not be decoded."; self.playing = false } }
                }
                self.player.replaceCurrentItem(with: item); self.preparing = false
                self.seek(min(self.position, max(0, self.duration - 0.01))); self.status = "Draft saved · \(self.document.clips.count) clips · \(Self.time(self.duration))"
            } catch {
                guard let self, !Task.isCancelled, token == self.generation else { return }
                self.preparing = false; self.result = nil; self.player.replaceCurrentItem(with: nil); self.status = error.localizedDescription; self.previewFailure = error.localizedDescription
            }
        }
    }
    func addExistingMedia(_ id: UUID) {
        guard !isExporting, let media = document.media.first(where: { $0.id == id && $0.kind == .video }) else { return }
        remember(); let clip = EditClip(mediaID: id, start: 0, end: media.duration, overlayID: document.broadcast.selectedOverlayID)
        document.clips.append(clip); selection = clip.id
    }
    func importMedia(_ kind: EditMedia.Kind, secondary: Bool = false) {
        guard !isExporting, !importing else { return }
        StudioFileDialog.media(image: kind == .image, multiple: !secondary, message: kind == .image ? "Choose an image for this shot" : secondary ? "Choose a guest or supporting video" : "Import footage into this draft") { [weak self] urls in
            self?.importMediaFiles(urls, kind: kind, secondary: secondary)
        }
    }
    private func importMediaFiles(_ urls: [URL], kind: EditMedia.Kind, secondary: Bool) {
        guard !isExporting, !importing, !urls.isEmpty else { return }
        importing = true
        Task {
            do {
                remember()
                for url in urls {
                    let length = try await EditStorage.inspect(url, kind: kind)
                    let media = EditMedia(name: url.lastPathComponent, fileName: UUID().uuidString + "." + url.pathExtension, kind: kind, duration: length)
                    let destination = EditStorage.source(media, in: folder)
                    try await Task.detached { try FileManager.default.copyItem(at: url, to: destination) }.value
                    var copy = document; copy.media.append(media)
                    if secondary, let index = copy.clips.firstIndex(where: { $0.id == selection }) { copy.clips[index].secondaryID = media.id; if copy.clips[index].layout == .presenter { copy.clips[index].layout = .replacement }; copy.clips[index].secondaryStart = 0; copy.clips[index].secondaryFill = kind == .video }
                    else if kind == .video { let clip = EditClip(mediaID: media.id, start: 0, end: length, overlayID: copy.broadcast.selectedOverlayID); copy.clips.append(clip); selection = clip.id }
                    document = copy
                }
                await refreshThumbnails()
            } catch { self.error = error.localizedDescription }
            importing = false
        }
    }
    func applyAnimation(_ item: LibraryAnimation) {
        guard !isExporting, !importing, let targetID = selected?.id else { return }
        importing = true
        Task {
            do {
                let media = EditMedia(name: item.name, fileName: UUID().uuidString + "." + URL(fileURLWithPath: item.fileName).pathExtension, kind: .animation, duration: item.duration)
                let destination = EditStorage.source(media, in: folder), source = EditStorage.animations.appendingPathComponent(item.fileName)
                try await Task.detached { try FileManager.default.copyItem(at: source, to: destination) }.value
                remember(); var copy = document; copy.media.append(media)
                if let index = copy.clips.firstIndex(where: { $0.id == targetID }) { copy.clips[index].animationID = media.id; copy.clips[index].transition = .library; copy.clips[index].transitionDuration = min(item.duration, copy.clips[index].duration); copy.clips[index].animationStart = 0; copy.clips[index].animationOffset = 0; copy.clips[index].animationOpacity = 1; copy.clips[index].animationVolume = 1 }
                document = copy; selection = targetID; seek(document.start(of: targetID)); animationLibraryOpen = false; await refreshThumbnails()
            } catch { self.error = error.localizedDescription }
            importing = false
        }
    }
    func refreshThumbnails() async {
        for media in document.media where thumbnails[media.id] == nil {
            if media.kind == .image { thumbnails[media.id] = EditStorage.image(EditStorage.source(media, in: folder), maxPixels: 320).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } }
            else {
                let url = EditStorage.source(media, in: folder)
                let thumbnail = await Task.detached { () -> Data? in
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 320, height: 180)
                    guard let image = try? generator.copyCGImage(at: CMTime(seconds: min(0.2, media.duration / 2), preferredTimescale: 600), actualTime: nil) else { return nil }
                    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                }.value
                thumbnails[media.id] = thumbnail.flatMap(NSImage.init(data:))
            }
        }
    }
    func export(defaultFolder: URL) {
        guard !isExporting, !importing else { return }
        do { try document.validate() } catch { self.error = error.localizedDescription; return }
        StudioFileDialog.export(name: document.name, folder: defaultFolder) { [weak self] url in self?.export(to: url) }
    }
    func export(to url: URL) {
        guard !isExporting else { return }
        player.pause(); playing = false; rebuildTask?.cancel(); isExporting = true; cancelRequested = false; exportProgress = 0; saveNow()
        let copy = document, directory = folder
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".Clasp-export-\(UUID().uuidString).mp4")
        Task {
            var progressTimer: Timer?
            do {
                let result = try await Task.detached(priority: .userInitiated) { try await EditCompositionBuilder.build(copy, folder: directory) }.value
                guard !cancelRequested else { throw StudioError.message("Export canceled. Your draft is still saved.") }
                guard let session = AVAssetExportSession(asset: result.composition, presetName: AVAssetExportPreset1280x720) else { throw StudioError.message("The export encoder is unavailable.") }
                exportSession = session; session.outputURL = temporary; session.outputFileType = .mp4; session.videoComposition = result.video; session.audioMix = result.audio; session.shouldOptimizeForNetworkUse = true
                progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak model = self] _ in Task { @MainActor in if let model { model.exportProgress = model.exportSession?.progress ?? 0 } } }
                await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } }
                guard session.status == .completed else { if let error = session.error { fputs("Clasp export: \(error as NSError)\n", stderr) }; throw session.error ?? StudioError.message(session.status == .cancelled ? "Export canceled. Your draft is still saved." : "Export could not finish.") }
                if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
                else { try FileManager.default.moveItem(at: temporary, to: url) }
                exportProgress = 1; status = "Exported \(url.lastPathComponent)"; onExport?(url)
            } catch { try? FileManager.default.removeItem(at: temporary); if cancelRequested { status = "Export canceled · draft and source media are safe" } else { self.error = error.localizedDescription } }
            progressTimer?.invalidate(); exportSession = nil; isExporting = false; scheduleRebuild()
        }
    }
    func cancelExport() { cancelRequested = true; exportSession?.cancelExport() }
    static func time(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        return String(format: "%02d:%02d.%02d", Int(safe) / 60, Int(safe) % 60, Int((safe.truncatingRemainder(dividingBy: 1)) * 30))
    }
}
