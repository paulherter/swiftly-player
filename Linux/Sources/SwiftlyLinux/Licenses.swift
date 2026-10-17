import CGtk
import Foundation

/// **Open-source licenses: data and pages.**
///
/// Reads `LICENSES/components.json`, the same file `THIRD-PARTY-NOTICES.md` is
/// generated from; no second list. It sits next to the program under
/// `Resources/Licenses/` (`build.sh` and the package scripts copy it from
/// `LICENSES/`; on Windows `build.ps1`). The full texts sit next to it as
/// `*.txt` and stay as they are.
struct LicenseComponent: Decodable {
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
}

struct LicenseSection: Decodable {
    enum CodingKeys: String, CodingKey {
        case title = "titel"
        case paragraphs = "absaetze"
    }
    let title: String
    let paragraphs: [String]
}

/// Sources and the written offer under LGPL-2.1 §6.
struct LicenseOffering: Decodable {
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

struct LicenseState: Decodable {
    enum CodingKeys: String, CodingKey {
        case offering = "angebot"
        case components = "bausteine"
    }
    let offering: LicenseOffering
    let components: [LicenseComponent]

    /// Read once. `nil` if the file next to the program is missing; the page says
    /// so instead of showing an empty list.
    static let shared: LicenseState? = load()

    /// How this version is named in `platforms`. Linux uses the system's libVLC
    /// and GTK, Windows bundles DLLs; the list separates them by this field, not
    /// by two copies.
    static var platform: String {
        #if os(Windows)
        "windows"
        #else
        "linux"
        #endif
    }

    func components(player: Bool) -> [LicenseComponent] {
        components.filter { ($0.group == "player") == player && $0.platforms.contains(Self.platform) }
    }

    func component(id: String) -> LicenseComponent? {
        components.first { $0.id == id }
    }

    private static func load() -> LicenseState? {
        guard let data = file("components.json").flatMap({ try? Data(contentsOf: URL(fileURLWithPath: $0)) })
        else { return nil }
        return try? JSONDecoder().decode(LicenseState.self, from: data)
    }

    private static func file(_ name: String) -> String? {
        Platform.bundled("Licenses/\(name)")
    }

    /// The full text of a license. The file name is in `LicenseComponent.texts`.
    static func text(_ name: String) -> String? {
        guard let path = file(name), let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Paragraphs of a full text. The license texts contain hard line breaks; lines
    /// belonging to one paragraph are joined so they wrap at any width. Indented
    /// lines form their own paragraphs.
    static func paragraphs(from text: String) -> [String] {
        var result: [String] = []
        var current: [String] = []
        var indented = false
        func complete() {
            if !current.isEmpty { result.append(current.joined(separator: " ")) }
            current = []
        }
        for row in text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
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

    /// The addresses in a paragraph, in order, without trailing punctuation.
    static func addresses(in text: String) -> [String] {
        var hit: [String] = []
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            guard let start = word.range(of: "https://") ?? word.range(of: "http://") else { continue }
            var a = String(word[start.lowerBound...])
            while let z = a.last, ",.;:)(".contains(z) { a.removeLast() }
            if !hit.contains(a) { hit.append(a) }
        }
        return hit
    }
}

extension App {

    private func licenseParagraph(_ text: String, quiet: Bool = true, top: Int32 = 10) -> Widget! {
        let l = label(text, style: "swiftly-koerper")
        if quiet { gtk_widget_add_css_class(l, "dim-label") }
        gtk_label_set_wrap(OpaquePointer(l), 1)
        gtk_label_set_xalign(OpaquePointer(l), 0)
        gtk_label_set_justify(OpaquePointer(l), GTK_JUSTIFY_LEFT)
        gtk_label_set_selectable(OpaquePointer(l), 1)
        gtk_widget_set_margin_top(l, top)
        return l
    }

    private func licenseCategory(_ text: String) -> Widget! {
        let k = category(text)
        gtk_widget_remove_css_class(k, "swiftly-leise")
        gtk_widget_add_css_class(k, "swiftly-gruppenrubrik")
        gtk_widget_set_margin_start(k, 0)
        gtk_widget_set_margin_top(k, 26)
        gtk_widget_set_margin_bottom(k, 10)
        return k
    }

