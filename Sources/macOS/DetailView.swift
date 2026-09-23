import AppKit
import JellyfinKit
import SwiftUI

/// Die Detailseite. Film und Serie tragen **denselben Kopf** — das ist auf dem
/// iPhone so entschieden und gilt hier unverändert. Verschieden ist nur, was
/// darunter steht.
struct DetailView: View {
    let model: AppModel
    let item: Item
    let zurueck: () -> Void

    @State private var voll: Item?

    /// **Der volle Satz, sobald er da ist.**
    ///
    /// Hier stand ein Riegel: bis die Seite steht, zeigte sie nur den mageren
    /// Listeneintrag, dann schaltete sie um. Das war falsch herum gedacht.
    /// Die Listenabfrage liefert nur `Overview` und das Seitenverhältnis —
    /// Beschreibung, Bewertung, Freigabe, Genres und Laufzeit erschienen
    /// dadurch **alle im selben Bild**, siebzig Millisekunden nachdem die
    /// Bewegung fertig war. Genau dieser Schlag liest sich als „und zack, ist
    /// es da".
    ///
    /// Der Kopf hat feste Plätze — es wandert nichts, wenn ein Text
    /// nachkommt. Also darf er kommen, wann er kommt.
    private var titel: Item { voll ?? item }

    var body: some View {
        Group {
            // **Nach `item.type` verzweigen, nicht nach `titel.type`.** Die
            // Art steht schon in der Liste; nach dem nachgeladenen Satz zu
            // verzweigen hiess, den Zweig unterwegs wechseln zu können — und
            // damit die halbe Seite wegzuwerfen und neu zu bauen.
            switch item.type {
            case "Series":
                SerienView(model: model, serie: titel, zurueck: zurueck)
            case "Episode":
                // **Eine Folge bekommt keine eigene Seite** (A8). Sie trüge
                // nichts, was nicht in der Folgenliste schon steht. Also die
                // Serie nachholen und deren Seite zeigen, mit der Staffel der
                // Folge bereits gewählt.
                StaffelZiel(model: model, folge: titel, zurueck: zurueck)
            default:
                FilmView(model: model, film: titel, zurueck: zurueck)
            }
        }
        .task { if voll == nil { voll = await model.item(id: item.id) } }
        // Nach dem Player den Titel neu holen — er liegt als Ebene darüber,
        // `.task` läuft nicht neu. Siehe `AppModel.wiedergabeBeendet`.
        .onChange(of: model.seitenAuffrischen) { _, _ in
            Task { if let neu = await model.item(id: item.id) { voll = neu } }
        }
    }
}

/// Der Zwischenschritt von einer Folge zur Serienseite.
struct StaffelZiel: View {
    let model: AppModel
    let folge: Item
    let zurueck: () -> Void

    @State private var serie: Item?
    /// **Die Staffel frisch holen, nicht die der Kachel glauben.**
    ///
    /// Der Listeneintrag traegt die Staffel, die er beim Laden der Startseite
    /// hatte. Wer eine Staffel zu Ende sieht und die naechste dazulegt, hat
    /// dort weiter die alte stehen — die Seite oeffnete dann mit „Abspielen
    /// S6E1" oben und Staffel 5 in der Folgenliste. Dasselbe Muster wie bei
    /// der Fortsetzstelle in `HomeView.starte`, und dieselbe Abhilfe.
    @State private var frischeStaffelID: String?
    @State private var frischeStaffelnummer: Int?
    /// **Und die Nummer mit.**
    ///
    /// Hier stand nur die Kennung; die Nummer kam weiter von der Kachel. Das
    /// reicht nicht: am Geraet gemessen liefert der Server an einer Folge
    /// nicht immer eine `SeasonId` (steht so in A10), und dann traegt allein
    /// die Nummer den Vergleich — die veraltete. Genau die Fehlerform, die
    /// A10 als behoben beschreibt, nur eine Stufe weiter unten. Linux frischt
    /// beides auf, iPhone und Mac frischten nur die Kennung auf.

    /// **Was vorgeholt ist, steht sofort** — dann gibt es die leere Seite gar
    /// nicht erst. Nachgereicht käme der Wert zu spät: der leere Durchgang
    /// hat dann schon stattgefunden, und der ist das, was man sieht.
    @MainActor init(model: AppModel, folge: Item, zurueck: @escaping () -> Void) {
        self.model = model
        self.folge = folge
        self.zurueck = zurueck
        _serie = State(initialValue: Serienspeicher.geteilt.serie(fuer: folge, mit: model))
    }

    var body: some View {
        Group {
            if let serie {
                SerienView(model: model, serie: serie,
                           startStaffelID: frischeStaffelID ?? folge.seasonId,
                           startStaffelNummer: frischeStaffelnummer ?? folge.parentIndexNumber,
                           zurueck: zurueck)
            } else {
                // Kein Ring: die Seite kommt gleich von selbst.
                Color.clear
            }
        }
        .task {
            guard let id = folge.seriesId else { return }
            async let frisch = model.item(id: folge.id)
            if serie == nil {
                let geholt = await model.item(id: id)
                if let geholt { Serienspeicher.geteilt.merken(geholt) }
                serie = geholt
            }
            let f = await frisch
            frischeStaffelID = f?.seasonId
            frischeStaffelnummer = f?.parentIndexNumber
        }
    }
}

