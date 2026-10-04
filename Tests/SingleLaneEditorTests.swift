import AppKit
import AVFoundation

extension StudioTests {
    static func singleLaneEditorChecks(main: EditMedia, folder: URL) async throws {
        var project = StudioProject(); project.graphics = false
        let length = min(0.4, main.duration)
        var initialShots = (0..<3).map { _ in EditClip(mediaID: main.id, start: 0, end: length, graphics: false) }
        initialShots[0].transition = .news; initialShots[0].volume = 0.3; initialShots[0].layout = .inset
        let shots = initialShots
        let original = VideoEditDocument(broadcast: project, media: [main], clips: shots)
        var order = original
        check(order.insertClip(shots[0].id, at: 3) && order.clips.map(\.id) == [shots[1].id, shots[2].id, shots[0].id], "Dropping after the last shot preserves the dragged shot and its effects")
        check(order.insertClip(shots[0].id, at: 0) && order.clips == shots, "Dropping before the first shot restores its source, layout, transition and audio")
        check(order.insertClip(shots[0].id, at: 2) && order.clips.map(\.id) == [shots[1].id, shots[0].id, shots[2].id], "A forward adjacent drop inserts after the neighboring shot")
        check(!order.insertClip(shots[0].id, at: 2) && abs(order.duration - original.duration) < 0.001, "Dropping into the same gap never changes duration or duplicates a shot")
        check(original.insertionIndex(at: -1) == 0 && original.insertionIndex(at: length * 0.75) == 1 && original.insertionIndex(at: 100) == 3, "Drag positions choose insertion gaps before, between and after shots")
        let picture = EditMedia(name: "Layout image", fileName: "picture.png", kind: .image, duration: 0)
        let image = BroadcastGraphics.bitmap(width: 320, height: 180) { ctx in BroadcastGraphics.fill(ctx, CGRect(x: 0, y: 0, width: 320, height: 180), NSColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1)) }!
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: EditStorage.source(picture, in: folder))
        var initialDocument = original; initialDocument.media.append(picture); initialDocument.clips[0].layout = .presenter
        let document = initialDocument
        let editor = await MainActor.run { VideoEditorModel(document: document, folder: folder) }
        await MainActor.run {
            editor.selection = shots[2].id; editor.seek(0); editor.setLayout(.split)
            check(editor.selected?.secondaryID == picture.id && editor.selected?.layout == .split && abs(editor.position - length * 2) < 0.001, "Changing layout chooses available supporting media and previews the selected shot")
            editor.insertClip(shots[2].id, at: 0); editor.undo()
            check(editor.document.clips.map(\.id) == shots.map(\.id), "One undo restores a timeline insertion")
        }
        for _ in 0..<200 { if await MainActor.run(body: { !editor.preparing && editor.pausedFrame != nil }) { break }; try await Task.sleep(nanoseconds: 25_000_000) }
        let edited = await MainActor.run { editor.document }
        let composition = try await EditCompositionBuilder.build(edited, folder: folder)
        let generator = AVAssetImageGenerator(asset: composition.composition); generator.videoComposition = composition.video
        let (frame, _) = try await generator.image(at: EditCompositionBuilder.time(length * 2 + length / 2))
        check(NSBitmapImageRep(cgImage: frame).colorAt(x: 950, y: 360)!.redComponent > 0.8, "The selected split layout renders its supporting image in the actual timeline composition")
        // The native chooser may finish after the user selects another shot.
        await MainActor.run {
            editor.importMediaFiles([EditStorage.source(picture, in: folder)], kind: .image, secondary: true, targetID: shots[2].id)
            editor.selection = shots[0].id
        }
        for _ in 0..<200 { if await MainActor.run(body: { !editor.importing }) { break }; try await Task.sleep(nanoseconds: 25_000_000) }
        await MainActor.run {
            check(editor.document.clips[2].secondaryID != picture.id && editor.document.clips[0].secondaryID == nil && editor.selection == shots[2].id, "Supporting-media import stays attached to the original target shot")
            editor.stop()
        }
    }
}
