import Foundation
import AppKit
import AVFoundation
import ImageIO

struct EditMedia: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case video, image, animation }
    var id = UUID()
    var name: String
    var fileName: String
    var kind: Kind
    var duration: Double
}
enum EditLayout: String, CaseIterable, Codable {
    case presenter = "Presenter", replacement = "Image / video", split = "Split screen", inset = "Picture in picture"
}
enum EditTransition: String, CaseIterable, Codable {
    case cut = "Cut", news = "News wipe", signature = "Clasp reveal", fade = "Fade through black", library = "Library animation"
}
struct EditClip: Identifiable, Codable, Equatable {
    var id = UUID()
    var mediaID: UUID
    var start: Double
    var end: Double
    var layout = EditLayout.presenter
    var graphics = true
    var topics = true
    var mirror = false
    var section = 0
    var overlayID: UUID?
    var secondaryID: UUID?
    var secondaryStart = 0.0
    var secondaryAudio = false
    var secondaryFill = false
    var volume = 1.0
    var transition = EditTransition.cut
    var transitionDuration = 0.8
    var animationID: UUID?
    var speed: Double?
    var zoom: Double?
    var panX: Double?
    var panY: Double?
    var splitRatio: Double?
    var swapSides: Bool?
    var animationStart: Double?
    var animationOffset: Double?
    var animationVolume: Double?
    var animationOpacity: Double?
    var referenceOverride: Bool?
    var reference: ReferencePresentation?
    var safeSpeed: Double { min(4, max(0.25, speed?.isFinite == true ? speed! : 1)) }
    var duration: Double { max(0, end - start) / safeSpeed }
}
struct RecordedSectionCue: Codable, Equatable { var time: Double; var section: Int }
struct VideoEditDocument: Codable {
    var schema = 1
    var name = "Untitled broadcast"
    var created = Date()
    var broadcast: StudioProject
    var media: [EditMedia] = []
    var clips: [EditClip] = []
    var duration: Double { clips.reduce(0) { $0 + $1.duration } }
    var outputRect: CGRect { BroadcastGraphics.outputRect(broadcast) }
    var outputAspectRatio: CGFloat { outputRect.width / outputRect.height }
    func start(of id: UUID) -> Double { clips.prefix(while: { $0.id != id }).reduce(0) { $0 + $1.duration } }
    func clip(at time: Double) -> EditClip? {
        var cursor = 0.0
        for clip in clips { cursor += clip.duration; if time < cursor { return clip } }
        return clips.last
    }
    mutating func split(at time: Double) -> UUID? {
        guard let original = clip(at: time), let index = clips.firstIndex(where: { $0.id == original.id }) else { return nil }
        let offset = time - start(of: original.id)
        guard offset >= 1.0 / 30, original.duration - offset >= 1.0 / 30 else { return nil }
        var right = original; right.id = UUID(); right.start += offset * original.safeSpeed; right.secondaryStart += offset; right.transition = .cut; right.animationID = nil
        clips[index].end = right.start; clips.insert(right, at: index + 1); return right.id
    }
    func validate(allowIncomplete: Bool = false) throws {
        guard schema == 1 else { throw StudioError.message("This draft was made by a newer version of Clasp Studio.") }
        guard media.allSatisfy({ $0.fileName == URL(fileURLWithPath: $0.fileName).lastPathComponent && !$0.fileName.isEmpty }) else { throw StudioError.message("A draft media path is invalid.") }
        guard !clips.isEmpty else { throw StudioError.message("Add at least one video clip before exporting.") }
        for clip in clips {
            guard let source = media.first(where: { $0.id == clip.mediaID }), source.kind == .video,
                  clip.start.isFinite, clip.end.isFinite, clip.start >= 0, clip.duration >= 1.0 / 30, clip.end > clip.start, clip.end <= source.duration + 0.02 else { throw StudioError.message("A clip has an invalid source range. Adjust its in and out points.") }
            if !allowIncomplete, clip.layout != .presenter, !media.contains(where: { $0.id == clip.secondaryID && $0.kind != .animation }) { throw StudioError.message("Choose an image or guest video for the \(clip.layout.rawValue.lowercased()) clip.") }
            if !allowIncomplete, clip.transition == .library, !media.contains(where: { $0.id == clip.animationID && $0.kind == .animation }) { throw StudioError.message("Choose an animation for this transition.") }
            let reference = clip.referenceOverride == true ? clip.reference : broadcast.reference
            if !allowIncomplete, let reference, reference.visible, !((broadcast.referenceImages ?? []).contains(where: { $0.id == reference.imageID && !$0.png.isEmpty })) { throw StudioError.message("The reference image is missing. Replace it or turn off its On air switch before exporting.") }
        }
    }
}
enum EditStorage {
    static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClaspStudio") }
    static var drafts: URL { root.appendingPathComponent("Drafts") }
    static var animations: URL { root.appendingPathComponent("Animations") }
    static func makeDraft() throws -> URL {
        let url = drafts.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Media"), withIntermediateDirectories: true)
        return url
    }
    static func save(_ document: VideoEditDocument, at folder: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: folder.appendingPathComponent("edit.json"), options: .atomic)
    }
    static func source(_ media: EditMedia, in folder: URL) -> URL { folder.appendingPathComponent("Media").appendingPathComponent(media.fileName) }
    static func image(_ url: URL, maxPixels: Int = 1920) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary)
    }
    static func inspect(_ url: URL, kind: EditMedia.Kind) async throws -> Double {
        if kind == .image {
            guard image(url, maxPixels: 32) != nil else { throw StudioError.message("This image could not be opened.") }; return 0
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= 1.0 / 30, !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw StudioError.message("Choose a playable video with a video track.") }
        return duration
    }
}
struct LibraryAnimation: Identifiable, Codable {
    var id = UUID()
    var name: String
    var fileName: String
    var duration: Double
}
@MainActor final class AnimationLibrary: ObservableObject {
    @Published var items: [LibraryAnimation] = []
    init() { if let data = try? Data(contentsOf: EditStorage.animations.appendingPathComponent("library.json")), let saved = try? JSONDecoder().decode([LibraryAnimation].self, from: data) { items = saved } }
    func importFiles(_ urls: [URL]) async throws {
        try FileManager.default.createDirectory(at: EditStorage.animations, withIntermediateDirectories: true)
        for url in urls {
            let duration = try await EditStorage.inspect(url, kind: .animation)
            let fileName = UUID().uuidString + "." + url.pathExtension
            try await Task.detached { try FileManager.default.copyItem(at: url, to: EditStorage.animations.appendingPathComponent(fileName)) }.value
            items.append(LibraryAnimation(name: url.deletingPathExtension().lastPathComponent, fileName: fileName, duration: duration))
            try save()
        }
    }
    func rename(_ id: UUID, name: String) throws { if let index = items.firstIndex(where: { $0.id == id }) { items[index].name = name; try save() } }
    func remove(_ id: UUID) throws {
        // Session media are independent copies, so existing edits remain valid.
        let file = items.first(where: { $0.id == id })?.fileName
        items.removeAll { $0.id == id }; try save()
        if let file { try? FileManager.default.removeItem(at: EditStorage.animations.appendingPathComponent(file)) }
    }
    private func save() throws { try JSONEncoder().encode(items).write(to: EditStorage.animations.appendingPathComponent("library.json"), options: .atomic) }
}
