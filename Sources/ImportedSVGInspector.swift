import SwiftUI

struct ImportedSVGInspector: View {
    @ObservedObject var model: StudioModel
    private var camera: SVGCameraWindow { model.overlay.cameraWindow ?? model.overlay.importedSVG?.cameraForRendering ?? SVGCameraWindow() }
    private func number(_ key: WritableKeyPath<SVGCameraWindow, Double>) -> Binding<Double> {
        Binding(get: { camera[keyPath: key] }, set: { value in var window = camera; window[keyPath: key] = value; model.editOverlay { $0.cameraWindow = window } })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                Label("Original SVG artwork", systemImage: "checkmark.circle").font(.system(size: 12, weight: .medium))
                Text("Colors, gradients, logos and lettering come directly from your file. The SVG is rendered once; the live camera stays native.").foregroundStyle(.secondary).lineSpacing(3)
                if model.importingSVG { ProgressView("Rendering SVG…").controlSize(.small) }
                Button("Replace SVG…") { model.importSVGOverlay(replacing: model.overlay.id) }.disabled(model.importingSVG || model.busy)
                Picker("Artwork framing", selection: Binding(get: { model.overlay.importedSVG?.fit ?? .fit }, set: { model.refreshImportedSVG(fit: $0) })) {
                    ForEach(SVGArtworkFit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).disabled(model.importingSVG || model.busy)
                Text("Fit shows the entire design. Fill crops the edges to cover 16:9. Both preserve the original proportions.").foregroundStyle(.secondary).lineSpacing(3)
                Toggle("Crop video to SVG canvas", isOn: Binding(get: { model.overlay.cropToSVG != false }, set: { value in model.editOverlay { $0.cropToSVG = value } })).toggleStyle(.checkbox)
                Text("The preview and exported video use the SVG’s proportions. Side space is removed; the artwork and camera opening keep their shape.").foregroundStyle(.secondary).lineSpacing(3)
                HStack { Text("Artwork opacity"); Spacer(); Text("\(Int((model.overlay.artworkOpacity ?? 1) * 100))%").monospacedDigit() }
                Slider(value: Binding(get: { model.overlay.artworkOpacity ?? 1 }, set: { value in model.editOverlay { $0.artworkOpacity = value } }), in: 0...1)
                Toggle("Replace large photos with camera", isOn: Binding(get: { model.overlay.importedSVG?.replacePhotos ?? true }, set: { model.refreshImportedSVG(replacePhotos: $0) })).toggleStyle(.checkbox).disabled(model.importingSVG || model.busy)
                Toggle("Remove solid canvas fill", isOn: Binding(get: { model.overlay.importedSVG?.removeCanvasFill ?? true }, set: { model.refreshImportedSVG(removeCanvasFill: $0) })).toggleStyle(.checkbox).disabled(model.importingSVG || model.busy)
                Divider()
                Text("Camera opening").font(.system(size: 12, weight: .medium))
                Text("Transparent areas show the camera. Adjust its position here, or cut a new window into an opaque design.").foregroundStyle(.secondary).lineSpacing(3)
                dimension("Left", \.x, in: 0...max(0, 1 - camera.rect.width / 1280))
                dimension("Top", \.y, in: 0...max(0, 1 - camera.rect.height / 720))
                dimension("Width", \.width, in: 0.05...1)
                dimension("Height", \.height, in: 0.05...1)
                HStack { Text("Corner radius"); Slider(value: number(\.radius), in: 0...40); Text("\(Int(camera.safeRadius))").monospacedDigit() }
                Toggle("Cut opening out of artwork", isOn: Binding(get: { model.overlay.cutCameraWindow == true }, set: { value in model.editOverlay { $0.cutCameraWindow = value } })).toggleStyle(.checkbox)
                Button("Reset camera opening") { model.editOverlay { $0.cameraWindow = nil; $0.cutCameraWindow = false } }
                Button("Full-frame camera") { model.editOverlay { $0.cameraWindow = SVGCameraWindow() } }
                Text("Outlined text stays in the SVG artwork. To change those letters or logos, edit the SVG and choose Replace SVG.").foregroundStyle(.secondary).lineSpacing(3)
            }.font(.system(size: 11)).controlSize(.small).padding(17).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func dimension(_ name: String, _ key: WritableKeyPath<SVGCameraWindow, Double>, in range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(name); Spacer(); Text("\(Int(camera[keyPath: key] * 100))%").monospacedDigit() }
            if range.upperBound - range.lowerBound >= 0.01 { Slider(value: number(key), in: range) }
        }
    }
}