// MARK: - Film

struct FilmView: View {
    let model: AppModel
    let film: Item
    let zurueck: () -> Void

    @State private var farbe = Bildfarbe()

    @State private var extras: [Item] = []
    @State private var aehnliche: [Item] = []
    @State private var sammlungsreihen: [Sammlungsreihe.Reihe] = []
    @State private var kopfstand = Kopfstand()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Heldenkopf(model: model, titel: film, stand: kopfstand)
                    // **Der Kopf malt über das, was unter ihm steht.**
                    //
                    // Ohne das liegt das Mehr-Menü hinter Reiterreihe und
                    // Folgenliste: die kommen im Stapel nach dem Kopf, also
                    // malen sie später und damit darüber. Man sah beides
                    // ineinander.
                    .zIndex(1)

                VStack(alignment: .leading, spacing: 26) {
                    // Die Beschreibung steht im Kopf, wie auf dem Apple TV —
                    // hier stünde sie ein zweites Mal.
                    Besetzungsreihe(model: model, leute: film.darsteller,
                                    herkunft: film.name)
                    // Extras und Ähnliches fehlten auf meiner Filmseite ganz.
                    // Reihenfolge wie auf iOS (A9).
                    Titelreihe(titel: "Extras", eintraege: extras, model: model)
                    // Über „Ähnliches": die Sammlung ist die nähere
                    // Verwandtschaft. Nur bei Titeln, die in einer stehen.
                    ForEach(sammlungsreihen, id: \.sammlung.id) { reihe in
                        Sammlungsreihe(model: model, reihe: reihe,
                                       art: Bibliotheksgattung.art(zuTyp: film.type))
                    }
                    Titelreihe(titel: "Ähnliches", eintraege: aehnliche, model: model)
                    if let quelle = film.mediaSources?.first {
                        Dateizeile(quelle: quelle)
                    }
                }
                .padding(.horizontal, Stil.randAbstand)
                .padding(.top, 26)
            }
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
        // **Der Inhalt läuft bis unter die Titelleiste durch.** SwiftUI rückt
        // ihn sonst um deren Sicherheitsbereich ein, und über dem Bild stand
        // ein dunkler Streifen. Die iPhone-Fassung tut dasselbe.

        // **Auch hier, nicht nur am Stapel.** `NavigationStack` bekommt den
        // Riegel in `HauptView`; für eine geschobene Ansicht stellt SwiftUI
        // den Werkzeugleisten-Grund trotzdem wieder dazu — als milchige
        // Leiste über dem Bild. E4 gilt auch für das, was das Rahmenwerk
        // ungefragt beisteuert.
        .toolbar(.hidden)
        .toolbarBackground(.hidden, for: .windowToolbar)
        // **Der Ton endet mit dem Heldbild, nicht 260 Punkt darunter.**
        //
        // Er lief bis `heldHoehe + 260` weiter, „wie bei Apple TV, wo die
        // ganze Seite vom Bild eingefaerbt wirkt". Auf dem Mac steht die
        // Knopfreihe aber **neben** dem Abspielknopf, also mitten in diesem
        // Auslauf — auf dem iPhone steht dieselbe Reihe **unter** dem Bild auf
        // reinem `grund`. Die Knoepfe tragen auf beiden Plattformen exakt
        // `flaeche` #262626; derselbe Grauton wirkt auf einem farbigen Grund
        // aber wie eine andere Farbe. Paul am 22.09.: „Das sind nicht
        // dieselben, so wie ich das sehe."
        //
        // Endet der Verlauf mit dem Bild, kommen an der Mitte der Knopfreihe
        // (356 von 380) noch 0,068 an — praktisch `grund` (0,063). Oben bleibt
        // der Ton voll.
        .background(alignment: .top) {
            LinearGradient(colors: [farbe.ton, Stil.grund],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Stil.heldHoehe)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Stil.grund)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
            kopfstand.versatz = neu
        }
        .overlay(alignment: .top) {
            Detailkopf(titel: film.name, stand: kopfstand, zurueck: zurueck)
        }
        .task { await farbe.laden(model.kopfbildURL(for: film)) }
        .task {
            async let a = model.extras(film)
            async let b = model.aehnliche(film)
            extras = (await a) ?? []
            aehnliche = (await b) ?? []
        }
        .task(id: "\(film.id)|\(model.kontowechsel)") {
            let gefunden = await Sammlungsreihe.laden(model, titel: film)
            withAnimation(Stil.einblenden) { sammlungsreihen = gefunden }
        }
    }
}

/// Eine waagerechte Reihe von Postern mit Überschrift — Extras, Ähnliches.
struct Titelreihe: View {
    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich
    let titel: LocalizedStringKey
    let eintraege: [Item]
    let model: AppModel

