import Foundation
import AppKit
import PDFKit

struct ScriptSection: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var body: String
    var words: [String] { body.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
    func duration(wpm: Double) -> Double { max(5, Double(words.count) / max(60, wpm) * 60) }
}
struct BrandLogo: Identifiable, Codable {
    var id = UUID()
    var name: String
    var data: Data
    var enabled = true
}
enum Backdrop: String, Codable, CaseIterable { case original = "Camera", blur = "Soft blur", studio = "Studio", custom = "Image" }
struct StudioProject: Codable {
    var showTitle = "THIS WEEK IN LAW"
    var presenter = "PAYTON YOUNG"
    var handle = "@Payt0nY"
    var category = "PERSONAL INJURY"
    var sponsor = "Clasp Legal"
    var sponsorNames: [String]? = ["Filevine", "Dropbox"]
    var overlayTimeZone: String? = "America/Los_Angeles"
    var graphics = true
    var mirror = true
    var showDate = true
    var background = Backdrop.original
    var backgroundData: Data? = nil
    var primaryLogoData: Data? = nil
    var edgeFeather: Double? = 0.8
    var edgeCleanup: Double? = 0.35
    var logos: [BrandLogo] = []
    var scriptName: String? = nil
    var recordingFolder: String? = nil
    var voiceFollowing: Bool? = true
    var broadcastHeadline: String? = "THIS WEEK IN LAW - FRIDAY, OCT 2ND"
    var useTemplateSponsors: Bool? = true
    var sponsorItems: [SponsorItem]?
    var carouselMoving: Bool? = true
    var carouselSpeed: Double? = 32
    var overlayLibrary: [OverlayDocument]?
    var selectedOverlayID: UUID?
    var overlayLibraryRevision: Int?
    var wordsPerMinute = 135.0
    var sections = ScriptParser.parse("""
    # Intro
    Welcome to This Week in Law. I'm Payton Young, and today we're covering the biggest updates in personal injury law. Let's get into it.

    # California Supreme Court ruling
    The California Supreme Court issued a new ruling this week that could significantly impact how damages are calculated in personal injury cases. Here is what you need to know.

    # Insurance minimums
    We're also seeing important changes to insurance minimums that will take effect in January. These changes could affect both policyholders and the claims process.

    # Appellate court guidance
    A new appellate decision provides guidance on premises liability. Let's walk through what this means for practitioners and their clients.

    # Key takeaways
    Those are the stories to watch this week. Thank you for joining me. I'll see you next time on This Week in Law.
    """)
}
enum ScriptParser {
    static func parse(_ text: String) -> [ScriptSection] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var result: [ScriptSection] = []
        var title = "Introduction"
        var lines: [String] = []
        func flush() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { result.append(ScriptSection(title: title, body: body)) }
            lines = []
        }
        let hasHeadings = normalized.split(separator: "\n").contains { $0.hasPrefix("# ") || $0.hasPrefix("## ") }
        if hasHeadings {
            for line in normalized.components(separatedBy: "\n") {
                if line.hasPrefix("# ") || line.hasPrefix("## ") {
                    flush(); title = line.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
                    if title.isEmpty { title = "Section \(result.count + 1)" }
                } else { lines.append(line) }
            }
            flush()
        } else {
            for paragraph in normalized.components(separatedBy: "\n\n") {
                let body = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                let first = body.components(separatedBy: "\n")
                let explicitTitle = first.count > 1 && first[0].count < 80
                result.append(ScriptSection(title: explicitTitle ? first[0] : "Section \(result.count + 1)", body: explicitTitle ? first.dropFirst().joined(separator: "\n") : body))
            }
        }
        return result
    }
    static func load(_ url: URL) throws -> String {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url), let text = doc.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError.message("This PDF has no readable text. Export it as text or use a PDF with selectable text.") }
            return text
        }
        if ["rtf", "docx"].contains(url.pathExtension.lowercased()) {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw StudioError.message("Save the script as UTF-8 text, Markdown, RTF, DOCX, or PDF.") }
        return text
    }
    static func markdown(_ sections: [ScriptSection]) -> String { sections.map { "# \($0.title)\n\($0.body)" }.joined(separator: "\n\n") }
}
enum StudioError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
extension NSImage {
    var studioCGImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
    var studioPNG: Data? {
        guard let cg = studioCGImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
