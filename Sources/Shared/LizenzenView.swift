import SwiftUI

// **Profil → Open-Source-Lizenzen (iPhone und iPad).**
//
// Drei Seiten, alle geschoben wie jede andere Unterseite: die Liste, ein
// Baustein mit Volltext, und Quelltext samt schriftlichem Angebot. Die Daten
// kommen aus `Lizenzbestand` — eine Quelle für alle Plattformen.

struct LizenzenRoute: Hashable {}
struct LizenzRoute: Hashable { let id: String }
struct LizenzangebotRoute: Hashable {}

/// Eine Zeile der Liste. Ohne Zeichen: es sind über fünfzig, und ein
/// Zeichen, das dasselbe in jeder Zeile sagt, sagt nichts.
private struct Lizenzzeile<Ziel: Hashable>: View {
    @Environment(\.breit) private var breit
    let titel: String
    let unter: String
    let ziel: Ziel
    var letzte = false

    var body: some View {
        NavigationLink(value: ziel) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: titel).font(Stil.listentitel)
                            .multilineTextAlignment(.leading)
                        Text(verbatim: unter)
                            .font(Stil.klein)
                            .foregroundStyle(Stil.schriftSehrLeise)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Stil.schriftSehrLeise)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Stil.schrift)
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.vertical, 14)
                if !letzte { Blattlinie() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
    }
}

private extension Lizenzbaustein {
    var unterzeile: String { "\(spdx) · \(version)" }
}

struct LizenzenView: View {
    @Environment(\.breit) private var breit
    @Environment(\.dismiss) private var zurueck

    private let bestand = Lizenzbestand.geteilt

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Unterseitenkopf(titel: String(localized: "Open-Source-Lizenzen")) { zurueck() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Swiftly Player nutzt VLCKit und libVLC von VideoLAN (LGPL 2.1 oder später). Was sonst noch drinsteckt, steht darunter, mit Lizenz und Urheber.")
                            .mitwachsend(15)
                            .lineSpacing(3)
                            .foregroundStyle(Stil.schriftLeise)
                            .padding(.horizontal, Stil.rand(breit: breit))
                            .padding(.bottom, 22)
                        if let bestand {
                            inhalt(bestand)
                        } else {
                            Text("Die Lizenzliste fehlt in dieser Fassung. Du findest sie auf GitHub in THIRD-PARTY-NOTICES.md.")
                                .mitwachsend(15)
                                .foregroundStyle(Stil.schriftLeise)
                                .padding(.horizontal, Stil.rand(breit: breit))
                        }
                    }
                    .padding(.bottom, 40)
                    .frame(maxWidth: breit ? Stil.lesebreite : .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
        }
        .tint(Stil.akzent)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
    }

    @ViewBuilder
    private func inhalt(_ bestand: Lizenzbestand) -> some View {
        let player = bestand.bausteine(gruppe: "player")
        Gruppentitel(text: "VLCKit und libVLC")
        Karte {
            ForEach(player) { b in
                Lizenzzeile(titel: b.name, unter: b.unterzeile, ziel: LizenzRoute(id: b.id))
            }
            Lizenzzeile(titel: String(localized: "Quelltext und schriftliches Angebot"),
                        unter: String(localized: "Woher VLCKit kommt und wie du es ersetzt"),
                        ziel: LizenzangebotRoute(), letzte: true)
        }
        Color.clear.frame(height: 22)
        gruppe("Weitere Bausteine", bestand.bausteine(gruppe: "app"))
        Color.clear.frame(height: 22)
        gruppe("In VLCKit eingebaut", bestand.bausteine(gruppe: "in-vlckit"))
    }

    @ViewBuilder
    private func gruppe(_ titel: LocalizedStringKey, _ liste: [Lizenzbaustein]) -> some View {
        if !liste.isEmpty {
            Gruppentitel(text: titel)
            Karte {
                ForEach(liste) { b in
                    Lizenzzeile(titel: b.name, unter: b.unterzeile, ziel: LizenzRoute(id: b.id),
                                letzte: b.id == liste.last?.id)
                }
            }
        }
    }
}

// MARK: Ein Baustein

