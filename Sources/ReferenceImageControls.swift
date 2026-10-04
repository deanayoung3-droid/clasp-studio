import SwiftUI

struct ReferenceImageSettings: View {
    let image: BroadcastReferenceImage?
    @Binding var presentation: ReferencePresentation?
    let choose: () -> Void
    var busy = false
    private func field<Value>(_ key: WritableKeyPath<ReferencePresentation, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { presentation?[keyPath: key] ?? fallback }, set: { value in guard var copy = presentation else { return }; copy[keyPath: key] = value; presentation = copy })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Text("Reference image").font(.system(size: 13, weight: .semibold)); Spacer(); if image != nil { Toggle("On air", isOn: field(\.visible, fallback: false)).toggleStyle(.switch).controlSize(.mini) } }
            if let image {
                if let cg = ReferenceCardGraphics.image(image) { Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 112).background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 7)) }
                Text(image.name).foregroundStyle(.secondary).lineLimit(1)
                TextField("Caption (optional)", text: field(\.caption, fallback: "")).textFieldStyle(.roundedBorder)
                Picker("Position", selection: field(\.side, fallback: .right)) { ForEach(ReferenceSide.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                HStack { Text("Size"); Slider(value: field(\.width, fallback: 0.36), in: 0.24...0.48); Text("\(Int((presentation?.safeWidth ?? 0.36) * 100))%").monospacedDigit().frame(width: 34) }
                HStack { Button("Replace image…", action: choose); Spacer(); Button("Remove") { presentation = nil }.buttonStyle(.plain).foregroundStyle(.secondary) }
            } else {
                Text("Show a photo, chart or document beside you. The card stays above the lower third and keeps the whole image visible.").foregroundStyle(.secondary).lineSpacing(3)
                Button(action: choose) { Label("Add image…", systemImage: "photo.badge.plus") }
            }
        }.font(.system(size: 11)).controlSize(.small).disabled(busy)
    }
}
struct LiveReferenceControls: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        ReferenceImageSettings(image: model.project.referenceImages?.first(where: { $0.id == model.project.reference?.imageID }), presentation: $model.project.reference, choose: { model.importReferenceImage() }, busy: model.importingReference || model.finishingRecording)
            .padding(18).frame(width: 300)
    }
}
