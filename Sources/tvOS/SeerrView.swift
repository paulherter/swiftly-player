import JellyfinKit
import SwiftUI

/// Seerr anbinden — die Fernseherfassung.
///
/// **Der Name steht schon da.** Auf beiden Seiten ist es dasselbe Konto;
/// Seerr fragt Jellyfin selbst, ob Name und Passwort stimmen. Getippt wird
/// nur, was wir nicht haben — und mit einer Fernbedienung ist jedes Zeichen
/// teuer, also so wenige wie möglich.
///
/// Als eigene Seite über allem, nicht als Zeile in den Einstellungen: drei
/// Felder und eine Bildschirmtastatur brauchen den Platz, den eine Zeile in
/// einer Liste nicht hat.
struct SeerrAnbindenView: View {
    let model: AppModel
    let seerr: Seerrmodell
    let schliessen: () -> Void

    @State private var adresse = ""
    @State private var benutzer = ""
    @State private var passwort = ""

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Text("Seerr")
                    .font(Stil.titelGross)
                    .foregroundStyle(Stil.schrift)

                Text("Jellyseerr oder Overseerr. Damit findest du in der Suche auch, was noch nicht auf deinem Server liegt — und kannst es anfragen.")
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .frame(width: 900, alignment: .leading)
                    .padding(.top, 16)

                if seerr.verbunden { verbunden } else { formular }

                HStack(spacing: 24) {
                    Button("Fertig") { schliessen() }
                        .buttonStyle(KnopfStil())
                }
                .padding(.top, 44)
            }
            .frame(width: 900, alignment: .leading)
        }
        .task {
            if benutzer.isEmpty { benutzer = model.session?.userName ?? "" }
            await seerr.nachsehen()
        }
    }

    @ViewBuilder
    private var verbunden: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: seerr.adresse ?? "")
                .font(Stil.koerper).foregroundStyle(Stil.schrift)
            Text(seerr.traegt ? "Sitzung aktiv" : "Sitzung abgelaufen")
                .font(Stil.klein)
                .foregroundStyle(seerr.traegt ? Stil.akzent : Stil.warnung)
            // **Kein „Abmelden", sondern „Trennen".** Bei Seerr selbst bleibt
            // alles, wie es ist — es geht nur um diesen einen Zugang.
            Button("Verbindung trennen") {
                seerr.trennen(); adresse = ""; passwort = ""
            }
            .buttonStyle(KnopfStil())
        }
        .padding(.top, 44)
    }

    @ViewBuilder
    private var formular: some View {
        VStack(alignment: .leading, spacing: 20) {
            Eingabefeld(platzhalter: "seerr.example.de", text: $adresse, inhalt: .URL)
            Eingabefeld(platzhalter: "Benutzername", text: $benutzer, inhalt: .username)
            Eingabefeld(platzhalter: "Passwort", text: $passwort,
                        sicher: true, inhalt: .password)

            if let fehler = seerr.fehler {
                Text(verbatim: fehler)
                    .font(Stil.klein).foregroundStyle(Stil.warnung)
            }

            // Kein gesperrter Knopf: solange nichts dasteht, ist nichts zu
            // tun, und ein grauer Knopf behauptet das Gegenteil.
            if !adresse.isEmpty, !benutzer.isEmpty, !passwort.isEmpty {
                Button(seerr.meldetAn ? "Verbinde…" : "Verbinden") {
                    guard !seerr.meldetAn else { return }
                    Task {
                        await seerr.verbinden(adresse: adresse, benutzer: benutzer,
                                              passwort: passwort)
                        if seerr.verbunden { passwort = "" }
                    }
                }
                .buttonStyle(KnopfStil())
            }

            Text("Dein Passwort wird nicht gespeichert — nur die Sitzung, die Seerr dafür ausstellt.")
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
        }
        .frame(width: 900, alignment: .leading)
        .padding(.top, 44)
    }
}