    /// Profile → Open-source licenses.
    func licensesBuild(_ block: Widget!) {
        append(block, subpageHeader(translated("Open-Source-Lizenzen")))
        guard let inventory = LicenseState.shared else {
            append(block, licenseParagraph(translated("Die Lizenzliste fehlt in dieser Fassung. Du findest sie auf GitHub in THIRD-PARTY-NOTICES.md."), top: 14))
            return
        }
        // **At the very top, prominent**, and in the wording the license requires.
        let headerSentence = licenseParagraph(translated("Swiftly Player nutzt libVLC von VideoLAN unter der LGPL 2.1 oder später"),
                                    quiet: false, top: 14)
        gtk_widget_add_css_class(headerSentence, "swiftly-listentitel")
        append(block, headerSentence)

        // Sources: every address from the "Source code" section, as a link.
        let sourceSection = inventory.offering.sections.first { $0.title == "Source code" }
        var addresses: [String] = []
        for paragraph in sourceSection?.paragraphs ?? [] {
            for a in LicenseState.addresses(in: paragraph) where !addresses.contains(a) { addresses.append(a) }
        }
        if !addresses.isEmpty {
            append(block, licenseCategory(translated("Quelltext")))
            let q = rowsGroup()
            for (i, a) in addresses.enumerated() {
                if i > 0 { append(q.space, rowsLine()) }
                append(q.space, valuesRow(symbol: "applications-internet-symbolic", title: a,
                                             arrow: true) {
                    if let url = URL(string: a) { browser(url) }
                })
            }
            append(block, q.outer)
        }

        // The written offer, in the wording of THIRD-PARTY-NOTICES.md.
        append(block, licenseCategory(translated("Quelltext und schriftliches Angebot")))
        for segment in inventory.offering.sections {
            let t = label(segment.title, style: "swiftly-listentitel")
            gtk_label_set_xalign(OpaquePointer(t), 0)
            gtk_widget_set_margin_top(t, 18)
            append(block, t)
            for paragraph in segment.paragraphs { append(block, licenseParagraph(paragraph)) }
        }

        licenseGroup(block, translated("libVLC"), inventory.components(player: true))
        licenseGroup(block, translated("Weitere Bausteine"), inventory.components(player: false))
    }

    private func licenseGroup(_ block: Widget!, _ title: String, _ list: [LicenseComponent]) {
        guard !list.isEmpty else { return }
        append(block, licenseCategory(title))
        let g = rowsGroup()
        for (i, b) in list.enumerated() {
            if i > 0 { append(g.space, rowsLine()) }
            append(g.space, valuesRow(symbol: "text-x-generic-symbolic", title: b.name,
                                         under: "\(b.spdx) · \(b.author)", arrow: true) { [weak self] in
                self?.subpageOpen(.licenseText(b.id))
            })
        }
        append(block, g.outer)
    }

    /// One component: details and the full text, scrollable like any subpage.
    func licenseTextBuild(_ block: Widget!, id: String) {
        guard let b = LicenseState.shared?.component(id: id) else {
            append(block, subpageHeader(translated("Open-Source-Lizenzen")))
            return
        }
        append(block, subpageHeader(b.name))
        let g = rowsGroup()
        gtk_widget_set_margin_top(g.outer, 14)
        let details: [(String, String)] = [(translated("Fassung"), b.version), (translated("Lizenz"), b.spdx),
                                           (translated("Urheber"), b.author), (translated("Quelle"), b.source)]
        for (i, a) in details.enumerated() {
            if i > 0 { append(g.space, rowsLine()) }
            let isSource = i == 3
            append(g.space, valuesRow(symbol: isSource ? "applications-internet-symbolic" : "text-x-generic-symbolic",
                                         title: a.0, under: a.1, arrow: isSource,
                                         pick: isSource ? {
                if let url = URL(string: b.source) { browser(url) }
            } : nil))
        }
        append(block, g.outer)
        if let n = b.note { append(block, licenseParagraph(n, top: 14)) }
        for file in b.texts {
            append(block, paddingHigh(22))
            if let text = LicenseState.text(file) {
                for paragraph in LicenseState.paragraphs(from: text) {
                    append(block, licenseParagraph(paragraph))
                }
            } else {
                append(block, licenseParagraph(translated("Der Lizenztext fehlt in dieser Fassung. Du findest ihn auf GitHub im Ordner LICENSES."), top: 0))
            }
        }
    }
}
