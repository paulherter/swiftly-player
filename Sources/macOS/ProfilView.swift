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
                bildblock

                Zeilengruppe {
                    Button { navigator.oeffne(.quickConnect, in: bereich) } label: {
                        Wertezeile(symbol: "rectangle.and.text.magnifyingglass",
                                   titel: Text("Quick Connect"),
                                   unter: Text("Code vom Fernseher eingeben"),
                                   akzent: true, pfeil: true, schwebbar: true)
                    }
                    .buttonStyle(.plain)
                }

                Color.clear.frame(height: 26)

                Zeilengruppe {
                    Button { navigator.oeffne(.wiedergabe, in: bereich) } label: {
                        Wertezeile(symbol: "play.fill", titel: Text("Wiedergabe"),
                                   unter: Text("Sprache, Untertitel, Tempo"),
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

                Color.clear.frame(height: 26)

                Zeilengruppe {
                    // **Ohne Anstrich, und immer da.** Wer nur ein Konto hat,
                    // soll nicht das Gefühl haben, ihm fehle eines — deshalb
                    // steht die Zeile schlicht über „Abmelden" statt als
                    // Angebot mit Akzentfarbe.
                    Button { navigator.oeffne(.kontoHinzufuegen, in: bereich) } label: {
                        Wertezeile(symbol: "person.badge.plus",
                                   titel: Text("Weiteres Konto hinzufügen"),
                                   unter: Text("Auf demselben Server"),
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

                Text(verbatim: "Swiftly 1.0")
                    .font(.system(size: 12))
                    .foregroundStyle(Stil.schrift.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 26)
            }
            .frame(maxWidth: 560)
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
        .overlay(alignment: .topLeading) {
            // Nur der Pfeil, kein Titel — der Bildblock ist der Titel.
            Aktionsknopf(symbol: "chevron.left", titel: "Zurück", auswahl: zurueck)
                .padding(.leading, Stil.randAbstand - 8)
                .padding(.top, 12)
        }
    }

    private var bildblock: some View {
        VStack(spacing: 10) {
            // **Ein Kreis, solange es einer ist.** Erst mit dem zweiten Konto
            // wird daraus ein Streifen. Vorher gäbe es nichts zu wählen, und
            // ein Bild, das sich anklicken lässt, ohne dass etwas geschieht,
            // ist eine Falle.
            if model.konten.count > 1 {
                Kontenstreifen(model: model)
            } else {
                Profilzeichen(name: model.session?.userName ?? "?",
                              bild: model.benutzerbildURL(groesse: 200), groesse: 84)
            }
            VStack(spacing: 3) {
                Text(verbatim: model.session?.userName ?? String(localized: "Angemeldet"))
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Stil.schrift)
                Text(verbatim: untertitel)
                    .font(.system(size: 13))
                    .foregroundStyle(Stil.schrift.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 42)
        .padding(.bottom, 30)
    }

    private var untertitel: String {
        var teile: [String] = []
        if let name = model.serverName { teile.append(name) }
        if let fassung = model.serverVersion { teile.append("Jellyfin \(fassung)") }
        return teile.joined(separator: " · ")
    }
}

// MARK: - Kontenstreifen

/// Die Konten dieses Servers nebeneinander. Antippen schaltet um.
///
/// **Zwei Dinge, die man nicht verwechseln darf.** Auf dem Fernseher ist
/// groß, was im Fokus steht, und das ändert sich beim Blättern — es bedeutet
/// nichts. **Verbunden** ist, was Akzentring und Punkt trägt, und das ändert
/// sich erst beim Drücken. Am Zeiger gibt es keinen Fokus, der wandert:
/// hier fällt beides zusammen, das aktive Konto steht groß in der Mitte des
/// Inhaltsbereichs. Die Trennung bleibt trotzdem sichtbar — Ring und Punkt
/// hängen am aktiven Konto, nicht an der Größe.
///
/// Maße aus dem abgenommenen Schreibtischentwurf: 96 aktiv, 72 daneben,
/// Abstand 26. Auf dem Telefon sind es 84/64 — dort ist weniger Platz und
/// das Auge näher dran.
private struct Kontenstreifen: View {
    let model: AppModel

    private let aktivGross: CGFloat = 96
    private let danebenGross: CGFloat = 72
    private let abstand: CGFloat = 26

    var body: some View {
        HStack(spacing: abstand) {
            ForEach(model.konten, id: \.userID) { konto in
                let aktiv = konto.userID == model.session?.userID
                Kontokreis(name: konto.userName,
                           bild: model.benutzerbildURL(fuer: konto,
                                                       groesse: aktiv ? 200 : 150),
                           groesse: aktiv ? aktivGross : danebenGross,
                           hoehe: aktivGross,
                           aktiv: aktiv) {
                    model.kontoWechseln(zu: konto.userID)
                }
            }
        }
        // **Das aktive Konto steht in der Mitte, nicht der Streifen.** Der
        // Entwurf setzt den aktiven Kreis auf die Mitte des Inhaltsbereichs
        // und die übrigen daneben. Bei zwei Konten heißt das: das aktive
        // mittig, das andere rechts davon — und nach dem Umschalten
        // andersherum.
        .offset(x: mittenversatz)
        .animation(Stil.zeitSeitenschub, value: model.session?.userID)
    }

    /// Wie weit der Streifen liegen muss, damit der aktive Kreis mittig steht.
    /// Reine Rechnung aus den Maßen — kein Messen der Auslage nötig.
    private var mittenversatz: CGFloat {
        let konten = model.konten
        guard konten.count > 1,
              let stelle = konten.firstIndex(where: { $0.userID == model.session?.userID })
        else { return 0 }
        let breiten = konten.map { $0.userID == model.session?.userID ? aktivGross : danebenGross }
        let gesamt = breiten.reduce(0, +) + abstand * CGFloat(konten.count - 1)
        let davor = breiten[..<stelle].reduce(0, +) + abstand * CGFloat(stelle)
        return gesamt / 2 - (davor + breiten[stelle] / 2)
    }
}

/// Ein Konto im Streifen: Bild, darunter der Punkt.
///
/// Der Ring ist kein neues Bauteil — `Profilzeichen(hervorgehoben:)` kann das
/// seit dem Kontenbund. Der Punkt sagt dasselbe noch einmal, für alle, die
/// den Farbring nicht auseinanderhalten.
private struct Kontokreis: View {
    let name: String
    let bild: URL?
    let groesse: CGFloat
    /// Gemeinsame Mittellinie: die kleineren Kreise sitzen mittig zum großen,
    /// nicht auf dessen Oberkante.
    let hoehe: CGFloat
    let aktiv: Bool
    let waehlen: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: waehlen) {
            VStack(spacing: 9) {
                Profilzeichen(name: name, bild: bild, groesse: groesse,
                              hervorgehoben: aktiv)
                    .frame(height: hoehe)
                Circle()
                    .fill(aktiv ? Stil.akzent : Color.clear)
                    .frame(width: 5, height: 5)
            }
            // Das aktive Konto steht voll da, die anderen zurückgenommen —
            // beim Überfahren treten sie hervor. Am Zeiger ist das die
            // Rückmeldung, die auf dem Fernseher der Fokus gibt.
            .opacity(aktiv ? 1 : (schwebt ? 0.85 : 0.55))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // **Nicht `disabled`.** Naheliegend wäre gewesen, das aktive Konto zu
        // sperren — es gibt dort nichts umzuschalten. SwiftUI legt über einen
        // gesperrten Knopf aber seinen eigenen Schleier, und der lag damit
        // über genau dem Bild, das am hellsten dastehen soll. Der Klick läuft
        // stattdessen ins Leere: `kontoWechseln` lehnt die eigene Kennung
        // ohnehin ab.
        .onHover { schwebt = $0 && !aktiv }
        .animation(Stil.zeitSchweben, value: schwebt)
        .accessibilityLabel(aktiv ? Text("\(name), angemeldet")
                                  : Text("Zu \(name) wechseln"))
    }
}

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
        .frame(maxWidth: 460, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
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
        .frame(maxWidth: 460, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
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
                .padding(.top, 14)

            HStack(spacing: 10) {
                Lader(groesse: 14, staerke: 2)
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
            Lader().padding(.top, 26)
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
private struct Umrissknopf: View {
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
