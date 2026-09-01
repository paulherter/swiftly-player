import JellyfinKit
import SwiftUI

/// Alles, was die Wiedergabe betrifft.
///
/// Bewusst getrennt von den Einstellungen: dort steht, was die App betrifft —
/// Darstellung und Server. Stünde Qualität an beiden Stellen, müsste man
/// raten, welche gilt.
struct WiedergabeEinstellungenView: View {
    let model: AppModel

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit
    @State private var offeneListe: Liste?

    private enum Liste: String, Identifiable {
        case bitrate, ton, untertitel, zurueck, vor
        var id: String { rawValue }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()
            ScrollView { inhalt }
                .scrollIndicators(.hidden)
            Seitenpfeil { zurueck() }
            blatt
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
    }

    private var inhalt: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Wiedergabe")
                .font(Stil.titel)
                .tracking(-0.6)
                .foregroundStyle(Stil.schrift)
                .padding(.horizontal, Stil.randAbstand)
                .padding(.top, 52)

            Text("Gilt für alles, was neu startet. Im Player lässt sich jederzeit abweichen.")
                .font(Stil.koerper)
                .lineSpacing(3)
                .foregroundStyle(Stil.schriftLeise)
                .padding(.horizontal, Stil.randAbstand)
                .padding(.top, 8)

            if breit {
                HStack(alignment: .top, spacing: 56) {
                    VStack(alignment: .leading, spacing: 0) {
                        qualitaet
                        sprache
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    verhalten.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                qualitaet
                sprache
                verhalten
            }

            Text("Die Bitrate greift nur, wenn Direct Play nicht erzwungen wird — sonst bliebe sie wirkungslos und stünde trotzdem da.")
                .mitwachsend(13)
                .lineSpacing(2)
                .foregroundStyle(Color.white.opacity(0.35))
                .padding(.horizontal, Stil.randAbstand)
                .padding(.top, 22)
        }
        .padding(.bottom, 40)
    }

    private var qualitaet: some View {
        let waehlen: (() -> Void)? = model.immerDirectPlay ? nil : { offeneListe = .bitrate }

        return Einstellungsgruppe(titel: "Qualität") {
            Wahlzeile(symbol: "play.fill", titel: Text("Immer Direct Play"),
                      unter: Text("Nie umwandeln lassen — der Grund für diese App"),
                      an: Binding(get: { model.immerDirectPlay },
                                  set: { model.immerDirectPlay = $0 }))
            Trennlinie().padding(.leading, Stil.trennEinzug(breit: breit))
            Wertzeile(symbol: "chart.bar", titel: Text("Höchste Bitrate"),
                      wert: Bitrate.text(model.bitratenGrenze),
                      gedimmt: model.immerDirectPlay, aktion: waehlen)
        }
    }

    private var sprache: some View {
        Einstellungsgruppe(titel: "Sprache") {
            Wertzeile(symbol: "speaker.wave.2", titel: Text("Ton"),
                      wert: model.tonSprache.isEmpty ? String(localized: "Wie die Datei") : model.tonSprache,
                      aktion: { offeneListe = .ton })
            Trennlinie().padding(.leading, Stil.trennEinzug(breit: breit))
            Wertzeile(symbol: "captions.bubble", titel: Text("Untertitel"),
                      wert: model.untertitelSprache.isEmpty ? String(localized: "Aus") : model.untertitelSprache,
                      aktion: { offeneListe = .untertitel })
            Trennlinie().padding(.leading, Stil.trennEinzug(breit: breit))
            Wahlzeile(symbol: "text.alignleft", titel: Text("Untertitel automatisch"),
                      unter: Text("Nur wenn der Ton nicht in der gewählten Sprache läuft"),
                      an: Binding(get: { model.untertitelAutomatisch },
                                  set: { model.untertitelAutomatisch = $0 }))
        }
    }

    private var verhalten: some View {
        Einstellungsgruppe(titel: "Verhalten") {
            Wahlzeile(symbol: "forward.end.fill", titel: Text("Nächste Folge automatisch"),
                      an: Binding(get: { model.naechsteAutomatisch },
                                  set: { model.naechsteAutomatisch = $0 }))
            Trennlinie().padding(.leading, Stil.trennEinzug(breit: breit))
            Wertzeile(symbol: "gobackward", titel: Text("Zurückspulen"),
                      wert: "\(model.zurueckSekunden) s",
                      aktion: { offeneListe = .zurueck })
            Trennlinie().padding(.leading, Stil.trennEinzug(breit: breit))
            Wertzeile(symbol: "goforward", titel: Text("Vorspulen"),
                      wert: "\(model.vorSekunden) s",
                      aktion: { offeneListe = .vor })
        }
    }

