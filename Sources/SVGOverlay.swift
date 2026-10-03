import AppKit
import CoreImage
import WebKit

struct SVGCameraWindow: Codable, Equatable {
    var x = 0.0, y = 0.0, width = 1.0, height = 1.0, radius = 0.0
    var rect: CGRect {
        let w = min(1, max(0.05, width.isFinite ? width : 1)), h = min(1, max(0.05, height.isFinite ? height : 1))
        let left = min(1 - w, max(0, x.isFinite ? x : 0)), top = min(1 - h, max(0, y.isFinite ? y : 0))
        return CGRect(x: left * 1280, y: (1 - top - h) * 720, width: w * 1280, height: h * 720)
    }
    var safeRadius: Double { min(40, max(0, radius.isFinite ? radius : 0)) }
}
struct ImportedSVGOverlay: Codable, Equatable {
    var id = UUID()
    var source: Data
    var png: Data
    var camera: SVGCameraWindow
    var replacePhotos = true
    var removeCanvasFill = true
    var removedPhotos = 0
}
enum SVGOverlayImport {
    // SVG is artwork, never executable input. Network and file references are
    // removed before WebKit sees it; its page also has a restrictive CSP.
    static func sanitize(_ data: Data) throws -> Data {
        guard data.count <= 12 * 1024 * 1024, let string = String(data: data, encoding: .utf8), !string.lowercased().contains("<!doctype"), !string.lowercased().contains("<!entity") else { throw StudioError.message("Choose an SVG under 12 MB, without document entities.") }
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard let root = document.rootElement(), root.localName?.lowercased() == "svg" else { throw StudioError.message("This file does not contain an SVG overlay.") }
        if let box = root.attribute(forName: "viewBox")?.stringValue {
            let values = box.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Double($0) }
            guard values.count == 4, values.allSatisfy({ $0.isFinite && abs($0) <= 100_000 }), values[2] > 0, values[3] > 0 else { throw StudioError.message("The SVG viewBox is invalid.") }
        }
        var count = 0
        func clean(_ element: XMLElement, depth: Int) throws {
            count += 1
            guard count <= 20_000, depth <= 100 else { throw StudioError.message("This SVG is too complex. Simplify it and import again.") }
            for child in element.children ?? [] {
                guard let node = child as? XMLElement else { continue }
                let name = (node.localName ?? node.name ?? "").lowercased()
                if ["script", "foreignobject", "iframe", "object", "embed", "animate", "animatetransform", "set", "link"].contains(name) { node.detach(); continue }
                if name == "style", let css = node.stringValue, css.lowercased().contains("@import") { node.detach(); continue }
                try clean(node, depth: depth + 1)
            }
            for attribute in element.attributes ?? [] {
                let name = (attribute.localName ?? attribute.name ?? "").lowercased(), value = attribute.stringValue ?? "", lower = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if name.hasPrefix("on") { attribute.detach(); continue }
                if name == "href", !lower.hasPrefix("#"), !["data:image/png;base64,", "data:image/jpeg;base64,", "data:image/webp;base64,", "data:image/gif;base64,"].contains(where: { lower.hasPrefix($0) }) { attribute.detach() }
            }
        }
        try clean(root, depth: 0)
        return root.xmlString(options: [.nodePreserveAll]).data(using: .utf8)!
    }
    @MainActor static func render(_ data: Data, replacePhotos: Bool = true, removeCanvasFill: Bool = true) async throws -> ImportedSVGOverlay {
        let clean = try await Task.detached { try sanitize(data) }.value
        let renderer = SVGImportRenderer()
        return try await renderer.render(clean, replacePhotos: replacePhotos, removeCanvasFill: removeCanvasFill)
    }
}
@MainActor private final class SVGImportRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView!
    private var continuation: CheckedContinuation<ImportedSVGOverlay, Error>?
    private var timeout: Task<Void, Never>?
    private var source = Data()
    private var replacePhotos = true, removeCanvasFill = true
    func render(_ source: Data, replacePhotos: Bool, removeCanvasFill: Bool) async throws -> ImportedSVGOverlay {
        self.source = source; self.replacePhotos = replacePhotos; self.removeCanvasFill = removeCanvasFill
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), configuration: config)
        webView.navigationDelegate = self; webView.setValue(false, forKey: "drawsBackground")
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeout = Task { [weak self] in do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }; self?.finish(.failure(StudioError.message("This SVG took too long to render. Simplify filters or embedded images and try again."))) }
            let svg = String(decoding: source, as: UTF8.self)
            webView.loadHTMLString("""
            <html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; script-src 'none'"><style>html,body{margin:0;width:1280px;height:720px;background:transparent;overflow:hidden}body>svg{display:block;width:1280px;height:720px}</style></head><body>\(svg)</body></html>
            """, baseURL: nil)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Our own geometry inspection runs after SVG scripts have been disabled.
        let script = #"""
        (()=>{
          const svg=document.querySelector('svg');
          if(!svg) throw Error('SVG missing');
          if(!svg.hasAttribute('viewBox')){
            const w=parseFloat(svg.getAttribute('width')),h=parseFloat(svg.getAttribute('height'));
            if(!(w>0&&h>0)) throw Error('SVG needs a viewBox or width and height');
            svg.setAttribute('viewBox',`0 0 ${w} ${h}`);
          }
          svg.setAttribute('width','1280');svg.setAttribute('height','720');svg.setAttribute('preserveAspectRatio','none');
          const bounds=e=>{const b=e.getBoundingClientRect();return {x:b.x/1280,y:b.y/720,width:b.width/1280,height:b.height/720}};
          const area=b=>b.width*b.height;
          const visible=e=>!e.closest('defs,clipPath,mask,pattern');
          const candidates=[];
          for(const e of svg.querySelectorAll('image,rect,path,polygon')){
            if(!visible(e))continue;
            const b=bounds(e);if(area(b)<.05)continue;
            const label=(e.id+' '+(e.getAttribute('data-role')||'')).toLowerCase();
            if(/camera|video-feed|presenter-photo/.test(label)) candidates.push({e,b,named:true});
            if(e.tagName.toLowerCase()==='image'&&area(b)>.18)candidates.push({e,b,photo:true});
            const fill=e.getAttribute('fill')||getComputedStyle(e).fill;
            const match=fill.match(/url\(["']?#([^"')]+)["']?\)/);
            const pattern=match?document.getElementById(match[1]):null;
            if(pattern&&pattern.tagName.toLowerCase()==='pattern'&&area(b)>.18){
              const embedded=pattern.querySelector('image')||Array.from(pattern.querySelectorAll('use')).map(u=>document.getElementById((u.getAttribute('href')||u.getAttribute('xlink:href')||'').replace(/^#/,''))).find(n=>n&&n.tagName.toLowerCase()==='image');
              if(embedded)candidates.push({e,b,photo:true,pattern,embedded});
            }
          }
          candidates.sort((a,b)=>(b.named?10:0)+area(b.b)-(a.named?10:0)-area(a.b));
          const camera=candidates[0]?.b||{x:0,y:0,width:1,height:1};let removed=0;
          if(\#(replacePhotos ? "true" : "false"))for(const c of candidates){
            if(c.photo||c.named){c.e.remove();if(c.pattern)c.pattern.remove();if(c.embedded)c.embedded.remove();removed++;}
          }
          if(\#(removeCanvasFill ? "true" : "false"))for(const e of Array.from(svg.querySelectorAll('rect'))){
            if(!visible(e))continue;const b=bounds(e),fill=e.getAttribute('fill')||getComputedStyle(e).fill;
            if(area(b)>.97&&!fill.includes('url(')&&fill!=='none')e.remove();
          }
          return {camera,removed};
        })()
        """#
        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self, self.continuation != nil else { return }
            guard error == nil, let result = value as? [String: Any] else { self.finish(.failure(StudioError.message("The SVG could not be rendered. Check its viewBox and embedded artwork."))); return }
            let raw = result["camera"] as? [String: Double] ?? [:]
            let camera = SVGCameraWindow(x: raw["x"] ?? 0, y: raw["y"] ?? 0, width: raw["width"] ?? 1, height: raw["height"] ?? 1)
            let snapshot = WKSnapshotConfiguration(); snapshot.rect = self.webView.bounds; snapshot.snapshotWidth = 1280
            self.webView.takeSnapshot(with: snapshot) { [weak self] image, error in
                guard let self, self.continuation != nil else { return }
                guard let cg = image?.studioCGImage, let normalized = BroadcastGraphics.image({ ctx in ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1280, height: 720)) }), let png = NSBitmapImageRep(cgImage: normalized).representation(using: .png, properties: [:]) else { self.finish(.failure(error ?? StudioError.message("The SVG preview could not be created."))); return }
                self.finish(.success(ImportedSVGOverlay(source: self.source, png: png, camera: camera, replacePhotos: self.replacePhotos, removeCanvasFill: self.removeCanvasFill, removedPhotos: result["removed"] as? Int ?? 0)))
            }
        }
    }
    private func finish(_ result: Result<ImportedSVGOverlay, Error>) {
        guard let continuation else { return }; self.continuation = nil
        timeout?.cancel(); webView.stopLoading(); webView.navigationDelegate = nil
        continuation.resume(with: result)
    }
}
enum ImportedSVGGraphics {
    private static let cache: NSCache<NSString, NSImage> = { let value = NSCache<NSString, NSImage>(); value.countLimit = 16; value.totalCostLimit = 64 * 1024 * 1024; return value }()
    static func artwork(_ asset: ImportedSVGOverlay) -> CGImage? {
        let key = asset.id.uuidString as NSString
        if let image = cache.object(forKey: key) { return image.studioCGImage }
        guard let image = NSImage(data: asset.png) else { return nil }
        cache.setObject(image, forKey: key, cost: 1280 * 720 * 4); return image.studioCGImage
    }
    static func settings(_ doc: OverlayDocument, mirror: Bool) -> RenderSettings {
        let camera = doc.cameraWindow ?? doc.importedSVG?.camera ?? SVGCameraWindow(), rect = camera.rect
        let overlay = BroadcastGraphics.image { ctx in
            if let asset = doc.importedSVG, let artwork = artwork(asset) { ctx.setAlpha(min(1, max(0, doc.artworkOpacity ?? 1))); ctx.draw(artwork, in: CGRect(x: 0, y: 0, width: 1280, height: 720)) }
            if doc.cutCameraWindow == true { ctx.setBlendMode(.clear); BroadcastGraphics.rounded(ctx, rect, camera.safeRadius, .clear) }
        }
        let mask = BroadcastGraphics.image { ctx in BroadcastGraphics.rounded(ctx, rect, camera.safeRadius, .white) }
        return RenderSettings(overlay: overlay, mirror: mirror, cameraRect: rect, cameraMask: mask)
    }
}
