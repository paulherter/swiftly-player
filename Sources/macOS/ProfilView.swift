import JellyfinKit
import SwiftUI

/// Profil, Quick Connect, Wiedergabe, Einstellungen, Abmelden.
///
/// Aufbau und Reihenfolge wörtlich von der iPhone-Fassung: mittiger Bildblock,
/// darunter drei Gruppen, getrennt nur durch Leerraum. Keine Karten.
///
/// Die Seite ist im Fenster schmal gehalten — über die volle Breite gezogen
/// stünden Symbol und Wert einen halben Meter auseinander.
struct ProfilView: View {
    let model: AppModel
    let zurueck: () -> Void
    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // **Ein Seitentitel wie auf jeder anderen Unterseite.**
                // Hier stand nur der Pfeil, mit der Begruendung, der
                // Bildblock sei der Titel. Als Karte ist er ein Gegenstand
                // auf der Seite, kein Kopf.
                // **Buendig mit den Karten, nicht davor.** Der Kopf war um
                // einen Seitenrand nach links gezogen und stiess damit an
                // die Seitenleiste; auf jeder anderen Unterseite sitzt der
                // Pfeil ueber der Kante des Inhalts.
                Unterseitenkopf(titel: "Profil", zurueck: zurueck)
                    .padding(.bottom, 10)

                Kontokarte(model: model,
                           hinzufuegenAuf: { server in
                               navigator.oeffne(.serverHinzufuegen(server), in: bereich)
                           },
                           hinzufuegen: {
                               navigator.oeffne(.kontoHinzufuegen, in: bereich)
                           })

                Color.clear.frame(height: 20)

                Zeilengruppe {
                    Button { navigator.oeffne(.quickConnect, in: bereich) } label: {
                        Wertezeile(symbol: "rectangle.and.text.magnifyingglass",
                                   titel: Text("Quick Connect"),
                                   unter: Text("Code vom Fernseher eingeben"),
                                   akzent: true, pfeil: true, schwebbar: true)
                    }
                    .buttonStyle(.plain)
                }

                Color.clear.frame(height: 18)

                // **Die Kategorien stehen hier, wie auf iPhone und iPad.**
                //
                // Sie waren kurz in die Einstellungen gewandert, mit dem
                // Argument, Befehl-Komma verspreche dort alles. Das Argument
                // stimmt, der Preis war zu hoch: das Profil bestand dann aus
                // einer einzigen Zeile, und wer „Darstellung" suchte, musste
                // erst wissen, dass sie zwei Ebenen tiefer liegt als auf
                // jedem anderen Geraet. Befehl-Komma fuehrt weiterhin auf die
                // Einstellungen; was dort steht, betrifft das Geraet.
                Zeilengruppe {
                    Button { navigator.oeffne(.wiedergabe, in: bereich) } label: {
                        Wertezeile(symbol: "play.fill", titel: Text("Wiedergabe"),
                                   unter: Text("Sprache, Untertitel, Tempo"),
                                   pfeil: true, schwebbar: true)
                    }
                    .buttonStyle(.plain)
                    Trennstrich().padding(.leading, 48)
                    Button { navigator.oeffne(.darstellung, in: bereich) } label: {
                        Wertezeile(symbol: "square.grid.2x2", titel: Text("Darstellung"),
                                   unter: Text("Startseite, Reihen, Genres"),
                                   pfeil: true, schwebbar: true)
                    }
                    .buttonStyle(.plain)
                    Trennstrich().padding(.leading, 48)
                    Button { navigator.oeffne(.einstellungen, in: bereich) } label: {
                        Wertezeile(symbol: "gearshape", titel: Text("Einstellungen"),
                                   pfeil: true, schwebbar: true)
                    }
                    .buttonStyle(.plain)
                }

                Color.clear.frame(height: 18)