    var body: some View {
        if !eintraege.isEmpty {
            // Reihenueberschrift: 20 Semifett in `schrift`, 12 Abstand zur
            // Reihe (BAUTEILE 8). 16 stand in keiner Leiter.
            VStack(alignment: .leading, spacing: 12) {
                Reihentitel(text: titel)
                Blätterreihe(rand: 0) {
                    ForEach(eintraege, id: \.id) { eintrag in
                        Button { navigator.oeffne(.titel(eintrag), in: bereich) } label: {
                            Posterkachel(titel: eintrag.name,
                                         zweitzeile: eintrag.productionYear.map { "\($0)" },
                                         bild: model.imageURL(for: eintrag, hochkant: true),
                                         fortschritt: eintrag.userData?.playedPercentage.map { $0 / 100 },
                                         marke: Anzeigeregeln.kachelmarke(
                                         art: eintrag.type,
                                         staffeln: eintrag.childCount,
                                         gesehen: eintrag.userData?.played,
                                         offeneFolgen: eintrag.userData?.unplayedItemCount),
                                         zeichen: eintrag.type == "Series" ? "tv" : "film")
                        }
                        .buttonStyle(Stil.Druckknopf())
                    }
                }
            }
        }
    }
}


// MARK: - Der gemeinsame Kopf

/// Das Heldenbild mit allem darin: Poster, Titel, Beleg, Hauptknopf,
/// Aktionsreihe. Nicht zu verwechseln mit `Detailkopf` — das ist die Leiste
/// mit Pfeil und Titel, die beim Scrollen einblendet.
///
/// Die Reihenfolge ist die der iPhone-Fassung: Beleg → Hauptknopf →
/// Aktionsreihe. Was sich ändert, ist die Anordnung, nicht die Folge — im
/// Fenster steht das Poster **neben** dem Titel statt darüber, weil eine 1400
/// Punkt breite Spalte mit einer Zeile Text darin unlesbar wäre.
struct Heldenkopf: View {
    let model: AppModel
    let titel: Item
    /// Wo die Seite steht — nur fürs Mitziehen des Bildes gebraucht.
    let stand: Kopfstand
    /// **Welche Staffel gerade offen ist** — für „Staffel als gesehen" in der
    /// Mehr-Liste.
    ///
    /// Hier stand an der Aufrufstelle fest `staffel: nil`, und damit fehlte
    /// der Eintrag auf dem Mac als einziger Plattform: iPhone
    /// (`Shared/SeriesView.swift:950`) und Fernseher
    /// (`tvOS/SerienView.swift:477`) reichen ihn durch, und Linux hat ihn
    /// ebenfalls. Der Kopf weiss die Staffel nicht von selbst — sie steht
    /// eine Ebene tiefer in `SerienView` —, also kommt sie von dort.
    var staffel: Item? = nil
    /// **Was der Ladeknopf auf einer Serienseite tut.**
    ///
    /// Auf dem iPhone steht auf **jeder** Film- und Serienseite ein Knopf zum
    /// Laden in der Reihe unter dem Abspielknopf; bei einer Serie oeffnet er
    /// die Auswahl (ganze Serie, Staffel, einzelne Folge). Hier war der Knopf
    /// an `titel.type != "Series"` gebunden — auf der Serienseite gab es ihn
    /// also gar nicht, und das Laden hing allein an einem Chip neben der
    /// Staffelwahl, an dem niemand sucht. Paul am 22.09.: „Der Laden-Knopf
    /// existiert nicht."
    ///
    /// Die Auswahl selbst braucht Staffeln und vorgeladene Folgen und steht
    /// deshalb weiter in `SerienView`; der Kopf kennt nur den Knopf und
    /// meldet den Klick nach oben. Bei einem Film bleibt es beim Kopf selbst:
    /// dort gibt es nichts zu waehlen, und die Ladetafel haengt direkt am
    /// Knopf.
    var ladeauswahl: (() -> Void)? = nil
    /// Ob die Ladeauswahl offen ist — der Knopf traegt den Zustand, wie der
    /// Mehr-Knopf daneben.
    var auswahlOffen: Bool = false

    /// **Wie weit über den oberen Rand hinausgezogen wurde.**
    ///
    /// Zieht man weiter nach oben, als es Inhalt gibt, wird der Versatz
    /// negativ. Der ganze Inhalt rutscht dabei um diesen Betrag nach unten —
    /// und genau dort entsteht die Lücke, die das Kopfbild füllen soll.
    ///
    /// Gedeckelt: irgendwann soll es aufhören. Bis 200 Punkt geht es mit,
    /// darüber steht es. So weit zieht man nur mit Absicht, und die Feder
    /// der Scrollfläche ist dort ohnehin schon straff.
    private var zug: CGFloat { min(max(0, -stand.versatz), 200) }

    @State private var plan: PlaybackPlan?
    @State private var spielbarerTitel: Item?
    @State private var merkliste = false
    @State private var gesehen = false
    @State private var mehrOffen = false
    @State private var ladetafelOffen = false
    @State private var meldung: String?
    @Environment(Abspielsteuerung.self) private var steuerung

    // MARK: Downloads

