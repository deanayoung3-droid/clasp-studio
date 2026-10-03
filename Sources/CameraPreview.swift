import SwiftUI
import MetalKit
import CoreImage
import AppKit
import QuartzCore

// A single latest-frame slot avoids a growing UI backlog. Camera frames never
// publish through StudioModel or force the script/settings hierarchy to redraw.
protocol CameraFrameDisplaying: AnyObject { func display(_ image: CIImage?) }

final class CameraPreviewSurface: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CIImage?
    private var scheduled = false
    private weak var view: (any CameraFrameDisplaying)?
    func submit(_ frame: CIImage) {
        lock.lock(); latest = frame
        let needsDraw = !scheduled; scheduled = true; lock.unlock()
        if needsDraw { DispatchQueue.main.async { [weak self] in self?.displayLatest() } }
    }
    func currentFrame() -> CIImage? { lock.lock(); defer { lock.unlock() }; return latest }
    func clear() {
        lock.lock(); latest = nil; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.view?.display(nil) }
    }
    @MainActor func attach(_ view: any CameraFrameDisplaying) { if self.view !== view { self.view = view; view.display(currentFrame()) } }
    @MainActor func detach(_ view: any CameraFrameDisplaying) { if self.view === view { self.view = nil } }
    @MainActor private func displayLatest() {
        lock.lock(); let frame = latest; scheduled = false; lock.unlock()
        view?.display(frame)
    }
}

final class CameraGPUContext {
    private let context: CIContext
    init(commands: MTLCommandQueue) { context = CIContext(mtlCommandQueue: commands, options: [.cacheIntermediates: false]) }
    func render(_ frame: CIImage, to texture: MTLTexture, command: MTLCommandBuffer) throws {
        let size = CGSize(width: texture.width, height: texture.height)
        let scaled = frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY)).transformed(by: CGAffineTransform(scaleX: size.width / frame.extent.width, y: size.height / frame.extent.height))
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: command)
        // A drawable's row zero is the top of the screen, unlike Core Image's y=0.
        destination.isFlipped = true; destination.colorSpace = CGColorSpaceCreateDeviceRGB()
        _ = try context.startTask(toRender: scaled, to: destination)
    }
}

final class CameraMetalView: MTKView, MTKViewDelegate, CameraFrameDisplaying {
    private var image: CIImage?
    private let renderer: CameraGPUContext
    private let commands: MTLCommandQueue
    private let inFlight = DispatchSemaphore(value: 1)
    private let renderQueue = DispatchQueue(label: "studio.preview.gpu", qos: .userInteractive)
    init(gpu: MTLDevice, commands: MTLCommandQueue) {
        renderer = CameraGPUContext(commands: commands)
        self.commands = commands
        super.init(frame: .zero, device: gpu)
        framebufferOnly = false; isPaused = true; enableSetNeedsDisplay = false
        colorPixelFormat = .bgra8Unorm; clearColor = MTLClearColorMake(0.04, 0.04, 0.04, 1)
        delegate = self
    }
    required init(coder: NSCoder) { fatalError("Programmatic camera preview") }
    func display(_ image: CIImage?) { self.image = image; draw() }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { draw() }
    func draw(in view: MTKView) {
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor,
              let metalLayer = layer as? CAMetalLayer,
              inFlight.wait(timeout: .now()) == .success else { return }
        let frame = image ?? CIImage(color: CIColor(red: 0.04, green: 0.04, blue: 0.04)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        // nextDrawable can wait on WindowServer/GPU. Acquire and render on this
        // queue so it cannot block recording controls or speech cue updates.
        let gate = inFlight, renderer = self.renderer, commands = self.commands
        renderQueue.async {
            guard let drawable = metalLayer.nextDrawable(), let command = commands.makeCommandBuffer() else { gate.signal(); return }
            do { try renderer.render(frame, to: drawable.texture, command: command) }
            catch { gate.signal(); return }
            command.present(drawable); command.addCompletedHandler { _ in gate.signal() }; command.commit()
        }
    }
}

final class CameraFallbackView: NSImageView, CameraFrameDisplaying {
    private let renderer = CIContext()
    func display(_ frame: CIImage?) {
        image = frame.flatMap { renderer.createCGImage($0, from: $0.extent) }.map { NSImage(cgImage: $0, size: NSSize(width: 1280, height: 720)) }
    }
}
struct CameraPreviewView: NSViewRepresentable {
    let surface: CameraPreviewSurface
    func makeNSView(context: Context) -> NSView {
        if let gpu = MTLCreateSystemDefaultDevice(), let commands = gpu.makeCommandQueue() {
            let view = CameraMetalView(gpu: gpu, commands: commands); surface.attach(view); return view
        }
        let view = CameraFallbackView(); view.imageScaling = .scaleAxesIndependently; surface.attach(view); return view
    }
    func updateNSView(_ view: NSView, context: Context) { if let target = view as? any CameraFrameDisplaying { surface.attach(target) } }
    static func dismantleNSView(_ view: NSView, coordinator: ()) { (view as? CameraMetalView)?.delegate = nil }
}

final class WindowAttachmentView: NSView {
    var onWindow: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { onWindow?(window) } }
}

// Enter full screen only when a recording starts. Preserve an existing full-screen
// window, and allow Escape / Exit focus without stopping the recording.
struct RecordingWindowBridge: NSViewRepresentable {
    @ObservedObject var model: StudioModel
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = WindowAttachmentView()
        view.onWindow = { [weak coordinator = context.coordinator] window in coordinator?.update(window: window, focus: model.recordingFocus) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        let focus = model.recordingFocus
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.update(window: window, focus: focus)
        }
    }
    final class Coordinator {
        private var focused = false
        private var entered = false
        private var exitWhenEntered = false
        private var observation: NSObjectProtocol?
        func update(window: NSWindow, focus: Bool) {
            if observation == nil {
                observation = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self, weak window] _ in
                    guard let self, self.exitWhenEntered, let window else { return }
                    self.exitWhenEntered = false; window.toggleFullScreen(nil)
                }
            }
            guard focus != focused else { return }; focused = focus
            if focus && !window.styleMask.contains(.fullScreen) {
                entered = true; exitWhenEntered = false; window.toggleFullScreen(nil)
            } else if !focus && entered {
                entered = false
                if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                else { exitWhenEntered = true }
            }
        }
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}
