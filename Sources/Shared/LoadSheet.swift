import JellyfinKit
import SwiftUI

/// The confirmation before every download.
///
/// In other apps you tap download and something just happens: 300 MB, done in
/// two minutes. Here it can be 18.6 GB, because we never transcode and so load
/// the original file. Three numbers and a button are the minimum at that size,
/// and the sentence below explains the number instead of apologizing for it:
/// **it is the benefit the app exists for**, not a defect.
///
/// Three cases; which one applies is not decided by the view:
/// `DownloadRules.slot` and `.mayLoad` say so, and both are verified in the
/// package.
struct LoadSheet: View {
    @Binding var opened: Bool
    let model: AppModel
    /// What is to be downloaded. Several for a season.
    let entries: [DownloadItem]
    /// For the title: “Dune: Part Two” or “Season 2”.
    let title: String
    /// ID to image URL. Travels to disk too, otherwise the list on a plane has no
    /// images. For a series both belong in: the series poster and each episode's
    /// landscape image.
    var images: [String: URL] = [:]
    /// What to show afterwards, such as a message.
    var afterThat: () -> Void = {}
    /// If the download fails right after starting, for the notice strip of the
    /// page below.
    var failed: (String) -> Void = { _ in }
    /// **Quality is chosen here** for a movie, which has no selection before. A
    /// series comes from `Ladeauswahl` and brings its choice along; then it is only
    /// displayed here.
    var qualitySelect = false

    @State private var choice: DownloadQuality = .original

