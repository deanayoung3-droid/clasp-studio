import SwiftUI
struct UpdateSettingsView: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var updater: AppUpdater
    @State private var token = ""
    @State private var connect = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("GitHub updates").font(.system(size: 13, weight: .semibold)); Spacer(); Text("Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")").font(.system(size: 10)).foregroundStyle(.secondary) }
            Text(updater.message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Automatically check and download updates", isOn: $updater.automatic).toggleStyle(.checkbox).font(.system(size: 11))
            Text("Downloaded updates install when you quit. Recording and saving always finish first.").font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Button(updater.working ? "Checking…" : "Check for updates") { Task { await updater.check() } }.disabled(updater.working || updater.ready)
                if updater.ready { Button("Install and restart") { guard !model.busy else { return }; updater.restartRequested = true; NSApp.terminate(nil) }.disabled(model.busy).keyboardShortcut(.defaultAction) }
                Spacer()
                Button("GitHub access…") { connect.toggle() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            }.controlSize(.small)
            if connect {
                Text(updater.accountDescription).font(.system(size: 10)).foregroundStyle(.secondary)
                SecureField("GitHub token · repository Contents: read", text: $token).textFieldStyle(.roundedBorder)
                HStack { Button("Save to Keychain") { updater.saveToken(token); token = "" }.disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty); if updater.hasToken { Button("Remove saved access") { updater.removeToken() } }; Link("Create GitHub token", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!) }.font(.system(size: 10)).controlSize(.small)
            }
        }.padding(15).background(Color.white.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
