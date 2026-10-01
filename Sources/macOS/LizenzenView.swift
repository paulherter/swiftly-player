import SwiftUI

// **Profil → Open-Source-Lizenzen (Mac).**
//
// Dieselben Daten wie auf iPhone und Fernseher (`Lizenzbestand`), der Aufbau
// des Mac: Seiten auf dem Stapel des Navigators, Karten mit Zeilen, Text zum
// Markieren. Der Lizenzwortlaut bleibt englisch, wie er in `LICENSES/` liegt.

private extension Lizenzbaustein {
    var unterzeile: String { "\(spdx) · \(version)" }
}

/// Der Rahmen jeder dieser Seiten: Kopf mit Pfeil, Karten in Formularbreite.
private struct Lizenzseite<Inhalt: View>: View {
    let titel: LocalizedStringKey
    let zurueck: () -> Void
    @ViewBuilder let inhalt: Inhalt

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Unterseitenkopf(titel: titel, zurueck: zurueck)
                inhalt
            }
            .frame(maxWidth: Stil.einstellungBreite, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Stil.randAbstand)
            .padding(.top, Stil.inhaltOben)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .seitenscrollen()
    }
}

private struct Fehlt: View {
    var body: some View {
        Text("Die Lizenzliste fehlt in dieser Fassung. Du findest sie auf GitHub in THIRD-PARTY-NOTICES.md.")
            .font(Stil.koerper)
            .foregroundStyle(Stil.schriftLeise)
    }
}

// MARK: Liste

struct LizenzenView: View {
    let zurueck: () -> Void

    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich

    private let bestand = Lizenzbestand.geteilt

    var body: some View {
        Lizenzseite(titel: "Open-Source-Lizenzen", zurueck: zurueck) {
            Text("Swiftly Player nutzt VLCKit und libVLC von VideoLAN (LGPL 2.1 oder später). Was sonst noch drinsteckt, steht darunter, mit Lizenz und Urheber.")
                .font(Stil.koerper)
                .lineSpacing(3)
                .foregroundStyle(Stil.schriftLeise)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            if let bestand {
                Einstellungsgruppe(titel: "VLCKit und libVLC") {
                    ForEach(bestand.bausteine(gruppe: "player")) { b in
                        zeile(b)
                        Blattlinie().padding(.leading, Stil.trennEinzugKarte)
                    }
                    Wertezeile(symbol: "doc.text",
                               titel: Text("Quelltext und schriftliches Angebot"),
                               unter: Text("Woher VLCKit kommt und wie du es ersetzt"),
                               pfeil: true) { navigator.oeffne(.lizenzangebot, in: bereich) }
                }
                gruppe("Weitere Bausteine", bestand.bausteine(gruppe: "app"))
                gruppe("In VLCKit eingebaut", bestand.bausteine(gruppe: "in-vlckit"))
            } else {
                Fehlt()
            }
        }
    }

    @ViewBuilder
    private func gruppe(_ titel: LocalizedStringKey, _ liste: [Lizenzbaustein]) -> some View {
        if !liste.isEmpty {
            Einstellungsgruppe(titel: titel) {
                ForEach(Array(liste.enumerated()), id: \.element.id) { stelle, b in
                    if stelle > 0 { Blattlinie().padding(.leading, Stil.trennEinzugKarte) }
                    zeile(b)
                }
            }
        }
    }

    private func zeile(_ b: Lizenzbaustein) -> some View {
        Wertezeile(symbol: "doc.text", titel: Text(verbatim: b.name),
                   unter: Text(verbatim: b.unterzeile), pfeil: true) {
            navigator.oeffne(.lizenz(b.id), in: bereich)
        }
    }
}

// MARK: Ein Baustein

struct LizenzView: View {
    let baustein: Lizenzbaustein
    let zurueck: () -> Void

    @Environment(\.openURL) private var oeffnen

    var body: some View {
        Lizenzseite(titel: LocalizedStringKey(baustein.name), zurueck: zurueck) {
            Zeilengruppe {
                VStack(alignment: .leading, spacing: 14) {
                    angabe("Fassung", baustein.version)
                    angabe("Lizenz", baustein.spdx)
                    angabe("Urheber", baustein.urheber)
                    if let url = baustein.quelleURL {
                        Button { oeffnen(url) } label: {
                            angabe("Quelle", baustein.quelle, fuehrtWeg: true)
                        }
                        .buttonStyle(Stil.Druckzeile())
                    }
                    if let notiz = baustein.notiz {
                        Text(verbatim: notiz)
                            .font(Stil.klein)
                            .foregroundStyle(Stil.schriftLeise)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, Stil.randAbstand)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 8)
            ForEach(baustein.texte, id: \.self) { datei in
                Einstellungsgruppe(titel: "Lizenztext") { volltext(datei) }
            }
        }
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

    @ViewBuilder
    private func volltext(_ datei: String) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            if let text = Lizenzbestand.text(datei) {
                ForEach(Array(Lizenzbestand.absaetze(von: text).enumerated()), id: \.offset) { _, absatz in
                    Text(verbatim: absatz)
                        .font(Stil.klein)
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
        .padding(.horizontal, Stil.randAbstand)
        .padding(.vertical, 14)
    }
}

// MARK: Quelltext und Angebot

struct LizenzangebotView: View {
    let zurueck: () -> Void

    private let angebot = Lizenzbestand.geteilt?.angebot

    var body: some View {
        Lizenzseite(titel: "Quelltext und Angebot", zurueck: zurueck) {
            if let angebot {
                ForEach(angebot.abschnitte, id: \.titel) { abschnitt in
                    Einstellungsgruppe(titel: LocalizedStringKey(abschnitt.titel)) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(abschnitt.absaetze, id: \.self) { absatz in
                                Text(Lizenzbestand.verlinkt(absatz))
                                    .font(Stil.klein)
                                    .lineSpacing(2)
                                    .foregroundStyle(Stil.schriftLeise)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.horizontal, Stil.randAbstand)
                        .padding(.vertical, 14)
                    }
                }
            } else {
                Fehlt()
            }
        }
    }
}
