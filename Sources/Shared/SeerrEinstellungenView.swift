import JellyfinKit
import SwiftUI

/// Seerr anbinden — Adresse, Name, Passwort.
///
/// **Der Name steht schon da.** Auf beiden Seiten ist es dasselbe Konto;
/// Seerr fragt Jellyfin selbst, ob Name und Passwort stimmen. Also wird nur
/// getippt, was wir nicht haben — das Passwort. Und es wird nicht gespeichert:
/// gesichert wird allein die Sitzung, die Seerr daraufhin ausstellt.
struct SeerrEinstellungenView: View {
    let model: AppModel
    let seerr: Seerrmodell

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit
    @State private var adresse = ""
    @State private var benutzer = ""
    @State private var passwort = ""

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()
            ScrollView { inhalt }.scrollIndicators(.hidden)
            Seitenpfeil { zurueck() }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        .task {
            if benutzer.isEmpty { benutzer = model.session?.userName ?? "" }
            await seerr.nachsehen()
        }
    }

    private var inhalt: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Seerr")
                .font(Stil.titel).tracking(-0.6).foregroundStyle(Stil.schrift)
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 52)

            Text("Jellyseerr oder Overseerr. Damit findest du in der Suche auch, was noch nicht auf deinem Server liegt — und kannst es anfragen.")
                .font(Stil.koerper)
                .foregroundStyle(Stil.schriftLeise)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 10)

            if seerr.verbunden { verbundenTeil } else { formular }

            Spacer(minLength: 40)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: breit ? .center : .leading)
    }

    // MARK: Verbunden

    private var verbundenTeil: some View {
        Einstellungsgruppe(titel: "Verbunden") {
            Wertzeile(symbol: "link", titel: Text(verbatim: seerr.adresse ?? ""),
                      wert: seerr.traegt ? String(localized: "Aktiv")
                                         : String(localized: "Sitzung abgelaufen"))
            Trennlinie().padding(.leading, Stil.trennEinzug(breit: breit))
            // **Kein „Abmelden", sondern „Trennen".** Bei Seerr selbst bleibt
            // alles, wie es ist — es geht nur um diesen einen Zugang hier.
            Wertzeile(symbol: "xmark.circle", titel: Text("Verbindung trennen"),
                      aktion: { seerr.trennen(); adresse = ""; passwort = "" })
        }
        .padding(.top, 26)
    }

    // MARK: Formular

    private var formular: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                // Die Adresse ist die einzige Angabe, die wirklich neu ist.
                Eingabefeld(text: $adresse, symbol: "link",
                            platzhalter: "seerr.example.de", tastatur: .adresse)
                // **Vorausgefüllt, aber änderbar.** Auf beiden Seiten ist
                // es meist dasselbe Konto — deshalb steht der Name schon da.
                // Meist ist nicht immer: wer sich bei Seerr unter einem
                // anderen Namen anmeldet, muss ihn überschreiben können.
                Eingabefeld(text: $benutzer, symbol: "person",
                            platzhalter: "Benutzername")
                Eingabefeld(text: $passwort, symbol: "lock",
                            platzhalter: "Passwort", geheim: true)
            }
            .padding(.horizontal, Stil.rand(breit: breit))

            if let fehler = seerr.fehler {
                Text(verbatim: fehler)
                    .font(Stil.klein)
                    .foregroundStyle(Stil.warnung)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Stil.rand(breit: breit))
                    .padding(.top, 14)
            }

            // Kein gesperrter Knopf: solange nichts dasteht, ist nichts zu
            // tun, und ein grauer Knopf behauptet das Gegenteil.
            if !adresse.isEmpty, !benutzer.isEmpty, !passwort.isEmpty, !seerr.meldetAn {
                // **Derselbe Knopf wie ueberall, nicht der dritte Nachbau.**
                // Er stand hier mit 15 statt 16 Punkt, Innenabstand 13 statt
                // Hoehe 48 und Ecke 10 statt 6 — dieselbe Sorte Abweichung
                // wie beim Anfragen-Knopf, nur eine Seite weiter.
                Button("Verbinden") { Task { await verbinden() } }
                    .buttonStyle(HauptknopfStil())
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 20)
            } else if seerr.meldetAn {
                Text("Verbinde…")
                    .font(Stil.koerper).foregroundStyle(Stil.schriftLeise)
                    .padding(.horizontal, Stil.rand(breit: breit))
                    .padding(.top, 20)
            }

            Text("Dein Passwort wird nicht gespeichert — nur die Sitzung, die Seerr dafür ausstellt.")
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 12)
        }
        .padding(.top, 26)
    }

    private func verbinden() async {
        await seerr.verbinden(adresse: adresse, benutzer: benutzer, passwort: passwort)
        if seerr.verbunden { passwort = "" }
    }
}
