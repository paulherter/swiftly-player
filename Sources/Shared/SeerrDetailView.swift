import JellyfinKit
import SwiftUI

/// Die Seite eines Titels, den der eigene Server noch nicht hat.
///
/// **Dieselbe Seite wie sonst, nur eine andere Handlung.** Getauscht ist der
/// grosse Knopf — aus *Fortsetzen* wird *Anfragen* — und die Reiter: es gibt
/// keine Folgen zu zeigen, wohl aber Besetzung und Vorschlaege.
///
/// **Der Aufbau ist der der Serienseite, Zeile fuer Zeile**, und das ist
/// keine Bequemlichkeit, sondern die Lehre aus drei Runden. Wer die Seite
/// nachbaut, trifft die Abstaende nicht: der Kopf sass tiefer, das Bild hing
/// beim Scrollen fest, oben stand ein Verlauf, den es dort nie gab. Jede
/// dieser drei Abweichungen war ein Baustein, der schon dalag und nicht
/// benutzt wurde — `Heldbild` misst sich im Raum „blatt", `Detailkopf`
/// bringt seinen eigenen, sehr viel schwaecheren Verlauf mit, und
/// `.ignoresSafeArea(edges: .top)` ist der Grund, warum das Bild ueberhaupt
/// bis nach oben laeuft.
///
/// Was hier abweicht, weicht mit Absicht ab und steht als Kommentar dabei.
struct SeerrDetailView: View {
    let model: AppModel
    let treffer: Seerrtreffer

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit

    /// Wie weit gescrollt wurde — der Kopf blendet danach ein. Wie dort.
    /// Wie hoch die Staffelliste zusammen ist — gemessen, damit das Blatt
    /// nicht hoeher wird als sein Inhalt.
    @State private var listenhoehe: CGFloat = 0
    @State private var versatz: CGFloat = 0

    @State private var stand: Seerrstand
    @State private var laeuft = false
    @State private var fehler: String?
    @State private var angefragt = false
    @State private var detail: Seerrdetail?
    /// **Der Unterschied, den die Seite bisher nicht kannte.** `detail` blieb
    /// bei einem stummen Jellyseerr auf `nil`, und Beschreibung, Staffeln,
    /// Besetzung und Ähnliches verschwanden wortlos — die Seite sah aus wie
    /// ein Titel, über den es nichts zu sagen gibt.
    @State private var detailGestoert = false
    /// Welche Staffeln angekreuzt sind. Leer heisst **alle** — so wie beim
    /// ersten Oeffnen, wo niemand etwas ausgewaehlt hat.
    @State private var gewaehlt: Set<Int> = []
    @State private var blattOffen = false
    /// **Hat der Nutzer schon einmal gedrueckt?** Bei einem Film ist die
    /// Anfrage sonst einen Fingerbreit entfernt Bei einer Serie fragt das
    /// Staffelblatt ohnehin nach, das ist dort der zweite Schritt.
    @State private var bestaetigt = false
    /// Welche der vier Bestaetigungen gerade dasteht. Wird beim Antippen
    /// gezogen, nicht beim Zeichnen.
    @State private var fassung = 0

