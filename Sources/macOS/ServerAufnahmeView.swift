import JellyfinKit
import SwiftUI

/// **Einen zweiten Jellyfin-Server hinzufügen.**
///
/// Adresse, dann Name und Passwort — wie beim ersten Anmelden, nur ohne dass
/// die laufende Sitzung etwas davon merkt. Erst wenn die Anmeldung dort
/// klappt, kommt der Server in den Bund, und die App wechselt zu ihm. Wer
/// abbricht, ist wieder genau da, wo er war.
///
/// **Quick Connect steht hier gleichberechtigt daneben.** Es fehlte zuerst,
/// und ein Tester fand es sofort: wer auf dem Fernseher schon angemeldet ist,
/// will sein Passwort nicht noch einmal eintippen.
///
/// Die Zugangsdaten werden hier eingegeben und nur an den Server geschickt;
/// gemerkt wird allein die Sitzung, die er ausgibt.
struct ServerAufnahmeView: View {
    let model: AppModel
    /// Ein Server, der schon im Bund ist — dann geht es um ein weiteres Konto
    /// dort, und die Adresse steht schon da.
    var voreingestellt: URL?
    let zurueck: () -> Void

    @State private var adresse = ""
    @State private var server: (name: String, fassung: String)?
    @State private var pruefe = false
    @State private var benutzer = ""
    @State private var kennwort = ""
    /// „Erweitert" — eigene Header für einen Dienst vor dem Server.
    @State private var koepfe: [Kopfzeile] = []
    /// Umgeschaltet auf den Code-Weg. Der Vorgang läuft erst dann an — sonst
    /// zöge jeder Besuch dieser Seite einen Code beim Server, den niemand
    /// braucht.
    ///
    /// **Im Fenster, nicht als Blatt darüber.** Auf dem iPhone öffnet Quick
    /// Connect einen eigenen Vollbildschirm: dort ist kein Platz, ein Feld
    /// und einen sechsstelligen Code nebeneinander lesbar zu halten. Hier
    /// ist Platz, und ein Blatt über einem halb ausgefüllten Formular nähme
    /// genau die Angabe weg, auf die sich der Code bezieht — an welchem
    /// Server man sich gerade anmeldet. Dieselbe Entscheidung wie bei
    /// „Weiteres Konto", einen Bildschirm weiter.
    @State private var perCode = false
    @State private var stand = QuickConnectModell()
    @FocusState private var feld: Feld?

    private enum Feld { case adresse, benutzer, kennwort }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Unterseitenkopf(titel: voreingestellt == nil ? "Server hinzufügen" : "Weiteres Konto",
                            zurueck: abbrechen)

            Text(erklaerung)
                .font(Stil.koerper)
                .lineSpacing(3)
                .foregroundStyle(Stil.schriftLeise)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            if let server {
                gefunden(server).padding(.top, 22)
                if perCode { codeteil } else { formular }
            } else {
                // Mit eingetragener Adresse gibt es nichts einzutippen — das
                // Feld erscheint nur, wenn der Server nicht antwortet.
                if voreingestellt == nil || model.errorMessage != nil { adressteil }
                else { sucht }
            }