/// Ein Titel, den der eigene Server noch nicht hat — die Fernseherkachel.
///
/// **Blass, und das ist die ganze Auskunft.** Wer über das Gitter fährt, soll
/// ohne ein Wort zu lesen sehen, dass hier nichts abzuspielen ist.
struct Seerrkachel: View {
    let treffer: Seerrtreffer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Bild(url: treffer.plakat(breite: 500),
                 breite: Stil.posterBreite, hoehe: Stil.posterHoehe)
                .opacity(0.45)
                .overlay(alignment: .bottomLeading) { marke.padding(10) }

            Text(verbatim: treffer.titel)
                .font(Stil.kachel)
                .foregroundStyle(Stil.schriftLeise)
                .lineLimit(1)
                .padding(.top, 14)

            Text(verbatim: untertitel)
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
                .lineLimit(1)
                .padding(.top, 2)
        }
        .frame(width: Stil.posterBreite, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(treffer.titel), \(treffer.stand.ansage)"))
    }

    private var untertitel: String {
        let art = treffer.istSerie ? String(localized: "Serie") : String(localized: "Film")
        return treffer.jahr.map { "\($0) · \(art)" } ?? art
    }

    @ViewBuilder
    private var marke: some View {
        if treffer.stand != .da {
            HStack(spacing: 5) {
                Image(systemName: treffer.stand.symbol)
                    .font(.system(size: 15, weight: .bold))
                if let wort = treffer.stand.kurzwort {
                    Text(verbatim: wort).font(.system(size: 17, weight: .semibold))
                }
            }
            .foregroundStyle(Stil.grund)
            .padding(.horizontal, treffer.stand.kurzwort == nil ? 9 : 12)
            .padding(.vertical, 5)
            .background(treffer.stand.farbe, in: Capsule())
        }
    }
}

/// Die Seite eines Titels, den der eigene Server noch nicht hat.
///
/// **Dieselbe Seite wie sonst, nur eine andere Handlung.** Getauscht ist der
/// grosse Knopf — aus *Abspielen* wird *Anfragen*.
struct SeerrDetailView: View {
    let model: AppModel
    let treffer: Seerrtreffer

    @State private var stand: Seerrstand
    @State private var detail: Seerrdetail?
    @State private var laeuft = false
    @State private var angefragt = false
    @State private var fehler: String?
    @State private var gewaehlt: Set<Int> = []
    @State private var staffelnOffen = false
    @State private var bestaetigt = false
    /// Der Fokus muss beim Aufklappen in die Tafel wandern — tvOS legt ihn
    /// nicht von selbst um, solange der Ausloeser stehenbleibt.
    @FocusState private var ersteZeile: Int?

