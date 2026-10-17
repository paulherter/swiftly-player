import SwiftUI

// **Profile > Open-Source Licenses (Mac).**
//
// Same data as on iPhone and TV (`LicenseState`), laid out the Mac way: pages on
// the navigator's stack, cards with rows, selectable text. The license text stays
// in English, as it lies in `LICENSES/`.

private extension LicenseComponent {
    var subline: String { "\(spdx) · \(version)" }
}

/// The frame of each of these pages: header with arrow, cards at form width.
private struct LicensePage<ContentBody: View>: View {
    let title: LocalizedStringKey
    let back: () -> Void
    @ViewBuilder let content: ContentBody

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SubpageHeader(title: title, back: back)
                content
            }
            .frame(maxWidth: Theme.settingWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .pagesScroll()
    }
}

private struct Missing: View {
    var body: some View {
        Text("Die Lizenzliste fehlt in dieser Fassung. Du findest sie auf GitHub in THIRD-PARTY-NOTICES.md.")
            .font(Theme.body)
            .foregroundStyle(Theme.fontQuiet)
    }
}

// MARK: List

struct LicensesView: View {
    let back: () -> Void

    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section

    private let inventory = LicenseState.shared

    var body: some View {
        LicensePage(title: "Open-Source-Lizenzen", back: back) {
            Text("Swiftly Player nutzt VLCKit und libVLC von VideoLAN (LGPL 2.1 oder später). Was sonst noch drinsteckt, steht darunter, mit Lizenz und Urheber.")
                .font(Theme.body)
                .lineSpacing(3)
                .foregroundStyle(Theme.fontQuiet)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            if let inventory {
                SettingGroup(title: "VLCKit und libVLC") {
                    ForEach(inventory.components(group: "player")) { b in
                        row(b)
                        SheetLine().padding(.leading, Theme.separatorInsetCard)
                    }
                    ValuesRow(symbol: "doc.text",
                               title: Text("Quelltext und schriftliches Angebot"),
                               under: Text("Woher VLCKit kommt und wie du es ersetzt"),
                               arrow: true) { navigator.openIt(.licenseOffering, in: section) }
                }
                group("Weitere Bausteine", inventory.components(group: "app"))
                group("In VLCKit eingebaut", inventory.components(group: "in-vlckit"))
            } else {
                Missing()
            }
        }
    }

    @ViewBuilder
    private func group(_ title: LocalizedStringKey, _ list: [LicenseComponent]) -> some View {
        if !list.isEmpty {
            SettingGroup(title: title) {
                ForEach(Array(list.enumerated()), id: \.element.id) { spot, b in
                    if spot > 0 { SheetLine().padding(.leading, Theme.separatorInsetCard) }
                    row(b)
                }
            }
        }
    }

    private func row(_ b: LicenseComponent) -> some View {
        ValuesRow(symbol: "doc.text", title: Text(verbatim: b.name),
                   under: Text(verbatim: b.subline), arrow: true) {
            navigator.openIt(.license(b.id), in: section)
        }
    }
}

// MARK: A building block

struct LicenseView: View {
    let component: LicenseComponent
    let back: () -> Void

    @Environment(\.openURL) private var open

    var body: some View {
        LicensePage(title: LocalizedStringKey(component.name), back: back) {
            RowsGroup {
                VStack(alignment: .leading, spacing: 14) {
                    detail("Fassung", component.version)
                    detail("Lizenz", component.spdx)
                    detail("Urheber", component.author)
                    if let url = component.sourceURL {
                        Button { open(url) } label: {
                            detail("Quelle", component.source, leadsRoute: true)
                        }
                        .buttonStyle(Theme.PressRow())
                    }
                    if let note = component.note {
                        Text(verbatim: note)
                            .font(Theme.small)
                            .foregroundStyle(Theme.fontQuiet)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, Theme.edgeSpacing)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 8)
            ForEach(component.texts, id: \.self) { file in
                SettingGroup(title: "Lizenztext") { fullText(file) }
            }
        }
    }

    private func detail(_ name: LocalizedStringKey, _ value: String, leadsRoute: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(Theme.small).foregroundStyle(Theme.fontVeryQuiet)
            HStack(spacing: 6) {
                Text(verbatim: value)
                    .font(Theme.body)
                    .foregroundStyle(Theme.font)
                    .multilineTextAlignment(.leading)
                // Shows that the row opens the address; the accent stays reserved for state.
                if leadsRoute {
                    Image(systemName: "arrow.up.right")
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func fullText(_ file: String) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            if let text = LicenseState.text(file) {
                ForEach(Array(LicenseState.paragraphs(from: text).enumerated()), id: \.offset) { _, paragraph in
                    Text(verbatim: paragraph)
                        .font(Theme.small)
                        .foregroundStyle(Theme.fontQuiet)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Der Text fehlt in dieser Fassung.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontQuiet)
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, Theme.edgeSpacing)
        .padding(.vertical, 14)
    }
}

// MARK: Source code and offer

struct LicenseOfferingView: View {
    let back: () -> Void

    private let offering = LicenseState.shared?.offering

    var body: some View {
        LicensePage(title: "Quelltext und Angebot", back: back) {
            if let offering {
                ForEach(offering.sections, id: \.title) { segment in
                    SettingGroup(title: LocalizedStringKey(segment.title)) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(segment.paragraphs, id: \.self) { paragraph in
                                Text(LicenseState.linked(paragraph))
                                    .font(Theme.small)
                                    .lineSpacing(2)
                                    .foregroundStyle(Theme.fontQuiet)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.horizontal, Theme.edgeSpacing)
                        .padding(.vertical, 14)
                    }
                }
            } else {
                Missing()
            }
        }
    }
}
