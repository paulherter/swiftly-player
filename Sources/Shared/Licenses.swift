import Foundation

// **Open-source licenses: the data, not the view.**
//
// `LICENSES/components.json` is read from the bundle, the same file
// `THIRD-PARTY-NOTICES.md` is generated from (`Werkzeuge/licenses-generate.py`).
// Nothing is here that would also have to be there: no second list that can drift
// apart. The license texts sit next to it as `LICENSES/*.txt` and stay as they are
// (English, official wording).
//
// Included in all three Apple targets; each platform has its own views.

struct LicenseComponent: Decodable, Identifiable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case spdx
        case author = "urheber"
        case source = "quelle"
        case platforms = "plattformen"
        case texts = "texte"
        case group = "gruppe"
        case note = "notiz"
    }
    let id: String
    let name: String
    let version: String
    let spdx: String
    let author: String
    let source: String
    let platforms: [String]
    let texts: [String]
    let group: String
    let note: String?

    var sourceURL: URL? { URL(string: source) }
}

struct LicenseSection: Decodable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey {
        case title = "titel"
        case paragraphs = "absaetze"
    }
    let title: String
    let paragraphs: [String]
}

/// Sources and written offer under LGPL-2.1 section 6.
struct LicenseOffering: Decodable, Sendable {
    enum CodingKeys: String, CodingKey {
        case title = "titel"
        case short = "kurz"
        case contact = "kontakt"
        case sections = "abschnitte"
    }
    let title: String
    let short: String
    let contact: String
    let sections: [LicenseSection]
}

struct LicenseState: Decodable, Sendable {
    enum CodingKeys: String, CodingKey {
        case offering = "angebot"
        case components = "bausteine"
    }
    let offering: LicenseOffering
    let components: [LicenseComponent]

    /// Read once. `nil` if the bundle does not carry the file; the view says so instead of showing an empty list.
    static let shared: LicenseState? = load()

    /// What this build is for: that is its name in `platforms`. iPhone and iPad are the same app and carry the same list.
    static var platform: String {
        #if os(macOS)
        "macos"
        #elseif os(tvOS)
        "tvos"
        #else
        "ios"
        #endif
    }

    /// The components of a group that are in this build.
    func components(group: String) -> [LicenseComponent] {
        components.filter { $0.group == group && $0.platforms.contains(Self.platform) }
    }

    func component(id: String) -> LicenseComponent? {
        components.first { $0.id == id }
    }

    /// A paragraph with clickable addresses. The addresses are in the text itself, as in `THIRD-PARTY-NOTICES.md`; here they are only detected, not kept again.
    static func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let reader = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return result
        }
        let section = NSRange(text.startIndex..., in: text)
        for hit in reader.matches(in: text, range: section) {
            guard let url = hit.url, let spot = Range(hit.range, in: text),
                  let target = Range(spot, in: result) else { continue }
            result[target].link = url
        }
        return result
    }

    private static func load() -> LicenseState? {
        guard let data = Data(licenseFile: "components.json") else { return nil }
        return try? JSONDecoder().decode(LicenseState.self, from: data)
    }

    /// The full text of a licence. The file name is in `LicenseComponent.texts`.
    static func text(_ file: String) -> String? {
        guard let data = Data(licenseFile: file) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Paragraphs of a full text. The license texts carry hard line breaks; what
    /// belongs to one paragraph is joined so the lines wrap at any width. Indented lines
    /// (titles, bullets) form their own paragraphs, separate from the non-indented ones.
    static func paragraphs(from text: String) -> [String] {
        var result: [String] = []
        var current: [String] = []
        var indented = false
        func complete() {
            if !current.isEmpty { result.append(current.joined(separator: " ")) }
            current = []
        }
        let rows = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for row in rows {
            let raw = String(row)
            let shortened = raw.trimmingCharacters(in: .whitespaces)
            if shortened.isEmpty { complete(); continue }
            let inset = raw.hasPrefix("   ") || raw.hasPrefix("\t")
            if inset != indented { complete(); indented = inset }
            current.append(shortened)
        }
        complete()
        return result
    }
}

private extension Data {
    /// `LICENSES/<name>` in the bundle. Included as a folder reference, so the structure is preserved.
    init?(licenseFile name: String) {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("LICENSES", isDirectory: true),
              let data = try? Data(contentsOf: folder.appendingPathComponent(name))
        else { return nil }
        self = data
    }
}
