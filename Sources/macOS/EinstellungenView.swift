import JellyfinKit
import SwiftUI

/// Einstellungen der App.
///
/// Hier steht, was die App betrifft. Alles zur Wiedergabe liegt auf einer
/// eigenen Seite — sonst stünde dasselbe an zwei Stellen. Diese Trennung ist
/// die der iPhone-Fassung und bleibt auf allen Plattformen gleich
/// (VERHALTEN.md, Abschnitt F).
struct EinstellungenView: View {
    let model: AppModel
    let zurueck: () -> Void

    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich
    @State private var pruefung: String?
    @State private var pruefe = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Unterseitenkopf(titel: "Einstellungen", zurueck: zurueck)

                wiedergabe
                darstellung
                offline
                integration
                server

                Text(verbatim: Fassung.mitUnterbau)
                    .font(.system(size: 12))
                    .foregroundStyle(Stil.schrift.opacity(0.3))
                    .padding(.top, 26)
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

    /// **Befehl-Komma verspricht alle Einstellungen, also stehen hier alle.**
    ///
    /// Auf dem Telefon tippt man sich durch eine Liste, und „Wiedergabe" darf
    /// neben „Einstellungen" hängen — dort hat niemand etwas zugesagt. Auf
    /// dem Mac sagt das **System** mit Befehl-Komma: hier sind die
    /// Einstellungen. Wer dann Darstellung, Offline, Integration und Server
    /// findet, hat die Hälfte gefunden und weiß es nicht — schlechter als gar
    /// kein Kürzel.
    ///
    /// Die Abweichung von den anderen Plattformen steht in `VERHALTEN.md`,
    /// Abschnitt F: der Grund ist die Eingabeart, das Kürzel gibt es nur hier.
    private var wiedergabe: some View {
        Einstellungsgruppe(titel: "Wiedergabe") {
            Button { navigator.oeffne(.wiedergabe, in: bereich) } label: {
                Wertezeile(symbol: "play.fill", titel: Text("Wiedergabe"),
                           unter: Text("Sprache, Untertitel, Tempo, Puffer"),
                           pfeil: true, schwebbar: true)
            }
            .buttonStyle(.plain)
        }
    }

    private var darstellung: some View {
        Einstellungsgruppe(titel: "Darstellung") {
            // „Querformat im Player sperren" gibt es hier **nicht**: ein
            // Fenster hat keine Ausrichtung, die man sperren könnte. Das ist
            // kein Weglassen, sondern eine Einstellung ohne Gegenstück
            // (VERHALTEN.md F).
            Schalterzeile(symbol: "chart.bar.fill",
                          titel: Text("Fortschritt auf Kacheln"),
                          an: Binding(get: { model.fortschrittAufKacheln },
                                      set: { model.fortschrittAufKacheln = $0 }))
        }
    }

    /// **Eine eigene Gruppe, vor der Integration.**
    ///
    /// Nicht unter *Darstellung*: Downloads sind keine Geschmacksfrage,
    /// sondern eine Funktion, die Platz belegt. Nicht unter *Integration*:
    /// das ist für fremde Dienste. **H1** — aus im Auslieferungszustand,
    /// und dann steht hier genau eine Zeile.
    private var offline: some View {
        Einstellungsgruppe(titel: "Offline") {
            Schalterzeile(symbol: "arrow.down.circle",
                          titel: Text("Downloads"),
                          unter: Text("Titel auf diesen Mac laden und ohne Netz sehen"),
                          an: Binding(get: { model.downloadsAn },
                                      set: { an in
                                          if an || model.downloads.posten.isEmpty {
                                              model.downloadsAn = an
                                          } else {
                                              abschaltfrage = true
                                          }
                                      }))
            if model.downloadsAn {
                Schalterzeile(symbol: "wifi",
                              titel: Text("Nur über WLAN"),
                              unter: Text("Über Mobilfunk warten Downloads"),
                              an: Binding(get: { model.nurUeberWLAN },
                                          set: { model.nurUeberWLAN = $0 }))
                Wertezeile(symbol: "internaldrive",
                           titel: Text("Speicher"),
                           unter: Text("\(model.downloads.posten.count) Titel auf diesem Mac"),
                           wert: Downloadregeln.groesse(
                               Downloadregeln.belegung(model.downloads.posten).bytes))
            }
        }
        // **H10 — Ausschalten löscht nichts ungefragt.** Auf dem Mac ist die
        // Nachfrage ein Systemdialog statt eines Blattes: die Frage gehört
        // zum Fenster, nicht zu einer Zeile darin.
        .confirmationDialog(Text("Downloads ausschalten?"),
                            isPresented: $abschaltfrage) {
            Button("Behalten") { model.downloadsAn = false }
            Button("Alles entfernen", role: .destructive) {
                model.downloads.allesEntfernen()
                model.downloadsAn = false
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(verbatim: abschalttext)
        }
    }

    @State private var abschaltfrage = false

    private var abschalttext: String {
        let b = Downloadregeln.belegung(model.downloads.posten)
        return String(localized: "\(b.anzahl) Titel bleiben auf diesem Mac")
            + " · " + Downloadregeln.groesse(b.bytes)
    }

    /// **Steht zwischen Offline und Server, und das ist kein Zufall.**
    /// Es ist ein zweiter Dienst, kein zweiter Server — und es ist eine
    /// Zugabe: wer nichts anbindet, sieht ausser dieser einen Zeile nirgends
    /// etwas davon.
    private var integration: some View {
        Einstellungsgruppe(titel: "Integration") {
            Wertezeile(symbol: "sparkle.magnifyingglass", titel: Text("Seerr"),
                       unter: Text("Anfragen, was noch nicht da ist"),
                       wert: model.seerr.verbunden ? String(localized: "Verbunden") : nil,
                       aktion: { navigator.oeffne(.seerr, in: bereich) })
            Trennstrich().padding(.leading, 48)
            // **Hier und nicht bei „Wiedergabe".** Die Zeilen dort sagen,
            // *wie* etwas abläuft. Diese gibt als einzige der ganzen App
            // etwas **nach draußen**: wer sie anlegt, sagt jedem in seinen
            // Discord-Servern, was er gerade sieht. Das ist ein zweiter
            // Dienst, wie Seerr — und wie dort gilt: aus, bis jemand sie
            // sucht.
            Schalterzeile(symbol: "bubble.left.and.text.bubble.right",
                          titel: Text(verbatim: "Discord"),
                          unter: Text("Zeigt im Profil, was gerade läuft"),
                          an: Binding(get: { model.discordAnzeigen },
                                      set: { model.discordAnzeigen = $0 }))
        }
    }

    private var server: some View {
        Einstellungsgruppe(titel: "Server") {
            Wertezeile(symbol: "externaldrive.connected.to.line.below",
                       titel: Text(verbatim: model.serverName ?? String(localized: "Server")),
                       wert: model.serverVersion ?? "?")
            Trennstrich().padding(.leading, 48)
            Wertezeile(symbol: "wifi", titel: Text("Verbindung prüfen"),
                       unter: pruefung.map { Text(verbatim: $0) },
                       wert: pruefe ? String(localized: "Moment…") : nil,
                       aktion: pruefe ? nil : { pruefen() })
        }
    }

    private func pruefen() {
        pruefe = true
        Task {
            pruefung = await model.verbindungPruefen()
            pruefe = false
        }
    }
}