    /// Was von diesem Titel schon auf der Platte liegt — `nil` heisst nichts.
    private var geladen: Downloadposten? { model.downloads.posten(fuer: titel.id) }

    /// Gefuellt heisst geladen, und es bleibt ein Pfeil: der Haken gehoert
    /// der Frage „hab ich das gesehen".
    private var ladezeichen: String {
        switch geladen?.stand {
        case nil:          "arrow.down"
        case .fertig:      "arrow.down.circle.fill"
        case .fehler:      "exclamationmark.circle"
        default:           "arrow.down.circle"
        }
    }

    /// Der Eintrag, den ein Download bekaeme. Die Groesse kommt aus derselben
    /// Quelle, die der Player naehme — **H2**, es ist dieselbe Datei.
    private var alsPosten: Downloadposten? {
        guard let konto = model.session?.userID else { return nil }
        let quelle = plan?.quelle ?? titel.mediaSources?.first
        return Downloadposten(
            id: titel.id, konto: konto, art: .film, titel: titel.name,
            laufzeitTicks: titel.runTimeTicks, container: quelle?.container,
            quelle: quelle?.id, bytes: quelle?.size ?? 0,
            gesehen: titel.userData?.played ?? false)
    }

    private var ladebilder: [String: URL] {
        guard let plakat = model.plakatURL(itemID: titel.id,
                                           marke: titel.imageTags?["Primary"])
        else { return [:] }
        return [titel.id: plakat]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // **Rechts, nicht über die volle Breite** — wie auf dem Apple TV.
            // Das Bild ragt nach unten über die Kopfzone hinaus; seine eigene
            // Maske beendet es, deshalb wird nicht beschnitten.
            // **Zuletzt irgendein Bild, nie gar keins.** `kopfbildURL`
            // sucht bei einer Serie ohne Hintergrund das Standbild der
            // nächsten Folge und bei allem anderen das Plakat — quer
            // beschnitten ist besser als ein leerer Kopf.
            Kulisse(url: model.querbildURL(for: titel, breite: 1600)
                         ?? model.kopfbildURL(for: titel),
                    hoehe: Stil.heldHoehe * 1.62)
                // **An der Unterkante festhalten, nicht an der oberen.**
                //
                // Der Inhalt rutscht beim Überziehen nach unten. Wächst das
                // Bild von oben nach unten, wandert seine Oberkante mit — und
                // die Lücke darüber bleibt als harte Kante stehen. Genau das,
                // was hier vermieden werden soll.
                //
                // Unten verankert wächst es **nach oben**, und zwar um genau
                // den Betrag, um den der Inhalt nach unten gerutscht ist:
                // die Oberkante bleibt damit stehen, wo sie war, und die
                // Lücke gibt es gar nicht erst.
                //
                // Der Faktor rechnet deshalb gegen die **volle** Bildhöhe,
                // nicht gegen die Höhe der Kopfzone — sonst wächst es um ein
                // Vielfaches dessen, was gebraucht wird. Das war der zweite
                // Fehler und der Grund, warum es zu kräftig wirkte.
                .scaleEffect(1 + zug / (Stil.heldHoehe * 1.62), anchor: .bottom)

            block
                .padding(.leading, Stil.randAbstand)
                .padding(.top, Stil.titelHoehe + 98)
        }
        .frame(height: Stil.heldHoehe, alignment: .topLeading)
        // Auch am Stand: nach dem Player kommt derselbe Titel frisch zurück.
        .task(id: "\(titel.id)|\(titel.istGesehen)|\(model.seitenAuffrischen)") {
            merkliste = titel.userData?.isFavorite ?? false
            gesehen = titel.istGesehen
            if titel.type == "Series" {
                spielbarerTitel = await model.standInSerie(titel)
            }
            // **Der Plan gehört zur Folge, nicht zur Serie.**
            //
            // Hier stand `spielbarerTitel?.id ?? titel.id` in einem eigenen
            // `.task` — und `spielbarerTitel` war zu dem Zeitpunkt immer noch
            // `nil`, weil es der *andere* `.task` setzt. Der Aufruf ging also
            // mit der Serien-ID raus. `AppModel.plan(for:)` sagt dazu selbst:
            // „Tritt bei Serien und Staffeln auf" — der Server nennt keine
            // MediaSource, es kommt `nil` zurück, und weil der `.task` keine
            // Kennung hatte, lief er nie wieder. Der Direct-Play-Beleg stand
            // auf der Serienseite deshalb nie.
            //
            // `PlaybackInfo` ist ein POST, bei dem der Server die Datei
            // anfasst — der teuerste Abruf der App, hier umsonst und mitten
            // in der Einfahrt. iOS und tvOS holen ihn beide für die Folge.
            if let ziel = spielbarerTitel ?? (titel.type == "Series" ? nil : titel) {
                plan = await model.plan(for: ziel.id)
            }
        }
    }

    /// **Kein Poster.** Auf dem Apple TV ist es weggefallen, weil es nur den
    /// Fortschrittsbalken trug — und der steht jetzt dort, wo er auf jeder
    /// anderen Kachel auch steht.
    ///
    /// **Jede Zeile hat eine feste Höhe.** Titel, Angaben, Beschreibung und
    /// Knopfreihe stehen damit auf **jeder** Filmseite an derselben Stelle,
    /// egal wie lang der Titel ist oder wie viel Beschreibung der Server
    /// liefert. Ohne das wandern Knöpfe und Reihen beim Blättern von Film zu
    /// Film, und die Seite wirkt jedes Mal anders gebaut.
    ///
    /// Dieselbe Überlegung wie `Stil.auskunftHoehe` auf dem Fernseher: dort
    /// ist die Höhe fest, und ein langer Titel schrumpft, statt die Seite zu
    /// verschieben.
    private var block: some View {
        // **Feste Stellen statt fester Höhen.**
        //
        // Ein Stapel mit festen Höhen je Zeile *sollte* reichen — tut es aber
        // offenbar nicht: die Knöpfe wanderten weiter, je nachdem was der
        // Server lieferte. Statt weiter zu raten, wo eine Zeile doch noch
        // wächst, steht jede Zeile jetzt an einer **ausgerechneten Stelle**.
        // Was darin zu groß wird, wird abgeschnitten und verschiebt nichts.
        //
        //     0    Titel        42
        //     54   Angaben      26
        //     92   Beschreibung 66   (drei Zeilen)
        //     182  Knopfreihe   48
        //     230  Ende
        ZStack(alignment: .topLeading) {
            Text(verbatim: titel.name)
                // **Der Titel ueber einem Heldbild *ist* der Seitentitel**
                // (BRAND 2): 28 Bold, Sperrung an der Stufe. 34 war eine
                // eigene Stufe fuer dieselbe Rolle.
                .font(Stil.titelGross)
                .tracking(Stil.sperrungTitel)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                // Ein langer Titel schrumpft, statt die Seite zu verschieben.
                .minimumScaleFactor(0.62)
                .frame(width: 640, height: 42, alignment: .leading)
                .offset(y: 0)

            // **26, nicht 20 — sonst schneidet der Beschnitt die Belege ab.**
            //
            // In dieser Zeile stehen die Freigabe-Plakette und der
            // Direct-Play-Beleg. Beide sind 13 Punkt Schrift mit 4 Punkt Luft
            // oben und unten, also rund 24 hoch. Auf 20 gedeckelt und
            // beschnitten fehlte ihnen oben und unten je ein Streifen: die
            // Plakette sah dadurch anders aus als dieselbe Plakette auf dem
            // iPhone, und der Beleg wirkte angeschnitten. Paul am 22.09.:
            // „oben und unten abgeschnitten."
            //
            // 26 ist der Wert der Vorlage — `Belegzeile` in
            // `Sources/Shared/Stil.swift` haelt dieselbe Zeile auf dem iPhone
            // genau so hoch, mit derselben Begruendung („so hoch wie eine
            // Marke, immer").
            //
            // Der Beschnitt bleibt: er haelt die ausgerechnete Stelle der
            // Beschreibung darunter, egal was der Server liefert. Bei 26
            // schneidet er nur nichts mehr weg. Dieselbe Falle wie bei den
            // Folgennamen, wo ein zu enger Rahmen die Unterlaengen frass.
            angabenReihe
                .frame(width: 640, height: 26, alignment: .leading)
                .clipped()
                .offset(y: 54)

            // **Der bereinigte Text, nicht der rohe.** Jellyfin gibt
            // Beschreibungen aus, wie sie beim Anbieter standen — mit
            // `<br>`, `<p>` und `&amp;`. Im Kopf stand das wörtlich da.
            Text(verbatim: titel.beschreibung ?? "")
                .font(Stil.koerper)
                .lineSpacing(3)
                // `schriftLeise` ist ein voller Wert. Deckkraft aendert
                // ihre Wirkung, sobald etwas darunter liegt — und hier liegt
                // das Heldbild darunter.
                .foregroundStyle(Stil.schriftLeise)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(width: 640, height: 66, alignment: .topLeading)
                .clipped()
                .offset(y: 92)

            knopfreihe
                .frame(height: Stil.hauptknopfHoehe, alignment: .leading)
                .offset(y: 182)
        }
        .frame(width: 640, height: 230, alignment: .topLeading)
    }

    /// Jahr, Laufzeit, Genres — und dahinter die Belegzeile: Direct Play,
    /// Bewertung, Freigabe. **Eine Zeile**, nicht drei.
    ///
    /// **Die Reihenfolge ist die der Vorlage.** In `Belegzeile`
    /// (`Sources/Shared/Stil.swift`) stehen die drei Belege als Beleg →
    /// Bewertung → Freigabe; hier standen sie als Bewertung → Freigabe →
    /// Beleg. Dieselben drei Angaben in anderer Folge lesen sich als eine
    /// andere Zeile, und die beiden sollen nebeneinander gleich aussehen.
    ///
    /// Jahr, Laufzeit und Genre stehen davor, weil der Mac sie nicht wie das
    /// iPhone unter dem Titel im Heldbild trägt — dort ist die `nebenzeile`
    /// Teil des `Heldkopf`, hier hat der Titelblock feste Stellen und keine
    /// zweite Zeile dafür.
    private var angabenReihe: some View {
        HStack(spacing: 14) {
            // Angabe (Jahr, Laufzeit, Genre): 12, wie im `Heldkopf` auf dem
            // iPhone. 14 und 10 stehen in keiner Leiter.
            Text(verbatim: angabenzeile)
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftLeise)
            if let plan { beleg(plan) }
            // In derselben Hülle wie Direct Play, wie in `Belegzeile`
            // (23.09.2026): vorher stand die Bewertung als einzige Angabe
            // der Zeile nackt da.
            if let bewertung = titel.communityRating {
                marke("star.fill",
                      String(format: "%.1f", bewertung).replacingOccurrences(of: ".", with: ","),
                      farbe: Stil.schriftLeise, gewicht: .semibold)
            }
            // **Ecke 8, nicht der Standardwert 3.** Dieselbe Rechnung wie auf
            // dem iPhone: die Skala steht bei 10/12/16, und eine Marke mit 3
            // sitzt hier neben Dingen mit 10 — sie war das eckigste Element
            // der Seite.
            //
            // Alle anderen Maße kommen aus dem Baustein selbst und sind damit
            // dieselben wie auf dem iPhone: 13 Medium, Innenabstand 10/4,
            // Fläche in 15 Prozent.
            if let freigabe = titel.officialRating {
                Plakette(text: freigabe, rundung: Stil.eckeKlein)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Der Direct-Play-Beleg als Marke — zeichengleich mit `Belegzeile.marke`
    /// in `Sources/Shared/Stil.swift`.
    ///
    /// **Der Beleg ist eine Marke, kein loser Text.** Er stand als Zeichen und
    /// Wort nackt auf dem Grund, direkt neben der umrandeten
    /// Freigabe-Plakette: zwei verschiedene Formen für zwei Angaben, die
    /// gleich viel wiegen. Jetzt tragen beide dieselbe Ecke und lesen sich als
    /// Paar; welche Auskunft es ist, sagt die Farbe.
    ///
    /// Fünfzehn Prozent Tönung, keine Füllung — der weiße Abspielknopf bleibt
    /// der einzige gefüllte Gegenstand der Seite. Ab etwa einem Drittel wird
    /// daraus ein zweiter Knopf.
    ///
    /// **Warum hier abgeschrieben und nicht geteilt:** `Belegzeile` liegt in
    /// `Sources/Shared/Stil.swift`, und diese Datei gehört nicht zum
    /// Mac-Ziel — dort gilt `Sources/macOS/Stil.swift`. Solange der Baustein
    /// nicht in eine Datei umzieht, die beide Ziele tragen (etwa
    /// `Sources/Shared/Bausteine.swift`, wo `Plakette` schon steht), bleibt es
    /// eine zweite Abschrift. Sie ist als solche vermerkt, damit sie nicht
    /// unbemerkt auseinanderläuft.
    @ViewBuilder
    private func beleg(_ plan: PlaybackPlan) -> some View {
        // **Halbfett nur beim Haken.** Die Warnung trägt Regular — was sie
        // laut macht, ist die Farbe, nicht das Gewicht. Auf dem iPhone ist
        // es genau so aufgeteilt; hier stand beides auf Semifett.
        marke(plan.isLossless ? "checkmark" : "exclamationmark.triangle.fill",
              plan.isLossless ? String(localized: "Direct Play") : plan.method.rawValue,
              farbe: plan.isLossless ? Stil.akzent : Stil.warnung,
              gewicht: plan.isLossless ? .semibold : .regular)
    }

    /// Die Hülle von Beleg und Bewertung — `Belegzeile.marke` auf dem iPhone.
    private func marke(_ symbol: String, _ wort: String,
                       farbe: Color, gewicht: Font.Weight) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: gewicht))
            Text(verbatim: wort).font(Stil.kachel)
        }
        .foregroundStyle(farbe)
        // Links enger als rechts: das Zeichen ist schmaler als seine
        // Zeichenzelle, sonst sitzt das Wort sichtbar aus der Mitte.
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(farbe.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: Stil.eckeKlein,
                                         style: .continuous))
    }

    /// Vier Ziele wie auf dem Apple TV: Fortsetzen, Von vorn, Merkliste,
    /// Mehr. „Gesehen" und „Trailer" sind in die Mehr-Liste gewandert —
    /// fünf beschriftete Knöpfe waren zu viel für eine Reihe.
    private var knopfreihe: some View {
        HStack(spacing: 12) {
            // **Feste Breite für den Hauptknopf, aber kein Platzhalter.**
            //
            // Die feste Breite bleibt: sonst wüchse der Knopf mit seiner
            // Beschriftung — „Fortsetzen" ist länger als „Abspielen" — und
            // schöbe alles dahinter. „Von vorn" gibt es dagegen nur bei
            // angefangenen Titeln, und wo es das nicht gibt, rückt der Rest
            // auf. Eine leere Lücke stehen zu lassen wäre schlimmer als der
            // kleine Versatz.
            if let ab = (spielbarerTitel ?? titel).fortsetzenAb {
                Hauptknopf(beschriftung: "Fortsetzen") { starten(ab) }
                    .frame(width: Stil.hauptknopfBreite)
                Aktionsknopf(mass: Stil.hauptknopfHoehe, symbol: "arrow.counterclockwise", titel: "Von vorn") {
                    starten(0)
                }
            } else {
                Hauptknopf(beschriftung: "Abspielen") { starten(0) }
                    .frame(width: Stil.hauptknopfBreite)
            }

            Aktionsknopf(mass: Stil.hauptknopfHoehe, symbol: merkliste ? "bookmark.fill" : "bookmark",
                       titel: "Merkliste", aktiv: merkliste) {
                merkliste.toggle()
                Task {
                    if let grund = await model.setzeMerkliste(titel, an: merkliste) {
                        merkliste.toggle()
                        melde(grund)
                    }
                }
            }

            // **Der Ladeknopf, und nur wenn die Funktion an ist.**
            //
            // Auf dem iPhone ist es das fünfte Feld einer Reihe; hier stehen
            // die Nebenknöpfe nebeneinander, also ist es einer mehr. Er steht
            // **nach** der Merkliste — die beiden sind das Paar „für später"
            // und gehören zusammen.
            //
            // **Bei einer Serie öffnet er die Auswahl, bei einem Film die
            // Ladetafel.** Dieselbe Aufteilung wie auf dem iPhone: dort ruft
            // die Serienseite `Ladeauswahl` und die Filmseite `Ladeblatt`. Bei
            // einer Serie ist zu klären, *was* geladen wird; bei einem Film
            // ist das die eine Datei.
            if model.downloadKnopfZeigen, titel.type == "Series",
               let ladeauswahl {
                Aktionsknopf(mass: Stil.hauptknopfHoehe, symbol: "arrow.down",
                             titel: "Laden", aktiv: auswahlOffen, auswahl: ladeauswahl)
            }
            if model.downloadKnopfZeigen, titel.type != "Series" {
                Aktionsknopf(mass: Stil.hauptknopfHoehe, symbol: ladezeichen, titel: "Laden",
                           aktiv: geladen != nil) {
                    ringGeklickt(geladen, model.downloads) {
                        withAnimation(Stil.sprung) { ladetafelOffen.toggle() }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if ladetafelOffen, let p = alsPosten {
                        Ladetafel(model: model, posten: [p], titel: titel.name,
                                  bilder: ladebilder, offen: $ladetafelOffen)
                            .offset(y: Stil.hauptknopfHoehe + 8)
                            .transition(.aufklappen(von: .topLeading))
                            .zIndex(30)
                    }
                }
                // Ein Klick daneben schliesst — dieselbe Erwartung wie beim
                // Mehr-Menue. Der Fang liegt unter der Tafel, nicht darueber.
                .background {
                    if ladetafelOffen {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .frame(width: 4000, height: 4000)
                            .onTapGesture {
                                withAnimation(Stil.sprung) { ladetafelOffen = false }
                            }
                    }
                }
            }

            Aktionsknopf(mass: Stil.hauptknopfHoehe, symbol: "ellipsis", titel: "Mehr", aktiv: mehrOffen) {
                withAnimation(Stil.sprung) { mehrOffen.toggle() }
            }
            .overlay(alignment: .topLeading) {
                if mehrOffen {
                    Handlungsliste(handlungen: mehrHandlungen, offen: $mehrOffen)
                        .offset(x: -206, y: Stil.hauptknopfHoehe + 8)
                        // Sie oeffnet nach links, ihre obere **rechte** Ecke
                        // liegt unter den drei Punkten.
                        .transition(.aufklappen(von: .topTrailing))
                }
            }

            if let meldung { Hinweisstreifen(text: meldung) }
            Spacer(minLength: 0)
        }
    }

    /// Jahr, Laufzeit und Genre — aus `Item.nebenzeile` in
    /// `Sources/Shared/Titelangaben.swift`.
    ///
    /// **Hier stand dieselbe Rechnung noch einmal**, zeichengleich bis auf
    /// das vorangestellte `titel.`. Darin steckt die Prüfung `sekunden > 0`,
    /// und genau die hat auf dem Fernseher schon einmal gefehlt — dort stand
    /// bei Serien „0 Min.", weil der Server für sie 0 liefert. Eine zweite
    /// Abschrift heisst: beim nächsten Mal fehlt sie hier.
    private var angabenzeile: String { titel.nebenzeile }

    private func starten(_ ab: Double) {
        steuerung.starte(spielbarerTitel ?? titel, ab: ab)
    }

    /// Dieselben Handlungen wie auf den anderen Plattformen, aus
    /// `Titelhandlungen` — dazu „Gesehen" und „Trailer", die auf dem Apple TV
    /// ebenfalls hier stehen statt in der Knopfreihe.
    private var mehrHandlungen: [Titelhandlung] {
        var liste: [Titelhandlung] = [
            .init(symbol: gesehen ? "checkmark.circle.fill" : "checkmark.circle",
                  text: gesehen ? "Als ungesehen markieren" : "Als gesehen markieren") {
                gesehen.toggle()
                Task {
                    if let grund = await model.setzeGesehen(titel, an: gesehen) {
                        gesehen.toggle()
                        melde(grund)
                    }
                }
            },
            .init(symbol: "film", text: "Trailer") { trailerStarten() },
        ]
        if titel.type == "Series" {
            liste += Titelhandlungen.fuerSerie(
                titel, stand: spielbarerTitel, staffel: staffel, model: model,
                folgeStarten: { folge, ab in steuerung.starte(folge, ab: ab) },
                melden: { melde($0) }, auffrischen: { await auffrischen() })
        } else {
            liste += Titelhandlungen.fuerFilm(
                titel, plan: plan, model: model,
                starten: { ab in steuerung.starte(titel, ab: ab) },
                melden: { melde($0) }, auffrischen: { await auffrischen() })
        }
        return liste
    }

    private func trailerStarten() {
        Task {
            if let film = await model.trailer(zu: titel) {
                steuerung.starte(film, ab: 0)
                return
            }
            if let adresse = titel.remoteTrailers?.compactMap(\.url).first,
               let ziel = URL(string: adresse) {
                NSWorkspace.shared.open(ziel)
                return
            }
            melde(String(localized: "Für diesen Titel liegt kein Trailer vor."))
        }
    }

    private func auffrischen() async {
        if titel.type == "Series" { spielbarerTitel = await model.standInSerie(titel) }
        plan = await model.plan(for: spielbarerTitel?.id ?? titel.id)
    }

    private func melde(_ text: String) {
        meldung = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { meldung = nil }
        }
    }
}

