import AVFoundation
import AppKit
import CoreImage

final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "studio.capture", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var settings = RenderSettings()
    private let audioQueue = DispatchQueue(label: "studio.microphone", qos: .userInitiated)
    private let pendingAudio = DispatchSemaphore(value: 12)
    private var renderer = BroadcastFrameRenderer(RenderSettings())
    private var demoTimer: DispatchSourceTimer?
    private var receivedVideo = false
    private var receivedAudio = false
    private var lastMeter = 0.0
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private var hasRecordedVideo = false
    private var recordingURL: URL?
    private var cleanRecording = false
    private var recordingBounds = CGRect(x: 0, y: 0, width: 1280, height: 720)
    private var hasAudio = false
    private var captureDevice: AVCaptureDevice?
    private var nativeBackground = false
    private var nativePortrait = false
    var onFirstVideo: (() -> Void)?
    var onFirstAudio: (() -> Void)?
    var onFrameTiming: ((Double) -> Void)?
    var onNativeEffects: ((Bool, Bool) -> Void)?
    var onFrame: ((CIImage) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onStatus: ((Bool, Bool, String?) -> Void)?
    var onRecordingStarted: (() -> Void)?
    var onRecordingFinished: ((URL?, String?) -> Void)?
    var onWarning: ((String) -> Void)?

    deinit { demoTimer?.cancel() }
    static func devices(_ type: AVMediaType) -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = type == .video ? [.builtInWideAngleCamera, .external, .continuityCamera] : [.microphone, .external]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: type, position: .unspecified).devices
    }
    func update(_ settings: RenderSettings) { queue.async { self.settings = settings; self.renderer = BroadcastFrameRenderer(settings) } }
    func connect(cameraID: String, microphoneID: String) {
        queue.async {
            guard self.writer == nil else { return }
            self.session.stopRunning()
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }
            self.hasAudio = false; self.captureDevice = nil; self.receivedVideo = false
            self.audioQueue.sync { self.receivedAudio = false }
            do {
                guard let camera = Self.devices(.video).first(where: { $0.uniqueID == cameraID }) else { throw StudioError.message("The selected camera is unavailable. Reconnect it and refresh devices.") }
                let input = try AVCaptureDeviceInput(device: camera)
                guard self.session.canAddInput(input) else { throw StudioError.message("Cannot connect this camera.") }
                self.session.addInput(input); self.captureDevice = camera
                if self.session.canSetSessionPreset(.hd1280x720) { self.session.sessionPreset = .hd1280x720 }
                let video = AVCaptureVideoDataOutput()
                let format = video.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA
                video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
                video.alwaysDiscardsLateVideoFrames = true
                video.setSampleBufferDelegate(self, queue: self.queue)
                guard self.session.canAddOutput(video) else { throw StudioError.message("Cannot receive video from this camera.") }
                self.session.addOutput(video)
                if let device = Self.devices(.audio).first(where: { $0.uniqueID == microphoneID }), AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                    let mic = try AVCaptureDeviceInput(device: device)
                    if self.session.canAddInput(mic) {
                        self.session.addInput(mic)
                        let audio = AVCaptureAudioDataOutput()
                        audio.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
                        audio.setSampleBufferDelegate(self, queue: self.audioQueue)
                        if self.session.canAddOutput(audio) { self.session.addOutput(audio); self.hasAudio = true }
                    }
                }
                self.session.commitConfiguration()
                // A 60/120 fps webcam should not double or quadruple the work for
                // this 30 fps HD studio. Leave unsupported device rates alone.
                if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                    do {
                        try camera.lockForConfiguration()
                        camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                        camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                        camera.unlockForConfiguration()
                    } catch { self.onWarning?("Using the camera's default frame rate: " + error.localizedDescription) }
                }
                self.session.startRunning()
                self.onStatus?(self.session.isRunning, self.hasAudio, self.session.isRunning ? nil : "The capture session did not start. Reconnect your camera.")
            } catch {
                self.session.commitConfiguration()
                self.onStatus?(false, false, error.localizedDescription)
            }
        }
    }
    func disconnect() { queue.async { if self.writer == nil { self.session.stopRunning(); self.onStatus?(false, false, nil); self.onLevel?(0) } } }
    func startRecording(to url: URL, syntheticAudio: Bool = false, cleanSource: Bool = false) {
        queue.async {
            guard self.writer == nil else { self.onRecordingFinished?(nil, "A recording is already active."); return }
            do {
                let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                self.recordingBounds = cleanSource ? CGRect(x: 0, y: 0, width: 1280, height: 720) : CGRect(origin: .zero, size: self.settings.outputRect.size)
                let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(self.recordingBounds.width), AVVideoHeightKey: Int(self.recordingBounds.height), AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoExpectedSourceFrameRateKey: 30]])
                video.expectsMediaDataInRealTime = true
                guard writer.canAdd(video) else { throw StudioError.message("The video encoder is unavailable.") }
                writer.add(video)
                self.adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Int(self.recordingBounds.width), kCVPixelBufferHeightKey as String: Int(self.recordingBounds.height), kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
                self.audioInput = nil
                if self.hasAudio || syntheticAudio {
                    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000])
                    audio.expectsMediaDataInRealTime = true
                    guard writer.canAdd(audio) else { throw StudioError.message("The audio encoder is unavailable.") }
                    writer.add(audio); self.audioInput = audio
                }
                guard writer.startWriting() else { throw writer.error ?? StudioError.message("Could not start recording.") }
                self.cleanRecording = cleanSource; self.writer = writer; self.videoInput = video; self.startTime = nil; self.hasRecordedVideo = false; self.recordingURL = url
            } catch { self.onRecordingFinished?(nil, error.localizedDescription) }
        }
    }
    func stopRecording() {
        queue.async {
            guard let writer = self.writer else { self.onRecordingFinished?(nil, "Recording did not start. Try connecting your camera again."); return }
            let url = self.recordingURL
            if self.startTime == nil {
                writer.cancelWriting(); self.writer = nil; self.videoInput = nil; self.audioInput = nil; self.adaptor = nil
                if let url { try? FileManager.default.removeItem(at: url) }
                self.onRecordingFinished?(nil, "No camera frames were received. Reconnect your camera and try again.")
                return
            }
            self.videoInput?.markAsFinished(); self.audioInput?.markAsFinished()
            self.writer = nil; self.videoInput = nil; self.audioInput = nil; self.adaptor = nil; self.startTime = nil
            writer.finishWriting {
                if writer.status == .completed { self.onRecordingFinished?(url, nil) }
                else { self.onRecordingFinished?(nil, writer.error?.localizedDescription ?? "No video frames were recorded. Check your camera and try again.") }
            }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput { processVideo(sample) }
        else {
            // Speech receives the selected mic independently of video composition/encoding.
            if !receivedAudio { receivedAudio = true; onFirstAudio?() }
            onAudio?(sample)
            guard pendingAudio.wait(timeout: .now()) == .success else { return }
            queue.async { self.processAudio(sample); self.pendingAudio.signal() }
        }
    }
    func processVideo(_ sample: CMSampleBuffer) {
        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { return }
        if !receivedVideo { receivedVideo = true; onFirstVideo?() }
        let source = CIImage(cvPixelBuffer: pixel)
        var background = false
        if #available(macOS 15, *) { background = captureDevice?.isBackgroundReplacementActive ?? false }
        let portrait = captureDevice?.isPortraitEffectActive ?? false
        if background != nativeBackground || portrait != nativePortrait {
            nativeBackground = background; nativePortrait = portrait; onNativeEffects?(background, portrait)
        }
        let frame = compose(source)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let captureDelay = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - CMTimeGetSeconds(pts)
        if captureDelay >= 0 && captureDelay < 5 { onFrameTiming?(captureDelay) }
        if let writer, let input = videoInput, let adaptor {
            if writer.status == .failed {
                let message = writer.error?.localizedDescription ?? "Recording failed."
                self.writer = nil; videoInput = nil; audioInput = nil; self.adaptor = nil; startTime = nil
                onRecordingFinished?(nil, message)
            } else if writer.status == .writing {
                if startTime == nil { startTime = pts; writer.startSession(atSourceTime: pts) }
                if input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool {
                    var buffer: CVPixelBuffer?
                    if CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer {
                        let recordedFrame = cleanRecording ? BroadcastFrameRenderer.fit(source, to: recordingBounds) : BroadcastFrameRenderer.fit(renderer.cropForOutput(frame), to: recordingBounds)
                        context.render(recordedFrame, to: buffer)
                        if adaptor.append(buffer, withPresentationTime: pts) {
                            if !hasRecordedVideo { hasRecordedVideo = true; onRecordingStarted?() }
                        } else { onWarning?(writer.error?.localizedDescription ?? "A video frame could not be saved.") }
                    }
                }
            }
        }
        onFrame?(renderer.cropForOutput(frame))
    }
    func processAudio(_ sample: CMSampleBuffer) {
        if let input = audioInput, let startTime, CMSampleBufferGetPresentationTimeStamp(sample) >= startTime, input.isReadyForMoreMediaData { if !input.append(sample), let error = writer?.error { onWarning?(error.localizedDescription) } }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMeter >= 0.1 else { return }; lastMeter = now
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return }
        var length = 0; var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { return }
        var total = 0.0; var count = 0
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32 {
            count = length / 4; let values = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
            for i in 0..<count { total += Double(values[i] * values[i]) }
        } else if asbd.mBitsPerChannel == 16 {
            count = length / 2; let values = UnsafeRawPointer(pointer).assumingMemoryBound(to: Int16.self)
            for i in 0..<count { let v = Double(values[i]) / 32768; total += v * v }
        }
        if count > 0 { onLevel?(min(1, sqrt(total / Double(count)) * 5)) }
    }
    func compose(_ source: CIImage, at time: Double = ProcessInfo.processInfo.systemUptime) -> CIImage { renderer.compose(source, at: time) }
    func startDemo() {
        queue.async { [self] in
            guard self.demoTimer == nil, let background = BroadcastGraphics.demoBackground else { return }
            let source = CIImage(cgImage: background)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in
                guard let self, !self.session.isRunning else { return }
                autoreleasepool { self.onFrame?(self.renderer.cropForOutput(self.compose(source))) }
            }
            self.demoTimer = timer; timer.resume()
        }
    }
}
