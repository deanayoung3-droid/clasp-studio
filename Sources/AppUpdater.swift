import AppKit
import CryptoKit
import Security

struct UpdateManifest: Codable {
    var schema = 1
    var repository: String
    var version: String
    var build: Int
    var asset: String
    var size: Int
    var sha256: String
}
enum UpdateVerification {
    static let repository = "deanayoung3-droid/clasp-studio"
    static func verify(_ data: Data, signature: Data, publicKey: Data) throws -> UpdateManifest {
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(signature, for: data) else { throw UpdateError.message("The update signature is invalid.") }
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        guard manifest.schema == 1, manifest.repository == repository, manifest.asset == "Clasp-Studio.zip", manifest.build > 0, manifest.size > 0, manifest.size <= 128 * 1024 * 1024, manifest.sha256.count == 64, manifest.sha256.allSatisfy({ $0.isHexDigit }) else { throw UpdateError.message("The update manifest is invalid.") }
        return manifest
    }
    static func verifyArchive(_ data: Data, manifest: UpdateManifest) throws {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == manifest.size, hash == manifest.sha256 else { throw UpdateError.message("The downloaded update does not match its signed checksum.") }
    }
}
enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
// All command output is bounded in time and consumed off the main UI thread.
enum UpdateCommand {
    final class Output: @unchecked Sendable { var data = Data(); let lock = NSLock(); func set(_ value: Data) { lock.lock(); data = value; lock.unlock() } }
    static func run(_ executable: String, _ arguments: [String], timeout: Double = 60) throws -> Data {
        let process = Process(), out = Pipe(), err = Pipe(), done = DispatchSemaphore(value: 0), readers = DispatchGroup()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment; environment["GH_PROMPT_DISABLED"] = "1"; environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        process.environment = environment; process.standardOutput = out; process.standardError = err
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        let stdout = Output(), stderr = Output()
        readers.enter(); DispatchQueue.global().async { stdout.set(out.fileHandleForReading.readDataToEndOfFile()); readers.leave() }
        readers.enter(); DispatchQueue.global().async { stderr.set(err.fileHandleForReading.readDataToEndOfFile()); readers.leave() }
        if done.wait(timeout: .now() + timeout) == .timedOut { process.terminate(); throw UpdateError.message("The update request timed out. Try again later.") }
        readers.wait()
        guard process.terminationStatus == 0 else { throw UpdateError.message(String(data: stderr.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(250).description ?? "The update command failed.") }
        return stdout.data
    }
}
struct GitHubRelease: Decodable {
    struct Asset: Decodable { let id: Int; let name: String; let size: Int; var browser_download_url: URL? }
    let tag_name: String
    let assets: [Asset]
}
struct GitHubTransport: Sendable {
    let token: String?
    static var cli: String? { ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) } }
    static func publicAssetURL(_ asset: GitHubRelease.Asset) -> URL? {
        guard let url = asset.browser_download_url, url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/" + UpdateVerification.repository + "/releases/download/"), url.lastPathComponent == asset.name else { return nil }
        return url
    }
    private func request(_ url: URL, binary: Bool, authenticated: Bool = false) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 45
        if authenticated, let token, !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.setValue(binary ? "application/octet-stream" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Clasp-Studio", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw UpdateError.message("GitHub updates are unavailable right now. Check your connection or repository access.") }
        return data
    }
    func get(_ path: String, binary: Bool = false) async throws -> Data {
        let url = URL(string: "https://api.github.com/" + path)!
        // Public releases work without a token, GitHub account or CLI. Keep
        // authenticated access as a fallback if the repository becomes private.
        do { return try await request(url, binary: binary) } catch {
            if let token, !token.isEmpty { return try await request(url, binary: binary, authenticated: true) }
            guard let cli = Self.cli else { throw error }
            return try await Task.detached { try UpdateCommand.run(cli, ["api", path, "--header", "Accept:" + (binary ? "application/octet-stream" : "application/vnd.github+json")]) }.value
        }
    }
    func asset(_ asset: GitHubRelease.Asset) async throws -> Data {
        guard asset.size > 0, asset.size <= 128 * 1024 * 1024 else { throw UpdateError.message("The update asset is too large.") }
        if let url = Self.publicAssetURL(asset) { do { return try await request(url, binary: true) } catch { /* Try authenticated API access for private releases. */ } }
        return try await get("repos/" + UpdateVerification.repository + "/releases/assets/\(asset.id)", binary: true)
    }
}
enum UpdateCredentials {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.clasp.studio.github-updates", kSecAttrAccount as String: "github-token"] }
    static func token() -> String? {
        var query = self.query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String) throws {
        let data = Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound { var new = query; new[kSecValueData as String] = data; new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; guard SecItemAdd(new as CFDictionary, nil) == errSecSuccess else { throw UpdateError.message("GitHub access could not be saved to Keychain.") } }
        else if status != errSecSuccess { throw UpdateError.message("GitHub access could not be saved to Keychain.") }
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
}
@MainActor final class AppUpdater: ObservableObject {
    @Published var message = "Signed updates download automatically from GitHub and install when you quit."
    @Published var working = false
    @Published var ready = false
    @Published var automatic = UserDefaults.standard.object(forKey: "automaticGitHubUpdates") as? Bool ?? true { didSet { UserDefaults.standard.set(automatic, forKey: "automaticGitHubUpdates") } }
    @Published var hasToken = false
    var restartRequested = false
    private var started = false
    private var timer: Timer?
    private var prepared: URL?
    private var updateBuild = 0
    private var cache: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.clasp.studio/updates", isDirectory: true) }
    var accountDescription: String { hasToken ? "Private-repository access saved in Keychain" : "Public updates work without a GitHub account. Access is only needed for private releases." }
    init() { hasToken = UpdateCredentials.token() != nil }
    deinit { timer?.invalidate() }
    func start() {
        guard !started else { return }; started = true
        if automatic { Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if self.automatic { await self.check() } } }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in Task { @MainActor in if let self, self.automatic { await self.check() } } }
    }
    func saveToken(_ token: String) { do { try UpdateCredentials.save(token); hasToken = true; message = "GitHub connected. Check for updates when ready." } catch { message = error.localizedDescription } }
    func removeToken() { UpdateCredentials.remove(); hasToken = false; message = "GitHub access removed from Keychain." }
    func check() async {
        guard !working else { return }; working = true; message = "Checking GitHub…"
        defer { working = false }
        do {
            let transport = GitHubTransport(token: UpdateCredentials.token())
            let release = try JSONDecoder().decode(GitHubRelease.self, from: await transport.get("repos/" + UpdateVerification.repository + "/releases/latest"))
            guard let manifestAsset = release.assets.first(where: { $0.name == "update-manifest.json" }), let signatureAsset = release.assets.first(where: { $0.name == "update-manifest.sig" }), let archiveAsset = release.assets.first(where: { $0.name == "Clasp-Studio.zip" }) else { throw UpdateError.message("This GitHub release does not contain a complete app update.") }
            let data = try await transport.asset(manifestAsset), signatureText = try await transport.asset(signatureAsset)
            guard let signature = Data(base64Encoded: signatureText, options: .ignoreUnknownCharacters), let keyURL = Bundle.main.url(forResource: "UpdatePublicKey", withExtension: "txt"), let key = Data(base64Encoded: try Data(contentsOf: keyURL), options: .ignoreUnknownCharacters) else { throw UpdateError.message("The update signing key is unavailable.") }
            let manifest = try UpdateVerification.verify(data, signature: signature, publicKey: key)
            let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
            guard manifest.build > build else { message = "You're up to date · build \(build)"; return }
            if ready, manifest.build <= updateBuild { message = "Update ready · installs when you quit, or restart now."; return }
            guard archiveAsset.size == manifest.size else { throw UpdateError.message("The release archive size does not match its signed manifest.") }
            if try Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly == true { message = "Update available. Install Clasp Studio in Applications first."; return }
            message = "Downloading Clasp Studio \(manifest.version)…"
            let archive = try await transport.asset(archiveAsset)
            try UpdateVerification.verifyArchive(archive, manifest: manifest)
            let folder = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let zip = folder.appendingPathComponent("update.zip"); try archive.write(to: zip, options: .atomic)
            let output = folder.appendingPathComponent("extracted", isDirectory: true)
            let app = output.appendingPathComponent("Clasp Studio.app")
            try await Task.detached {
                _ = try UpdateCommand.run("/usr/bin/ditto", ["-x", "-k", "--norsrc", "--noextattr", zip.path, output.path])
                _ = try UpdateCommand.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
                guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "com.clasp.studio", Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") == manifest.build else { throw UpdateError.message("The app inside this update does not match the signed release.") }
            }.value
            let previous = prepared
            prepared = app; updateBuild = manifest.build; ready = true
            if let previous { try? FileManager.default.removeItem(at: previous.deletingLastPathComponent().deletingLastPathComponent()) }
            message = "Update ready · installs when you quit, or restart now."
        } catch { message = error.localizedDescription.contains("404") ? "Waiting for the first GitHub release." : error.localizedDescription }
    }
    func installOnQuit() throws {
        guard ready, let prepared else { return }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "ClaspUpdateInstaller") else { throw UpdateError.message("The update installer is missing.") }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let executable = cache.appendingPathComponent("installer-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: helper, to: executable); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let process = Process(); process.executableURL = executable
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path, prepared.path, String(updateBuild), restartRequested ? "1" : "0", cache.appendingPathComponent("last-install.json").path]
        try process.run()
    }
}
