import JellyfinKit
import OSLog
import SwiftUI

/// Die Serienseite.
///
/// Kern ist der eine große Knopf: er weiß, wo du stehst. Jellyfins NextUp
/// beantwortet beides in einem Aufruf — die angefangene Folge, oder die
/// nächste ungesehene, wenn keine offen ist.
struct SeriesDetailView: View {
    let model: AppModel
    let serie: Item
    /// Kommt man von einer Folge, ist deren Staffel gleich ausgewählt.
    var startStaffelID: String? = nil
    /// Die **Nummer** der Staffel, aus der man kommt.
    ///
    /// **Weil die Kennung fehlen kann.** Am Geraet gemessen: dem Testserver
    /// liefert an einer Folge kein `SeasonId` — weder im Listeneintrag noch
    /// beim Einzelabruf, weder ueber `Shows/NextUp` noch sonstwo. Damit
    /// griffen beide Kennungsvergleiche ins Leere und die Wahl fiel auf
    /// `staffeln.first`: oben stand „Abspielen S6 E1", unten Staffel 5.
    ///
    /// Die Nummer steht dagegen immer da — an der Folge als
    /// `parentIndexNumber`, an der Staffel als `indexNumber`. Sie ist der
    /// verlaesslichere Weg und deshalb kein Notnagel, sondern eine
    /// gleichrangige Stufe.
    var startStaffelNummer: Int? = nil

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit
    @Environment(\.weit) private var weit

    /// Wie weit gescrollt wurde — der Kopf blendet danach ein.
    @State private var versatz: CGFloat = 0

