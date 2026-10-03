import Foundation
import CryptoKit
let args = CommandLine.arguments
func fail(_ text: String) -> Never { fputs(text + "\n", stderr); exit(1) }
if args.count == 4, args[1] == "generate" {
    let key = Curve25519.Signing.PrivateKey()
    let privateURL = URL(fileURLWithPath: args[2]), publicURL = URL(fileURLWithPath: args[3])
    guard !FileManager.default.fileExists(atPath: privateURL.path) else { fail("Refusing to replace an existing update signing key.") }
    try (key.rawRepresentation.base64EncodedString() + "\n").write(to: privateURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateURL.path)
    try (key.publicKey.rawRepresentation.base64EncodedString() + "\n").write(to: publicURL, atomically: true, encoding: .utf8)
    print("Created update signing key; only its public key belongs in the app.")
} else if args.count == 5, args[1] == "sign" {
    guard let raw = ProcessInfo.processInfo.environment["CLASP_UPDATE_SIGNING_KEY"], let data = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("CLASP_UPDATE_SIGNING_KEY is required.") }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    let archive = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let info = NSDictionary(contentsOfFile: args[3])!
    let manifest: [String: Any] = ["schema": 1, "repository": "deanayoung3-droid/clasp-studio", "version": info["CFBundleShortVersionString"]!, "build": Int(info["CFBundleVersion"] as! String)!, "asset": "Clasp-Studio.zip", "size": archive.count, "sha256": SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()]
    let body = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
    let folder = URL(fileURLWithPath: args[4]); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try body.write(to: folder.appendingPathComponent("update-manifest.json"))
    try (key.signature(for: body).base64EncodedString() + "\n").write(to: folder.appendingPathComponent("update-manifest.sig"), atomically: true, encoding: .utf8)
    print("Signed update manifest for build \(manifest["build"]!)")
} else { fail("Usage: generate PRIVATE_FILE PUBLIC_FILE | sign ZIP INFO_PLIST OUTPUT_FOLDER") }