                Zeilengruppe {
                    // **Jetzt mit Unterbau.** Hier stand ein Hinweis, dass
                    // mehrere Server spaeter kommen — der Kontenbund hielt
                    // genau einen. Seit dem 12.09.2026 haelt er mehrere, und
                    // die Zeile fuehrt auf die Aufnahme: Adresse, dann
                    // anmelden, wahlweise mit Quick Connect.
                    //
                    // „Weiteres Konto hinzufuegen" stand hier und ist weg:
                    // das Plus in der Kontokarte tut dasselbe, und zwar dort,
                    // wo die Konten stehen.
                    Button { navigator.oeffne(.serverHinzufuegen(nil), in: bereich) } label: {
                        Wertezeile(symbol: "externaldrive.connected.to.line.below",
                                   titel: Text("Server hinzufügen"),
                                   unter: Text("Ein zweiter Jellyfin, eigene Konten"),
                                   pfeil: true, schwebbar: true)
                    }
                    .buttonStyle(.plain)
                    Trennstrich().padding(.leading, 48)
                    // **Trifft nur das aktive Konto.** Sind noch andere da,
                    // schaltet die App auf das nächste um; erst beim letzten
                    // geht es zurück zur Anmeldung. Steht so im
                    // Zustandshalter, nicht hier.
                    Wertezeile(symbol: "rectangle.portrait.and.arrow.right",
                               titel: Text("Abmelden")) { model.signOut() }
                }

                // **Nicht getippt.** Hier stand „Swiftly 1.0" — seit der
                // ersten Abgabe falsch, und genau diese Zeile schreibt ein
                // Tester in seinen Fehlerbericht.
                Text(verbatim: Fassung.zeile)
                    .font(.system(size: 12))
                    .foregroundStyle(Stil.schrift.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 26)
            }
            // **Linksbuendig, nicht in der Fenstermitte — wie auf dem iPad.**
            // Die Seite hing als schmale Saeule zwischen Seitenleiste und
            // rechtem Rand, an keiner Kante, die es sonst gibt. Die Breite
            // bleibt begrenzt; nur der Platz, der uebrig ist, liegt jetzt
            // rechts statt zu beiden Seiten.
            .frame(maxWidth: Stil.lesebreite, alignment: .leading)
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
        .ohneKanteneffekt()
    }
}

/// **Hier standen `bildblock`, `Kontenstreifen` und `Kontokreis`** — ein
/// mittiger Bildblock mit einem Streifen wanderender Kreise. Sie riefen
/// einander, aber niemand rief sie: der Rumpf zeigt seit dem Umbau auf Karten
/// die `Kontokarte`. Hundertzehn Zeilen, die niemand sah und die trotzdem bei
/// jeder Änderung mitgelesen wurden.

// MARK: - Quick Connect

/// Einen Code freigeben, der auf einem anderen Gerät steht.
struct QuickConnectView: View {
    let model: AppModel
    let zurueck: () -> Void

    @State private var code = ""
    @State private var laeuft = false
    @State private var meldung: String?
    @State private var geschafft = false
    @FocusState private var imFeld: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Unterseitenkopf(titel: "Quick Connect", zurueck: zurueck)

            Text("Auf dem anderen Gerät steht ein sechsstelliger Code. Gib ihn hier ein, dann meldet es sich mit deinem Konto an.")
                .font(Stil.koerper)
                .lineSpacing(3)
                .foregroundStyle(Stil.schriftLeise)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            TextField("", text: $code,
                      prompt: Text(verbatim: "000000").foregroundColor(Stil.schrift.opacity(0.22)))
                .textFieldStyle(.plain)
                .font(.system(size: 34, weight: .semibold).monospacedDigit())
                .multilineTextAlignment(.center)
                .foregroundStyle(Stil.schrift)
                .focused($imFeld)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.ecke))
                .overlay { RoundedRectangle(cornerRadius: Stil.ecke).strokeBorder(Stil.rand) }
                .padding(.top, 26)
                .onSubmit(freigeben)

            if let meldung {
                Text(verbatim: meldung)
                    .font(.system(size: 13))
                    .foregroundStyle(geschafft ? Stil.akzent : Stil.warnung)
                    .padding(.top, 12)
            }

            Hauptknopf(beschriftung: laeuft ? "Moment…" : "Freigeben",
                       symbol: "checkmark", auswahl: freigeben)
                .disabled(laeuft || code.count < 4)
                .opacity(code.count < 4 ? 0.4 : 1)
                .padding(.top, 22)

            Spacer(minLength: 0)
        }
        // Schmal wie ein Formular, aber am linken Rand wie jede Unterseite:
        // mittig stand der Pfeil mitten im Fenster, an keiner Kante.
        .frame(maxWidth: 460, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Stil.randAbstand)
        .padding(.top, Stil.inhaltOben)
        // Kein Warten auf eine Tastaturanimation wie auf dem iPhone — im
        // Fenster schiebt nichts.
        .onAppear { imFeld = true }
    }

    private func freigeben() {
        guard code.count >= 4, !laeuft else { return }
        laeuft = true
        meldung = nil
        Task {
            defer { laeuft = false }
            do {
                try await model.quickConnectFreigeben(code: code)
                geschafft = true
                meldung = String(localized: "Freigegeben. Das andere Gerät ist gleich angemeldet.")
                try? await Task.sleep(for: .seconds(2))
                zurueck()
            } catch {
                geschafft = false
                meldung = model.lesbar(error)
            }
        }
    }
}