    @State private var stand: Item?
    @State private var staffeln: [Item] = []
    @State private var gewaehlteStaffel: Item?
    @State private var folgen: [Item] = []
    @State private var ladeblatt = false
    @State private var ladeposten: [Downloadposten] = []
    @State private var ladetitel = ""
    @State private var aehnliche: [Item] = []
    @State private var laedt = true
    @State private var abspielen: Abspielwunsch?
    @State private var mehrOffen = false
    @State private var meldung: String?
    @State private var bereitet = false
    @State private var gemerkt = false
    @State private var gesehen = false
    @State private var plan: PlaybackPlan?
    @State private var reiter = 0
    @State private var staffellisteOffen = false
    /// Hat der Nutzer selbst eine Staffel gewaehlt? Dann redet ihm nichts
    /// mehr hinein.
    @State private var selbstGewaehlt = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Derselbe Kopf wie auf der Filmseite — er steht als
                    // eigener Baustein, damit er nicht zweimal dasteht.
                    if breit {
                        Heldkopf(bild: model.backdropURL(for: serie),
                                 poster: model.imageURL(for: serie, maxHeight: 600,
                                                        hochkant: true),
                                 titel: serie.name, nebenzeile: nebenzeile,
                                 fortschritt: serie.userData?.playedPercentage
                                     .map { $0 / 100 }) {
                            VStack(alignment: .leading, spacing: 14) {
                                belegzeile
                                // Nebeneinander nur, wenn es reicht.
                                // Hochkant hat der Textblock 476 Punkt; die
                                // Reihe braucht rund 620, und SwiftUI setzt
                                // die Beschriftungen dann senkrecht.
                                if weit {
                                    HStack(alignment: .center, spacing: 14) {
                                        hauptknopf
                                        aktionsreihe
                                    }
                                } else {
                                    hauptknopf
                                    aktionsreihe
                                }
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
                        // Doch über dem Knopf, direkt unter dem Namen.
                        belegzeile
                        hauptknopf
                        aktionsreihe
                            // Die Reihe traegt ihre Beschriftungen dicht unter
                            // den Kreisen; ohne Zugabe stossen sie fast an den
                            // Text darunter.
                            .padding(.bottom, 8)
                        beschreibung
                    }
                    .padding(.horizontal, Stil.rand(breit: breit))
                    .padding(.top, 14)
                    .padding(.bottom, 22)
                    }

                    Reiter(titel: ["Folgen", "Besetzung", "Ähnliches"], gewaehlt: $reiter)

                    switch reiter {
                    case 0: folgenbereich
                    case 1: besetzung
                    default: aehnlichesbereich
                    }
                }
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(.named("blatt"))
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
                versatz = neu
                // **Scrollen schliesst die Staffelliste, Tippen nicht mehr.**
                //
                // Hier hing eine `simultaneousGesture` auf der ganzen
                // Scrollflaeche, die beim Tippen schloss. „Simultan" heisst
                // woertlich, was es sagt: tippte man die Pille selbst an,
                // feuerten **beide** — die Geste schloss, und der Knopf
                // schaltete daraufhin von zu auf offen. Es sah aus, als ginge
                // das Fenster zu und sofort wieder auf, und genau so hat
                //
                // Scrollen ist die Bewegung, bei der eine aufgeklappte Liste
                // wirklich stoert — und sie kann mit keinem Knopf um dieselbe
                // Beruehrung streiten.
                if staffellisteOffen { staffellisteOffen = false }
            }
            .ignoresSafeArea(edges: .top)

            // Derselbe Kopf wie auf der Filmseite. Hier stand noch der alte
            // Verlauf mit freistehendem Pfeil — deshalb blendete auf der
            // Serienseite nie eine Leiste ein.
            // Das Blatt haengt an einer leeren Flaeche; ohne `if` gaebe es
            // auf breiten Fenstern zwei Wege zu denselben Handlungen.
            if !breit {
                Handlungsblatt(offen: $mehrOffen, titel: blatttitel,
                               handlungen: mehrHandlungen)
                    .zIndex(20)
            }
            // **Das Blatt steht immer im Baum, auch leer.**
            //
            // Es hing an `if !ladeposten.isEmpty` — und beim **ersten**
            // Oeffnen wurden Posten und `offen` im selben Durchgang gesetzt.
            // Damit entstand die Ansicht in dem Moment, in dem sie schon
            // offen sein sollte: es gab keinen geschlossenen Zustand, von dem
            // aus sie haette hereinfahren koennen. Das Fenster stand
            // schlagartig da und der Titel gleich an seinem Platz; ab dem
            // zweiten Mal fuhr es, weil die Ansicht dann schon existierte.
            //
            // `Ladeblatt` traegt leere Posten ohne Weiteres — `bytes` ist
            // dann 0, und geschlossen zeichnet es ohnehin nichts.
            Ladeblatt(offen: $ladeblatt, model: model, posten: ladeposten,
                      titel: ladetitel, bilder: ladebilder)
                .zIndex(20)
            if let meldung {
                Hinweisstreifen(text: meldung) { self.meldung = nil }
                    .zIndex(21)
            }

            Detailkopf(titel: serie.name, versatz: versatz) { zurueck() }
        }
        .animation(.easeOut(duration: 0.14), value: staffellisteOffen)
        .animation(.easeInOut(duration: 0.16), value: reiter)
        // Breit hängt die Tafel am Knopf statt am unteren Bildrand. Der
        // Anker kommt aus `alsHandlungsanker()`; über feste Koordinaten
        // ginge es nicht, weil die Knopfreihe mit der Länge der
        // Beschriftung wandert.
        .overlayPreferenceValue(Handlungsanker.self) { anker in
            GeometryReader { raum in
                if breit, mehrOffen, let anker {
                    Handlungstafel(offen: $mehrOffen, titel: blatttitel,
                                   handlungen: mehrHandlungen,
                                   anker: raum[anker], raum: raum.size)
                }
            }
        }
        #if os(iOS)
        .background(WischZurueck())
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $abspielen) { wunsch in
            PlayerScreen(model: model, item: wunsch.item,
                         plan: wunsch.plan, startAt: wunsch.startAt)
        }
        #endif
        .task { await laden() }
        // **Die mitgebrachte Staffel kann nachtraeglich eintreffen.**
        //
        // `StaffelZiel` holt die Folge frisch nach, weil der Listeneintrag
        // eine alte Staffel tragen kann — wer eine Staffel zu Ende sieht und
        // die naechste dazulegt, hat auf der Kachel weiter die alte stehen.
        // Diese Antwort kommt aber erst, wenn die Seite schon steht und
        // `laden()` seine Wahl getroffen hat. Ohne diese Zeile war das
        // Nachholen wirkungslos: oben „Abspielen S6E1", unten Staffel 5.
        .onChange(of: startStaffelID) { _, neu in
            guard !selbstGewaehlt, let neu,
                  let treffer = staffeln.first(where: { $0.id == neu }),
                  treffer.id != gewaehlteStaffel?.id else { return }
            gewaehlteStaffel = treffer
            Task { await folgenLaden() }
        }
    }

    /// Alles holen, was sich ändern kann.
    ///
    /// **Eine Ladefunktion, nicht zwei.** Vorher gab es daneben ein
    /// `auffrischen`, das einen Teil davon nachbaute — und dabei den Plan
    /// vergaß. Nach „Staffel als gesehen" zeigte der Hauptknopf die neue
    /// Folge und trug den Plan der alten, samt falschem Direct-Play-Beleg.
    /// Der tvOS-Chat hat denselben Fehler bei sich gefunden und ihn treffend
    /// benannt: `auffrischen` galt als Stellvertreter für „alles ist wieder
    /// frisch", weil es meistens mit ihm zusammenfällt. Meistens.
    private func laden() async {
        async let a = model.standInSerie(serie)
        async let b = model.staffeln(serie)
        async let c = model.aehnliche(serie)
        (stand, staffeln, aehnliche) = await (a, b, c)
        // Kommt man von einer Folge, deren Staffel — sonst die, in der man
        // zuletzt war. Beim Auffrischen bleibt die getroffene Wahl stehen.
        if gewaehlteStaffel == nil {
            gewaehlteStaffel = staffeln.first { $0.id == startStaffelID }
                ?? staffeln.first { $0.id == stand?.seasonId }
                // Ueber die Nummer, wenn keine Kennung ankam.
                ?? staffeln.first { nummer($0) != nil && nummer($0) == startStaffelNummer }
                ?? staffeln.first { nummer($0) != nil && nummer($0) == stand?.parentIndexNumber }
                ?? staffeln.first
        }
        Protokoll.schreib("[Staffel] \(serie.name): mitgebracht=\(startStaffelID ?? "-")/\(startStaffelNummer.map(String.init) ?? "-") "
            + "stand=\(stand.map { "S\($0.parentIndexNumber ?? -1)E\($0.indexNumber ?? -1) " + ($0.seasonId ?? "-") } ?? "-") "
            + "gewaehlt=\(gewaehlteStaffel?.name ?? "-") "
            + "vorhanden=[\(staffeln.map { "\($0.name)=\($0.id)" }.joined(separator: " "))]")
        gemerkt = serie.userData?.isFavorite ?? false
        gesehen = serie.userData?.played ?? false
        if let stand { plan = await model.plan(for: stand.id) }
        await folgenLaden()
        laedt = false
    }

    private func auffrischen() async { await laden() }

    // MARK: Teile

    private var hero: some View {
        Heldbild(url: model.backdropURL(for: serie))
            .overlay(alignment: .bottom) { Heldauslauf() }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(serie.name)
                        .font(Stil.titel)
                        .tracking(-0.6)
                        .foregroundStyle(Stil.schrift)
                    Text(nebenzeile)
                        .font(.system(size: 14))
                        .foregroundStyle(Stil.schriftLeise)
                        .lineLimit(1)
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.bottom, 16)
            }
    }

    private var nebenzeile: String {
        var teile: [String] = []
        if let jahr = serie.productionYear { teile.append(String(jahr)) }
        // Nicht `childCount`: das Feld meint je nach Abfrage etwas anderes und
        // stand bei einer Serie mit neunzehn Staffeln auf eins. Sobald die
        // Staffeln geladen sind, zählen wir sie selbst.
        // Liegt nur eine Staffel in der Bibliothek, sagen wir welche.
        // „1 Staffel" neben einem Knopf, auf dem „S2 · E1" steht, liest sich
        // wie ein Widerspruch — dabei fehlt schlicht Staffel 1 auf der Platte.
        if staffeln.count == 1, let einzige = staffeln.first {
            teile.append(einzige.name)
        } else if let anzahl = staffeln.isEmpty ? serie.childCount : staffeln.count {
            teile.append(String(localized: "\(anzahl) Staffeln"))
        }
        if let genres = serie.genres, !genres.isEmpty {
            teile.append(genres.prefix(2).joined(separator: ", "))
        }
        return teile.joined(separator: " · ")
    }

    private var belegzeile: some View {
        Belegzeile(direktplay: plan?.isLossless ?? false,
                   hinweis: plan.map { $0.isLossless ? nil : $0.method.rawValue } ?? nil,
                   bewertung: serie.communityRating,
                   freigabe: serie.officialRating)
    }

    private var hauptknopf: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                if let stand { starte(stand) }
            } label: {
                HStack(spacing: 8) {
                    // Kein Ring im Knopf: die Beschriftung sagt es ohnehin
                    // („Lädt…"), und ein zweites Zeichen daneben ist Lärm.
                    Image(systemName: "play.fill").font(.system(size: 15))
                        .opacity(bereitet ? 0.5 : 1)
                    Text(knopftext)
                }
            }
            .buttonStyle(HauptknopfStil(dehnt: !breit))
            // **Waehrend geladen wird bleibt er an und zeigt „Laedt…".**
            //
            // Auf tvOS ist ein abgeschalteter Knopf kein Fokusziel: kam man aus
            // der Suche, wo nichts vorgeladen ist, sprang der Startfokus auf
            // „Merkliste" — und kehrte nicht zurueck, wenn die Folge ankam.
            // Hier gilt dasselbe Muster, nur ohne sichtbare Folge, weil der
            // Finger sich seinen Knopf selbst sucht. Gleich gehalten, damit die
            // Plattformen nicht wieder auseinanderlaufen.
            //
            // Ein Druck waehrend des Ladens tut nichts — `starte` hat den
            // `guard` ohnehin.
            .disabled(bereitet || (stand == nil && !laedt))

            if let stand, let rest = restzeit(stand) {
                Text(rest).font(.system(size: 11)).foregroundStyle(Stil.schriftLeise)
            }
            // Breit sitzt der Fortschritt am Poster im Kopf — hier wäre er
            // ein zweites Mal dasselbe, und zwar quer über die Seite.
            if !breit, let stand, let anteil = stand.userData?.playedPercentage,
               anteil > 0 {
                Fortschrittsbalken(anteil: anteil / 100)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
        }
    }

    /// Dieselbe Reihe wie auf der Filmseite — vier Symbole mit
    /// Beschriftung. Vorher standen hier zwei breite Knöpfe, dadurch sahen
    /// die beiden Seiten unterschiedlich aus.
    private var aktionsreihe: some View {
        HStack(spacing: 8) {
            Aktionsknopf(symbol: gemerkt ? "bookmark.fill" : "bookmark",
                         titel: "Merkliste", aktiv: gemerkt, dehnt: !weit) {
                gemerkt.toggle()
                Task {
                    if let grund = await model.setzeMerkliste(serie, an: gemerkt) {
                        gemerkt.toggle()
                        meldung = grund
                    }
                }
            }
            Aktionsknopf(symbol: "film", titel: "Trailer", dehnt: !weit) { trailerStarten() }
            Aktionsknopf(symbol: gesehen ? "checkmark.circle.fill" : "checkmark.circle",
                         titel: "Gesehen", aktiv: gesehen, dehnt: !weit) {
                gesehen.toggle()
                Task {
                    if let grund = await model.setzeGesehen(serie, an: gesehen) {
                        gesehen.toggle()
                        meldung = grund
                    }
                }
            }
            Aktionsknopf(symbol: "ellipsis", titel: "Mehr", dehnt: !weit) { mehrOffen = true }
                .alsHandlungsanker()
        }
        // Kein eigener Rand mehr: die vier Felder teilen sich die Zeile und
        // enden dort, wo der Knopf darüber endet. Die Zwischenräume, die die
        // Kreise über die Breite verteilten, sind mit ihnen weggefallen.
    }

    @ViewBuilder
    private var beschreibung: some View {
        if let text = serie.overview {
            Klapptext(text: text)
        }
    }

    private var folgenbereich: some View {
        // Über die volle Breite, wie auf dem iPhone. Der Haken gehört an den
        // rechten Rand der Zeile; auf ein Lesemaß eingeschnürt stand er
        // mitten auf der Seite und sah aus, als gehöre er zu nichts.
        folgenliste
    }

    private var folgenliste: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !staffeln.isEmpty {
                Aufklappliste(beschriftung: gewaehlteStaffel?.name ?? "Staffel",
                              eintraege: staffeln,
                              text: { $0.name },
                              istGewaehlt: { $0.id == gewaehlteStaffel?.id },
                              waehlen: { staffel in
                                  selbstGewaehlt = true
                                  gewaehlteStaffel = staffel
                                  Task { await folgenLaden() }
                              },
                              offen: $staffellisteOffen)
                    .padding(.leading, Stil.rand(breit: breit))
                    .padding(.top, 14)
                    .padding(.bottom, 14)
                    .zIndex(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        // **Rechts neben der Staffelwahl**, dieselbe Höhe,
                        // dieselbe Form. Erscheint nur, wenn die Funktion an
                        // ist — und ist die Staffel schon vollständig da,
                        // steht dort nichts mehr statt eines Knopfs, der
                        // nichts tut.
                        if model.downloadsAn, !staffelVollstaendig, !folgen.isEmpty {
                            Chipknopf {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("Staffel laden")
                                }
                            } aktion: {
                                staffelLaden()
                            }
                            .padding(.trailing, Stil.rand(breit: breit))
                        }
                    }
            }

            // Nicht faul: jede Zeile ist seit dem Wischen selbst eine
            // Scrollfläche, und verschachtelt kann ein LazyVStack ihre Höhe
            // nicht mehr schätzen — es blieb nur die erste Zeile stehen.
            // Eine Staffel hat selten mehr als 25 Folgen, das trägt der
            // gewöhnliche Stapel mühelos.
            VStack(spacing: 0) {
                ForEach(folgen) { folge in
                    let ist = folge.userData?.played ?? false
                    Wischzeile(symbol: ist ? "arrow.uturn.backward" : "checkmark",
                               beschriftung: ist ? "Ungesehen" : "Gesehen",
                               aktion: { gesehenUmschalten(folge) },
                               tippen: { starte(folge) }) {
                        Folgenzeile(model: model, folge: folge) {
                            folgeGetippt(folge)
                        }
                    }
                    Rectangle().fill(Stil.linie).frame(height: 1)
                        .padding(.leading, Stil.randAbstand)
                }
            }
        }
    }

    @ViewBuilder
    private var besetzung: some View {
        let leute = (stand?.darsteller.isEmpty == false ? stand!.darsteller : serie.darsteller)
        if leute.isEmpty {
            leerhinweis("Keine Besetzung hinterlegt.")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 14)],
                      spacing: 20) {
                ForEach(leute) { person in
                    Besetzungskachel(bild: model.personBild(person),
                                     name: person.name, rolle: person.role)
                }
            }
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.top, 20)
        }
    }

    @ViewBuilder
    private var aehnlichesbereich: some View {
        if aehnliche.isEmpty {
            leerhinweis("Nichts Ähnliches gefunden.")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Stil.kachelBreite,
                                                   maximum: Stil.kachelBreite + 30),
                                         spacing: Stil.kachelAbstand)],
                      alignment: .leading, spacing: 20) {
                ForEach(aehnliche) { titel in
                    NavigationLink(value: titel) {
                        PosterTile(model: model, item: titel)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.top, 20)
        }
    }

    private func leerhinweis(_ text: String) -> some View {
        Text(text)
            .font(Stil.koerper)
            .foregroundStyle(Stil.schriftSehrLeise)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
    }

    // MARK: Ableitungen

    private var knopftext: String { Item.serienknopf(folge: stand, laedt: laedt) }

    private func restzeit(_ folge: Item) -> String? { folge.restzeitText }

    /// Die Nummer einer Staffel — Jellyfin fuehrt sie als `IndexNumber`.
    private func nummer(_ staffel: Item) -> Int? { staffel.indexNumber }

    private func folgenLaden() async {
        folgen = await model.folgen(serie: serie.id, staffel: gewaehlteStaffel?.id)
    }

    // MARK: Downloads

    /// Liegt schon jede Folge dieser Staffel auf dem Gerät? Dann fällt der
    /// Chip weg — ein Knopf, der nichts mehr tut, ist schlechter als keiner.
    private var staffelVollstaendig: Bool {
        !folgen.isEmpty && folgen.allSatisfy { model.downloads.posten(fuer: $0.id) != nil }
    }

    /// Ein `Downloadposten` aus einer Folge. **Dieselbe Quelle, die der
    /// Player nähme** — H2, es ist dieselbe Datei.
    private func posten(_ folge: Item) -> Downloadposten? {
        guard let konto = model.session?.userID else { return nil }
        let quelle = folge.mediaSources?.first
        return Downloadposten(
            id: folge.id, konto: konto, art: .folge, titel: folge.name,
            serie: serie.name, serienId: serie.id,
            staffel: folge.parentIndexNumber ?? gewaehlteStaffel?.indexNumber,
            folge: folge.indexNumber,
            laufzeitTicks: folge.runTimeTicks, container: quelle?.container,
            quelle: quelle?.id, bytes: quelle?.size ?? 0,
            gesehen: folge.userData?.played ?? false)
    }

    /// Das Plakat der Serie plus das Querbild jeder Folge, die geladen wird.
    private var ladebilder: [String: URL] {
        var karte: [String: URL] = [:]
        if let plakat = model.plakatURL(itemID: serie.id,
                                        marke: serie.imageTags?["Primary"]) {
            karte[serie.id] = plakat
        }
        for p in ladeposten {
            if let f = folgen.first(where: { $0.id == p.id }),
               let bild = model.imageURL(for: f, maxHeight: 220) {
                karte[p.id] = bild
            }
        }
        return karte
    }

    /// **Die ganze Staffel, der Reihe nach.** Gleichzeitig gäbe es nicht: H4
    /// lässt immer nur einen laufen, der Rest wartet sichtbar. Was schon da
    /// ist, kommt nicht noch einmal in die Schlange.
    private func staffelLaden() {
        let offene = folgen.filter { model.downloads.posten(fuer: $0.id) == nil }
        ladeposten = offene.compactMap { posten($0) }
        guard !ladeposten.isEmpty else { return }
        ladetitel = gewaehlteStaffel?.name ?? serie.name
        ladeblatt = true
    }

    /// **Eine einzelne Folge laden.**
    ///
    /// Aus einer Nutzermeldung: eine Anime-Staffel hat ueber hundert Folgen,
    /// und fuer die Bahnfahrt sollen zwei davon mit. Eine ganze Staffel ist
    /// dafuer die falsche Groessenordnung.
    ///
    /// Was ein Tipp auf den Ring tut, steht in `ringGetippt` und ist an allen
    /// Stellen dasselbe: anhalten, fortsetzen, oder — wenn noch nichts da ist
    /// — das Blatt oeffnen, das die Groesse nennt, bevor etwas beginnt.
    private func folgeGetippt(_ folge: Item) {
        ringGetippt(model.downloads.posten(fuer: folge.id), model.downloads) {
            guard let p = posten(folge) else { return }
            ladeposten = [p]
            ladetitel = folge.name
            ladeblatt = true
        }
    }

    private func starte(_ folge: Item) {
        guard !bereitet else { return }
        bereitet = true
        Task {
            defer { bereitet = false }
            guard let plan = await model.plan(for: folge.id) else { return }
            abspielen = Abspielwunsch(item: folge, plan: plan,
                                      startAt: folge.fortsetzenAb ?? 0)
        }
    }
}

