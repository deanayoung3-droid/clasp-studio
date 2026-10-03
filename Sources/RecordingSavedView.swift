import SwiftUI

struct RecordingSavedView: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 38, weight: .light)).foregroundStyle(.white).padding(.top, 4)
            VStack(spacing: 9) {
                Text("Recording saved").font(.system(size: 26, weight: .semibold)).tracking(-0.7)
                Text("Your take is ready.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            VStack(spacing: 7) {
                Text(model.lastRecording?.lastPathComponent ?? "Your recording").font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Text(model.lastRecording?.deletingLastPathComponent().path ?? "").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.padding(16).frame(maxWidth: .infinity).background(Color.white.opacity(0.055)).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 12) {
                Button("Done") { model.recordingSavedOpen = false }.keyboardShortcut(.cancelAction).buttonStyle(StudioButton()).frame(maxWidth: .infinity)
                Button { model.revealLastRecording(); model.recordingSavedOpen = false } label: { Label("Show in Finder", systemImage: "folder").frame(maxWidth: .infinity) }.keyboardShortcut(.defaultAction).buttonStyle(StudioButton(primary: true))
            }.padding(.top, 4)
        }.padding(30).frame(width: 520).background(Color(white: 0.045)).foregroundStyle(.white).preferredColorScheme(.dark)
    }
}