// MARK: - Weiteres Konto

/// Ein zweites Konto **auf demselben Server** aufnehmen.
///
/// **Kein Serverfeld.** Ein Kontenbund gehört zu genau einem Server; die
/// Adresse steht längst fest und wird nur noch angezeigt. Wer den Server
/// wechseln will, meldet sich ab.
///
/// **Name und Passwort sind hier der Normalweg**, Quick Connect steht
/// daneben. Auf dem Fernseher ist es umgekehrt — dort ist ein Passwort auf
/// der Fernbedienung eine Zumutung, hier liegt eine Tastatur davor.
struct KontoHinzufuegenView: View {
    let model: AppModel
    let zurueck: () -> Void

    @State private var benutzer = ""
    @State private var kennwort = ""
    /// Umgeschaltet auf den Code-Weg. Der Vorgang läuft erst dann an — sonst
    /// zöge jeder Besuch dieser Seite einen Code beim Server, den niemand
    /// braucht.
    @State private var perCode = false
    @State private var stand = QuickConnectModell()
    @FocusState private var feld: Feld?

    private enum Feld { case benutzer, kennwort }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Unterseitenkopf(titel: "Weiteres Konto", zurueck: zurueck)

            Text("Ein zweites Jellyfin-Konto auf demselben Server. Beide bleiben angemeldet; oben auf der Profilseite wechselst du zwischen ihnen.")
                .font(Stil.koerper)
                .lineSpacing(3)
                .foregroundStyle(Stil.schriftLeise)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            serverzeile.padding(.top, 22)

            if perCode { codeteil } else { formular }

            Spacer(minLength: 0)
        }
        // Schmal wie ein Formular, aber am linken Rand wie jede Unterseite:
        // mittig stand der Pfeil mitten im Fenster, an keiner Kante.
        .frame(maxWidth: 460, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Stil.randAbstand)
        .padding(.top, Stil.inhaltOben)
        .onAppear { feld = .benutzer }
        // Der Code wird erst geholt, wenn jemand darauf umschaltet.
        .task(id: perCode) { if perCode { await stand.neuStarten(model) } }
        .onDisappear { stand.anhalten() }
        .onChange(of: stand.freigegeben) { _, neu in
            guard let neu else { return }
            Task {
                await model.anmeldenMitQuickConnect(neu)
                schliesseWennGeklappt()
            }
        }
    }

    /// Wohin das Konto kommt. Anzeige, kein Feld.
    private var serverzeile: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 13))
            Text(verbatim: serverbeschreibung)
                .font(Stil.zweitzeile)
        }
        .foregroundStyle(Stil.schriftSehrLeise)
    }

    private var serverbeschreibung: String {
        [model.serverName, model.serverAdresse]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    // MARK: Name und Passwort

    @ViewBuilder
    private var formular: some View {
        Eingabezeile(text: $benutzer, symbol: "person",
                     platzhalter: String(localized: "Benutzername")) { feld = .kennwort }
            .padding(.top, 26)
            .focused($feld, equals: .benutzer)

        Eingabezeile(text: $kennwort, symbol: "lock", geheim: true,
                     platzhalter: String(localized: "Passwort"), abschluss: hinzufuegen)
            .padding(.top, 10)
            .focused($feld, equals: .kennwort)

        fehlerzeile

        Hauptknopf(beschriftung: "Hinzufügen", symbol: "arrow.right",
                   auswahl: hinzufuegen)
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
            Text("Gib diesen Code in Jellyfin auf einem Gerät ein, an dem du schon angemeldet bist.")
                .font(Stil.zweitzeile)
                .foregroundStyle(Stil.schriftLeise)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 26)

            Text(verbatim: vorgang.code)
                .font(.system(size: 40, weight: .semibold).monospacedDigit())
                .tracking(6)
                .foregroundStyle(Stil.schrift)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.ecke))
                .overlay { RoundedRectangle(cornerRadius: Stil.ecke).strokeBorder(Stil.rand) }
                // Ein Klick legt den Code in die Zwischenablage — meist wird
                // er gleich daneben in einem Browserfenster eingefügt.
                .kopierbar(vorgang.code)
                .padding(.top, 14)

            HStack(spacing: 10) {
                Text("Läuft ab in \(stand.restsekunden / 60):\(String(format: "%02d", stand.restsekunden % 60))")
                    .font(Stil.zweitzeile)
                    .foregroundStyle(Stil.schriftSehrLeise)
            }
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
        HStack(spacing: 8) {
            Rectangle().fill(Stil.linie).frame(height: 1)
            Text("oder")
                .font(.system(size: 12))
                .foregroundStyle(Stil.schriftSehrLeise)
            Rectangle().fill(Stil.linie).frame(height: 1)
        }
    }

    private func hinzufuegen() {
        guard !benutzer.isEmpty, !model.isWorking else { return }
        Task {
            await model.login(username: benutzer, password: kennwort)
            schliesseWennGeklappt()
        }
    }

    /// **Die Seite schließt sich selbst — aber nur, wenn es geklappt hat.**
    ///
    /// Beim ersten Anmelden verschwindet der Schirm nebenbei: `RootView`
    /// tauscht bei `phase == .ready` den ganzen Inhalt. Über einer bereits
    /// angemeldeten App geschieht das nicht — das Konto kam dazu, und die
    /// Seite blieb trotzdem stehen, als sei nichts passiert. Die Prüfung auf
    /// `errorMessage` gehört dazu, sonst verschluckt das Schließen die
    /// Fehlermeldung.
    private func schliesseWennGeklappt() {
        if model.errorMessage == nil { zurueck() }
    }
}