// MARK: - Bausteine der Detailseiten

// **Hier stand `Beschreibung`** — ein Textblock, den niemand rief. Die
// Beschreibung steht seit dem Umbau im Kopf, wie auf dem Apple TV; der
// Baustein blieb stehen und wurde bei jeder Aenderung mitgelesen.

struct Besetzungsreihe: View {
    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich
    let model: AppModel
    let leute: [Person]
    /// Woher man kommt — steht auf der Personenseite über der Rolle.
    var herkunft: String? = nil

    var body: some View {
        if !leute.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Reihentitel(text: "Besetzung")
                Blätterreihe(rand: 0, breiteJeStueck: 84 + 18, bildHoehe: 84) {
                    ForEach(leute, id: \.id) { person in
                        // **Ein Kopf ist jetzt ein Weg.** Ein Tester tippte
                        // die Besetzung an und landete nirgends.
                        Button {
                            navigator.oeffne(.person(person, herkunft: herkunft), in: bereich)
                        } label: {
                            Kopfbild(name: person.name, rolle: person.role,
                                     bild: model.personBild(person))
                        }
                        .buttonStyle(Stil.Druckknopf())
                    }
                }
            }
        }
    }
}



struct Kopfbild: View {
    let name: String
    let rolle: String?
    let bild: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Stil.flaeche
                // **Mit Zeichen, wie jedes andere fehlende Bild auf dem
                // Mac.** Ohne es blieb an der Besetzungsreihe als einziger
                // Stelle ein blanker grauer Kreis stehen.
                Netzbild(url: bild, zeichen: "person", anzeigekante: 76)
            }
            .frame(width: 76, height: 76)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                    .font(Stil.zweitzeile.weight(.medium))
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(2)
                if let rolle {
                    Text(verbatim: rolle)
                        .font(Stil.zweitzeile)
                        .foregroundStyle(Stil.schriftLeise)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: 84, alignment: .leading)
    }
}