    init(model: AppModel, treffer: Seerrtreffer) {
        self.model = model
        self.treffer = treffer
        _stand = State(initialValue: treffer.stand)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                kopf
                besetzung
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Stil.abschlussLuft)
        }
        .scrollIndicators(.hidden)
        // **Der seitliche Rand wird einmal vergeben, nicht zweimal.**
        //
        // Er fehlte hier, und deshalb sass die Seite als einzige doppelt so
        // weit innen: tvOS haelt selbst 80 Punkt frei, `Stil.randSeite` legt
        // noch einmal 80 darauf. Dieselbe Zeile steht mit ihrer Begruendung in
        // `DetailView`.
        .ignoresSafeArea()
        .bildgrund(url: treffer.kulisse(breite: 1280))
        // **Solange die Tafel offen ist, ist der Rest kein Fokusziel** — wie
        // beim Mehr-Blatt der Detailseite. `focusSection` ordnet den Fokus
        // nur; ohne die Sperre springt ein Druck nach links aus der Tafel
        // heraus, und sie bleibt offen stehen.
        .disabled(staffelnOffen)
        .overlay(alignment: .topLeading) {
            if staffelnOffen {
                staffeltafel
                    .padding(.leading, Stil.randSeite)
                    .padding(.top, Handlungstafel.unterDerKnopfreihe)
                    .transition(.opacity)
            }
        }
        .animation(Stil.fokusAnimation, value: staffelnOffen)
        .task { detail = await model.seerr.detail(treffer) }
    }

    /// **Derselbe Kopf wie auf einer echten Detailseite.**
    ///
    /// Hier stand eine Titelzeile ohne Bild: die Seite trug nur den gefaerbten
    /// Grund, das Querbild von TMDB sah man nie. Aufbau, Masse und Reihenfolge
    /// sind die von `Detailkopf` — Kulisse rechts, Kopfschatten darueber, der
    /// Textblock links bei 140 + Versatz.
    private var kopf: some View {
        ZStack(alignment: .topLeading) {
            Kulisse(url: treffer.kulisse(breite: 1280))
                .frame(maxWidth: .infinity, alignment: .trailing)

            Kopfschatten()

            block
                .padding(.leading, Stil.randSeite)
                .padding(.top, 140 + Stil.kopfversatzDetail)
        }
        .frame(height: Stil.heldenHoeheDetail, alignment: .topLeading)
        .focusSection()
    }

    /// Titel, Angaben, Beschreibung, Knopf — die Reihenfolge von
    /// `Kopfauskunft`, mit denselben Graden und Hoehen. Der Stand steht in
    /// der Angabenzeile statt in einer eigenen darunter; so bleibt der Knopf
    /// auf der Hoehe, auf der er auf jeder anderen Seite steht — und die
    /// Tafel darunter trifft ihre Stelle.
    private var block: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: treffer.titel)
                .font(.system(size: 60, weight: .bold))
                .tracking(-1.4)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .frame(height: 68, alignment: .leading)

            HStack(spacing: 24) {
                Text(verbatim: nebenzeile)
                    .font(.system(size: 29))
                    .foregroundStyle(Stil.schrift.opacity(0.62))
                    .lineLimit(1)
                belegzeile
            }
            .frame(height: 34)
            .padding(.top, 14)

            Text(verbatim: detail?.beschreibung ?? "")
                .font(.system(size: 29))
                .lineSpacing(Stil.beschreibungLuft)
                .foregroundStyle(Stil.schrift.opacity(0.62))
                .lineLimit(3)
                .padding(.top, 22)
                .frame(width: 1000, height: Stil.beschreibungHoehe(3),
                       alignment: .topLeading)

            handlung.padding(.top, 36)
        }
        .frame(width: 1000, alignment: .topLeading)
    }

    private var nebenzeile: String {
        var teile: [String] = []
        if let jahr = treffer.jahr { teile.append("\(jahr)") }
        if treffer.istSerie {
            let n = detail?.staffeln.count ?? 0
            if n > 0 { teile.append(n == 1 ? String(localized: "1 Staffel")
                                           : String(localized: "\(n) Staffeln")) }
        } else if let m = detail?.laufzeit, m > 0 {
            teile.append(String(localized: "\(m) Min."))
        }
        let gattungen = detail?.genres ?? []
        if !gattungen.isEmpty { teile.append(gattungen.joined(separator: ", ")) }
        if teile.isEmpty {
            teile.append(treffer.istSerie ? String(localized: "Serie")
                                          : String(localized: "Film"))
        }
        return teile.joined(separator: " · ")
    }

    private var belegzeile: some View {
        HStack(spacing: 22) {
            HStack(spacing: 8) {
                Image(systemName: stand.symbol).font(.system(size: 20, weight: .heavy))
                Text(verbatim: stand.wort).font(.system(size: 24, weight: .medium))
            }
            .foregroundStyle(stand.farbe)

            if let b = detail?.bewertung, b > 0 {
                HStack(spacing: 7) {
                    Image(systemName: "star.fill").font(.system(size: 20))
                    Text(verbatim: String(format: "%.1f", b)
                            .replacingOccurrences(of: ".", with: ","))
                        .font(.system(size: 24))
                }
                .foregroundStyle(Stil.schrift.opacity(0.8))
            }
        }
    }

    /// **Ein Stand ist keine Schaltflaeche.** Was wartet oder laedt, laesst
    /// sich nicht noch einmal anfragen; dort steht eine Auskunft.
    @ViewBuilder
    private var handlung: some View {
        if angefragt {
            auskunft(String(localized: "Angefragt. Sobald sie freigegeben ist, lädt sie von selbst."))
        } else if stand.anfragbar {
            VStack(alignment: .leading, spacing: 20) {
                Button(knopftext) { gedrueckt() }
                    .buttonStyle(KnopfStil())
                if let fehler {
                    Text(verbatim: fehler).font(Stil.klein).foregroundStyle(Stil.warnung)
                }
            }
        } else {
            auskunft(stand.hinweis)
        }
    }

    private var knopftext: LocalizedStringKey {
        if laeuft { return "Wird angefragt…" }
        if treffer.istSerie { return "Staffeln wählen" }
        return bestaetigt ? "Wirklich anfragen?" : "Anfragen"
    }

    /// **Zwei Stufen, und die zweite ist der eigentliche Auftrag.** Mit einer
    /// Fernbedienung ist ein Klick besonders schnell passiert.
    ///
    /// Bei einer Serie uebernimmt die Tafel die zweite Stufe: dort wird
    /// gewaehlt, und die letzte Zeile darin loest aus. Vorher trug der Knopf
    /// beide Stufen — er hiess erst „Staffeln waehlen", dann „Anfragen" —,
    /// und die Liste hing als gewoehnlicher Block darunter im Fluss.
    private func gedrueckt() {
        guard !laeuft else { return }
        if treffer.istSerie { staffelnOffen = true; return }
        guard bestaetigt else { bestaetigt = true; return }
        Task { await anfragen() }
    }

    /// **Die Staffelwahl ist eine Tafel, kein Block im Fluss.**
    ///
    /// Sie stand als schlichte Liste unter dem Knopf, mit `.plain`-Knoepfen:
    /// damit malte tvOS seine eigene weisse Fokuspille darueber, die Zeilen
    /// sassen nicht in unserem Raster, und die Menuetaste schloss sie nicht,
    /// weil niemand zuhoerte.
    ///
    /// Aufbau, Breite, Rundung, Schatten und Fokusfuehrung sind die von
    /// `Handlungstafel` — dieselbe Tafel, die auf der Detailseite unter dem
    /// Mehr-Knopf aufgeht. Was sie unterscheidet, ist die Mehrfachwahl: sie
    /// schliesst sich beim Antippen einer Zeile **nicht**, und die letzte
    /// Zeile ist der Auftrag.
    private var staffeltafel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(detail?.staffeln ?? []) { st in
                Button {
                    guard st.stand.anfragbar else { return }
                    if gewaehlt.contains(st.nummer) { gewaehlt.remove(st.nummer) }
                    else { gewaehlt.insert(st.nummer) }
                } label: {
                    staffelzeile(st)
                }
                .buttonStyle(ZeilenStil())
                .focused($ersteZeile, equals: st.nummer)
            }

            Rectangle().fill(Stil.rand).frame(height: 1)

            // **Nie leer abschicken.** Ohne Staffeln bedeutet die Anfrage bei
            // Seerr „alle" — der Fall, den niemand versehentlich ausloesen
            // soll. Solange nichts gewaehlt ist, sagt die Zeile das auch.
            Button {
                guard !gewaehlt.isEmpty else { return }
                staffelnOffen = false
                Task { await anfragen() }
            } label: {
                HStack(spacing: 22) {
                    Image(systemName: "plus").frame(width: 38)
                    Text(gewaehlt.isEmpty ? "Staffel wählen"
                                          : "\(gewaehlt.count) anfragen")
                    Spacer(minLength: 0)
                }
                .foregroundStyle(gewaehlt.isEmpty ? Stil.schriftSehrLeise : Stil.schrift)
            }
            .buttonStyle(ZeilenStil())
        }
        .frame(width: 620)
        .clipShape(RoundedRectangle(cornerRadius: Stil.ecke + 8))
        .background(Stil.erhoeht, in: RoundedRectangle(cornerRadius: Stil.ecke + 8))
        .overlay(RoundedRectangle(cornerRadius: Stil.ecke + 8).strokeBorder(Stil.rand))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 16)
        .focusSection()
        .task { ersteZeile = erstWaehlbare }
        .onExitCommand { staffelnOffen = false }
    }

    /// Die Zeile selbst — als eigener Baustein, damit der Uebersetzer sie in
    /// endlicher Zeit prueft: als ein Ausdruck im `label` brach er ab.
    private func staffelzeile(_ st: Seerrstaffel) -> some View {
        let an = gewaehlt.contains(st.nummer)
        let frei = st.stand.anfragbar
        return HStack(spacing: 22) {
            Image(systemName: zeichen(fuer: st))
                .frame(width: 38)
                .foregroundStyle(an ? Stil.akzent : Stil.schriftSehrLeise)
            Text("Staffel \(st.nummer)")
            Spacer(minLength: 0)
            if st.folgen > 0 {
                Text("\(st.folgen) Folgen")
                    .foregroundStyle(Stil.schriftSehrLeise)
            }
        }
        // Was schon dasteht, ist kein Angebot.
        .foregroundStyle(frei ? Stil.schrift : Stil.schriftSehrLeise)
    }

    /// Kaestchen, Haken, oder der Kringel fuer das, was schon da ist.
    private func zeichen(fuer st: Seerrstaffel) -> String {
        guard st.stand.anfragbar else { return "checkmark.circle" }
        return gewaehlt.contains(st.nummer) ? "checkmark.square.fill" : "square"
    }

    /// Worauf der Fokus faellt, wenn die Tafel aufgeht: die erste Staffel,
    /// die ueberhaupt zu haben ist.
    private var erstWaehlbare: Int? {
        (detail?.staffeln ?? []).first { $0.stand.anfragbar }?.nummer
    }

    @ViewBuilder
    private var besetzung: some View {
        let leute = detail?.besetzung ?? []
        if !leute.isEmpty {
            Text("Besetzung")
                .font(Stil.reihe).foregroundStyle(Stil.schrift)
                .padding(.top, 50)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 28) {
                    ForEach(leute.prefix(12)) { person in
                        Besetzungskachel(bild: person.bild(breite: 300),
                                         name: person.name, rolle: person.rolle)
                    }
                }
            }
            .padding(.top, 20)
        }
    }

    private func auskunft(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Stil.koerper)
            .foregroundStyle(Stil.schriftLeise)
            .frame(width: 900, alignment: .leading)
            .padding(.vertical, 20).padding(.horizontal, 24)
            .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.ecke))
    }

    private func anfragen() async {
        fehler = nil
        laeuft = true
        defer { laeuft = false }
        do {
            // Leer heisst alle — Seerr versteht das Wort `all`.
            // **Nie leer.** `nil` bedeutet bei Seerr „alle Staffeln", und das
            // ist der Fall, den niemand versehentlich ausloesen soll — wer
            // nur nachsieht, welche es gibt, fragt sonst die ganze Serie an.
            guard !gewaehlt.isEmpty else { return }
            let staffeln = Array(gewaehlt).sorted()
            try await model.seerr.anfragen(treffer, staffeln: staffeln)
            angefragt = true
            stand = .wartetAufFreigabe
        } catch {
            fehler = error.localizedDescription
        }
    }
}
