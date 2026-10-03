import AVFoundation
import AppKit
import CoreImage

struct EditCompositionResult: @unchecked Sendable {
    let composition: AVMutableComposition
    let video: AVMutableVideoComposition
    let audio: AVMutableAudioMix
    func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition); item.videoComposition = video; item.audioMix = audio; return item
    }
}
enum EditCompositionBuilder {
    static func time(_ seconds: Double) -> CMTime { CMTime(value: Int64((seconds * 600).rounded()), timescale: 600) }
    private struct Source {
        let asset: AVURLAsset
        let video: AVAssetTrack
        let audio: AVAssetTrack?
        let transform: CGAffineTransform
    }
    private static func audio(_ source: AVAssetTrack?, into target: AVMutableCompositionTrack, range: CMTimeRange, at start: CMTime) async throws {
        guard let source else { return }
        let available = try await source.load(.timeRange)
        let intersection = CMTimeRangeGetIntersection(range, otherRange: available)
        if intersection.duration.seconds > 0 { try target.insertTimeRange(intersection, of: source, at: CMTimeAdd(start, CMTimeSubtract(intersection.start, range.start))) }
    }
    static func build(_ document: VideoEditDocument, folder: URL, preview: Bool = false) async throws -> EditCompositionResult {
        try document.validate(allowIncomplete: preview)
        let composition = AVMutableComposition()
        guard let primary = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1), let primaryAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 2), let secondary = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 3), let secondaryAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 4), let animation = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 5), let animationAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 6) else { throw StudioError.message("The timeline could not be created.") }
        let mainMix = AVMutableAudioMixInputParameters(track: primaryAudio)
        let guestMix = AVMutableAudioMixInputParameters(track: secondaryAudio)
        let animationMix = AVMutableAudioMixInputParameters(track: animationAudio)
        var sources: [UUID: Source] = [:], stills: [UUID: CIImage] = [:]
        let needed = Set(document.clips.flatMap { [$0.mediaID, $0.secondaryID, $0.animationID].compactMap { $0 } })
        for media in document.media where needed.contains(media.id) {
            try Task.checkCancellation()
            let url = EditStorage.source(media, in: folder)
            guard FileManager.default.fileExists(atPath: url.path) else { throw StudioError.message("Missing media: \(media.name). Re-import the file into this draft.") }
            if media.kind == .image {
                guard let image = EditStorage.image(url) else { throw StudioError.message("Could not open \(media.name).") }
                stills[media.id] = CIImage(cgImage: image)
            } else {
                let asset = AVURLAsset(url: url)
                guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw StudioError.message("No video track in \(media.name).") }
                sources[media.id] = Source(asset: asset, video: video, audio: try await asset.loadTracks(withMediaType: .audio).first, transform: try await video.load(.preferredTransform))
            }
        }
        var cursor = 0.0, instructions: [EditCompositionInstruction] = [], renderers: [String: BroadcastFrameRenderer] = [:]
        for (index, clip) in document.clips.enumerated() {
            try Task.checkCancellation()
            guard let source = sources[clip.mediaID] else { throw StudioError.message("A clip source is unavailable.") }
            let start = time(cursor), timelineDuration = CMTimeSubtract(time(cursor + clip.duration), time(cursor))
            let range = CMTimeRange(start: time(clip.start), duration: CMTimeSubtract(time(clip.end), time(clip.start)))
            try primary.insertTimeRange(range, of: source.video, at: start)
            try await audio(source.audio, into: primaryAudio, range: range, at: start)
            if CMTimeCompare(range.duration, timelineDuration) != 0 {
                let inserted = CMTimeRange(start: start, duration: range.duration)
                primary.scaleTimeRange(inserted, toDuration: timelineDuration)
                if source.audio != nil { primaryAudio.scaleTimeRange(inserted, toDuration: timelineDuration) }
            }
            let volume = Float(min(1, max(0, clip.volume)))
            mainMix.setVolume(volume, at: start); guestMix.setVolume(clip.secondaryAudio ? 1 : 0, at: start)
            var guestID: CMPersistentTrackID?, animationID: CMPersistentTrackID?, guestTransform = CGAffineTransform.identity, animationTransform = CGAffineTransform.identity, animationDuration = 0.0
            if clip.layout != .presenter, let id = clip.secondaryID, let guest = sources[id], let media = document.media.first(where: { $0.id == id }) {
                guestID = secondary.trackID; guestTransform = guest.transform
                // Short supporting videos loop to cover the selected timeline clip.
                var offset = 0.0, sourceStart = min(max(0, clip.secondaryStart), max(0, media.duration - 1.0 / 30))
                var repeats = 0
                while offset < clip.duration - 0.001 {
                    try Task.checkCancellation(); repeats += 1
                    guard repeats <= 1000 else { throw StudioError.message("This supporting video is too short for the clip. Choose a longer video or use an image.") }
                    let length = min(media.duration - sourceStart, clip.duration - offset)
                    guard length > 0 else { break }
                    let segment = CMTimeRange(start: time(sourceStart), duration: time(length)), destination = time(cursor + offset)
                    try secondary.insertTimeRange(segment, of: guest.video, at: destination)
                    if clip.secondaryAudio { try await audio(guest.audio, into: secondaryAudio, range: segment, at: destination) }
                    offset += length; sourceStart = 0
                }
            }
            if clip.transition == .library, let id = clip.animationID, let asset = sources[id], let media = document.media.first(where: { $0.id == id }) {
                let sourceStart = min(max(0, clip.animationStart ?? 0), max(0, media.duration - 1.0 / 30))
                let offset = min(max(0, clip.animationOffset ?? 0), max(0, clip.duration - 1.0 / 30))
                animationDuration = min(media.duration - sourceStart, clip.duration - offset, max(1.0 / 30, clip.transitionDuration))
                animationID = animation.trackID; animationTransform = asset.transform
                let range = CMTimeRange(start: time(sourceStart), duration: time(animationDuration)), destination = time(cursor + offset)
                try animation.insertTimeRange(range, of: asset.video, at: destination)
                try await audio(asset.audio, into: animationAudio, range: range, at: destination)
                let animationVolume = Float(min(1, max(0, clip.animationVolume ?? 1)))
                animationMix.setVolume(animationVolume, at: destination)
                if asset.audio != nil, animationVolume > 0 {
                    mainMix.setVolume(volume * 0.25, at: destination); guestMix.setVolume(clip.secondaryAudio ? 0.25 : 0, at: destination)
                    mainMix.setVolume(volume, at: time(cursor + offset + animationDuration)); guestMix.setVolume(clip.secondaryAudio ? 1 : 0, at: time(cursor + offset + animationDuration))
                }
            }
            let key = "\(clip.overlayID?.uuidString ?? "default")-\(clip.graphics)-\(clip.topics)-\(clip.mirror)-\(clip.section)"
            let previousSection = index > 0 ? document.clips[index - 1].section : nil
            let localDesign = document.broadcast.overlayLibrary?.first(where: { $0.id == clip.overlayID }) ?? BroadcastGraphics.document(document.broadcast)
            let scopedKey = key + (localDesign.template == .ticker ? "-\(cursor)-\(previousSection ?? -1)" : "")
            let renderer = renderers[scopedKey] ?? EditShotRenderer(clip: clip, project: document.broadcast, previousSection: previousSection, tickerEpoch: cursor).renderer
            renderers[scopedKey] = renderer
            let shot = EditShotRenderer(clip: clip, renderer: renderer)
            let next = document.clips.indices.contains(index + 1) ? document.clips[index + 1] : nil
            let fadeOut = next?.transition == .fade ? min((next?.transitionDuration ?? 0.8) / 2, clip.duration / 2) : 0
            let offset = min(max(0, clip.animationOffset ?? 0), max(0, clip.duration - 1.0 / 30))
            let boundaries = Array(Set([0.0, clip.duration] + (animationID != nil ? [offset, offset + animationDuration] : []))).sorted()
            for interval in 0..<(boundaries.count - 1) {
                let begin = boundaries[interval], end = boundaries[interval + 1]
                guard end - begin > 0.0001 else { continue }
                let activeAnimation = begin >= offset - 0.0001 && begin < offset + animationDuration - 0.0001 ? animationID : nil
                instructions.append(EditCompositionInstruction(range: CMTimeRange(start: time(cursor + begin), duration: CMTimeSubtract(time(cursor + end), time(cursor + begin))), shotRange: CMTimeRange(start: start, duration: timelineDuration), primary: primary.trackID, secondary: guestID, animation: activeAnimation, primaryTransform: source.transform, secondaryTransform: guestTransform, animationTransform: animationTransform, still: clip.secondaryID.flatMap { stills[$0] }, shot: shot, animationDuration: animationDuration, animationOffset: offset, fadeOutDuration: fadeOut, newsOutDuration: next?.transition == .news || next?.transition == .signature ? min((next?.transitionDuration ?? 0.8) / 2, clip.duration) : 0, signatureOut: next?.transition == .signature))
            }
            cursor += clip.duration
        }
        // Empty audio tracks with audio-mix parameters make AVFoundation reject
        // otherwise valid silent timelines, including transparent stingers.
        let populatedAudio = Set([primaryAudio, secondaryAudio, animationAudio].filter { !$0.segments.isEmpty }.map(\.trackID))
        for track in [primaryAudio, secondaryAudio, animationAudio, secondary, animation] where track.segments.isEmpty { composition.removeTrack(track) }
        let video = AVMutableVideoComposition(); video.customVideoCompositorClass = EditVideoCompositor.self
        video.renderSize = CGSize(width: 1280, height: 720); video.frameDuration = CMTime(value: 1, timescale: 30); video.instructions = instructions
        let audioMix = AVMutableAudioMix(); audioMix.inputParameters = [mainMix, guestMix, animationMix].filter { populatedAudio.contains($0.trackID) }
        return EditCompositionResult(composition: composition, video: video, audio: audioMix)
    }
}
