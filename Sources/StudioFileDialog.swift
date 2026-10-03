import AppKit
import UniformTypeIdentifiers

@MainActor enum StudioFileDialog {
    private static var parent: NSWindow? {
        if let studio = NSApp.windows.first(where: { $0.title == "Clasp Studio" }) { return studio.attachedSheet ?? studio }
        return NSApp.keyWindow ?? NSApp.mainWindow
    }
    static func svg(completion: @escaping (URL) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.svg]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.prompt = "Import overlay"
        panel.message = "Choose an SVG. Its artwork and gradients become a reusable overlay."
        let finish: (NSApplication.ModalResponse) -> Void = { response in if response == .OK, let url = panel.url { completion(url) } }
        if let window = parent { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
    static func media(image: Bool = false, multiple: Bool, message: String, completion: @escaping ([URL]) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = image ? [.image, .png, .jpeg, .heic, .tiff] : [.quickTimeMovie, .mpeg4Movie, .movie, .video]
        // Some file providers return dynamic content types. Decode and validate
        // selected media ourselves instead of disabling otherwise valid files.
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple; panel.resolvesAliases = true
        panel.message = message; panel.prompt = "Import"
        let finish: (NSApplication.ModalResponse) -> Void = { response in if response == .OK { completion(panel.urls) } }
        if let window = parent { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
    static func export(name: String, folder: URL, completion: @escaping (URL) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = folder; panel.nameFieldStringValue = name + ".mp4"
        panel.message = "Export your edited broadcast"; panel.prompt = "Export"
        let finish: (NSApplication.ModalResponse) -> Void = { response in if response == .OK, let url = panel.url { completion(url) } }
        if let window = parent { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
}