/// Eine Folge in der Liste — Vorschaubild, Nummer, Laufzeit, Fortschritt.
struct Folgenzeile: View {
    @Environment(\.breit) private var breit
    let model: AppModel
    let folge: Item
    /// Was ein Tipp auf den Ring tut. `nil` heisst: diese Liste hat keine
    /// Ladespalte — die Staffelansicht ueber die Bibliothek etwa.
    var ringtipp: (() -> Void)?

    private var gesehen: Bool { folge.userData?.played ?? false }
    private var geladen: Downloadposten? { model.downloads.posten(fuer: folge.id) }
    /// Die Spalte gibt es nur mit dem Schalter — H1.
    private var mitSpalte: Bool { ringtipp != nil && model.downloadsAn }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            vorschau

            VStack(alignment: .leading, spacing: 3) {
                Text("\(folge.indexNumber.map { "\($0). " } ?? "")\(folge.name)")
                    .font(.system(size: 14, weight: .medium))
                    // **Gesehenes tritt zurueck, es verschwindet nicht.** Der
                    // gedaempfte Titel ist die dritte Auskunft neben dem
                    // abgedunkelten Bild und dem Haken darauf — zusammen liest
                    // man den Zustand, ohne ein Zeichen suchen zu muessen.
                    .foregroundStyle(gesehen ? Stil.schriftLeise : Stil.schrift)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                Text(nebenzeile)
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
            }