/// Der zweite Weg auf einer Seite: Rand statt Fläche, Akzent statt Schwarz.
///
/// Steht hier und nicht in `Macbausteine`, solange es genau eine Stelle gibt,
/// die ihn braucht. Kommt eine zweite dazu, gehört er dorthin.
/// Umrandeter Knopf — der zweite Weg neben dem Hauptknopf.
///
/// **Nicht mehr privat:** die Serveraufnahme stellt denselben Knopf unter
/// ihr Formular, und zwei gleiche wären die kopierte Funktion aus CLAUDE.md.
struct Umrissknopf: View {
    let beschriftung: LocalizedStringKey
    let symbol: String
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 14))
                Text(beschriftung).font(.system(size: 15, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: Stil.hauptknopfHoehe)
            .foregroundStyle(Stil.akzent)
            .background(schwebt ? Stil.schrift.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: Stil.ecke))
            .overlay { RoundedRectangle(cornerRadius: Stil.ecke).strokeBorder(Stil.rand) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
    }
}

/// **Die Kontokarte — A4 aus dem Entwurf vom 11.09.2026, wörtlich wie auf
/// iPhone und iPad.**
///
/// Zwei Achsen, zwei Gesten, und sie sagen zwei verschiedene Sachen: ein
/// Konto in der Reihe **anklicken** wechselt den Benutzer auf demselben
/// Server; die Karte **weiterblättern** wechselt den Server. Ein zweites
/// **Die Konten, nach Servern sortiert.**
///
/// Konto ist der Mitbewohner — gleiche Bibliothek, andere Fortschritte. Ein
/// zweiter Server ist ein anderer Ort.
///
/// **Untereinander, nicht zum Wischen.** Auf dem iPhone liegt je Server eine
/// Karte in einem Blätterband mit Punkten darunter — dort ist die Seite
/// schmal, und zwei Karten übereinander wären zwei Bildschirmhöhen. Im
/// Fenster ist Platz nach unten, und Wischen ist eine Geste des Fingers: hier
/// stehen die Server einfach untereinander, der verbundene zuerst. Das ist
/// die Abweichung, die `VERHALTEN.md` zulässt — Eingabeart und Fenstergröße,
/// nicht Geschmack.
private struct Kontokarte: View {
    let model: AppModel
    /// Ein Konto auf einem **anderen** Server als dem verbundenen.
    var hinzufuegenAuf: (URL) -> Void = { _ in }
    /// Ein Konto auf **diesem** Server — die gewohnte Anmeldung.
    let hinzufuegen: () -> Void

    /// Der verbundene Server zuerst, die übrigen in ihrer Reihenfolge.
    private var server: [URL] {
        model.server.sorted { a, b in istAktiv(a) && !istAktiv(b) }
    }