    private var management: DownloadManager { model.downloads }
    /// The items in the chosen quality, with estimated size once converting.
    private var version: [DownloadItem] {
        qualitySelect ? entries.map { $0.inQuality(choice) } : entries
    }
    private var bytes: Int64 { version.reduce(0) { $0 + $1.bytes } }
    private var converted: Bool { version.contains(where: \.converted) }
    private var offered: [DownloadQuality] {
        DownloadQuality.offered(
            selectable: model.downloadQualitySelectable,
            sourceBitrateOf: DownloadQuality.sourceBitrateOf(entries.map { ($0.bytes, $0.runtimeTicks) }))
    }
    /// Size as text, with "≈" when estimated.
    private var sizesText: String {
        (converted ? "≈ " : "") + DownloadRules.size(bytes)
    }
    private var inquiry: DownloadRules.SpaceInfo { management.inquiry(for: bytes) }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(opened: $opened) {
                if !inquiry.suffices {
                    spaceTight
                } else if !DownloadRules.mayLoad(wLAN: management.wLAN,
                                                   onlyOverWLAN: management.onlyOverWLAN) {
                    withoutWLAN
                } else {
                    normalCase
                }
            }
    }

    // MARK: The three layers

    private var normalCase: some View {
        VStack(spacing: 0) {
            SheetCategory(text: Text(verbatim: String(localized: "\(title) laden")))
            detail("internaldrive", "Größe", sizesText)
            if qualitySelect, model.downloadQualitySelectable, offered.count > 1 {
                qualityRow
            } else if let g = guete {
                detail("sparkles", "Qualität", g)
            }
            detail("externaldrive", "Danach frei", DownloadRules.size(inquiry.freeAfter))
            button("Laden", filled: true) { start() }
            // **Explains the number instead of apologizing.**
            if converted {
                hint("Der Server wandelt die Datei beim Laden um. Die Größe ist geschätzt, Untertitel kommen als eigene Dateien mit.")
            } else {
                hint("Swiftly lädt die Originaldatei, in derselben Qualität wie beim Streamen.")
            }
        }
    }

    private var withoutWLAN: some View {
        VStack(spacing: 0) {
            SheetCategory(text: Text(verbatim: String(localized: "\(title) laden")))
            detail("internaldrive", "Größe", sizesText)
            detail("wifi.slash", "Kein WLAN", String(localized: "Mobilfunk"), cautionary: true)
            // The upper button is the friendly answer and so sits on top and filled. The
            // lower one is possible, but you have to read it.
            button("In die Warteschlange", filled: true) { start() }
            button("Jetzt über Mobilfunk laden", filled: false) {
                model.onlyOverWLAN = false
                start()
            }
            hint("Der Download startet von selbst, sobald WLAN da ist.")
        }
    }

    private var spaceTight: some View {
        VStack(spacing: 0) {
            SheetCategory(text: Text("Nicht genug Platz"))
            detail("internaldrive", "Diese Datei", sizesText)
            // **The obvious way out is a smaller version.** For a movie the choice
            // therefore appears here too; if it then fits, the sheet switches to the normal
            // case by itself.
            if qualitySelect, model.downloadQualitySelectable, offered.count > 1 {
                qualityRow
            }
            detail("externaldrive", "Frei auf dem Gerät",
                   DownloadRules.size(management.free), cautionary: true)

            // **A way out instead of an error message.** The app knows what has been
            // watched and is therefore expendable, and calculates that it is enough. The expendable-titles rule: it
            // still deletes nothing on its own.
            if inquiry.sufficesToCleanUp, !inquiry.dispensable.isEmpty {
                detail("checkmark.circle", "Gesehene Titel",
                       DownloadRules.size(inquiry.dispensableBytes))
                button("Gesehene entfernen und laden", filled: true) {
                    management.remove(inquiry.dispensable.map(\.id))
                    start()
                }
                button("Abbrechen", filled: false) { opened = false }
            } else {
                hint("Auch nach dem Entfernen der gesehenen Titel reicht der Platz nicht. In den Einstellungen unter Offline steht, was belegt ist.")
                button("Verstanden", filled: false) { opened = false }
            }
        }
    }

    // MARK: Building blocks

    private func detail(_ symbol: String, _ was: LocalizedStringKey,
                        _ value: String, cautionary: Bool = false) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(cautionary ? Theme.warning : Theme.fontQuiet)
                .frame(width: 20)
            Text(was)
                // **Scales, not fixed**. The value on the right stays
                // fixed: it runs tabular and shares a column with the other rows.
                .growing(15)
                .foregroundStyle(cautionary ? Theme.warning : Theme.font)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .font(.system(size: 15))
                .monospacedDigit()
                .foregroundStyle(Theme.font)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, Theme.edgeSpacing)
        // **52 like every row in a sheet.** It was the only one with no measure at
        // all and relied on its padding alone: a good 44 points, eight flatter than the
        // rows in the neighboring sheet. `minHeight`, so it can grow with a larger
        // system font.
        .frame(minHeight: 52)
        .overlay(alignment: .top) {
            // Sheet, so continuous; see `SheetLine`.
            SheetLine()
        }
    }

    /// **Quality as a row with the choice on the right**, the same pill as in the
    /// download selection, so movie and series have the same place.
    private var qualityRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 17))
                .foregroundStyle(Theme.fontQuiet)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text("Qualität")
                .growing(15)
                .foregroundStyle(Theme.font)
            Spacer(minLength: 12)
            QualityBadge(choice: $choice, offered: offered, selectable: true,
                               size: { q in entries.reduce(0) {
                                   $0 + q.estimatedBytes(original: $1.bytes,
                                                           runtimeTicks: $1.runtimeTicks) } })
        }
        .padding(.vertical, 4)
        .padding(.horizontal, Theme.edgeSpacing)
        .frame(minHeight: 52)
        .overlay(alignment: .top) { SheetLine() }
    }

    private func button(_ text: LocalizedStringKey, filled: Bool,
                       perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Text(text) }
            .buttonStyle(filled ? AnyButtonStyle(PrimaryButtonStyle(stretches: true))
                                  : AnyButtonStyle(SecondaryButtonStyle(stretches: true)))
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, 14)
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .growing(13)
            .foregroundStyle(Theme.fontQuiet)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, 10)
    }

    /// What the quality row consists of: the details that justify the price. If
    /// they are missing, the row is omitted instead of saying "unknown".
    private var guete: String? {
        var parts: [String] = []
        // If the series arrives converted from the selection, the level comes first.
        if let q = version.first?.guete, !q.isOriginal { parts.append(q.name + " · " + q.addition()) }
        if let c = version.first?.container { parts.append(c.uppercased()) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func start() {
        opened = false
        // Only what newly joins: an already failed item with the same ID would
        // otherwise count as "failed" immediately.
        let new = version.map(\.id).filter { id in !management.entries.contains { $0.id == id } }
        management.trigger(version, images: images)
        afterThat()
        let lager = management, report = failed
        Task {
            if let reason = await lager.immediateFailed(new) { report(reason) }
        }
    }
}

/// Two button styles in one expression; without it the `if` in `buttonStyle`
/// becomes a type error.
struct AnyButtonStyle: ButtonStyle {
    private let construct: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        construct = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { construct(configuration) }
}
