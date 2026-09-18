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
            VStack(spacing: 0) {
                // **Der Titel steht neben dem Pfeil, nicht darunter.**
                //
                // Er stand als eigene Zeile unter einem schwebenden Pfeil —
                // zwei Zeilen fuer eine Auskunft, und der Pfeil gehoerte zu
                // nichts. `Unterseitenkopf` setzt beides in eine Zeile,
                // dieselbe, die Merkliste und geladene Serie schon tragen.
                Unterseitenkopf(titel: String(localized: "Einstellungen")) { zurueck() }
                ScrollView { inhalt }
                    .scrollIndicators(.hidden)
            }
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
            // Breit nebeneinander. Beide Gruppen sind kurz; untereinander
            // stünden sie in einer Spalte, neben der zwei Drittel der Seite
            // leer bleiben.
            //
            // Ausdrücklich **nicht** mit Wiedergabe und Profil zu einer Seite
            // zusammengelegt, wie es der Fernseher tut. Dort ist der Grund
            // die Fernbedienung: jeder gesparte Sprung ist ein Weg. Ein Tipp
            // auf dem iPad kostet nichts.
            if breit {
                // **Null, seit die Gruppen Karten sind.** Jede Karte traegt links
                // und rechts schon `Stil.rand` — bei 56 dazwischen standen
                // 112 Punkt zwischen zwei Karten, und dafuer sind sie zu
                // schmal. Den Abstand tragen jetzt die Karten selbst.
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) { offline; integration }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) { server; gemeinschaft }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                offline
                integration
                server
                gemeinschaft
            }

            // **Nicht getippt.** Hier stand „Swiftly 1.0" — eine Zahl, die
            // seit 1.0.1 falsch war und die niemand mitzieht. Der Mac las
            // sie schon aus dem Bündel; das hier war die letzte Kopie.
            Text(verbatim: Fassung.mitUnterbau)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.3))
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 26)
        }
        .padding(.bottom, 40)
    }

    // MARK: Gruppen

    // **Darstellung steht nicht mehr hier**, sondern als eigene Seite im
    // Profil neben „Wiedergabe" — mit der Startseite zusammen, ohne ein
    // Untermenü im Untermenü. Seit dem 11.09.2026.

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
                Trennlinie().padding(.leading, Stil.trennEinzugKarte(breit: breit))
                Wahlzeile(symbol: "wifi",
                          titel: Text("Nur über WLAN"),
                          unter: Text("Über Mobilfunk warten Downloads"),
                          an: Binding(get: { model.nurUeberWLAN },
                                      set: { model.nurUeberWLAN = $0 }))
                Trennlinie().padding(.leading, Stil.trennEinzugKarte(breit: breit))
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
            NavigationLink(value: SeerrRoute()) {
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
            Trennlinie().padding(.leading, Stil.trennEinzugKarte(breit: breit))
            Wertzeile(symbol: "wifi", titel: Text("Verbindung prüfen"),
                      unter: pruefung.map { Text(verbatim: $0) },
                      wert: pruefe ? String(localized: "Moment…") : nil,
                      aktion: anstossen)
        }
    }

    /// **Bewerten, Discord, Fehler melden — immer da, nie aufdringlich.**
    ///
    /// Ganz unten, nach allem, was das Gerät betrifft: wer hier ankommt,
    /// sucht es. Von selbst kommt die App nur zweimal darauf zu, nach dem
    /// dritten und dem fünften zu Ende geschauten Titel (`Gemeinschaft`).
    private var gemeinschaft: some View {
        Einstellungsgruppe(titel: "Swiftly") {
            Wertzeile(symbol: "star", titel: Text("Swiftly bewerten"),
                      unter: Text("Im App Store"),
                      aktion: { oeffnen(Gemeinschaft.appStoreBewertung) })
            Trennlinie().padding(.leading, Stil.trennEinzugKarte(breit: breit))
            Wertzeile(symbol: "bubble.left.and.bubble.right", titel: Text("Discord beitreten"),
                      unter: Text("Fragen stellen und sagen, was fehlt"),
                      aktion: { oeffnen(Gemeinschaft.discord) })
            Trennlinie().padding(.leading, Stil.trennEinzugKarte(breit: breit))
            Wertzeile(symbol: "ladybug", titel: Text("Fehler melden"),
                      unter: Text("Auf GitHub, deine Fassung steht schon drin"),
                      aktion: { oeffnen(Fassung.fehlerMelden) })
        }
    }

    // MARK: Kleinkram

    @Environment(\.openURL) private var oeffnen



    private func pruefen() {
        pruefe = true
        Task {
            pruefung = await model.verbindungPruefen()
            pruefe = false
        }
    }
}
