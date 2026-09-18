import JellyfinKit
import SwiftUI

/// Wiedergabe: Qualität, Sprache, Verhalten.
///
/// Gruppen, Reihenfolge und Texte wörtlich von der iPhone-Fassung. Die Werte
/// selbst kommen aus `Wiedergabewahlen` und `Tempostufen` — nicht als eigene
/// Listen (VERHALTEN.md B9/B10).
///
/// Einziger Unterschied: die Werteliste klappt **unter der Zeile** auf statt
/// als Blatt von unten. „Auswahl bleibt am Ort" — dieselbe Regel, anderes
/// Mittel.
struct WiedergabeEinstellungenView: View {
    let model: AppModel
    let zurueck: () -> Void

    @State private var offeneListe: Liste?

    enum Liste { case bitrate, ton, untertitel, zurueck, vor }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Unterseitenkopf(titel: "Wiedergabe", zurueck: zurueck)

                Text("Gilt für alles, was neu startet. Im Player lässt sich jederzeit abweichen.")
                    .font(Stil.koerper)
                    .lineSpacing(3)
                    .foregroundStyle(Stil.schriftLeise)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)

                qualitaet

                Text("Die Bitrate greift nur, wenn Direct Play nicht erzwungen wird — sonst bliebe sie wirkungslos und stünde trotzdem da.")
                    .font(.system(size: 12))
                    .foregroundStyle(Stil.schrift.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                sprache
                verhalten
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Stil.randAbstand)
            .padding(.top, Stil.inhaltOben)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        // **Die milchige Leiste am oberen Rand.** macOS 26 legt sie von sich
        // aus über jede Scrollfläche — sie war nie in unserem Code, und
        // deshalb habe ich zweimal an der falschen Stelle gesucht. Über dem
        // Bild verlor sie sich, links auf blankem Grund stand sie als Balken.
        //
        // E4 wieder: was das Rahmenwerk ungefragt dazustellt, gehört ebenso
        // abgestellt wie das, was man selbst hinschreibt.
        .ohneKanteneffekt()
    }

    // MARK: Gruppen

    private var qualitaet: some View {
        Einstellungsgruppe(titel: "Qualität") {
            Schalterzeile(symbol: "play.fill", titel: Text("Immer Direct Play"),
                          unter: Text("Nie umwandeln lassen — der Grund für diese App"),
                          an: Binding(get: { model.immerDirectPlay },
                                      set: { model.immerDirectPlay = $0 }))
            Trennstrich().padding(.leading, 48)
            Wertezeile(symbol: "chart.bar", titel: Text("Höchste Bitrate"),
                       wert: Bitrate.text(model.bitratenGrenze),
                       pfeil: true, aktion: { umschalten(.bitrate) })
                .disabled(model.immerDirectPlay)
                .opacity(model.immerDirectPlay ? 0.4 : 1)
            if offeneListe == .bitrate {
                Werteliste(eintraege: Bitrate.stufen,
                           beschriftung: { Bitrate.text($0.wert) },
                           istGewaehlt: { $0.wert == model.bitratenGrenze },
                           waehlen: { model.bitratenGrenze = $0.wert; schliessen() })
            }
        }
    }

    private var sprache: some View {
        Einstellungsgruppe(titel: "Sprache") {
            Wertezeile(symbol: "speaker.wave.2", titel: Text("Ton"),
                       wert: model.tonSprache, pfeil: true, aktion: { umschalten(.ton) })
            if offeneListe == .ton {
                Werteliste(eintraege: Sprachwahl.alle, beschriftung: { $0.name },
                           istGewaehlt: { $0.name == model.tonSprache },
                           waehlen: { model.tonSprache = $0.wert; schliessen() })
            }
            Trennstrich().padding(.leading, 48)
            Wertezeile(symbol: "captions.bubble", titel: Text("Untertitel"),
                       wert: model.untertitelSprache, pfeil: true,
                       aktion: { umschalten(.untertitel) })
            if offeneListe == .untertitel {
                Werteliste(eintraege: Sprachwahl.alle(aus: String(localized: "Aus")),
                           beschriftung: { $0.name },
                           istGewaehlt: { $0.name == model.untertitelSprache },
                           waehlen: { model.untertitelSprache = $0.wert; schliessen() })
            }
            Trennstrich().padding(.leading, 48)
            Schalterzeile(symbol: "text.alignleft", titel: Text("Untertitel automatisch"),
                          unter: Text("Nur wenn der Ton nicht in der gewählten Sprache läuft"),
                          an: Binding(get: { model.untertitelAutomatisch },
                                      set: { model.untertitelAutomatisch = $0 }))
        }
    }

    private var verhalten: some View {
        Einstellungsgruppe(titel: "Verhalten") {
            Schalterzeile(symbol: "forward.end.fill",
                          titel: Text("Nächste Folge automatisch"),
                          an: Binding(get: { model.naechsteAutomatisch },
                                      set: { model.naechsteAutomatisch = $0 }))
            Trennstrich().padding(.leading, 48)
            Wertezeile(symbol: "gobackward", titel: Text("Zurückspulen"),
                       wert: "\(model.zurueckSekunden) s", pfeil: true,
                       aktion: { umschalten(.zurueck) })
            if offeneListe == .zurueck {
                Werteliste(eintraege: Spanne.stufen, beschriftung: { "\($0.wert) s" },
                           istGewaehlt: { $0.wert == model.zurueckSekunden },
                           waehlen: { model.zurueckSekunden = $0.wert; schliessen() })
            }
            Trennstrich().padding(.leading, 48)
            Wertezeile(symbol: "goforward", titel: Text("Vorspulen"),
                       wert: "\(model.vorSekunden) s", pfeil: true,
                       aktion: { umschalten(.vor) })
            if offeneListe == .vor {
                Werteliste(eintraege: Spanne.stufen, beschriftung: { "\($0.wert) s" },
                           istGewaehlt: { $0.wert == model.vorSekunden },
                           waehlen: { model.vorSekunden = $0.wert; schliessen() })
            }
        }
    }

    private func umschalten(_ liste: Liste) {
        withAnimation(Stil.zeitSprung) {
            offeneListe = offeneListe == liste ? nil : liste
        }
    }

    private func schliessen() {
        withAnimation(Stil.zeitSprung) { offeneListe = nil }
    }
}
