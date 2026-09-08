import JellyfinKit
import SwiftUI

/// Seerr anbinden — Adresse, Name, Passwort. Die Mac-Fassung.
///
/// **Der Name steht schon da.** Auf beiden Seiten ist es dasselbe Konto;
/// Seerr fragt Jellyfin selbst, ob Name und Passwort stimmen. Also wird nur
/// getippt, was wir nicht haben — das Passwort. Und es wird nicht
/// gespeichert: gesichert wird allein die Sitzung, die Seerr daraufhin
/// ausstellt.
///
/// **Eine Zugabe, kein Fundament.** Wer nichts anbindet, sieht ausser der
/// einen Zeile in den Einstellungen nirgends etwas davon — keine leere
/// Rubrik, kein grauer Knopf, kein Hinweis, dass ihm etwas entgeht.
struct SeerrEinstellungenView: View {
    let model: AppModel
    let seerr: Seerrmodell
    let zurueck: () -> Void

    @State private var adresse = ""
    @State private var benutzer = ""
    @State private var passwort = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Unterseitenkopf(titel: "Seerr", zurueck: zurueck)

                Text("Jellyseerr oder Overseerr. Damit findest du in der Suche auch, was noch nicht auf deinem Server liegt — und kannst es anfragen.")
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                if seerr.verbunden { verbunden } else { formular }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Stil.randAbstand)
            .padding(.top, Stil.inhaltOben)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .ohneKanteneffekt()
        .task {
            if benutzer.isEmpty { benutzer = model.session?.userName ?? "" }
            await seerr.nachsehen()
        }
    }

    private var verbunden: some View {
        Einstellungsgruppe(titel: "Verbunden") {
            Wertezeile(symbol: "link",
                       titel: Text(verbatim: seerr.adresse ?? ""),
                       wert: seerr.traegt ? String(localized: "Aktiv")
                                          : String(localized: "Sitzung abgelaufen"))
            Trennstrich().padding(.leading, 48)
            // **Kein „Abmelden", sondern „Trennen".** Bei Seerr selbst bleibt
            // alles, wie es ist — es geht nur um diesen einen Zugang hier.
            Wertezeile(symbol: "xmark.circle", titel: Text("Verbindung trennen"),
                       aktion: { seerr.trennen(); adresse = ""; passwort = "" })
        }
        .padding(.top, 26)
    }

    private var formular: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                // Die Adresse ist die einzige Angabe, die wirklich neu ist.
                Eingabezeile(text: $adresse, symbol: "link",
                             platzhalter: "seerr.example.de")
                // **Vorausgefüllt, aber änderbar.** Auf beiden Seiten ist es
                // meist dasselbe Konto — meist ist nicht immer.
                Eingabezeile(text: $benutzer, symbol: "person",
                             platzhalter: String(localized: "Benutzername"))
                Eingabezeile(text: $passwort, symbol: "lock", geheim: true,
                             platzhalter: String(localized: "Passwort"),
                             abschluss: { Task { await verbinden() } })
            }

            if let fehler = seerr.fehler {
                Text(verbatim: fehler)
                    .font(Stil.zweitzeile)
                    .foregroundStyle(Stil.warnung)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }

            // Kein gesperrter Knopf: solange nichts dasteht, ist nichts zu
            // tun, und ein grauer Knopf behauptet das Gegenteil.
            if !adresse.isEmpty, !benutzer.isEmpty, !passwort.isEmpty {
                Hauptknopf(beschriftung: seerr.meldetAn ? "Verbinde…" : "Verbinden",
                           symbol: "link") {
                    guard !seerr.meldetAn else { return }
                    Task { await verbinden() }
                }
                .padding(.top, 20)
            }

            Text("Dein Passwort wird nicht gespeichert — nur die Sitzung, die Seerr dafür ausstellt.")
                .font(Stil.zweitzeile)
                .foregroundStyle(Stil.schriftSehrLeise)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .padding(.top, 26)
    }

    private func verbinden() async {
        await seerr.verbinden(adresse: adresse, benutzer: benutzer, passwort: passwort)
        if seerr.verbunden { passwort = "" }
    }
}
