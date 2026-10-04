import AppKit
import AVFoundation
import CoreImage

extension StudioTests {
    static func referenceImageChecks(main: EditMedia, folder: URL) async throws {
        let portrait = BroadcastGraphics.bitmap(width: 160, height: 320) { ctx in BroadcastGraphics.fill(ctx, CGRect(x: 0, y: 0, width: 160, height: 320), NSColor(red: 0.95, green: 0.02, blue: 0.02, alpha: 1)) }!
        let asset = BroadcastReferenceImage(name: "Portrait reference", png: NSBitmapImageRep(cgImage: portrait).representation(using: .png, properties: [:])!)
        var project = StudioProject(); project.graphics = false; project.mirror = false; project.referenceImages = [asset]; project.reference = ReferencePresentation(imageID: asset.id, caption: "Court filing")
        let rect = ReferenceCardGraphics.rect(project.reference!, camera: CGRect(x: 0, y: 0, width: 1280, height: 720))
        check(rect.minY > 220 && rect.maxX < 1280 && rect.maxY < 660, "Reference cards keep clear of lower thirds and top broadcast badges")
        let context = CIContext(), bounds = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let host = CIImage(color: CIColor(red: 0.05, green: 0.15, blue: 0.8)).cropped(to: bounds)
        let settings = BroadcastGraphics.renderSettings(project, activeIndex: 0)
        let pixels = NSBitmapImageRep(cgImage: context.createCGImage(BroadcastFrameRenderer(settings).compose(host, at: 0), from: bounds)!)
        let middleY = Int(720 - (rect.midY + 21))
        check(pixels.colorAt(x: Int(rect.midX), y: middleY)!.redComponent > 0.9 && pixels.colorAt(x: Int(rect.minX + 15), y: middleY)!.greenComponent > 0.9 && pixels.colorAt(x: 100, y: 360)!.blueComponent > 0.7, "A portrait reference stays proportional inside its card while the presenter remains visible")
        project.reference?.side = .left
        let left = ReferenceCardGraphics.rect(project.reference!, camera: bounds)
        check(left.minX == 28 && left.width == rect.width, "Reference cards switch sides without changing image size")
        project.reference?.visible = false
        check(BroadcastGraphics.renderSettings(project, activeIndex: 0).referenceCard == nil, "Turning off On air removes the reference card from the native compositor")
        project.reference?.visible = true
        let mediaID = main.id, duration = min(0.6, main.duration)
        var document = VideoEditDocument(broadcast: project, media: [main])
        let hidden = RecordedReferenceCue(time: duration / 2, presentation: nil)
        document.clips = RecordedTimeline.clips(mediaID: mediaID, duration: duration, project: project, sections: [RecordedSectionCue(time: 0, section: 0), RecordedSectionCue(time: duration / 3, section: 1)], references: [RecordedReferenceCue(time: 0, presentation: project.reference), hidden])
        check(document.clips.count == 3 && document.clips[0].reference?.visible == true && document.clips[2].reference == nil && document.clips[2].referenceOverride == true && abs(document.duration - duration) < 0.0001, "Recording image cues create editable timeline shots and retain explicit hide events")
        let quick = RecordedTimeline.clips(mediaID: mediaID, duration: 1, project: project, sections: [RecordedSectionCue(time: 0, section: 0), RecordedSectionCue(time: 0.01, section: 1)], references: [])
        check(quick.first?.start == 0 && abs(quick.reduce(0) { $0 + $1.duration } - 1) < 0.0001, "Rapid live cues never drop frames from the beginning of the saved take")
        let restored = try JSONDecoder().decode(VideoEditDocument.self, from: JSONEncoder().encode(document))
        check(restored.broadcast.referenceImages == [asset] && restored.clips == document.clips, "Reference images, captions, sides and visibility persist with the draft")
        let composition = try await EditCompositionBuilder.build(document, folder: folder)
        let generator = AVAssetImageGenerator(asset: composition.composition); generator.videoComposition = composition.video
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let (shown, _) = try await generator.image(at: EditCompositionBuilder.time(duration / 6))
        let (removed, _) = try await generator.image(at: EditCompositionBuilder.time(duration * 0.8))
        let cardCenter = ReferenceCardGraphics.rect(project.reference!, camera: bounds)
        let x = Int(cardCenter.midX), y = Int(720 - (cardCenter.midY + 21))
        check(NSBitmapImageRep(cgImage: shown).colorAt(x: x, y: y)!.redComponent > 0.8 && NSBitmapImageRep(cgImage: removed).colorAt(x: x, y: y)!.redComponent < 0.5, "Scrubbing and export composition show the reference only during its recorded interval")
        let croppedSVG = try await SVGOverlayImport.render(Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1000 720'><rect id='camera' width='1000' height='720'/></svg>".utf8))
        var croppedDoc = OverlayDocument.presets(project)[0]; croppedDoc.template = .custom; croppedDoc.importedSVG = croppedSVG
        var croppedProject = project; croppedProject.graphics = true; croppedProject.overlayLibrary = [croppedDoc]; croppedProject.selectedOverlayID = croppedDoc.id
        var cropEdit = VideoEditDocument(broadcast: croppedProject, media: [main])
        cropEdit.clips = [EditClip(mediaID: main.id, start: 0, end: duration, graphics: true, mirror: false, section: 0, overlayID: croppedDoc.id)]
        let cropResult = try await EditCompositionBuilder.build(cropEdit, folder: folder)
        let cropGenerator = AVAssetImageGenerator(asset: cropResult.composition); cropGenerator.videoComposition = cropResult.video
        let (cropImage, _) = try await cropGenerator.image(at: .zero)
        check(cropResult.video.renderSize == CGSize(width: 1000, height: 720) && cropImage.width == 1000 && cropImage.height == 720, "Timeline preview uses the cropped SVG output dimensions")
        let cropURL = folder.appendingPathComponent("svg-cropped-export.mp4")
        try? FileManager.default.removeItem(at: cropURL)
        guard let cropExport = AVAssetExportSession(asset: cropResult.composition, presetName: AVAssetExportPreset1280x720) else { throw StudioError.message("Crop test encoder unavailable") }
        cropExport.outputURL = cropURL; cropExport.outputFileType = .mp4; cropExport.videoComposition = cropResult.video; cropExport.audioMix = cropResult.audio
        await withCheckedContinuation { continuation in cropExport.exportAsynchronously { continuation.resume() } }
        guard cropExport.status == .completed else { throw cropExport.error ?? StudioError.message("Crop test export failed") }
        let cropTracks = try await AVURLAsset(url: cropURL).loadTracks(withMediaType: .video)
        let cropSize = try await cropTracks[0].load(.naturalSize)
        check(cropSize == CGSize(width: 1000, height: 720), "The encoded MP4 has SVG dimensions, with no padded 16:9 side bars")
        var missing = document; missing.broadcast.referenceImages = []
        check((try? missing.validate()) == nil, "Export reports missing reference images instead of silently omitting them")
    }
    static func referencePreviewAsset() -> BroadcastReferenceImage {
        let image = BroadcastGraphics.bitmap(width: 900, height: 560) { ctx in
            BroadcastGraphics.fill(ctx, CGRect(x: 0, y: 0, width: 900, height: 560), NSColor(studioHex: "F4F3EF"))
            BroadcastGraphics.text("THE STORY AT A GLANCE", at: CGRect(x: 50, y: 440, width: 800, height: 60), size: 34, weight: .bold, color: .black, fit: true)
            BroadcastGraphics.text("Reference image preview", at: CGRect(x: 50, y: 399, width: 800, height: 40), size: 21, color: .darkGray, fit: true)
            for index in 0..<5 {
                let height = CGFloat([112, 185, 152, 244, 298][index]), x = CGFloat(75 + index * 158)
                BroadcastGraphics.fill(ctx, CGRect(x: x, y: 65, width: 98, height: height), NSColor(studioHex: index == 4 ? "2B6174" : "C1C5C3"))
            }
        }!
        return BroadcastReferenceImage(name: "Example chart", png: NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!)
    }
}
