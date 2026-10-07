import Foundation
import AppKit
import Darwin
let args = CommandLine.arguments
if args.count != 7 { exit(2) }
let parent = pid_t(args[1]) ?? 0, target = URL(fileURLWithPath: args[2]), source = URL(fileURLWithPath: args[3]), build = Int(args[4]) ?? 0, restart = args[5] == "1", result = URL(fileURLWithPath: args[6])
let fm = FileManager.default
let stage = target.deletingLastPathComponent().appendingPathComponent(".Clasp-Update-\(UUID().uuidString).app")
let backup = target.deletingLastPathComponent().appendingPathComponent(".Clasp-Previous-\(UUID().uuidString).app")
var movedOld = false
func record(_ success: Bool, _ message: String) { try? JSONSerialization.data(withJSONObject: ["success": success, "build": build, "message": message], options: [.sortedKeys]).write(to: result, options: .atomic) }
func copyUpdate(_ app: URL, to destination: URL) throws {
    // Finder can attach metadata while an app is in Documents. Export the
    // verified bundle without resource forks or extra attributes so the staged
    // copy keeps the same strict signature as the release archive.
    let copy = Process(); copy.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    copy.arguments = ["--norsrc", "--noextattr", app.path, destination.path]
    copy.standardOutput = FileHandle.nullDevice; copy.standardError = FileHandle.nullDevice
    try copy.run(); copy.waitUntilExit()
    guard copy.terminationStatus == 0 else { throw NSError(domain: "ClaspUpdate", code: 5, userInfo: [NSLocalizedDescriptionKey: "The update could not be copied into the app folder."]) }
}
func verify(_ app: URL) throws {
    guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")), info["CFBundleIdentifier"] as? String == "com.clasp.studio", Int(info["CFBundleVersion"] as? String ?? "0") == build else { throw NSError(domain: "ClaspUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "The update app identity does not match."]) }
    // Finder can immediately reattach icon metadata to copied apps in Documents.
    // Clear unsigned icon metadata; never change or re-sign app contents.
    var diagnostic = ""
    for _ in 0..<3 {
        // Allow Finder's icon update after a move to finish before clearing it.
        Thread.sleep(forTimeInterval: 0.15)
        // Inspecting bundle contents can make File Provider refresh the root icon.
        // Strip root metadata last, immediately before signature verification.
        let entries = (fm.enumerator(at: app, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []) + [app]
        for entry in entries {
            for attribute in ["com.apple.FinderInfo", "com.apple.ResourceFork"] {
                _ = entry.path.withCString { path in attribute.withCString { name in removexattr(path, name, XATTR_NOFOLLOW) } }
            }
        }
        let errors = Pipe()
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); p.arguments = ["--verify", "--deep", "--strict", app.path]; p.standardOutput = FileHandle.nullDevice; p.standardError = errors; try p.run(); p.waitUntilExit()
        diagnostic = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus == 0 { return }
    }
    throw NSError(domain: "ClaspUpdate", code: 2, userInfo: [NSLocalizedDescriptionKey: "The copied app signature is invalid. \(diagnostic.trimmingCharacters(in: .whitespacesAndNewlines).prefix(350))"])
}
do {
    guard parent > 1, target.pathExtension == "app", source.pathExtension == "app", target.standardizedFileURL != source.standardizedFileURL else { throw NSError(domain: "ClaspUpdate", code: 3) }
    try verify(source); try copyUpdate(source, to: stage); try verify(stage)
    let deadline = Date().addingTimeInterval(90)
    while kill(parent, 0) == 0 {
        if Date() > deadline { throw NSError(domain: "ClaspUpdate", code: 4, userInfo: [NSLocalizedDescriptionKey: "The running app did not finish quitting."]) }
        Thread.sleep(forTimeInterval: 0.1)
    }
    try fm.moveItem(at: target, to: backup); movedOld = true
    try fm.moveItem(at: stage, to: target); try verify(target)
    try? fm.removeItem(at: backup)
    // Only clean our own extracted download folder, never an arbitrary source.
    let download = source.deletingLastPathComponent().deletingLastPathComponent()
    let updates = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.clasp.studio/updates", isDirectory: true)
    if source.deletingLastPathComponent().lastPathComponent == "extracted", download.deletingLastPathComponent().standardizedFileURL == updates.standardizedFileURL {
        try? fm.removeItem(at: download)
    }
    record(true, "Installed build \(build)")
    if restart {
        NSWorkspace.shared.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration()) { _, _ in exit(0) }
        RunLoop.main.run(until: Date().addingTimeInterval(15))
    }
    exit(0)
} catch {
    if movedOld { try? fm.removeItem(at: target); try? fm.moveItem(at: backup, to: target) }
    try? fm.removeItem(at: stage); record(false, error.localizedDescription); exit(1)
}