            Spacer(minLength: 0)

            // **Die rechte Spalte gehoert dem Download, und ihm allein.**
            //
            // Hier stand der Haken fuer „gesehen". Ein zweites rundes Zeichen
            // daneben waere dasselbe Suchbild, das wir bei zwei Haken schon
            // einmal hatten: zwei Formen nebeneinander, die Verschiedenes
            // meinen. Der Haken ist deshalb auf das Vorschaubild gezogen —
            // dort steht ohnehin schon der Fortschrittsbalken, also die
            // Auskunft „wie weit bin ich", und der Haken ist deren Ende.
            //
            // Netflix macht es genauso: rechts nur der Pfeil, der Sehstand
            // auf dem Bild. Prime Video legt beides in dieselbe Spalte, und
            // genau dort wird es mehrdeutig.
            if mitSpalte {
                Downloadring(posten: geladen, mass: 26) { ringtipp?() }
                    // Mittig zur Kachel: sie ist 65 hoch, die Trefferflaeche
                    // 44. (65 − 44) / 2 = 10,5.
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, Stil.rand(breit: breit))
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// Das Vorschaubild traegt den Sehstand: angefangen als Balken, gesehen
    /// als Haken auf abgedunkeltem Grund. Dasselbe Abzeichen wie oben rechts
    /// auf einer Plakatkachel — kein neues Zeichen, nur an einem Ort mehr.
    private var vorschau: some View {
        Bild(url: model.imageURL(for: folge, maxHeight: 220),
             breite: 116, hoehe: 65, ecke: Stil.eckeKachel,
             // Ein voller Balken **und** ein Haken waeren dieselbe Auskunft
             // zweimal.
             fortschritt: gesehen ? nil
                                  : folge.userData?.playedPercentage.map { $0 / 100 })
            .opacity(gesehen ? 0.45 : 1)
            .overlay(alignment: .topTrailing) {
                if gesehen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Stil.schrift)
                        .frame(width: 18, height: 18)
                        .background(Stil.grund.opacity(0.72), in: Circle())
                        .padding(5)
                }
            }
            .animation(Stil.einblenden, value: gesehen)
    }


    private var nebenzeile: String {
        // `runtimeSeconds` ist bei einer Folge ohne Angabe 0, nicht nil —
        // die Regel im Paket fängt beides ab. Genau diese Prüfung fehlte
        // einmal auf dem Fernseher, und dort stand „0 Min." an der Serie.
        guard Anzeigeregeln.laufzeitZeigen(sekunden: folge.runtimeSeconds),
              let gesamt = folge.runtimeSeconds else { return "" }
        var text = folge.restzeitText ?? "\(Int(gesamt / 60)) min"
        // **Die Größe erst, wenn sie eine Rolle spielt.** Ohne Downloads ist
        // sie eine Zahl ohne Frage dahinter.
        if model.downloadsAn, let bytes = folge.mediaSources?.first?.size, bytes > 0 {
            text += " · " + Downloadregeln.groesse(bytes)
        }
        return text
    }
}

