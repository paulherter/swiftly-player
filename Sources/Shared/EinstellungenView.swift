import JellyfinKit
import SwiftUI

/// Einstellungen der App.
///
/// Gleicher Aufbau wie die Profilseite: flache Zeilen mit Haarlinien, Gruppen
/// nur durch Leerraum und einen kleinen gesperrten Titel getrennt.
///
/// Hier steht, was die App betrifft. Alles zur Wiedergabe — Qualität,
/// Sprache, Verhalten — liegt auf einer eigenen Seite; sonst stünde dasselbe
/// an zwei Stellen.
struct EinstellungenView: View {
    let model: AppModel

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit
    @State private var pruefung: String?
    @State private var pruefe = false

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()
            ScrollView { inhalt }
                .scrollIndicators(.hidden)
            Seitenpfeil { zurueck() }
        }
        .overlay(alignment: .topTrailing) {
            // **H10 — Ausschalten löscht nichts ungefragt.** Stilles Löschen
            // von vierzig Gigabyte, die jemand über eine Woche geladen hat,
            // wäre die schlechteste Variante. Behaltene Dateien tauchen
            // wieder auf, sobald der Schalter erneut umgelegt wird.
            Handlungsblatt(offen: $abschaltblatt, titel: abschalttitel, handlungen: [
                Titelhandlung(symbol: "tray.and.arrow.down", text: "Behalten") {
                    model.downloadsAn = false
                },
                Titelhandlung(symbol: "trash", text: "Alles entfernen", warnend: true) {
                    model.downloads.allesEntfernen()
                    model.downloadsAn = false
                },
            ])
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
    }

    @State private var abschaltblatt = false

    private var abschalttitel: String {
        let b = Downloadregeln.belegung(model.downloads.posten)
        return String(localized: "\(b.anzahl) Titel bleiben auf dem Gerät")
            + " · " + Downloadregeln.groesse(b.bytes)
    }

    private var inhalt: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Einstellungen")
                .font(Stil.titel)
                .tracking(-0.6)
                .foregroundStyle(Stil.schrift)
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 52)

            // Breit nebeneinander. Beide Gruppen sind kurz; untereinander
            // stünden sie in einer Spalte, neben der zwei Drittel der Seite
            // leer bleiben.
            //
            // Ausdrücklich **nicht** mit Wiedergabe und Profil zu einer Seite
            // zusammengelegt, wie es der Fernseher tut. Dort ist der Grund
            // die Fernbedienung: jeder gesparte Sprung ist ein Weg. Ein Tipp
            // auf dem iPad kostet nichts.
            if breit {
                HStack(alignment: .top, spacing: 56) {
                    VStack(alignment: .leading, spacing: 0) { darstellung; offline; integration }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    server.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                darstellung
                offline
                integration
                server
            }

            // **Nicht getippt.** Hier stand „Swiftly 1.0" — eine Zahl, die
            // seit 1.0.1 falsch war und die niemand mitzieht. Der Mac las
            // sie schon aus dem Bündel; das hier war die letzte Kopie.
            Text(verbatim: "\(Fassung.zeile) · VLCKit 4.0.0-a23")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.3))
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 26)
        }
        .padding(.bottom, 40)
    }

    // MARK: Gruppen

    private var darstellung: some View {
        Einstellungsgruppe(titel: "Darstellung") {
            // Auf dem iPad fehlt diese Zeile, und das ist Absicht: ohne
            // `UIRequiresFullScreen` gilt die App als multitaskingfähig, und
            // eine solche App darf die Drehung nicht erzwingen. Der Schalter
            // hätte dort keine Wirkung — und ein Schalter ohne Wirkung ist
            // schlechter als keiner. Die Frage beantwortet `Orientierung`,
            // nicht diese Ansicht — dort steht auch der Grund.
            if Orientierung.querformatSperreMoeglich {
                Wahlzeile(symbol: "rectangle.on.rectangle",
                            titel: Text("Querformat im Player sperren"),
                            an: Binding(get: { model.querformatFest },
                                        set: { model.querformatFest = $0 }))
                Trennlinie().padding(.leading, Stil.trennEinzug(breit: breit))
            }
            Wahlzeile(symbol: "chart.bar.fill", titel: Text("Fortschritt auf Kacheln"),
                        an: Binding(get: { model.fortschrittAufKacheln },
                                    set: { model.fortschrittAufKacheln = $0 }))
            Trennlinie().padding(.leading, Stil.trennEinzug(breit: breit))
            // **Geschmacksfrage, deshalb ein Schalter und keine Regel.**
            // Manche wollen eine Reihe mit allem, manche nur Filme, manche
            // beides getrennt. Aus heißt: wie bisher.
            Wahlzeile(symbol: "square.split.2x1",
                        titel: Text("Neuzugänge getrennt"),
                        unter: Text("Neue Filme und neue Serien in eigenen Reihen"),
                        an: Binding(get: { model.neuzugangGetrennt },
                                    set: { model.neuzugangGetrennt = $0 }))
        }
    }

    /// **Eine eigene Gruppe, und die steht vor der Integration.**
    ///
    /// Nicht unter *Darstellung*: Downloads sind keine Geschmacksfrage,
    /// sondern eine Funktion, die Platz auf dem Gerät belegt. Nicht unter
    /// *Integration*: das ist für fremde Dienste. Und vor *Server*, weil es
    /// um dieses Gerät geht, nicht um jenes.
    ///
    /// **H1** — aus im Auslieferungszustand, und dann steht hier genau eine
    /// Zeile.
    private var offline: some View {
        Einstellungsgruppe(titel: "Offline") {
            Wahlzeile(symbol: "arrow.down.circle",
                      titel: Text("Downloads"),
                      unter: Text("Titel aufs Gerät laden und ohne Netz sehen"),
                      an: Binding(get: { model.downloadsAn },
                                  set: { an in
                                      if an { model.downloadsAn = true }
                                      // H10: Ausschalten löscht nichts
                                      // ungefragt. Liegt nichts da, gibt es
                                      // auch nichts zu fragen.
                                      else if model.downloads.posten.isEmpty { model.downloadsAn = false }
                                      else { abschaltblatt = true }
                                  }))
            if model.downloadsAn {
                Trennlinie().padding(.leading, Stil.trennEinzug(breit: breit))
                Wahlzeile(symbol: "wifi",
                          titel: Text("Nur über WLAN"),
                          unter: Text("Über Mobilfunk warten Downloads"),
                          an: Binding(get: { model.nurUeberWLAN },
                                      set: { model.nurUeberWLAN = $0 }))
                Trennlinie().padding(.leading, Stil.trennEinzug(breit: breit))
                // **Die Zahl steht in der Zeile, nicht erst dahinter.** Wer
                // wissen will, wie viel belegt ist, soll dafür nicht tippen
                // müssen — es ist die einzige Auskunft, um die es hier geht.
                Wertzeile(symbol: "internaldrive",
                          titel: Text("Speicher"),
                          unter: Text("\(model.downloads.posten.count) Titel auf diesem Gerät"),
                          wert: Downloadregeln.groesse(
                              Downloadregeln.belegung(model.downloads.posten).bytes))
            }
        }
    }

    /// **Steht zwischen Offline und Server, und das ist kein Zufall.**
    /// Es ist ein zweiter Dienst, kein zweiter Server — und es ist eine
    /// Zugabe: wer nichts anbindet, sieht ausser dieser einen Zeile nirgends
    /// etwas davon.
    private var integration: some View {
        Einstellungsgruppe(titel: "Integration") {
            NavigationLink {
                SeerrEinstellungenView(model: model, seerr: model.seerr)
            } label: {
                Wertzeile(symbol: "sparkle.magnifyingglass", titel: Text("Seerr"),
                          unter: Text("Anfragen, was noch nicht da ist"),
                          wert: model.seerr.verbunden ? String(localized: "Verbunden") : nil)
            }
            .buttonStyle(.plain)
        }
    }

    private var server: some View {
        let anstossen: (() -> Void)? = pruefe ? nil : { pruefen() }

        return Einstellungsgruppe(titel: "Server") {
            Wertzeile(symbol: "externaldrive.connected.to.line.below",
                      titel: Text(verbatim: model.serverName ?? "Server"),
                      wert: model.serverVersion ?? "?")
            Trennlinie().padding(.leading, Stil.trennEinzug(breit: breit))
            Wertzeile(symbol: "wifi", titel: Text("Verbindung prüfen"),
                      unter: pruefung.map { Text(verbatim: $0) },
                      wert: pruefe ? String(localized: "Moment…") : nil,
                      aktion: anstossen)
        }
    }

    // MARK: Kleinkram



    private func pruefen() {
        pruefe = true
        Task {
            pruefung = await model.verbindungPruefen()
            pruefe = false
        }
    }
}