            Spacer(minLength: 0)
        }
        // Schmal wie ein Formular, aber am linken Rand wie jede Unterseite.
        .frame(maxWidth: Stil.formularbreite, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Stil.randAbstand)
        .padding(.top, Stil.inhaltOben)
        .onAppear {
            // **Aufräumen, bevor es losgeht.** Ein abgebrochener Versuch
            // hinterlässt sonst seinen Server und seine Fehlermeldung.
            model.serverAufnahmeAbbrechen()
            stand.neuerServer = true
            if let voreingestellt {
                adresse = voreingestellt.absoluteString
                pruefen()
            } else {
                feld = .adresse
            }
        }
        // Der Code wird erst geholt, wenn jemand darauf umschaltet.
        .task(id: perCode) { if perCode { await stand.neuStarten(model) } }
        .onDisappear { stand.anhalten() }
        .onChange(of: stand.freigegeben) { _, neu in
            guard let neu else { return }
            Task { _ = await model.anmeldenMitQuickConnectAmNeuenServer(neu) }
        }
    }

    private var erklaerung: LocalizedStringKey {
        voreingestellt == nil
        ? "Ein zweiter Jellyfin mit eigenen Konten. Beide bleiben angemeldet; auf der Profilseite wechselst du zwischen ihnen."
        : "Ein weiteres Konto auf diesem Server. Beide bleiben angemeldet; auf der Profilseite wechselst du zwischen ihnen."
    }

    // MARK: Adresse

    @ViewBuilder
    private var adressteil: some View {
        Eingabezeile(text: $adresse, symbol: "server.rack",
                     platzhalter: String(localized: "jellyfin.beispiel.de"),
                     abschluss: pruefen)
            .padding(.top, 26)
            .focused($feld, equals: .adresse)

        MacErweitert(zeilen: $koepfe)
            .padding(.top, 10)

        fehlerzeile

        Hauptknopf(beschriftung: pruefe ? "Moment…" : "Weiter", symbol: "arrow.right",
                   auswahl: pruefen)
            .padding(.top, 22)
            .disabled(adresse.isEmpty || pruefe)
            .opacity(adresse.isEmpty ? 0.4 : 1)
    }

    /// Solange die eingetragene Adresse geprüft wird, steht hier die Form des
    /// Ergebnisses statt eines Rings.
    private var sucht: some View {
        Ladefeld(ecke: Stil.eckeFeld)
            .frame(width: 280, height: 20)
            .padding(.top, 26)
    }

    /// Wohin das Konto kommt. Anzeige, kein Feld.
    private func gefunden(_ server: (name: String, fassung: String)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(Stil.klein)
                .foregroundStyle(Stil.akzent)
            Text(verbatim: "\(server.name) · Jellyfin \(server.fassung)")
                .font(Stil.zweitzeile)
                .foregroundStyle(Stil.schriftSehrLeise)
        }
    }

    // MARK: Name und Passwort

    @ViewBuilder
    private var formular: some View {
        Eingabezeile(text: $benutzer, symbol: "person",
                     platzhalter: String(localized: "Benutzername")) { feld = .kennwort }
            .padding(.top, 26)
            .focused($feld, equals: .benutzer)

        Eingabezeile(text: $kennwort, symbol: "lock", geheim: true,
                     platzhalter: String(localized: "Passwort"), abschluss: anmelden)
            .padding(.top, 10)
            .focused($feld, equals: .kennwort)

        fehlerzeile

        Hauptknopf(beschriftung: model.isWorking ? "Moment…" : "Anmelden",
                   symbol: "arrow.right", auswahl: anmelden)
            .padding(.top, 22)
            .disabled(benutzer.isEmpty || model.isWorking)
            .opacity(benutzer.isEmpty ? 0.4 : 1)

        trennerMitOder.padding(.top, 18)

        Umrissknopf(beschriftung: "Mit Quick Connect anmelden",
                    symbol: "rectangle.and.text.magnifyingglass") { perCode = true }
            .padding(.top, 18)
    }

    // MARK: Quick Connect

    @ViewBuilder
    private var codeteil: some View {
        if let vorgang = stand.vorgang {
            Text("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du an diesem Server schon angemeldet bist.")
                .font(Stil.zweitzeile)
                .foregroundStyle(Stil.schriftLeise)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 26)

            Text(verbatim: vorgang.code)
                // 28 Bold ist die hoechste Stufe der Leiter; 40 stand
                // darueber.
                .font(Stil.titelGross.monospacedDigit())
                .tracking(6)
                .foregroundStyle(Stil.schrift)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Stil.flaeche,
                            in: RoundedRectangle(cornerRadius: Stil.eckeFeld, style: .continuous))
                // Ein Klick legt den Code in die Zwischenablage — meist wird
                // er gleich daneben in einem Browserfenster eingefügt.
                .kopierbar(vorgang.code)
                .padding(.top, 14)

            Text("Läuft ab in \(stand.restsekunden / 60):\(String(format: "%02d", stand.restsekunden % 60))")
                .font(Stil.zweitzeile)
                .foregroundStyle(Stil.schriftSehrLeise)
                .padding(.top, 14)
        } else if let fehler = stand.fehler {
            Text(verbatim: fehler)
                .font(Stil.zweitzeile)
                .foregroundStyle(Stil.warnung)
                .padding(.top, 26)
        } else {
            // Der Code kommt gleich; solange steht seine Form da.
            Ladefeld(ecke: Stil.eckeFeld)
                .frame(width: 240, height: 64)
                .padding(.top, 26)
        }

        fehlerzeile

        Umrissknopf(beschriftung: "Lieber Name und Passwort", symbol: "person") {
            stand.anhalten()
            perCode = false
        }
        .padding(.top, 22)
    }

    // MARK: Kleinteile

    @ViewBuilder
    private var fehlerzeile: some View {
        if let fehler = model.errorMessage {
            Text(verbatim: fehler)
                .font(Stil.zweitzeile)
                .foregroundStyle(Stil.warnung)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    private var trennerMitOder: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Stil.linie).frame(height: 1)
            Text("oder")
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
            Rectangle().fill(Stil.linie).frame(height: 1)
        }
    }

    // MARK: Ablauf

    private func pruefen() {
        guard !adresse.isEmpty, !pruefe else { return }
        pruefe = true
        Task {
            let antwort = await model.serverPruefen(adresse, koepfe: koepfe.koepfe)
            withAnimation(Stil.sprung) { server = antwort }
            pruefe = false
            if antwort != nil { feld = .benutzer }
        }
    }

    private func anmelden() {
        guard !benutzer.isEmpty else { return }
        Task {
            if await model.anmeldenAmNeuenServer(benutzer: benutzer, passwort: kennwort) {
                kennwort = ""
                // **Kein `zurueck()` hier.** Die Anmeldung wechselt auf den
                // neuen Server, und `HauptView` raeumt darauf den Stapel bis
                // zur Profilseite ab — diese Seite ist dann laengst weg. Ein
                // Zurueck obendrauf nahm die Profilseite gleich mit und lief
                // in einen leeren Stapel.
            }
        }
    }

    private func abbrechen() {
        stand.anhalten()
        model.serverAufnahmeAbbrechen()
        zurueck()
    }
}