/// Ganz unten: was für eine Datei das eigentlich ist. Sie beantwortet eine
/// Frage, die man erst später stellt.
///
/// Die Texte kommen aus `Dateiangaben` im Paket — Container,
/// Codec und Untertitel sind auf allen Plattformen dieselbe Auskunft. Meine
/// erste Fassung stellte sie selbst zusammen und ließ Codec und Untertitel
/// weg.
struct Dateizeile: View {
    let quelle: MediaSource

    var body: some View {
        HStack(spacing: 22) {
            ForEach(angaben, id: \.self) { text in Text(verbatim: text) }
        }
        .font(Stil.zweitzeile)
        .foregroundStyle(Stil.schriftSehrLeise)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Stil.linie).frame(height: 1) }
    }

    private var angaben: [String] {
        var zeilen: [String] = []
        // Die Größe hängt an „MKV · 10,3 GB"; einzeln steht sie nur, wenn
        // der Server keinen Container nennt. Vorher stand sie zweimal da —
        // unbemerkt, weil sie mit einem führenden „ · " getarnt war.
        if let behaelter = Dateiangaben.container(quelle) {
            zeilen.append(behaelter)
        } else {
            zeilen.append(Dateiangaben.groesse(quelle))
        }
        if let spur = Dateiangaben.videospur(quelle) {
            zeilen.append(Dateiangaben.video(spur, quelle))
        }
        let ut = Dateiangaben.untertitel(Dateiangaben.untertitelspuren(quelle))
        if !ut.isEmpty { zeilen.append(ut) }
        return zeilen.filter { !$0.isEmpty }
    }
}
