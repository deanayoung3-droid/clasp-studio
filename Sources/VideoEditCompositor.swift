import AVFoundation
import CoreImage
import AppKit

struct EditShotRenderer: @unchecked Sendable {
    let clip: EditClip
    let renderer: BroadcastFrameRenderer
    init(clip: EditClip, renderer: BroadcastFrameRenderer) { self.clip = clip; self.renderer = renderer }
    init(clip: EditClip, project: StudioProject) {
        self.clip = clip
        var project = project; project.graphics = clip.graphics; project.mirror = clip.mirror
        if let id = clip.overlayID { project.selectedOverlayID = id }
        if !clip.topics {
            let docID = BroadcastGraphics.document(project).id
            if let index = project.overlayLibrary?.firstIndex(where: { $0.id == docID }) { project.overlayLibrary?[index].showHeadlines = false }
        }
        var settings = BroadcastGraphics.renderSettings(project, activeIndex: clip.section, at: BroadcastGraphics.document(project).date, epoch: 0)
        if clip.graphics && !clip.topics && BroadcastGraphics.document(project).template != .glass {
            let old = settings.cameraRect
            let wide = CGRect(x: 14, y: old.minY, width: 1252, height: 720 - old.minY - 12)
            let doc = BroadcastGraphics.document(project)
            if let base = settings.overlay {
                settings.overlay = BroadcastGraphics.image { ctx in
                    BroadcastGraphics.fill(ctx, CGRect(x: 0, y: 0, width: 1280, height: 720), NSColor(studioHex: doc.template == .law ? "080808" : doc.template == .jai ? "E1E1E1" : "F7F8F8"))
                    ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: 0, width: 1280, height: old.minY)); ctx.draw(base, in: CGRect(x: 0, y: 0, width: 1280, height: 720)); ctx.restoreGState()
                    ctx.setBlendMode(.clear); ctx.addPath(CGPath(roundedRect: wide, cornerWidth: 14, cornerHeight: 14, transform: nil)); ctx.fillPath(); ctx.setBlendMode(.normal)
                    for component in [OverlayComponent.live, .presentedBy] where component.isVisible(in: doc) {
                        ctx.saveGState(); ctx.clip(to: doc.zone(component)); ctx.draw(base, in: CGRect(x: 0, y: 0, width: 1280, height: 720)); ctx.restoreGState()
                    }
                }
            }
            settings.cameraRect = wide
            settings.cameraMask = BroadcastGraphics.image { ctx in BroadcastGraphics.rounded(ctx, wide, 14, .white) }
        }
        renderer = BroadcastFrameRenderer(settings)
    }
    func frame(primary: CIImage, secondary: CIImage?, at time: Double) -> CIImage {
        if clip.layout == .presenter { return renderer.compose(primary, at: time) }
        let rect = renderer.settings.cameraRect
        var host = primary
        if clip.mirror { host = Self.mirror(host) }
        let secondary = secondary ?? CIImage(color: .black).cropped(to: rect)
        if clip.layout == .replacement { return renderer.composePreparedCamera(Self.fit(secondary, to: rect, fill: clip.secondaryFill), at: time) }
        let left = CGRect(x: rect.minX, y: rect.minY, width: (rect.width - 6) / 2, height: rect.height)
        let right = CGRect(x: left.maxX + 6, y: rect.minY, width: left.width, height: rect.height)
        let matte = CIImage(color: .black).cropped(to: rect)
        let split = Self.fit(host, to: left, fill: true).composited(over: Self.fit(secondary, to: right, fill: clip.secondaryFill).composited(over: matte))
        return renderer.composePreparedCamera(split, at: time)
    }
    static func mirror(_ image: CIImage) -> CIImage { image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: image.extent.minX + image.extent.maxX, ty: 0)) }
    static func fit(_ image: CIImage, to rect: CGRect, fill: Bool) -> CIImage {
        if fill { return BroadcastFrameRenderer.fit(image, to: rect).cropped(to: rect) }
        let extent = image.extent
        let scale = min(rect.width / extent.width, rect.height / extent.height)
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return normalized.transformed(by: CGAffineTransform(translationX: rect.midX - normalized.extent.width / 2, y: rect.midY - normalized.extent.height / 2)).composited(over: CIImage(color: .black).cropped(to: rect)).cropped(to: rect)
    }
}
final class EditCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let requiredSourceTrackIDs: [NSValue]?
    let primaryID: CMPersistentTrackID
    let secondaryID: CMPersistentTrackID?
    let animationID: CMPersistentTrackID?
    let primaryTransform: CGAffineTransform
    let secondaryTransform: CGAffineTransform
    let animationTransform: CGAffineTransform
    let still: CIImage?
    let shot: EditShotRenderer
    let animationDuration: Double
    let fadeOutDuration: Double
    let newsOutDuration: Double
    init(range: CMTimeRange, primary: CMPersistentTrackID, secondary: CMPersistentTrackID?, animation: CMPersistentTrackID?, primaryTransform: CGAffineTransform, secondaryTransform: CGAffineTransform, animationTransform: CGAffineTransform, still: CIImage?, shot: EditShotRenderer, animationDuration: Double, fadeOutDuration: Double, newsOutDuration: Double) {
        timeRange = range; primaryID = primary; secondaryID = secondary; animationID = animation
        requiredSourceTrackIDs = ([primary] + [secondary, animation].compactMap { $0 }).map { NSNumber(value: $0) }
        self.primaryTransform = primaryTransform; self.secondaryTransform = secondaryTransform; self.animationTransform = animationTransform
        self.still = still; self.shot = shot; self.animationDuration = animationDuration; self.fadeOutDuration = fadeOutDuration; self.newsOutDuration = newsOutDuration
    }
}
final class EditVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()]
    private let queue = DispatchQueue(label: "studio.edit.compositor", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var generation = 0
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func cancelAllPendingVideoCompositionRequests() { lock.lock(); generation += 1; lock.unlock() }
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock(); let token = generation; lock.unlock()
        queue.async { [self] in autoreleasepool {
            lock.lock(); let canceled = token != generation; lock.unlock()
            guard !canceled else { request.finishCancelledRequest(); return }
            guard let instruction = request.videoCompositionInstruction as? EditCompositionInstruction, let primary = request.sourceFrame(byTrackID: instruction.primaryID), let output = request.renderContext.newPixelBuffer() else { request.finish(with: StudioError.message("A source video frame could not be decoded.")); return }
            let main = CIImage(cvPixelBuffer: primary).transformed(by: instruction.primaryTransform)
            let second = instruction.secondaryID.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0).transformed(by: instruction.secondaryTransform) } ?? instruction.still
            let time = request.compositionTime.seconds
            var frame = instruction.shot.frame(primary: main, secondary: second, at: time)
            let local = time - instruction.timeRange.start.seconds
            let length = instruction.timeRange.duration.seconds
            let clip = instruction.shot.clip
            if let stinger = Self.newsArtwork {
                let incomingLength = min(clip.transitionDuration / 2, length)
                if clip.transition == .news, local < incomingLength {
                    frame = stinger.transformed(by: CGAffineTransform(translationX: local / max(1.0 / 30, incomingLength) * 1280, y: 0)).composited(over: frame)
                }
                let remaining = length - local
                if instruction.newsOutDuration > 0, remaining < instruction.newsOutDuration {
                    let x = -1280 + (1 - remaining / instruction.newsOutDuration) * 1280
                    frame = stinger.transformed(by: CGAffineTransform(translationX: x, y: 0)).composited(over: frame)
                }
            }
            var alpha = 1.0
            if clip.transition == .fade { alpha = min(1, local / max(1.0 / 30, min(clip.transitionDuration / 2, length / 2))) }
            if instruction.fadeOutDuration > 0 { alpha = min(alpha, max(0, (length - local) / instruction.fadeOutDuration)) }
            if alpha < 1 { frame = frame.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)]).composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))) }
            if local < instruction.animationDuration, let track = instruction.animationID, let pixel = request.sourceFrame(byTrackID: track) {
                let animation = CIImage(cvPixelBuffer: pixel).transformed(by: instruction.animationTransform)
                // Aspect-fit preserves transparent padding and alpha in ProRes MOVs.
                let extent = animation.extent, scale = min(1280 / extent.width, 720 / extent.height)
                let fitted = animation.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                frame = fitted.transformed(by: CGAffineTransform(translationX: 640 - fitted.extent.width / 2, y: 360 - fitted.extent.height / 2)).composited(over: frame)
            }
            context.render(frame.cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720)), to: output, bounds: CGRect(x: 0, y: 0, width: 1280, height: 720), colorSpace: CGColorSpaceCreateDeviceRGB())
            lock.lock(); let canceledAfterRender = token != generation; lock.unlock()
            if canceledAfterRender { request.finishCancelledRequest() } else { request.finish(withComposedVideoFrame: output) }
        } }
    }
    static let newsArtwork: CIImage? = BroadcastGraphics.image { ctx in
        BroadcastGraphics.fill(ctx, CGRect(x: 0, y: 0, width: 1280, height: 720), NSColor(studioHex: "111318"))
        BroadcastGraphics.fill(ctx, CGRect(x: 1210, y: 0, width: 70, height: 720), .white)
        if let logo = BroadcastGraphics.bundledLogo?.studioCGImage { BroadcastGraphics.drawLogo(ctx, logo, in: CGRect(x: 567, y: 310, width: 110, height: 110), tint: .white) }
        BroadcastGraphics.text("CLASP", at: CGRect(x: 447, y: 230, width: 350, height: 60), size: 36, weight: .bold, color: .white, alignment: .center)
    }.map(CIImage.init(cgImage:))
}
