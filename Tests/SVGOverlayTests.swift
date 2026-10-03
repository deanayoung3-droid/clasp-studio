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
        let bitmap = NSBitmapImageRep(data: asset.png)!
        check(asset.removedPhotos == 1 && asset.camera.rect == CGRect(x: 0, y: 0, width: 1280, height: 720), "SVG photo patterns become a correctly positioned live camera opening")
        let clear = bitmap.colorAt(x: 640, y: 360)!.alphaComponent, middle = bitmap.colorAt(x: 640, y: 630)!.alphaComponent, bottom = bitmap.colorAt(x: 640, y: 715)!.alphaComponent
        check(clear < 0.01 && middle > 0.3 && middle < 0.7 && bottom > 0.9, "SVG alpha gradients survive import instead of becoming a solid background")
        check(bitmap.colorAt(x: 1210, y: 40)!.redComponent > 0.9 && bitmap.colorAt(x: 1210, y: 40)!.alphaComponent > 0.9, "Small embedded SVG logos remain in the original artwork")
        var doc = OverlayDocument.presets(StudioProject())[0]; doc.template = .custom; doc.importedSVG = asset
        let encoded = try JSONEncoder().encode(doc), restored = try JSONDecoder().decode(OverlayDocument.self, from: encoded)
        check(restored.importedSVG == asset, "Imported SVG artwork and camera settings persist in projects and drafts")
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
        await MainActor.run {
            let model = StudioModel(persist: false)
            var nearFull = doc; nearFull.cameraWindow = SVGCameraWindow(height: 0.9995)
            model.project.overlayLibrary?.append(nearFull); model.project.selectedOverlayID = nearFull.id
            let view = NSHostingView(rootView: ImportedSVGInspector(model: model)); view.frame = CGRect(x: 0, y: 0, width: 265, height: 740); view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap); check(bitmap.pixelsWide > 0, "Nearly full-frame SVG camera controls render without invalid slider ranges") }
            else { check(false, "SVG inspector renders") }
        }
    }
}