/// Folgenliste einer Staffel — für den Weg über die Bibliothek.
struct SeasonView: View {
    let model: AppModel
    let serie: Item
    let staffel: Item

    @State private var folgen: [Item] = []
    @State private var laedt = true
    @State private var abspielen: Abspielwunsch?
    /// Sperre gegen den zweiten Tipp, während der Plan noch geholt wird.
    /// Fehlte hier — auf der Serienseite gab es sie, in der Staffelansicht nicht.
    @State private var bereitet = false

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(folgen) { folge in
                        let gesehen = (folge.userData?.played ?? false)
                        Wischzeile(symbol: gesehen ? "arrow.uturn.backward" : "checkmark",
                                   beschriftung: gesehen ? "Ungesehen" : "Gesehen",
                                   aktion: { gesehenUmschalten(folge) },
                                   tippen: { starte(folge) }) {
                            Folgenzeile(model: model, folge: folge)
                        }
                        Rectangle().fill(Stil.linie).frame(height: 1)
                            .padding(.leading, Stil.randAbstand)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(staffel.name)
        #if os(iOS)
        .background(WischZurueck())
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Stil.grund, for: .navigationBar)
        .fullScreenCover(item: $abspielen) { wunsch in
            PlayerScreen(model: model, item: wunsch.item,
                         plan: wunsch.plan, startAt: wunsch.startAt)
        }
        #endif
        .task {
            folgen = await model.folgen(serie: serie.id, staffel: staffel.id)
            laedt = false
        }
    }

    private func starte(_ folge: Item) {
        guard !bereitet else { return }
        bereitet = true
        Task {
            defer { bereitet = false }
            guard let plan = await model.plan(for: folge.id) else { return }
            abspielen = Abspielwunsch(item: folge, plan: plan,
                                      startAt: folge.fortsetzenAb ?? 0)
        }
    }
}

