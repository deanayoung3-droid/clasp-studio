import AppKit
import AVFoundation
import CoreImage

extension StudioTests {
    static func advancedEditorChecks(main: EditMedia, alpha: EditMedia, broadcast: StudioProject, folder: URL) async throws {
        var clip = EditClip(mediaID: main.id, start: 0, end: min(main.duration, 0.6), graphics: false, transition: .library, animationID: alpha.id)
        clip.animationOffset = 0.15; clip.animationStart = 0.1; clip.transitionDuration = 0.2
        let document = VideoEditDocument(broadcast: broadcast, media: [main, alpha], clips: [clip])
        let composition = try await EditCompositionBuilder.build(document, folder: folder)
        let instructions = composition.video.instructions.compactMap { $0 as? EditCompositionInstruction }
        check(instructions.count == 3 && instructions[0].animationID == nil && instructions[1].animationID != nil && instructions[2].animationID == nil, "An animation requests frames only during its actual timeline interval")
        let valid = try await composition.video.isValid(for: composition.composition, timeRange: CMTimeRange(start: .zero, duration: composition.composition.duration), validationDelegate: nil)
        check(valid, "Offset animations create contiguous, valid instruction ranges")
        let generator = AVAssetImageGenerator(asset: composition.composition); generator.videoComposition = composition.video
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let (before, _) = try await generator.image(at: EditCompositionBuilder.time(0.05))
        let (during, _) = try await generator.image(at: EditCompositionBuilder.time(0.2))
        let (after, _) = try await generator.image(at: EditCompositionBuilder.time(0.5))
        check(NSBitmapImageRep(cgImage: before).colorAt(x: 100, y: 360)!.greenComponent < 0.5 && NSBitmapImageRep(cgImage: during).colorAt(x: 100, y: 360)!.greenComponent > 0.6 && NSBitmapImageRep(cgImage: after).colorAt(x: 100, y: 360)!.greenComponent < 0.5, "Scrubbing renders the source before and after an offset transparent animation")
        let editor = await MainActor.run { VideoEditorModel(document: document, folder: folder) }
        for _ in 0..<200 { if await MainActor.run(body: { editor.pausedFrame != nil }) { break }; try await Task.sleep(nanoseconds: 25_000_000) }
        let stillLoaded = await MainActor.run { editor.pausedFrame != nil && editor.previewFailure == nil }
        check(stillLoaded, "A paused editor displays an actual composed video frame")
        await MainActor.run { editor.duplicate() }
        let duplicate = await MainActor.run { editor.document.clips.count == 2 && editor.document.clips[0].id != editor.document.clips[1].id }
        check(duplicate, "Duplicated shots keep their edit settings and independent identity")
        await MainActor.run { editor.undo(); editor.setSpeed(2) }
        let fast = await MainActor.run { editor.document }
        check(abs(fast.duration - document.duration / 2) < 0.001, "Playback speed changes timeline duration without changing the source range")
        let fastComposition = try await EditCompositionBuilder.build(fast, folder: folder)
        check(abs(fastComposition.composition.duration.seconds - fast.duration) < 1.0 / 600, "Composition video and audio use the edited playback speed")
        var fastSplit = fast
        _ = fastSplit.split(at: fast.duration / 2)
        check(fastSplit.clips.count == 2 && abs(fastSplit.clips[1].start - clip.end / 2) < 0.001 && abs(fastSplit.duration - fast.duration) < 0.001, "Splitting a retimed shot preserves source continuity and duration")
        await MainActor.run { editor.stop() }
        var incomplete = document; incomplete.clips[0].animationID = nil; incomplete.clips[0].layout = .split
        check((try? incomplete.validate()) == nil, "Export still requires complete picture and animation selections")
        let unfinished = try await EditCompositionBuilder.build(incomplete, folder: folder, preview: true)
        let unfinishedGenerator = AVAssetImageGenerator(asset: unfinished.composition); unfinishedGenerator.videoComposition = unfinished.video
        let (fallback, _) = try await unfinishedGenerator.image(at: .zero)
        check(fallback.width == 1280, "Incomplete layout edits retain a playable camera preview")
        let context = CIContext(), host = CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        let guest = CIImage(color: CIColor(red: 0.9, green: 0.05, blue: 0.05)).cropped(to: host.extent)
        var split = clip; split.transition = .cut; split.layout = .split; split.splitRatio = 0.25; split.swapSides = true
        let splitFrame = EditShotRenderer(clip: split, project: broadcast).frame(primary: host, secondary: guest, at: 0)
        let splitPixels = NSBitmapImageRep(cgImage: context.createCGImage(splitFrame, from: splitFrame.extent)!)
        check(splitPixels.colorAt(x: 100, y: 360)!.redComponent > 0.8 && splitPixels.colorAt(x: 1000, y: 360)!.blueComponent > 0.7, "Split position and swap controls change the rendered picture")
        split.layout = .inset; split.swapSides = false
        let inset = EditShotRenderer(clip: split, project: broadcast).frame(primary: host, secondary: guest, at: 0)
        let insetPixels = NSBitmapImageRep(cgImage: context.createCGImage(inset, from: inset.extent)!)
        check(insetPixels.colorAt(x: 640, y: 360)!.blueComponent > 0.7 && insetPixels.colorAt(x: 1100, y: 620)!.redComponent > 0.8, "Picture-in-picture preserves the host and adds a supporting inset")
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let clear = pixels(CIImage(color: .clear), rect: bounds, context: context)
        check(pixels(BroadcastTransition.frame(progress: 0), rect: bounds, context: context) == clear && pixels(BroadcastTransition.frame(progress: 1), rect: bounds, context: context) == clear, "Clasp reveal leaves both ends of the transition unobstructed")
        let cover = NSBitmapImageRep(cgImage: context.createCGImage(BroadcastTransition.frame(progress: 0.5), from: bounds)!)
        check([CGPoint(x: 5, y: 5), CGPoint(x: 1270, y: 700), CGPoint(x: 640, y: 360)].allSatisfy { cover.colorAt(x: Int($0.x), y: Int($0.y))!.alphaComponent > 0.99 }, "Clasp reveal fully covers the speaker cut at its midpoint")
        let zone = CGRect(x: 319, y: 94, width: 930, height: 80)
        let ticker = HeadlineTicker(current: "New ruling changes personal injury cases", previous: "This week in law", zone: zone, style: OverlayComponentStyle(), epoch: 10)
        check(pixels(ticker.frame(at: 10), rect: zone, context: context) != pixels(ticker.frame(at: 10.6), rect: zone, context: context), "Headline ticker moves to the new script section with an upward reveal")
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 8, "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!.cropped(to: bounds)
        let mask = BroadcastGraphics.image { ctx in BroadcastGraphics.fill(ctx, CGRect(x: 100, y: 100, width: 300, height: 300), .white) }!
        let frosted = BroadcastFrameRenderer(RenderSettings(overlay: nil, mirror: false, frostMask: mask, frostRadius: 22)).compose(checker, at: 0)
        let frostedPixels = NSBitmapImageRep(cgImage: context.createCGImage(frosted, from: bounds)!)
        let inside = frostedPixels.colorAt(x: 200, y: 520)!.redComponent
        let outside = frostedPixels.colorAt(x: 700, y: 520)!.redComponent
        check(inside > 0.25 && inside < 0.75 && (outside < 0.1 || outside > 0.9), "Frosted overlay panels blur their backdrop while the camera remains sharp elsewhere")
    }
}