    var body: some View {
        VStack(spacing: 14) {
            if server.isEmpty {
                karte(model.session?.serverURL)
            } else {
                ForEach(server, id: \.absoluteString) { url in karte(url) }
            }
        }
    }

    private func istAktiv(_ server: URL?) -> Bool {
        server?.absoluteString.lowercased() == model.session?.serverURL.absoluteString.lowercased()
    }

    @ViewBuilder
    private func karte(_ server: URL?) -> some View {
        let alle = server.map { model.konten(auf: $0) } ?? model.konten
        let aktiv = istAktiv(server)
        // Auf dem verbundenen Server steht vorn, wer angemeldet ist; auf einem
        // anderen das erste Konto dort — ein Klick wechselt dorthin.
        let vorn = aktiv ? model.session : alle.first
        let andere = alle.filter { $0.kontoschluessel != vorn?.kontoschluessel }
        Karte {
            kopfzeile(vorn, aktiv: aktiv, server: server)
            Trennstrich()
            reihe(andere, aktiv: aktiv, server: server)
        }
        // Der verbundene Server trägt den Akzentrand; die anderen stehen als
        // gewöhnliche Karten da. Bei einem einzigen gäbe es nichts zu
        // unterscheiden — dann bleibt er weg.
        .overlay {
            if aktiv, model.server.count > 1 {
                RoundedRectangle(cornerRadius: Stil.eckeFlaeche)
                    .strokeBorder(Stil.akzent.opacity(0.55), lineWidth: 1.5)
            }
        }
    }

    @ViewBuilder
    private func kopfzeile(_ konto: Session?, aktiv: Bool, server: URL?) -> some View {
        let inhalt = HStack(spacing: 14) {
            Profilzeichen(name: konto?.userName ?? "?",
                          bild: konto.flatMap { model.benutzerbildURL(fuer: $0) },
                          groesse: 56,
                          hervorgehoben: aktiv && model.server.count > 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: konto?.userName ?? String(localized: "Angemeldet"))
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Stil.schrift)
                // Name und Fassung kennen wir nur vom Server, mit dem wir
                // gerade verbunden sind; bei den anderen steht die Adresse.
                Text(verbatim: aktiv ? (model.serverName ?? server?.host() ?? "")
                                     : (server?.host() ?? ""))
                    .font(.system(size: 13))
                    .foregroundStyle(Stil.schrift.opacity(0.45))
                    .lineLimit(1)
                if aktiv, let fassung = model.serverVersion {
                    Text(verbatim: "Jellyfin \(fassung)")
                        .font(.system(size: 12))
                        .foregroundStyle(Stil.schrift.opacity(0.45))
                        .lineLimit(1)
                } else if !aktiv {
                    Text("Klicken zum Wechseln")
                        .font(.system(size: 12))
                        .foregroundStyle(Stil.schrift.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .contentShape(Rectangle())
        if !aktiv, let konto {
            Button { model.kontoWechseln(zu: konto.kontoschluessel) } label: { inhalt }
                .buttonStyle(.plain)
        } else {
            inhalt
        }
    }

    /// Die übrigen Konten dieses Servers, dahinter das Plus.
    private func reihe(_ andere: [Session], aktiv: Bool, server: URL?) -> some View {
        HStack(spacing: 14) {
            ForEach(andere, id: \.kontoschluessel) { konto in
                Button { model.kontoWechseln(zu: konto.kontoschluessel) } label: {
                    Profilzeichen(name: konto.userName,
                                  bild: model.benutzerbildURL(fuer: konto),
                                  groesse: 40)
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: konto.userName))
            }

            // **Das Plus steht auf jeder Karte** und legt ein Konto auf
            // *diesem* Server an. Auf dem verbundenen die gewohnte Anmeldung,
            // auf einem anderen dieselbe wie beim Hinzufügen eines Servers —
            // nur mit schon eingetragener Adresse. Es stand vorher nur auf der
            // Karte des verbundenen Servers; wer ein Konto anderswo anlegen
            // wollte, musste erst dorthin wechseln.
            Button {
                if aktiv { hinzufuegen() } else if let server { hinzufuegenAuf(server) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Stil.schrift.opacity(0.45))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Circle().strokeBorder(Stil.rand,
                                              style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(Text("Weiteres Konto hinzufügen"))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