    init(model: AppModel, treffer: Seerrtreffer) {
        self.model = model
        self.treffer = treffer
        _stand = State(initialValue: treffer.stand)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // **Breit derselbe Kopf wie eine echte Detailseite.**
                    //
                    // Hier stand auch im Querformat der schmale Aufbau: ein
                    // Streifen ueber die ganze Breite, Titel darunter, Knopf
                    // darunter. Auf einem 1000 Punkt breiten Fenster ist das
                    // der Briefschlitz, gegen den `Heldkopf` gebaut wurde —
                    // und die Seite stand damit neben Film und Serie wie aus
                    // einer anderen App. Auf dem Mac ist genau das der
                    // Unterschied: Plakat und Text nebeneinander, die
                    // Beschreibung als eigener Block darunter.
                    //
                    // Kein Fortschritt: was es hier noch nicht gibt, hat auch
                    // niemand halb gesehen.
                    if breit {
                        Heldkopf(bild: treffer.kulisse(),
                                 poster: treffer.plakat(),
                                 titel: treffer.titel,
                                 nebenzeile: nebenzeile) {
                            VStack(alignment: .leading, spacing: 14) {
                                belegzeile
                                hauptknopf
                            }
                        }
                        beschreibung
                            .frame(maxWidth: Stil.lesebreite, alignment: .leading)
                            .padding(.horizontal, Stil.randSeiteBreit)
                            .padding(.top, 18)
                            .padding(.bottom, 22)
                    } else {
                    hero

                    VStack(alignment: .leading, spacing: 14) {
                        belegzeile
                        hauptknopf
                        beschreibung
                    }
                    .padding(.horizontal, Stil.rand(breit: breit))
                    .padding(.top, 14)
                    }

                    // **Zwei Reihen, keine Reiter.** Genau wie auf der
                    // Filmseite: eine Reihe Besetzung, darunter eine Reihe
                    // Aehnliches. Als Reiter mit Raster stand hier eine Wand
                    // aus zwanzig Koepfen Waagerecht zeigt eine Reihe fuenf
                    // und deutet den Rest an; wer mehr will, schiebt.
                    besetzung
                    aehnlichesreihe
                    if detailGestoert {
                        // Hier steht Seerrs Adresse, nicht die des eigenen
                        // Servers: der eigene laeuft, sonst waere man nicht
                        // auf dieser Seite.
                        Stoerhinweis(model: model, erneut: { Task { await detailLaden() } },
                                     adresse: model.seerr.adresse)
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            // Der Raum, in dem `Heldbild` seine Dehnung misst. Fehlte er,
            // blieb das Bild beim Scrollen stehen, statt mitzugehen.
            .coordinateSpace(.named("blatt"))
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
                versatz = neu
            }
            // Ohne das steht ueber dem Bild der schwarze Streifen des
            // sicheren Bereichs.
            .ignoresSafeArea(edges: .top)

            // **Unser eigenes Blatt, nicht das des Systems.** Ein `.sheet`
            // bringt seine eigene Sprache mit — abgerundete Ecken oben,
            // Griff, Navigationsleiste — und stand damit neben „Mehr" und
            // den Wiedergabelisten wie aus einer anderen App.
            if let fehler {
                Hinweisstreifen(text: fehler) { self.fehler = nil }
                    .zIndex(21)
            }

            Detailkopf(titel: treffer.titel, versatz: versatz) { zurueck() }
        }
        // Welche Staffeln — als Blatt von unten, an der Seite und nicht im
        // Stapel: ein Blatt ist ein Modifikator.
        .blatt(offen: $blattOffen) { staffelblatt }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        // **Die Frage steht nicht ewig.** Wer den Knopf einmal antippt und
        // dann weiterliest, soll nicht Minuten spaeter einen Knopf vorfinden,
        // der beim naechsten Tipp sofort anfragt.
        .task(id: bestaetigt) {
            guard bestaetigt else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            bestaetigt = false
        }
        // **Nichts vorausgewaehlt.** „Man laedt ja nie alle runter im
        // Normalfall" — wer alles will, kreuzt alles an; wer eine will, muss
        // nicht erst acht abwaehlen.
        .task { await detailLaden() }
    }

    private func detailLaden() async {
        let geholt = await model.seerr.detail(treffer)
        detailGestoert = geholt == nil
        if let geholt { detail = geholt }
    }

    // MARK: Teile

    /// Wortgleich mit `SeriesDetailView.hero`, nur mit dem Querbild von TMDB
    /// statt dem des eigenen Servers.
    private var hero: some View {
        Heldbild(url: treffer.kulisse())
            .overlay(alignment: .bottom) { Heldauslauf() }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: treffer.titel)
                        .font(Stil.titel)
                        .tracking(Stil.sperrungTitel)
                        .foregroundStyle(Stil.schrift)
                    Text(verbatim: nebenzeile)
                        // Jahr, Laufzeit, Genre sind eine Angabe: 12, wie
                        // unter jedem anderen Heldbild. Vorher 13 Regular —
                        // eine Stufe, die es nicht gibt.
                        .font(Stil.klein)
                        .foregroundStyle(Stil.schriftLeise)
                        .lineLimit(1)
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.bottom, 16)
            }
    }

    /// Jahr, Staffeln oder Laufzeit, Gattungen — dieselbe Reihenfolge wie
    /// dort.
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

    /// **Wirklich dieselbe Zeile wie dort.** Sie stand hier ein zweites Mal
    /// nachgebaut, mit denselben Zahlen — Symbol 11 heavy, Wort 13 medium,
    /// Abstaende 6 und 14. Jetzt reicht die Seite nur noch Symbol, Wort und
    /// Farbe hinein; die Masse stehen an einer Stelle.
    ///
    /// **Null ist keine Bewertung.** TMDB liefert bei einem unbewerteten
    /// Titel eine Null, und daraus wuerde „★ 0,0" — eine Auskunft, die
    /// falsch ist. Deshalb faellt sie hier heraus und nicht erst dort.
    private var belegzeile: some View {
        Belegzeile(bewertung: (detail?.bewertung).flatMap { $0 > 0 ? $0 : nil },
                   eigen: (symbol: stand.symbol, wort: stand.wort, farbe: stand.farbe))
    }

    /// **Ein Stand ist keine Schaltflaeche.**
    ///
    /// Was wartet oder laedt, laesst sich nicht noch einmal anfragen; dort
    /// steht eine Auskunft statt eines grauen Knopfes.
    ///
    /// Der Stapel ringsum ist der von `SeriesDetailView.hauptknopf` —
    /// derselbe `VStack(spacing: 9)`, damit die Zeile darunter auf derselben
    /// Hoehe sitzt wie dort „Noch 25 Minuten".
    @ViewBuilder
    private var hauptknopf: some View {
        VStack(alignment: .leading, spacing: 9) {
            if angefragt {
                auskunft(String(localized: "Angefragt. Sobald sie freigegeben ist, lädt sie von selbst."))
            } else if stand.anfragbar {
                Button(action: gedrueckt) {
                    HStack(spacing: 8) {
                        // Kein Ring: der Text sagt „Wird angefragt…".
                        Image(systemName: bestaetigt ? "checkmark" : "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .opacity(laeuft ? 0.5 : 1)
                        Text(knopftext)
                    }
                }
                // **Derselbe Knopf wie „Fortsetzen", ohne Wenn und Aber.**
                // Er war einmal in Akzent — aber der Stand darueber traegt
                // ihn schon, und zweimal dieselbe Farbe auf einer Seite macht
                // aus einem Zeichen fuer Zustand eine Grundfarbe. Was ihn
                // unterscheidet, ist das Wort darauf.
                //
                // Hoehe, Ecke und Schriftgrad stehen im Stil und nicht hier —
                // ein nachgebauter Knopf sass sichtbar tiefer und runder.
                .buttonStyle(HauptknopfStil(dehnt: !breit))
                .disabled(laeuft)
                // Der Wechsel der Beschriftung soll zu sehen sein, sonst
                // liest niemand, dass sich etwas geaendert hat.
                .animation(.snappy(duration: 0.18), value: bestaetigt)
            } else {
                auskunft(stand.hinweis)
            }
        }
    }

    /// **Die zweite Stufe sagt, was zu tun ist.**
    ///
    /// Vorher stand dort „Wirklich anfragen?" — Paul am 21.09.: „Man versteht
    /// nicht, dass man nochmal drücken muss." Ein Knopf, auf dem eine Frage
    /// steht, ist eine Frage ohne Antwort: man weiss nicht, ob Druecken
    /// bestaetigt oder abbricht. Jede Fassung faengt deshalb mit „Nochmal" an
    /// — die Anweisung vorn, die Pointe dahinter.
    ///
    /// Vier Fassungen, und gewuerfelt wird **einmal**, beim Antippen: sonst
    /// wechselte der Text unter dem Finger, sobald die Ansicht neu zeichnet.
    /// Dieselbe zweimal hintereinander kommt nicht.
    ///
    /// Kein Emoji: das Zeichen bleibt der Haken, und die Laune steckt im Wort.
    /// Sobald Seerr ein Zuruecknehmen kann, faellt die Rueckfrage ganz weg —
    /// dann geschieht die Anfrage sofort und bietet „Rueckgaengig" an, so wie
    /// es in `BRAND.md` steht. Dafuer fehlt im Modell der Aufruf zum
    /// Zurueckziehen; solange er fehlt, waere ein Tipp ohne Rueckfrage nicht
    /// umkehrbar.
    private static let bestaetigungen: [LocalizedStringResource] = [
        "Nochmal, dann läuft’s", "Nochmal — ab die Post",
        "Nochmal, dann frag ich", "Nochmal, her damit"
    ]

    private var knopftext: String {
        if laeuft { return String(localized: "Wird angefragt…") }
        guard bestaetigt else { return String(localized: "Anfragen") }
        return String(localized: Self.bestaetigungen[fassung])
    }

    /// **Zwei Stufen, und die zweite ist der eigentliche Auftrag.**
    ///
    /// Bei einer Serie uebernimmt das Staffelblatt die zweite Stufe: dort
    /// steht noch einmal, was angefragt wird, und der Knopf darin loest aus.
    /// Ein Film hat nichts auszuwaehlen — deshalb fragt hier der Knopf
    /// selbst nach, statt ein Blatt zu oeffnen, das nur eine Frage enthaelt.
    private func gedrueckt() {
        if treffer.istSerie {
            blattOffen = true
            return
        }
        guard bestaetigt else {
            // Einmal wuerfeln, und nicht dieselbe wie zuletzt.
            let andere = (0 ..< Self.bestaetigungen.count).filter { $0 != fassung }
            fassung = andere.randomElement() ?? 0
            bestaetigt = true
            return
        }
        Task { await anfragen() }
    }

    @ViewBuilder
    private var beschreibung: some View {
        if let text = detail?.beschreibung {
            Klapptext(text: text)
        }
    }

    /// Wortgleich mit `ItemDetailView.besetzung`, nur mit den Koepfen von
    /// TMDB statt denen des eigenen Servers — samt der Grenze bei zwoelf.
    ///
    /// Kein Pfeil daneben: eine Seite mit der vollen Besetzung gibt es hier
    /// nicht, und ein Pfeil waere das Versprechen, dass es sie gaebe.
    @ViewBuilder
    private var besetzung: some View {
        let leute = detail?.besetzung ?? []
        if !leute.isEmpty {
            Abschnitt(titel: "Besetzung") {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(leute.prefix(12)) { person in
                        Besetzungskachel(bild: person.bild(), name: person.name,
                                         rolle: person.rolle)
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
            }
        }
    }

    /// Dieselbe Reihe wie dort — mit `Seerrkachel` statt `PosterTile`, weil
    /// auch das Vorgeschlagene nicht auf dem Server liegt und blass gehoert.
    ///
    /// Das feste Mass steht hier und nicht in der Kachel: im Raster der Suche
    /// bekommt sie ihre Breite von der Spalte, in einer Reihe hat sie keine.
    @ViewBuilder
    private var aehnlichesreihe: some View {
        let andere = detail?.aehnliches ?? []
        if !andere.isEmpty {
            Abschnitt(titel: "Ähnliche Titel") {
                HStack(alignment: .top, spacing: Stil.kachelAbstand) {
                    ForEach(andere) { t in
                        NavigationLink(value: t) {
                            Seerrkachel(treffer: t).frame(width: Stil.kachelBreite)
                        }
                        .buttonStyle(Stil.Druckknopf())
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
            }
        }
    }

    // MARK: Stand in Worten

    // Symbol, Wort, Farbe und Hinweis stehen in `Seerrmarke.swift` — dieselbe
    // Tabelle, aus der auch die Kachel liest. Hier stand sie ein zweites Mal,
    // mit anderen Symbolen und anderen Farben.

    private func auskunft(_ text: String) -> some View {
        Text(verbatim: text)
            // **Mitwachsend, nicht fest** — BRAND.md, Abschnitt 2. Gilt für die
            // Auskunft, die Staffelzeilen und den Knopf im Blatt; ihre Höhen
            // sind deshalb Mindesthöhen. Fest bleiben der Seitentitel über dem
            // Heldbild und seine Nebenzeile: die Leiste dort trägt ein Bild.
            .mitwachsend(15)
            .foregroundStyle(Stil.schriftLeise)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 13).padding(.horizontal, 14)
            // Flaechenmass, nicht Feldmass: der Kasten ist eine Flaeche,
            // kein Eingabefeld. Er stand auf 10, weil das die Zahl war, die
            // gerade in der Naehe stand.
            .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.eckeFlaeche, style: .continuous))
    }

    // MARK: Staffeln

    /// Die Staffeln zum Ankreuzen.
    ///
    /// **Was schon da ist, laesst sich nicht ankreuzen** — und sagt daneben,
    /// dass es da ist. Ein Kaestchen, das man druecken darf und das nichts
    /// bewirkt, ist schlimmer als keines.
    @ViewBuilder
    private var staffelliste: some View {
        ForEach(detail?.staffeln ?? []) { st in
            Button {
                guard st.stand.anfragbar else { return }
                if gewaehlt.contains(st.nummer) { gewaehlt.remove(st.nummer) }
                else { gewaehlt.insert(st.nummer) }
            } label: {
                HStack(spacing: 10) {
                    Text("Staffel \(st.nummer)")
                        .mitwachsend(15)
                        .foregroundStyle(st.stand.anfragbar ? Stil.schrift
                                                            : Stil.schriftSehrLeise)
                    if st.folgen > 0 {
                        Text("· \(st.folgen) Folgen")
                            .mitwachsend(12).foregroundStyle(Stil.schriftSehrLeise)
                    }
                    Spacer(minLength: 8)
                    if st.stand.anfragbar {
                        Image(systemName: gewaehlt.contains(st.nummer)
                                ? "checkmark.square.fill" : "square")
                            .font(.system(size: 17))
                            .foregroundStyle(gewaehlt.contains(st.nummer)
                                ? Stil.akzent : Stil.schriftSehrLeise)
                    } else {
                        Text(st.stand == .da ? "vorhanden" : "unterwegs")
                            .mitwachsend(12).foregroundStyle(Stil.schriftSehrLeise)
                    }
                }
                .padding(.horizontal, Stil.randAbstand)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(Stil.Druckzeile())
            // Das Kreuz im Kaestchen ist der Akzent, und der Akzent ist
            // Farbe: vorgelesen klang eine angekreuzte Staffel wie jede
            // andere. `.isSelected` sagt den Zustand mit.
            .accessibilityAddTraits(gewaehlt.contains(st.nummer) ? .isSelected : [])
        }
    }

    /// Was im Blatt steht. Rumpf, Bewegung und Griff kommen von
    /// ``Blattmodifikator``.
    @ViewBuilder
    private var staffelblatt: some View {
        Blattrubrik(text: Text("Welche Staffeln?"))

        ScrollView {
            VStack(spacing: 0) { staffelliste }
                // Gemessen, nicht angenommen.
                .onGeometryChange(for: CGFloat.self) { $0.size.height }
                    action: { listenhoehe = $0 }
        }
        // **So hoch wie die Staffeln, hoechstens 320.**
        //
        // Hier stand `.frame(maxHeight: 320)`, und das reicht nicht: eine
        // `ScrollView` ist senkrecht gierig und nimmt sich die 320 auch dann,
        // wenn drei Staffeln nur 150 brauchen. Uebrig blieb ein Hohlraum von
        // gut zwei Zentimetern unter der letzten Zeile, der nichts tut. Paul
        // am 22.09.: „da sind so 2 cm frei, als waere da etwas, was aber eben
        // nicht da ist."
        //
        // Dieselbe Rechnung wie im `Auswahlblatt`, wo sie samt Begruendung
        // schon steht.
        .frame(height: min(listenhoehe, 320))
        .scrollIndicators(.hidden)

        // Über die volle Breite, weil der Knopf darunter es auch ist.
        Blattlinie()

        Button {
            blattOffen = false
            Task { await anfragen() }
        } label: {
            Text(gewaehlt.isEmpty ? "Staffel wählen"
                                  : "\(gewaehlt.count) anfragen")
                .mitwachsend(15, .semibold)
                .foregroundStyle(gewaehlt.isEmpty ? Stil.schriftSehrLeise : Stil.akzent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 54)
        }
        .buttonStyle(Stil.Druckzeile())
        .disabled(gewaehlt.isEmpty)
    }

    private func anfragen() async {
        fehler = nil
        laeuft = true
        defer { laeuft = false }
        do {
            // Leer heisst alle — Seerr versteht das Wort `all`, und wer
            // nichts angekreuzt hat, will nicht nichts.
            // **Nie leer.** `nil` bedeutet bei Seerr „alle Staffeln", und das
            // ist der Fall, den niemand versehentlich ausloesen soll — wer
            // nur nachsieht, welche es gibt, fragt sonst die ganze Serie an.
            //
            // **Nur für Serien.** Ein Film hat keine Staffeln, `gewaehlt` ist
            // dort immer leer — der Wächter warf ihn stillschweigend hinaus,
            // und der Druck auf „Anfragen" tat gar nichts.
            let staffeln: [Int]?
            if treffer.istSerie {
                guard !gewaehlt.isEmpty else { return }
                staffeln = Array(gewaehlt).sorted()
            } else {
                staffeln = nil
            }
            try await model.seerr.anfragen(treffer, staffeln: staffeln)
            angefragt = true
            stand = .wartetAufFreigabe
        } catch {
            fehler = lesbarerFehler(error)
        }
    }
}
