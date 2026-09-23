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

                // **Zwei Spalten, linksbuendig — die Anordnung des iPads.**
                //
                // Die Seite stand in einer 560 Punkt breiten Spalte in der
                // Fenstermitte. Links davon lag die Seitenleiste, rechts
                // nichts, und der Inhalt begann irgendwo dazwischen — an
                // keiner Kante, die es sonst auf dieser Seite gibt. Jede
                // andere Seite der App beginnt am linken Rand ihres Bereichs.
                //
                // Die Aufteilung ist die der iPad-Fassung: alles, was dieses
                // Geraet betrifft, in der linken Spalte, der Server allein in
                // der rechten. Er ist die einzige Gruppe, die nicht von hier
                // handelt, und er ist kurz — untereinander bliebe neben ihm
                // zwei Drittel der Seite leer.
                //
                // Der Zwischenraum ist doppelter Seitenrand: so stehen die
                // beiden Karten zueinander wie zum Fensterrand.
                // **Und jede Spalte hoert bei `formularbreite` auf.**
                //
                // Sie standen auf `maxWidth: .infinity` in einem Rahmen von
                // 1366 — also 659 Punkt je Spalte, und darin eine Zeile aus
                // Zeichen, einem Wort und einem Schalter. Das ist dieselbe
                // Sache, die Paul auf der Profilseite gesehen hat: lang
                // gezogen und dabei flach. Eine Liste aus Zeilen ist ein
                // Formular, nicht Fliesstext.
                HStack(alignment: .top, spacing: Stil.randAbstand * 2) {
                    VStack(alignment: .leading, spacing: 0) {
                        offline
                        integration
                    }
                    .frame(maxWidth: Stil.formularbreite, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        server
                        // Eigene Header für einen Dienst vor dem Server
                        // (Issue #4) — zugeklappt unter der Gruppe.
                        MacEigeneKoepfe(model: model)
                    }
                    .frame(maxWidth: Stil.formularbreite, alignment: .leading)
                    Spacer(minLength: 0)
                }

                // Die Fassung ist eine Angabe: 12 in `schriftSehrLeise`.
                // „Weiss 30 %" traegt gerechnet 2,67:1 und steht in BRAND 1
                // ausdruecklich unter den verbotenen Werten.
                Text(verbatim: Fassung.mitUnterbau)
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .padding(.top, 26)
            }
            .frame(maxWidth: Stil.einstellungBreite, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .seitenscrollen()
    }

    // **Hier standen `wiedergabe` und `darstellung`.** Sie gehoeren ins
    // Profil, neben Quick Connect — so wie auf iPhone, iPad und Fernseher.
    // Der Versuch, mit Befehl-Komma wirklich *alle* Einstellungen an einem
    // Ort zu versprechen, hat das Profil auf eine Zeile eingedampft und die
    // Darstellung zwei Ebenen tief vergraben. Was hier bleibt, betrifft das
    // Geraet: Offline, Integration, Server.

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
                          unter: Text("Titel auf diesen Mac laden und offline schauen"),
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
                              unter: Text("Downloads warten, bis du im WLAN bist"),
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
            // **Neben Seerr, und nur mit Zugangsdaten im Bau**
            // (`TraktZugang`) — ohne sie gaebe es einen Knopf, der
            // garantiert scheitert.
            if model.trakt.verfuegbar {
                Blattlinie().padding(.leading, Stil.trennEinzugKarte)
                Wertezeile(symbol: "checkmark.circle", titel: Text(verbatim: "Trakt"),
                           unter: Text("Trägt ein, was du schaust"),
                           wert: model.trakt.verbunden ? String(localized: "Verbunden") : nil,
                           aktion: { navigator.oeffne(.trakt, in: bereich) })
            }
            // **Hier und nicht bei „Wiedergabe".** Die Zeilen dort sagen,
            // *wie* etwas abläuft. Diese gibt als einzige der ganzen App
            // etwas **nach draußen**: wer sie anlegt, sagt jedem in seinen
            // Discord-Servern, was er gerade sieht. Das ist ein zweiter
            // Dienst, wie Seerr — und wie dort gilt: aus, bis jemand sie
            // sucht.
            //
            // **Im Sandkasten steht sie gar nicht da**, und das ist kein
            // Verstecken, sondern das Gegenteil einer halben Zusage. Am
            // 10.09.2026 am Gerät durchgemessen, alle drei Wege zu Discord:
            //
            // - Die Steckdose liegt unter `/var/folders/…/T/discord-ipc-0`.
            //   Der Sandkasten gibt der App ihren **eigenen** `TMPDIR`;
            //   darin liegt keine. Der Pfad trägt einen zufälligen Teil und
            //   ist nicht einmal als Ausnahme benennbar.
            // - WebSocket auf 6463, **ohne** Origin-Kopfzeile — das gilt im
            //   Netz als Ausweg: `101 Switching Protocols`, dann sofort ein
            //   Schließrahmen „Invalid Origin". Eine RPC-Herkunft lässt sich
            //   seit der Abkündigung im Portal nicht mehr eintragen.
            // - HTTP-Transport: hier greift die Herkunftsprüfung wirklich
            //   nicht, die Antwort kommt mit 200 — und lautet
            //   `command not available from "http" transport` (4002).
            //
            // Ein grauer Schalter wirft die Frage jedes Mal neu auf; einer,
            // der nicht da ist, wirft sie einmal auf. Und es ist umkehrbar:
            // kommt je ein Bau ohne Sandkasten, kommt die Zeile mit ihm
            // zurück, ohne dass jemand daran denken muss.
            if !imSandkasten {
                Blattlinie().padding(.leading, Stil.trennEinzugKarte)
                Schalterzeile(symbol: "bubble.left.and.text.bubble.right",
                              titel: Text(verbatim: "Discord"),
                              unter: Text("Zeigt im Profil, was gerade läuft"),
                              an: Binding(get: { model.discordAnzeigen },
                                          set: { model.discordAnzeigen = $0 }))
            }
        }
    }

    /// Läuft die App im Sandkasten? Im Store ist er Pflicht.
    ///
    /// Am Heimatverzeichnis abgelesen, nicht an einer Umgebungsvariablen:
    /// eine Anwendung im Sandkasten bekommt ihren Behälter als Zuhause, und
    /// genau daran hängt auch, dass sie Discords Steckdose nicht sieht. Die
    /// Prüfung misst also dieselbe Sache, die das Hindernis ist.
    private var imSandkasten: Bool {
        NSHomeDirectory().contains("/Library/Containers/")
    }

    private var server: some View {
        Einstellungsgruppe(titel: "Server") {
            Wertezeile(symbol: "externaldrive.connected.to.line.below",
                       titel: Text(verbatim: model.serverName ?? String(localized: "Server")),
                       wert: model.serverVersion ?? "?")
            Blattlinie().padding(.leading, Stil.trennEinzugKarte)
            Wertezeile(symbol: "wifi", titel: Text("Verbindung prüfen"),
                       unter: pruefung.map { Text(verbatim: $0) },
                       wert: pruefe ? String(localized: "Moment…") : nil,
                       aktion: pruefe ? nil : { pruefen() })
        }
    }

    // **Bewerten, Discord, Fehler melden stehen jetzt im Profil**, ganz unten
    // unter Server/Abmelden — hier wurden sie kaum gesehen.

    @Environment(\.openURL) private var oeffnen

    private func pruefen() {
        pruefe = true
        Task {
            pruefung = await model.verbindungPruefen()
            pruefe = false
        }
    }
}