    @ViewBuilder
    private var blatt: some View {
        switch offeneListe {
        case .bitrate:
            auswahl("Höchste Bitrate", Bitrate.stufen, { Bitrate.text($0.wert) },
                    { $0.wert == model.bitratenGrenze }, { model.bitratenGrenze = $0.wert })
        case .ton:
            auswahl("Ton", Sprachwahl.alle, { $0.name },
                    { $0.name == model.tonSprache }, { model.tonSprache = $0.wert })
        case .untertitel:
            auswahl("Untertitel", Sprachwahl.alle(aus: String(localized: "Aus")), { $0.name },
                    { $0.name == model.untertitelSprache }, { model.untertitelSprache = $0.wert })
        case .zurueck:
            auswahl("Zurückspulen", Spanne.stufen, { "\($0.wert) s" },
                    { $0.wert == model.zurueckSekunden }, { model.zurueckSekunden = $0.wert })
        case .vor:
            auswahl("Vorspulen", Spanne.stufen, { "\($0.wert) s" },
                    { $0.wert == model.vorSekunden }, { model.vorSekunden = $0.wert })
        case nil:
            EmptyView()
        }
    }

    private func auswahl<E: Identifiable>(_ titel: LocalizedStringKey, _ eintraege: [E],
                                          _ text: @escaping (E) -> String,
                                          _ gewaehlt: @escaping (E) -> Bool,
                                          _ waehlen: @escaping (E) -> Void) -> some View {
        Auswahlblatt(offen: Binding(get: { offeneListe != nil },
                                    set: { if !$0 { offeneListe = nil } }),
                     titel: titel, eintraege: eintraege,
                     beschriftung: text, istGewaehlt: gewaehlt, waehlen: waehlen)
    }


}


// MARK: - Zeilen

/// Zeile mit Schalter.
struct Wahlzeile: View {
    let symbol: String
    /// Bewusst `Text` und nicht `String` oder `LocalizedStringKey`: die
    /// Zeilen tragen mal eine feste Beschriftung — `Text("Sprache")`, wird
    /// übersetzt —, mal einen Wert vom Server wie den Servernamen, der
    /// unverändert bleiben muss (`Text(verbatim:)`). `Text` kann beides,
    /// zwei Erzeuger je Zeilentyp wären der umständlichere Weg zum selben.
    let titel: Text
    var unter: Text?
    @Binding var an: Bool

    var body: some View {
        Zeilenaufbau(symbol: symbol, titel: titel, unter: unter, gedimmt: false) {
            Schalter(an: $an)
        }
    }
}

/// Zeile mit Wert, wahlweise antippbar.
struct Wertzeile: View {
    let symbol: String
    let titel: Text
    var unter: Text?
    /// Der gewählte Wert — kommt teils vom Server (Sprachname), teils aus
    /// einer eigenen Liste. Bleibt deshalb eine Zeichenkette und wird dort
    /// übersetzt, wo er entsteht.
    var wert: String?
    var gedimmt = false
    var aktion: (() -> Void)?

    var body: some View {
        let rumpf = Zeilenaufbau(symbol: symbol, titel: titel, unter: unter,
                                 gedimmt: gedimmt) {
            HStack(spacing: 8) {
                if let wert {
                    Text(wert)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                if aktion != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.28))
                }
            }
        }
        if let aktion {
            Button(action: aktion) { rumpf }.buttonStyle(.plain)
        } else {
            rumpf
        }
    }
}

/// Symbol, Text, rechts etwas.
struct Zeilenaufbau<Rechts: View>: View {
    @Environment(\.breit) private var breit
    let symbol: String
    let titel: Text
    var unter: Text?
    var gedimmt: Bool
    @ViewBuilder var rechts: () -> Rechts

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                titel.mitwachsend(16)
                if let unter {
                    unter
                        .mitwachsend(13)
                        .foregroundStyle(Color.white.opacity(0.45))
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
            rechts()
        }
        .foregroundStyle(Stil.schrift.opacity(gedimmt ? 0.4 : 1))
        .padding(.horizontal, Stil.rand(breit: breit))
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}
