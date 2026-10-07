import Foundation
import AVFoundation
import AppKit

extension StudioTests {
    static func audioTailExportChecks(source: URL, directory: URL) async throws {
        let folder = directory.appendingPathComponent("audio-tail-export-fixture")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Media"), withIntermediateDirectories: true)
        let asset = AVURLAsset(url: source)
        let video = try await asset.loadTracks(withMediaType: .video).first!
        let audio = try await asset.loadTracks(withMediaType: .audio).first!
        let videoRange = try await video.load(.timeRange), audioRange = try await audio.load(.timeRange)
        let fixture = AVMutableComposition()
        let v = fixture.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let a = fixture.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try v.insertTimeRange(videoRange, of: video, at: .zero)
        try a.insertTimeRange(audioRange, of: audio, at: .zero)
        try a.insertTimeRange(CMTimeRange(start: audioRange.start, duration: EditCompositionBuilder.time(0.25)), of: audio, at: audioRange.duration)
        let sourceURL = folder.appendingPathComponent("Media/tail.mov")
        let fixtureExport = AVAssetExportSession(asset: fixture, presetName: AVAssetExportPresetPassthrough)!
        fixtureExport.outputURL = sourceURL; fixtureExport.outputFileType = .mov
        await withCheckedContinuation { continuation in fixtureExport.exportAsynchronously { continuation.resume() } }
        guard fixtureExport.status == .completed else { throw fixtureExport.error ?? StudioError.message("Audio-tail fixture failed") }
        let tailAsset = AVURLAsset(url: sourceURL), length = try await tailAsset.load(.duration).seconds
        let tailVideo = try await tailAsset.loadTracks(withMediaType: .video).first!
        let videoEnd = CMTimeRangeGetEnd(try await tailVideo.load(.timeRange)).seconds
        check(length - videoEnd > 0.1, "Export regression fixture has audio extending beyond the final video frame")
        let media = EditMedia(name: "Audio tail.mov", fileName: "tail.mov", kind: .video, duration: length)
        var broadcast = StudioProject(); broadcast.graphics = false
        var document = VideoEditDocument(name: "Audio tail", broadcast: broadcast, media: [media], clips: [EditClip(mediaID: media.id, start: 0, end: length, graphics: false)])
        for cut in [false, true] {
            if cut { _ = document.split(at: length * 0.73 + 0.007) }
            let result = try await EditCompositionBuilder.build(document, folder: folder)
            let output = folder.appendingPathComponent(cut ? "cut.mp4" : "full.mp4")
            let session = AVAssetExportSession(asset: result.composition, presetName: AVAssetExportPreset1280x720)!
            session.outputURL = output; session.outputFileType = .mp4; session.videoComposition = result.video; session.audioMix = result.audio
            await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } }
            check(session.status == .completed, "\(cut ? "Cut" : "Full") recording exports successfully through an audio-only tail: \(session.error?.localizedDescription ?? "no error")")
            let exported = AVURLAsset(url: output)
            let exportedDuration = try await exported.load(.duration).seconds
            check(abs(exportedDuration - length) < 0.04, "Export preserves the complete audio-tail timeline duration")
            let generator = AVAssetImageGenerator(asset: exported)
            let (frame, _) = try await generator.image(at: EditCompositionBuilder.time(length - 0.06))
            let pixel = NSBitmapImageRep(cgImage: frame).colorAt(x: 640, y: 360)!
            check(pixel.redComponent > 0.2, "Audio tail retains the final camera frame instead of exporting black")
        }
    }
}
