import Foundation
import AppKit
import AVFoundation
import CoreImage

extension StudioTests {
    static func alphaAnimation(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input); guard writer.startWriting() else { throw writer.error ?? StudioError.message("ProRes encoder unavailable") }; writer.startSession(atSourceTime: .zero)
        let context = CIContext(), bounds = CGRect(x: 0, y: 0, width: 320, height: 180)
        let frame = CIImage(color: CIColor(red: 0.05, green: 0.9, blue: 0.05)).cropped(to: CGRect(x: 0, y: 0, width: 150, height: 180)).composited(over: CIImage(color: .clear).cropped(to: bounds))
        for index in 0..<15 {
            var waits = 0
            while !input.isReadyForMoreMediaData && waits < 200 { try await Task.sleep(nanoseconds: 5_000_000); waits += 1 }
            guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { throw StudioError.message("ProRes encoder stalled") }
            var pixel: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel)
            guard let pixel else { throw StudioError.message("ProRes frame allocation failed") }
            context.render(frame, to: pixel)
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else { throw writer.error ?? StudioError.message("ProRes frame failed") }
        }
        input.markAsFinished(); await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? StudioError.message("ProRes fixture could not finish") }
    }
    static func editorChecks(source: URL, animation: URL, directory: URL) async {
        do {
            let folder = directory.appendingPathComponent("editor-fixture")
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("Media"), withIntermediateDirectories: true)
            let mainLength = try await EditStorage.inspect(source, kind: .video), animationLength = try await EditStorage.inspect(animation, kind: .animation)
            let main = EditMedia(name: "Camera.mov", fileName: "camera.mov", kind: .video, duration: mainLength)
            let stinger = EditMedia(name: "Stinger.mov", fileName: "stinger.mov", kind: .animation, duration: animationLength)
            let still = EditMedia(name: "Red picture.png", fileName: "picture.png", kind: .image, duration: 0)
            try FileManager.default.copyItem(at: source, to: EditStorage.source(main, in: folder)); try FileManager.default.copyItem(at: animation, to: EditStorage.source(stinger, in: folder))
            let picture = BroadcastGraphics.bitmap(width: 320, height: 180) { ctx in BroadcastGraphics.fill(ctx, CGRect(x: 0, y: 0, width: 320, height: 180), NSColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1)) }!
            try NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:])!.write(to: EditStorage.source(still, in: folder))
            var broadcast = StudioProject(); broadcast.overlayLibrary = OverlayDocument.presets(broadcast); broadcast.selectedOverlayID = broadcast.overlayLibrary?.last?.id
            let length = min(0.4, mainLength)
            var document = VideoEditDocument(name: "Editor verification", broadcast: broadcast, media: [main, still, stinger], clips: [EditClip(mediaID: main.id, start: 0, end: length, graphics: false)])
            let id = document.split(at: length / 2)
            check(id != nil && document.clips.count == 2 && abs(document.duration - length) < 0.001, "Timeline splits preserve exact source duration")
            check(document.clips[1].transition == .cut && document.clips[1].start == document.clips[0].end, "Splits join source ranges without adding a gap or duplicate stinger")
            check(document.split(at: 0) == nil, "A boundary split cannot create an empty clip")
            var split = EditClip(mediaID: main.id, start: 0, end: length, layout: .split, graphics: false, topics: false, secondaryID: still.id)
            var replacement = split; replacement.id = UUID(); replacement.layout = .replacement
            let host = CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.7)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
            let guest = CIImage(cgImage: picture)
            let renderer = EditShotRenderer(clip: split, project: broadcast), context = CIContext()
            let frame = renderer.frame(primary: host, secondary: guest, at: 0)
            let bitmap = NSBitmapImageRep(cgImage: context.createCGImage(frame, from: CGRect(x: 0, y: 0, width: 1280, height: 720))!)
            check(bitmap.colorAt(x: 300, y: 360)!.blueComponent > 0.6 && bitmap.colorAt(x: 950, y: 360)!.redComponent > 0.8, "Split screen composites separate host and supporting-image regions")
            split.graphics = true
            let wide = EditShotRenderer(clip: split, project: broadcast)
            check(wide.renderer.settings.cameraRect.width > 1200 && wide.renderer.settings.overlay != nil, "Removing topics expands the camera while preserving broadcast branding")
            var invalid = document; invalid.clips[0].layout = .split
            check((try? invalid.validate()) == nil, "A split-screen clip requires supporting media")
            var animated = replacement; animated.id = UUID(); animated.transition = .library; animated.animationID = stinger.id
            document.clips = [EditClip(mediaID: main.id, start: 0, end: length, graphics: false), replacement, animated]
            try EditStorage.save(document, at: folder)
            let saved = try JSONDecoder().decode(VideoEditDocument.self, from: Data(contentsOf: folder.appendingPathComponent("edit.json")))
            check(saved.clips == document.clips && saved.media == document.media, "Draft source ranges, layouts and animations survive reopening")
            let sourceData = try Data(contentsOf: source)
            let snapshot = document
            let editor = await MainActor.run { VideoEditorModel(document: snapshot, folder: folder) }
            for _ in 0..<200 {
                if await MainActor.run(body: { editor.player.currentItem?.status == .readyToPlay }) { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            let playable = await MainActor.run { editor.player.currentItem?.status == .readyToPlay && editor.previewFailure == nil }
            check(playable, "The edited timeline becomes ready for native playback")
            await MainActor.run { editor.seek(0.15); editor.togglePlayback() }
            for _ in 0..<100 {
                if await MainActor.run(body: { editor.player.currentTime().seconds > 0.17 }) { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            let advanced = await MainActor.run { editor.player.currentTime().seconds > 0.17 }
            check(advanced, "Play advances the composed timeline from the scrubbed position")
            await MainActor.run { editor.player.pause(); editor.playing = false; editor.seek(0) }
            await MainActor.run {
                editor.moveClip(snapshot.clips[0].id, to: 2)
                check(editor.document.clips[2].id == snapshot.clips[0].id, "Dragging a shot to a new index reorders the timeline")
                editor.undo()
            }
            await MainActor.run {
                editor.select(snapshot.clips[1].id); editor.changeClip { $0.topics = false }
                check(editor.canUndo, "Timeline edits create an undo state")
                editor.undo(); check(editor.document.clips[1].topics == snapshot.clips[1].topics && editor.canRedo, "Undo restores the previous clip settings")
                editor.redo(); check(editor.document.clips[1].topics == false, "Redo restores the edit")
            }
            let destination = directory.appendingPathComponent("edited-broadcast.mp4")
            try? FileManager.default.removeItem(at: destination)
            await MainActor.run { editor.export(to: destination) }
            for _ in 0..<400 {
                if await MainActor.run(body: { !editor.isExporting }) { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let failure = await MainActor.run { editor.error }
            check(failure == nil && FileManager.default.fileExists(atPath: destination.path), "The timeline exports a playable MP4: \(failure ?? "no error")")
            let asset = AVURLAsset(url: destination)
            let duration = try await asset.load(.duration).seconds
            check(abs(duration - length * 3) < 0.08, "Exported cuts match the edited timeline duration")
            let audio = try await asset.loadTracks(withMediaType: .audio)
            check(!audio.isEmpty, "Library-animation audio is included in the final export")
            let generator = AVAssetImageGenerator(asset: asset); generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let (image, _) = try await generator.image(at: EditCompositionBuilder.time(length + length / 2))
            let red = NSBitmapImageRep(cgImage: image).colorAt(x: 640, y: 360)!
            check(image.width == 1280 && image.height == 720 && red.redComponent > 0.8 && red.greenComponent < 0.15, "The exported replacement shot matches the red image shown by the compositor")
            let after = try Data(contentsOf: source)
            check(after == sourceData, "Editing and export leave the original recording unchanged")
            let exportedData = try Data(contentsOf: destination)
            await MainActor.run { editor.export(to: destination); editor.cancelExport() }
            for _ in 0..<200 { if await MainActor.run(body: { !editor.isExporting }) { break }; try await Task.sleep(nanoseconds: 50_000_000) }
            let afterCancel = try Data(contentsOf: destination)
            check(afterCancel == exportedData, "Canceling an export preserves an existing finished movie")
            check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("edit.json").path), "Canceling export keeps the editable draft")
            await MainActor.run { editor.stop() }
            let alphaFolder = directory.appendingPathComponent("editor-alpha-fixture")
            try? FileManager.default.removeItem(at: alphaFolder)
            try FileManager.default.createDirectory(at: alphaFolder.appendingPathComponent("Media"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: EditStorage.source(main, in: alphaFolder))
            let alphaURL = alphaFolder.appendingPathComponent("Media/alpha.mov")
            try await alphaAnimation(at: alphaURL)
            let alpha = EditMedia(name: "Transparent transition.mov", fileName: "alpha.mov", kind: .animation, duration: 0.5)
            let alphaDoc = VideoEditDocument(name: "Alpha verification", broadcast: broadcast, media: [main, alpha], clips: [EditClip(mediaID: main.id, start: 0, end: min(0.6, mainLength), graphics: false, transition: .library, animationID: alpha.id)])
            let alphaBuild = try await EditCompositionBuilder.build(alphaDoc, folder: alphaFolder)
            let alphaValid = try await alphaBuild.video.isValid(for: alphaBuild.composition, timeRange: CMTimeRange(start: .zero, duration: alphaBuild.composition.duration), validationDelegate: nil)
            check(alphaValid, "Animation instruction ranges form a valid complete video composition")
            let alphaSnapshot = alphaDoc
            let alphaEditor = await MainActor.run { VideoEditorModel(document: alphaSnapshot, folder: alphaFolder) }
            let alphaExport = directory.appendingPathComponent("alpha-broadcast.mp4"); try? FileManager.default.removeItem(at: alphaExport)
            await MainActor.run { alphaEditor.export(to: alphaExport) }
            for _ in 0..<400 { if await MainActor.run(body: { !alphaEditor.isExporting }) { break }; try await Task.sleep(nanoseconds: 50_000_000) }
            let alphaFailure = await MainActor.run { alphaEditor.error }
            check(alphaFailure == nil && FileManager.default.fileExists(atPath: alphaExport.path), "Transparent ProRes MOV animations export successfully: \(alphaFailure ?? "no error")")
            let alphaGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: alphaExport))
            alphaGenerator.requestedTimeToleranceBefore = .zero; alphaGenerator.requestedTimeToleranceAfter = .zero
            let (alphaImage, _) = try await alphaGenerator.image(at: EditCompositionBuilder.time(0.15))
            let alphaPixels = NSBitmapImageRep(cgImage: alphaImage)
            check(alphaPixels.colorAt(x: 100, y: 360)!.greenComponent > 0.6 && alphaPixels.colorAt(x: 1100, y: 360)!.blueComponent > 0.15, "Transparent stingers preserve the camera beneath their alpha channel")
            if mainLength >= 0.6 {
                let (afterAnimation, _) = try await alphaGenerator.image(at: EditCompositionBuilder.time(0.55))
                check(NSBitmapImageRep(cgImage: afterAnimation).colorAt(x: 100, y: 360)!.greenComponent < 0.5, "The picture continues after a shorter animation ends")
            }
            await MainActor.run { alphaEditor.stop() }
            try await advancedEditorChecks(main: main, alpha: alpha, broadcast: broadcast, folder: alphaFolder)
        } catch { check(false, "Timeline integration: \(error.localizedDescription)") }
    }
}
