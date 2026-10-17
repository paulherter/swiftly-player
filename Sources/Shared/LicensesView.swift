import SwiftUI

// **Profile -> Open-source licenses (iPhone and iPad).**
//
// Three pages, all pushed like any other subpage: the list, a component with its
// full text, and source code plus the written offer. The data comes from
// `LicenseState`, one source for all platforms.

struct LicensesRoute: Hashable {}
struct LicenseRoute: Hashable { let id: String }
struct LicenseOfferingRoute: Hashable {}

/// A row of the list. No symbol: there are over fifty, and a symbol saying the same in every row says nothing.
private struct LicenseRow<Destination: Hashable>: View {
    @Environment(\.wide) private var wide
    let title: String
    let under: String
    let target: Destination
    var last = false

    var body: some View {
        NavigationLink(value: target) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title).font(Theme.listTitle)
                            .multilineTextAlignment(.leading)
                        Text(verbatim: under)
                            .font(Theme.small)
                            .foregroundStyle(Theme.fontVeryQuiet)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Theme.font)
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.vertical, 14)
                if !last { SheetLine() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Theme.PressButton())
    }
}

private extension LicenseComponent {
    var subline: String { "\(spdx) · \(version)" }
}

struct LicensesView: View {
    @Environment(\.wide) private var wide
    @Environment(\.dismiss) private var back

    private let inventory = LicenseState.shared

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                SubpageHeader(title: String(localized: "Open-Source-Lizenzen")) { back() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Swiftly Player nutzt VLCKit und libVLC von VideoLAN (LGPL 2.1 oder später). Was sonst noch drinsteckt, steht darunter, mit Lizenz und Urheber.")
                            .growing(15)
                            .lineSpacing(3)
                            .foregroundStyle(Theme.fontQuiet)
                            .padding(.horizontal, Theme.margin(wide: wide))
                            .padding(.bottom, 22)
                        if let inventory {
                            content(inventory)
                        } else {
                            Text("Die Lizenzliste fehlt in dieser Fassung. Du findest sie auf GitHub in THIRD-PARTY-NOTICES.md.")
                                .growing(15)
                                .foregroundStyle(Theme.fontQuiet)
                                .padding(.horizontal, Theme.margin(wide: wide))
                        }
                    }
                    .padding(.bottom, 40)
                    .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
        }
        .tint(Theme.accent)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
    }

    @ViewBuilder
    private func content(_ inventory: LicenseState) -> some View {
        let player = inventory.components(group: "player")
        GroupsTitle(text: "VLCKit und libVLC")
        CardView {
            ForEach(player) { b in
                LicenseRow(title: b.name, under: b.subline, target: LicenseRoute(id: b.id))
            }
            LicenseRow(title: String(localized: "Quelltext und schriftliches Angebot"),
                        under: String(localized: "Woher VLCKit kommt und wie du es ersetzt"),
                        target: LicenseOfferingRoute(), last: true)
        }
        Color.clear.frame(height: 22)
        group("Weitere Bausteine", inventory.components(group: "app"))
        Color.clear.frame(height: 22)
        group("In VLCKit eingebaut", inventory.components(group: "in-vlckit"))
    }

    @ViewBuilder
    private func group(_ title: LocalizedStringKey, _ list: [LicenseComponent]) -> some View {
        if !list.isEmpty {
            GroupsTitle(text: title)
            CardView {
                ForEach(list) { b in
                    LicenseRow(title: b.name, under: b.subline, target: LicenseRoute(id: b.id),
                                last: b.id == list.last?.id)
                }
            }
        }
    }
}

// MARK: One component

struct LicenseView: View {
    @Environment(\.wide) private var wide
    @Environment(\.dismiss) private var back
    @Environment(\.openURL) private var open

    let component: LicenseComponent

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                SubpageHeader(title: component.name) { back() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        CardView {
                            VStack(alignment: .leading, spacing: 14) {
                                detail("Fassung", component.version)
                                detail("Lizenz", component.spdx)
                                detail("Urheber", component.author)
                                if let url = component.sourceURL {
                                    Button { open(url) } label: {
                                        detail("Quelle", component.source, leadsRoute: true)
                                    }
                                    .buttonStyle(Theme.PressButton())
                                }
                                if let note = component.note {
                                    Text(verbatim: note)
                                        .font(Theme.small)
                                        .foregroundStyle(Theme.fontQuiet)
                                }
                            }
                            .padding(.horizontal, Theme.margin(wide: wide))
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(component.texts, id: \.self) { file in
                            Color.clear.frame(height: 22)
                            fullText(file)
                        }
                    }
                    .padding(.bottom, 40)
                    .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
        }
        .tint(Theme.accent)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
    }

    private func detail(_ name: LocalizedStringKey, _ value: String, leadsRoute: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(Theme.small).foregroundStyle(Theme.fontVeryQuiet)
            HStack(spacing: 6) {
                Text(verbatim: value)
                    .font(Theme.body)
                    .foregroundStyle(Theme.font)
                    .multilineTextAlignment(.leading)
                // Shows that the row opens the address; the accent is reserved for state.
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

    /// The wording as it lies in `LICENSES/`: English, not translated.
    @ViewBuilder
    private func fullText(_ file: String) -> some View {
        GroupsTitle(text: "Lizenztext")
        CardView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let text = LicenseState.text(file) {
                    ForEach(Array(LicenseState.paragraphs(from: text).enumerated()), id: \.offset) { _, paragraph in
                        Text(verbatim: paragraph)
                            .growing(12)
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
            .padding(.horizontal, Theme.margin(wide: wide))
            .padding(.vertical, 14)
        }
    }
}

// MARK: Source code and offer

struct LicenseOfferingView: View {
    @Environment(\.wide) private var wide
    @Environment(\.dismiss) private var back

    private let offering = LicenseState.shared?.offering

    var body: some View {
        ZStack(alignment: .top) {
            Theme.reason.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                SubpageHeader(title: String(localized: "Quelltext und Angebot")) { back() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let offering {
                            ForEach(offering.sections, id: \.title) { segment in
                                GroupsTitle(text: LocalizedStringKey(segment.title))
                                CardView {
                                    VStack(alignment: .leading, spacing: 12) {
                                        ForEach(segment.paragraphs, id: \.self) { paragraph in
                                            Text(LicenseState.linked(paragraph))
                                                .growing(13)
                                                .lineSpacing(2)
                                                .foregroundStyle(Theme.fontQuiet)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    .textSelection(.enabled)
                                    .padding(.horizontal, Theme.margin(wide: wide))
                                    .padding(.vertical, 14)
                                }
                                Color.clear.frame(height: 22)
                            }
                        } else {
                            Text("Die Lizenzliste fehlt in dieser Fassung. Du findest sie auf GitHub in THIRD-PARTY-NOTICES.md.")
                                .growing(15)
                                .foregroundStyle(Theme.fontQuiet)
                                .padding(.horizontal, Theme.margin(wide: wide))
                        }
                    }
                    .padding(.bottom, 40)
                    .frame(maxWidth: wide ? Theme.readWidth : .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
        }
        .tint(Theme.accent)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
    }
}