struct LizenzView: View {
    @Environment(\.breit) private var breit
    @Environment(\.dismiss) private var zurueck
    @Environment(\.openURL) private var oeffnen

    let baustein: Lizenzbaustein

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Unterseitenkopf(titel: baustein.name) { zurueck() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Karte {
                            VStack(alignment: .leading, spacing: 14) {
                                angabe("Fassung", baustein.version)
                                angabe("Lizenz", baustein.spdx)
                                angabe("Urheber", baustein.urheber)
                                if let url = baustein.quelleURL {
                                    Button { oeffnen(url) } label: {
                                        angabe("Quelle", baustein.quelle, fuehrtWeg: true)
                                    }
                                    .buttonStyle(Stil.Druckknopf())
                                }
                                if let notiz = baustein.notiz {
                                    Text(verbatim: notiz)
                                        .font(Stil.klein)
                                        .foregroundStyle(Stil.schriftLeise)
                                }
                            }
                            .padding(.horizontal, Stil.rand(breit: breit))
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(baustein.texte, id: \.self) { datei in
                            Color.clear.frame(height: 22)
                            volltext(datei)
                        }
                    }
                    .padding(.bottom, 40)
                    .frame(maxWidth: breit ? Stil.lesebreite : .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
        }
        .tint(Stil.akzent)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
    }

    private func angabe(_ name: LocalizedStringKey, _ wert: String, fuehrtWeg: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(Stil.klein).foregroundStyle(Stil.schriftSehrLeise)
            HStack(spacing: 6) {
                Text(verbatim: wert)
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schrift)
                    .multilineTextAlignment(.leading)
                // Zeigt, dass die Zeile die Adresse öffnet; der Akzent bleibt
                // dem Zustand vorbehalten.
                if fuehrtWeg {
                    Image(systemName: "arrow.up.right")
                        .font(Stil.klein)
                        .foregroundStyle(Stil.schriftSehrLeise)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Der Wortlaut, wie er in `LICENSES/` liegt — englisch, nicht übersetzt.
    @ViewBuilder
    private func volltext(_ datei: String) -> some View {
        Gruppentitel(text: "Lizenztext")
        Karte {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let text = Lizenzbestand.text(datei) {
                    ForEach(Array(Lizenzbestand.absaetze(von: text).enumerated()), id: \.offset) { _, absatz in
                        Text(verbatim: absatz)
                            .mitwachsend(12)
                            .foregroundStyle(Stil.schriftLeise)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("Der Text fehlt in dieser Fassung.")
                        .font(Stil.klein)
                        .foregroundStyle(Stil.schriftLeise)
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.vertical, 14)
        }
    }
}

// MARK: Quelltext und Angebot

struct LizenzangebotView: View {
    @Environment(\.breit) private var breit
    @Environment(\.dismiss) private var zurueck

    private let angebot = Lizenzbestand.geteilt?.angebot

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Unterseitenkopf(titel: String(localized: "Quelltext und Angebot")) { zurueck() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let angebot {
                            ForEach(angebot.abschnitte, id: \.titel) { abschnitt in
                                Gruppentitel(text: LocalizedStringKey(abschnitt.titel))
                                Karte {
                                    VStack(alignment: .leading, spacing: 12) {
                                        ForEach(abschnitt.absaetze, id: \.self) { absatz in
                                            Text(Lizenzbestand.verlinkt(absatz))
                                                .mitwachsend(13)
                                                .lineSpacing(2)
                                                .foregroundStyle(Stil.schriftLeise)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    .textSelection(.enabled)
                                    .padding(.horizontal, Stil.rand(breit: breit))
                                    .padding(.vertical, 14)
                                }
                                Color.clear.frame(height: 22)
                            }
                        } else {
                            Text("Die Lizenzliste fehlt in dieser Fassung. Du findest sie auf GitHub in THIRD-PARTY-NOTICES.md.")
                                .mitwachsend(15)
                                .foregroundStyle(Stil.schriftLeise)
                                .padding(.horizontal, Stil.rand(breit: breit))
                        }
                    }
                    .padding(.bottom, 40)
                    .frame(maxWidth: breit ? Stil.lesebreite : .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
        }
        .tint(Stil.akzent)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
    }
}