extension SeasonView {
    /// Gesehen-Zustand umschalten und die Liste sofort nachziehen, damit der
    /// Haken nicht erst beim nächsten Laden erscheint.
    func gesehenUmschalten(_ folge: Item) {
        let neu = !(folge.userData?.played ?? false)
        Task {
            guard await model.setzeGesehen(folge, an: neu) == nil else { return }
            folgen = await model.folgen(serie: serie.id, staffel: staffel.id)
        }
    }
}

extension SeriesDetailView {
    /// Gesehen-Zustand einer Folge umschalten und die Liste nachziehen.
    func gesehenUmschalten(_ folge: Item) {
        let neu = !(folge.userData?.played ?? false)
        Task {
            if let grund = await model.setzeGesehen(folge, an: neu) {
                meldung = grund
                return
            }
            await folgenLaden()
        }
    }
}

extension SeriesDetailView {

    /// Erst der Trailer vom Server, dann der verlinkte.
    ///
    /// Liegt er als Datei vor, läuft er im eigenen Player — mit Direct Play
    /// wie alles andere. Sonst bleibt nur die verlinkte Adresse, und die führt
    /// bei Jellyfin fast immer zu YouTube; die kann nur der Browser öffnen.
    func trailerStarten() {
        Task {
            if let film = await model.trailer(zu: serie),
               let plan = await model.plan(for: film.id) {
                abspielen = Abspielwunsch(item: film, plan: plan, startAt: 0)
                return
            }
            #if os(iOS)
            if let adresse = serie.remoteTrailers?.compactMap(\.url).first,
               let ziel = URL(string: adresse) {
                await UIApplication.shared.open(ziel)
                return
            }
            #endif
            meldung = String(localized: "Für diesen Titel liegt kein Trailer vor.")
        }
    }

    /// Woran das Blatt arbeitet: die angefangene Folge, sonst die Serie.
    var blatttitel: String {
        guard let stand else { return serie.name }
        if let st = stand.parentIndexNumber, let fo = stand.indexNumber {
            return "\(serie.name) · S\(st) E\(fo)"
        }
        return serie.name
    }

    var mehrHandlungen: [Titelhandlung] {
        Titelhandlungen.fuerSerie(serie, stand: stand, staffel: gewaehlteStaffel,
                                  model: model,
                                  folgeStarten: { folgeStarten($0, ab: $1) },
                                  melden: { meldung = $0 },
                                  auffrischen: { await auffrischen() })
    }

    private func folgeStarten(_ folge: Item, ab: Double) {
        Task {
            guard let wunsch = await model.folgenwunsch(folge, ab: ab) else {
                meldung = AppModel.folgeNichtGeladen
                return
            }
            abspielen = wunsch
        }
    }
}
