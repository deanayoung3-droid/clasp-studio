import SwiftUI
import AppKit

struct VideoDraftsView: View {
    @ObservedObject var studio: StudioModel
    struct Draft: Identifiable { var id: URL; var name: String; var date: Date; var duration: Double; var clips: Int }
    @State private var drafts: [Draft] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("Your drafts").font(.system(size: 24, weight: .semibold)); Text("Continue editing a take or imported recording.").font(.system(size: 12)).foregroundStyle(.secondary) }; Spacer(); Button("Done") { studio.draftsOpen = false } }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(drafts) { draft in
                        Button { studio.openDraft(draft.id) } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "film.stack").font(.system(size: 24)).frame(width: 52, height: 52).background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 7) { Text(draft.name).font(.system(size: 14, weight: .semibold)); Text("\(draft.clips) clips · \(VideoEditorModel.time(draft.duration)) · " + draft.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary) }
                                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }.padding(15).background(Color.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                    if drafts.isEmpty { Text("Record a take or import a video to create your first draft.").font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 80) }
                }
            }
            Text("Drafts save automatically on this Mac. Export creates the finished video.").font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(26).frame(width: 700, height: 560).background(Color(white: 0.035)).foregroundStyle(.white).preferredColorScheme(.dark)
            .onAppear {
                let folders = (try? FileManager.default.contentsOfDirectory(at: EditStorage.drafts, includingPropertiesForKeys: nil)) ?? []
                drafts = folders.compactMap { folder in
                    let file = folder.appendingPathComponent("edit.json")
                    guard let data = try? Data(contentsOf: file), let document = try? JSONDecoder().decode(VideoEditDocument.self, from: data) else { return nil }
                    let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? document.created
                    return Draft(id: folder, name: document.name, date: date, duration: document.duration, clips: document.clips.count)
                }.sorted { $0.date > $1.date }
            }
    }
}
