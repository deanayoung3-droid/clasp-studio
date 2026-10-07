import AppKit
import CoreImage
import SwiftUI

extension StudioTests {
    static func svgOverlayChecks() async throws {
        let unsafe = Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100' onload='steal()'><script>steal()</script><foreignObject/><image href='file:///private/secret'/><rect width='20' height='20' fill='red'/></svg>".utf8)
        let safe = String(decoding: try SVGOverlayImport.sanitize(unsafe), as: UTF8.self)
        check(!safe.contains("steal") && !safe.contains("foreignObject") && !safe.contains("file:///"), "SVG imports remove scripts, embedded HTML and external file references")
        check((try? SVGOverlayImport.sanitize(Data("<!DOCTYPE svg [<!ENTITY private SYSTEM 'file:///private/secret'>]><svg/>".utf8))) == nil, "SVG document entities are rejected before parsing")
        check((try? SVGOverlayImport.sanitize(Data("<svg viewBox='0 0 -5 10'/>".utf8))) == nil, "Malformed SVG dimensions do not enter the library")
        let logo = await MainActor.run { NSBitmapImageRep(cgImage: BroadcastGraphics.bitmap(width: 8, height: 8) { ctx in BroadcastGraphics.fill(ctx, CGRect(x: 0, y: 0, width: 8, height: 8), .red) }!).representation(using: .png, properties: [:])!.base64EncodedString() }
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1280" height="720" viewBox="0 0 1280 720">
        <rect width="1280" height="720" fill="white"/><rect width="1280" height="720" fill="url(#photo)"/>
        <rect y="540" width="1280" height="180" fill="url(#fade)"/>
        <image x="1200" y="30" width="24" height="24" href="data:image/png;base64,\(logo)"/>
        <defs><pattern id="photo" width="1" height="1" patternContentUnits="objectBoundingBox"><use xlink:href="#photoImage" transform="scale(.125)"/></pattern>
        <image id="photoImage" width="8" height="8" href="data:image/png;base64,\(logo)"/>
        <linearGradient id="fade" x1="0" y1="540" x2="0" y2="720" gradientUnits="userSpaceOnUse"><stop stop-color="#292929" stop-opacity="0"/><stop offset="1" stop-color="#282828"/></linearGradient></defs></svg>
        """
        let asset = try await SVGOverlayImport.render(Data(svg.utf8))
        let editableSource = Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1280 720'><defs><linearGradient id='g'><stop stop-color='black' stop-opacity='0'/><stop offset='1' stop-color='black'/></linearGradient></defs><rect y='540' width='1280' height='180' fill='url(#g)'/><path d='M410 560h60v20h-60z' fill='red'/><path d='M100 560h40v20h-40z' fill='green'/></svg>".utf8)
        let editableRegion = SVGCameraWindow(x: 0.3, y: 0.75, width: 0.6, height: 0.12)
        let unmodified = try await SVGOverlayImport.render(editableSource)
        let editable = try await SVGOverlayImport.render(editableSource, editableRegions: [editableRegion])
        let cleanPixels = NSBitmapImageRep(data: editable.png)!, originalPixels = NSBitmapImageRep(data: unmodified.png)!
        check(originalPixels.colorAt(x: 430, y: 570)!.redComponent > 0.8 && cleanPixels.colorAt(x: 430, y: 570)!.redComponent < 0.1, "Editable SVG regions remove baked-in vector lettering from the cached artwork")
        check(cleanPixels.colorAt(x: 110, y: 570)!.greenComponent > 0.3 && abs(cleanPixels.colorAt(x: 700, y: 610)!.alphaComponent - originalPixels.colorAt(x: 700, y: 610)!.alphaComponent) < 0.02, "Editing an SVG region preserves unrelated logos and original gradient panels")
        check(editable.source == unmodified.source, "Editable SVG imports retain the untouched source for restoring original content")
        var mapped = BroadcastGraphics.document(StudioProject())
        mapped.template = .custom; mapped.importedSVG = editable; mapped.svgRegions = [OverlayComponent.headlines.rawValue: editableRegion, OverlayComponent.sponsors.rawValue: SVGCameraWindow(x: 0.1, y: 0.93, width: 0.8, height: 0.06)]
        mapped.showHeadlines = true; mapped.showSponsors = true
        var mappedProject = StudioProject(); mappedProject.graphics = true; mappedProject.overlayLibrary = [mapped]; mappedProject.selectedOverlayID = mapped.id
        let mappedSettings = BroadcastGraphics.renderSettings(mappedProject, activeIndex: 0)
        check(mappedSettings.animation?.headlineTicker?.zone == editableRegion.contentRect && mappedSettings.animation?.sponsors?.destination == mapped.svgRegions![OverlayComponent.sponsors.rawValue]!.contentRect, "Imported SVG headlines and sponsor carousel use editable regions in the shared recording compositor")
        let persisted = try JSONDecoder().decode(OverlayDocument.self, from: JSONEncoder().encode(mapped))
        check(persisted.svgRegions == mapped.svgRegions, "SVG editable regions survive saving and reopening drafts")
        let rollbackSafe = await MainActor.run {
            let model = StudioModel(persist: false)
            var other = mapped; other.id = UUID(); other.name = "Other overlay"
            model.project.overlayLibrary = [mapped, other]; model.project.selectedOverlayID = mapped.id
            model.editOverlay { $0.title = "Failed edit" }
            model.selectOverlay(other.id); model.restoreSVGOverlay(mapped)
            return model.overlay == other && model.project.overlayLibrary?.first == mapped
        }
        check(rollbackSafe, "A failed SVG edit restores its own overlay after selection changes, without replacing another design")
        var renamed = mappedProject; renamed.sections[0].title = "A newly edited headline"; renamed.sponsorItems = [SponsorItem(name: "New sponsor")]
        let changed = BroadcastGraphics.renderSettings(renamed, activeIndex: 0)
        let editContext = CIContext()
        let oldText = mappedSettings.animation!.headlineTicker!.current, newText = changed.animation!.headlineTicker!.current
        let oldPNG = NSBitmapImageRep(cgImage: editContext.createCGImage(oldText, from: oldText.extent)!).representation(using: .png, properties: [:])!
        let newPNG = NSBitmapImageRep(cgImage: editContext.createCGImage(newText, from: newText.extent)!).representation(using: .png, properties: [:])!
        check(oldPNG != newPNG && changed.animation?.sponsors?.count == 1, "Imported overlays use current script headlines and edited sponsor names")
        let bitmap = NSBitmapImageRep(data: asset.png)!
        check(asset.removedPhotos == 1 && asset.camera.rect == CGRect(x: 0, y: 0, width: 1280, height: 720), "SVG photo patterns become a correctly positioned live camera opening")
        let clear = bitmap.colorAt(x: 640, y: 360)!.alphaComponent, middle = bitmap.colorAt(x: 640, y: 630)!.alphaComponent, bottom = bitmap.colorAt(x: 640, y: 715)!.alphaComponent
        check(clear < 0.01 && middle > 0.3 && middle < 0.7 && bottom > 0.9, "SVG alpha gradients survive import instead of becoming a solid background")
        check(bitmap.colorAt(x: 1210, y: 40)!.redComponent > 0.9 && bitmap.colorAt(x: 1210, y: 40)!.alphaComponent > 0.9, "Small embedded SVG logos remain in the original artwork")
        let square = Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><rect id='camera' width='100' height='100'/><circle cx='50' cy='50' r='20' fill='red'/></svg>".utf8)
        let fitted = try await SVGOverlayImport.render(square)
        let fitPixels = NSBitmapImageRep(data: fitted.png)!
        check(fitted.fit == .fit && fitted.camera.rect == CGRect(x: 280, y: 0, width: 720, height: 720), "Non-16:9 SVGs fit with a camera opening that preserves source proportions")
        check(fitPixels.colorAt(x: 500, y: 360)!.alphaComponent > 0.9 && fitPixels.colorAt(x: 480, y: 360)!.alphaComponent < 0.01 && fitPixels.colorAt(x: 640, y: 500)!.alphaComponent > 0.9 && fitPixels.colorAt(x: 640, y: 520)!.alphaComponent < 0.01, "A square SVG circle stays circular in the 16:9 preview")
        let filled = try await SVGOverlayImport.render(square, fit: .fill)
        let fillPixels = NSBitmapImageRep(data: filled.png)!
        check(filled.camera.rect == CGRect(x: 0, y: 0, width: 1280, height: 720) && fillPixels.colorAt(x: 390, y: 360)!.alphaComponent > 0.9 && fillPixels.colorAt(x: 640, y: 610)!.alphaComponent > 0.9, "Fill covers the broadcast by cropping, without stretching SVG geometry")
        let portrait = try await SVGOverlayImport.render(Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='10 20 100 200'><rect x='10' y='20' width='100' height='200' fill='white'/><rect id='camera' x='10' y='20' width='100' height='200'/></svg>".utf8))
        check(portrait.camera.rect == CGRect(x: 460, y: 0, width: 360, height: 720) && NSBitmapImageRep(data: portrait.png)!.colorAt(x: 640, y: 360)!.alphaComponent < 0.01, "Portrait SVGs and nonzero viewBox origins retain their camera alignment and remove solid canvas fills")
        var legacy = fitted; legacy.id = UUID(); legacy.fit = nil; legacy.camera = SVGCameraWindow()
        let stretched = BroadcastGraphics.image { ctx in BroadcastGraphics.fill(ctx, CGRect(x: 0, y: 0, width: 1280, height: 720), .red) }!
        legacy.png = NSBitmapImageRep(cgImage: stretched).representation(using: .png, properties: [:])!
        var legacyDoc = OverlayDocument.presets(StudioProject())[0]; legacyDoc.template = .custom; legacyDoc.importedSVG = legacy
        let legacySettings = ImportedSVGGraphics.settings(legacyDoc, mirror: false), legacyPixels = NSBitmapImageRep(cgImage: legacySettings.overlay!)
        check(legacySettings.cameraRect == CGRect(x: 280, y: 0, width: 720, height: 720) && legacyPixels.colorAt(x: 300, y: 360)!.redComponent > 0.9, "Previously saved stretched SVGs recover their original aspect ratio with the original camera opening")
        var squareDoc = legacyDoc; squareDoc.importedSVG = fitted
        check(ImportedSVGGraphics.settings(squareDoc, mirror: false).cameraRect == CGRect(x: 280, y: 0, width: 720, height: 720), "SVG camera opening preserves its original proportions")
        var squareProject = StudioProject(); squareProject.overlayLibrary = [squareDoc]; squareProject.selectedOverlayID = squareDoc.id
        let squareSettings = BroadcastGraphics.renderSettings(squareProject, activeIndex: 0), squareRenderer = BroadcastFrameRenderer(squareSettings)
        let blueSquare = CIImage(color: CIColor(red: 0, green: 0.6, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        let cropped = squareRenderer.cropForOutput(squareRenderer.compose(blueSquare, at: 0))
        check(squareSettings.outputRect == CGRect(x: 280, y: 0, width: 720, height: 720) && cropped.extent == CGRect(x: 0, y: 0, width: 720, height: 720), "Output crops to the SVG canvas instead of filling side margins")
        let squarePixels = NSBitmapImageRep(cgImage: CIContext().createCGImage(cropped, from: cropped.extent)!)
        check(squarePixels.colorAt(x: 1, y: 360)!.blueComponent > 0.9 && squarePixels.colorAt(x: 719, y: 360)!.blueComponent > 0.9, "Cropped output has camera at both edges without black bars")
        squareProject.overlayLibrary?[0].cropToSVG = false
        check(BroadcastGraphics.outputRect(squareProject).width == 1280, "The optional 16:9 canvas remains available")
        let narrowFade = try await SVGOverlayImport.render(Data(svg.replacingOccurrences(of: "width=\"1280\" height=\"720\" viewBox=\"0 0 1280 720\"", with: "width=\"1000\" height=\"720\" viewBox=\"0 0 1000 720\"").utf8))
        squareProject.overlayLibrary?[0].cropToSVG = nil; squareProject.overlayLibrary?[0].importedSVG = narrowFade
        check(BroadcastGraphics.outputRect(squareProject) == CGRect(x: 140, y: 0, width: 1000, height: 720), "Narrow SVG output removes only the transparent side space")
        var doc = OverlayDocument.presets(StudioProject())[0]; doc.template = .custom; doc.importedSVG = asset
        let encoded = try JSONEncoder().encode(doc), restored = try JSONDecoder().decode(OverlayDocument.self, from: encoded)
        check(restored.importedSVG == asset, "Imported SVG artwork and camera settings persist in projects and drafts")
        let fillRoundTrip = try JSONDecoder().decode(ImportedSVGOverlay.self, from: JSONEncoder().encode(filled))
        check(fillRoundTrip.fit == .fill, "SVG framing choice persists in saved projects")
        let context = CIContext(), bounds = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let blue = CIImage(color: CIColor(red: 0, green: 0.6, blue: 1)).cropped(to: bounds)
        let rendered = BroadcastFrameRenderer(ImportedSVGGraphics.settings(doc, mirror: false)).compose(blue, at: 0)
        let final = NSBitmapImageRep(cgImage: context.createCGImage(rendered, from: bounds)!)
        check(final.colorAt(x: 640, y: 360)!.blueComponent > 0.95 && final.colorAt(x: 640, y: 630)!.blueComponent < 0.8, "The native camera remains visible through the imported SVG fade")
        var ticker = OverlayDocument.presets(StudioProject()).first(where: { $0.template == .ticker })!; ticker.showDate = false
        let tickerPixels = NSBitmapImageRep(cgImage: BroadcastGraphics.tickerOverlay(StudioProject(), doc: ticker, at: Date())!)
        check(tickerPixels.colorAt(x: 950, y: 540)!.alphaComponent < 0.02 && tickerPixels.colorAt(x: 950, y: 635)!.alphaComponent > 0.4 && tickerPixels.colorAt(x: 950, y: 715)!.alphaComponent > 0.95, "The supplied ticker uses its original clear-to-charcoal gradient")
        doc.cameraWindow = SVGCameraWindow(x: 0.1, y: 0.1, width: 0.5, height: 0.5, radius: 12); doc.cutCameraWindow = true
        let adjusted = ImportedSVGGraphics.settings(doc, mirror: false)
        check(adjusted.cameraRect == CGRect(x: 128, y: 288, width: 640, height: 360), "Imported SVG camera windows can be resized and repositioned independently")
        let inspectorDocument = doc
        await MainActor.run {
            let model = StudioModel(persist: false)
            var nearFull = inspectorDocument; nearFull.cameraWindow = SVGCameraWindow(height: 0.9995)
            model.project.overlayLibrary?.append(nearFull); model.project.selectedOverlayID = nearFull.id
            let view = NSHostingView(rootView: ImportedSVGInspector(model: model)); view.frame = CGRect(x: 0, y: 0, width: 265, height: 740); view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); check(bitmap.pixelsWide > 0, "Nearly full-frame SVG camera controls render without invalid slider ranges") }
            else { check(false, "SVG inspector renders") }
        }
    }
}
