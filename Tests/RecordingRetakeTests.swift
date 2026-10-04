import AppKit
import AVFoundation

extension StudioTests {
    static func recordingRetakeChecks() async {
        let model = await MainActor.run { () -> StudioModel in
            let model = StudioModel(persist: false); model.connected = true; model.prompterMode = .timed
            model.activeSection = 1; model.startRecording(); return model
        }
        for index in 0..<8 {
            model.engine.queue.sync { model.engine.processVideo(videoSample(index: index)!) }
            try? await Task.sleep(nanoseconds: 35_000_000)
        }
        await MainActor.run { model.discardRecording(retake: true) }
        for _ in 0..<100 {
            if await MainActor.run(body: { model.preparingRecording && !model.finishingRecording }) { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        await MainActor.run {
            check(model.preparingRecording && model.recordingFocus && model.activeSection == 0 && model.videoEditor == nil && model.alert == nil, "Retake finalizes and discards the old take, resets the script and starts a fresh encoder")
        }
        for index in 0..<8 {
            model.engine.queue.sync { model.engine.processVideo(videoSample(index: index)!) }
            try? await Task.sleep(nanoseconds: 35_000_000)
        }
        await MainActor.run { model.stopRecording() }
        for _ in 0..<100 {
            if await MainActor.run(body: { model.videoEditor != nil && !model.busy }) { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        await MainActor.run {
            check(model.videoEditor != nil && model.alert == nil, "The replacement take remains playable and opens the editor normally")
            let folder = model.videoEditor!.folder
            model.discardDraft()
            check(model.videoEditor == nil && !FileManager.default.fileExists(atPath: folder.path) && model.activeSection == 0, "Discard draft moves its media to Trash and returns to a reset studio")
            model.startRecording(); model.discardRecording()
        }
        for _ in 0..<100 {
            if await MainActor.run(body: { !model.busy }) { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        await MainActor.run {
            check(!model.busy && model.videoEditor == nil && !model.recordingFocus && model.alert == nil, "Discard before the first frame cancels cleanly without a recording-error popup")
        }
    }
}
