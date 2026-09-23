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

    /// **Was gemerkt ist, steht sofort da** — sonst gibt es einen leeren
    /// Durchgang, und der ist das, was man sieht.
    ///
    /// Der `Serienspeicher` lag seit `2fc501c` geteilt daneben und wurde von
    /// iPhone und iPad nicht benutzt: hier wartete die Serienseite bei
    /// **jedem** Oeffnen auf den Server. Auf dem Mac waren das gemessene 92
    /// bis 174 ms leere Seite, und das Nachreichen kommt zu spaet.
    ///
    /// **Ein Unterschied zur Mac-Fassung, mit Absicht.** Die waehlt aus dem
    /// Gemerkten immer eine Staffel, notfalls die erste. Kommt man ohne
    /// Hinweis auf die Seite, kennt `laden()` aber den besseren Weg — die
    /// Staffel, in der man gerade steht (`stand?.seasonId`). Deshalb wird die
    /// Wahl hier nur vorgezogen, wenn ein Hinweis mitkam; sonst steht die
    /// Staffelliste sofort und nur die Auswahl faellt einen Wimpernschlag
    /// spaeter. Der leere Durchgang ist so oder so weg.
    @MainActor init(model: AppModel, serie: Item,
                    startStaffelID: String? = nil, startStaffelNummer: Int? = nil) {
        self.model = model
        self.serie = serie
        self.startStaffelID = startStaffelID
        self.startStaffelNummer = startStaffelNummer

        let gemerkt = Serienspeicher.geteilt.stand(serie.id, mit: model)
        let staffeln = gemerkt?.staffeln ?? []
        _staffeln = State(initialValue: staffeln)

        let hinweis = startStaffelID != nil || startStaffelNummer != nil
        let staffel = hinweis
            ? staffeln.first { $0.id == startStaffelID }
                ?? staffeln.first { $0.indexNumber != nil
                                    && $0.indexNumber == startStaffelNummer }
            : nil
        _gewaehlteStaffel = State(initialValue: staffel)

        let folgen = staffel.flatMap { gemerkt?.folgen[$0.id] } ?? []
        _folgen = State(initialValue: folgen)
        _laedt = State(initialValue: folgen.isEmpty)
    }

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit
    @Environment(\.weit) private var weit
    @Environment(\.displayScale) private var pixelmass
    /// Fuer das Kopfbild, das mit einem Download aufs Geraet geht.
    @State private var seitenbreite: CGFloat = 0

    /// Wie weit gescrollt wurde — der Kopf blendet danach ein.
    /// Siehe `ItemDetailView.weg` — als `@State` baute jeder Scrollschritt die Seite neu.
    @State private var weg = Scrollweg()

    @State private var stand: Item?
    /// **Ob die nächste Folge schon geklärt ist** — auch dann, wenn es keine
    /// gibt. Der Zwischenspeicher bringt Staffeln und Folgen mit, aber nicht
    /// den Stand; mit gemerkten Folgen stand `laedt` deshalb schon am Anfang
    /// auf fertig, und der Knopf sagte eine Sekunde lang „Keine Folgen", bis
    /// der Stand kam. Bis hierhin heißt es jetzt „Lädt…".
    @State private var standGeklaert = false
    /// Der Plan ist beantwortet — mit oder ohne Ergebnis. Siehe `belegzeile`.
    @State private var planDa = false
    @State private var staffeln: [Item] = []
    /// **Drei Zustaende, nicht zwei.** `[]` heisst „die Serie hat keine
    /// Staffeln", diese Flagge heisst „der Server hat nicht geantwortet".
    /// Bis zum 21.09.2026 sahen beide gleich aus, und die Seite behauptete bei
    /// jedem Netzfehler, es gaebe nichts.
    @State private var staffelnGestoert = false
    @State private var gewaehlteStaffel: Item?
    @State private var folgen: [Item] = []
    /// Die Folgenliste hatte weder Lade- noch Leer- noch Stoerzweig: leere
    /// Staffel, gescheiterter Abruf und laufender Abruf sahen alle gleich aus.
    @State private var folgenLaedt = false
    @State private var folgenGestoert = false
    @State private var ladeblatt = false
    @State private var ladeposten: [Downloadposten] = []
    /// Die Stufe **vor** dem Ladeblatt: was soll geladen werden?
    @State private var auswahlOffen = false
    @State private var ladetitel = ""
    @State private var aehnliche: [Item] = []
    @State private var aehnlicheGestoert = false
    @State private var laedt = true
    @State private var abspielen: Abspielwunsch?
    @State private var mehrOffen = false
    @State private var meldung: String?
    @State private var bereitet = false
    @State private var gemerkt = false
    @State private var gesehen = false
    @State private var plan: PlaybackPlan?
    @State private var reiter = 0
    /// Breite des Rasters unter „Ähnliches" — daraus die Spaltenzahl, wie in
    /// Bibliothek, Suche und Merkliste.
    @State private var rasterbreite: CGFloat = 0
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
                        Heldkopf(bild: model.kopfbildURL(for: serie),
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
                        // **Knopf und Reihe sind ein Block, also stehen sie
                        // dichter.** Der Abstand war 14, genauso gross wie der
                        // zu allem anderen — waagerecht stehen die Felder der
                        // Reihe aber nur 8 auseinander. Damit war der Abstand
                        // nach oben groesser als der zwischen den Feldern, und
                        // die Reihe las sich als eigene Sache statt als
                        // Fortsetzung des Knopfs. Paul am 21.09.: „damit es
                        // irgendwie clean wie ein Element aussieht".
                        VStack(alignment: .leading, spacing: 8) {
                            hauptknopf
                            aktionsreihe
                        }
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
                // **Nie breiter als der Schirm.** Wird ein Kind breiter, ist es
                // sonst die ganze Seite — und eine Seite, die breiter ist als
                // ihre Scrollfläche, lässt sich seitwärts ziehen.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(.named("blatt"))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { seitenbreite = $0 }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
                weg.setzen(neu)
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
            // **Die Auswahl steht vor dem Ladeblatt, nicht daneben.** Sie
            // sammelt nur Folgen; Platz, WLAN und die Groesse rechnet weiter
            // `Ladeblatt`.
            Ladeauswahl(offen: $auswahlOffen, model: model, serie: serie,
                        staffeln: staffeln,
                        vorgeladen: gewaehlteStaffel.map { [$0.id: folgen] } ?? [:]) { gewaehlt in
                let neue = gewaehlt.compactMap { posten($0) }
                guard !neue.isEmpty else { return }
                blattZeigen(neue, titel: serie.name)
            }
            .zIndex(20)
            if let meldung {
                Hinweisstreifen(text: meldung) { self.meldung = nil }
                    .zIndex(21)
            }

            Detailkopfleser(titel: serie.name, weg: weg) { zurueck() }
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
        .playerCover(item: $abspielen) { wunsch in
            PlayerScreen(model: model, item: wunsch.item,
                         plan: wunsch.plan, startAt: wunsch.startAt)
        }
        #endif
        .task { await laden() }
        // **Nach dem Player neu holen**, und zwar erst, wenn die Endmeldung
        // durch ist — siehe `AppModel.wiedergabeBeendet`. Sonst blieben
        // Fortschritt und „gesehen" auf dem Stand von vor dem Abspielen.
        .onChange(of: model.seitenAuffrischen) { _, _ in
            Task { await laden(); await folgenLaden() }
        }
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
        // Doppelte Kennungen raus — siehe `ItemDetailView`.
        //
        // **`nil` ist keine leere Liste.** Bleibt der Server stumm, behaelt die
        // Seite, was sie hatte, und merkt sich die Stoerung. Vorher setzte
        // derselbe Fall beide Listen auf leer — die Staffelwahl verschwand und
        // darunter stand „Nichts Ähnliches gefunden".
        let (frischerStand, frischeStaffeln, frischeAehnliche) = await (a, b, c)
        stand = frischerStand
        staffelnGestoert = frischeStaffeln == nil
        if let frischeStaffeln { staffeln = frischeStaffeln }
        aehnlicheGestoert = frischeAehnliche == nil
        if let frischeAehnliche { aehnliche = Listenregeln.ohneDoppelte(frischeAehnliche) }
        standGeklaert = true
        // Kommt man von einer Folge, deren Staffel — sonst die, in der man
        // zuletzt war. Beim Auffrischen bleibt die getroffene Wahl stehen.
        // A10: erst der Hinweis (Kennung, dann Nummer), dann der Stand. Die
        // Kette liegt im Paket; die eigene Kopie hier prüfte die Kennung des
        // Stands vor der Nummer des Hinweises — kam eine Folge ohne
        // `SeasonId`, stand die laufende Staffel da statt ihrer.
        if gewaehlteStaffel == nil {
            gewaehlteStaffel = Staffelwahlregel.waehle(aus: staffeln,
                                                       hinweisID: startStaffelID,
                                                       hinweisNummer: startStaffelNummer,
                                                       stand: stand)
        }
        Protokoll.schreib("[Staffel] \(serie.name): mitgebracht=\(startStaffelID ?? "-")/\(startStaffelNummer.map(String.init) ?? "-") "
            + "stand=\(stand.map { "S\($0.parentIndexNumber ?? -1)E\($0.indexNumber ?? -1) " + ($0.seasonId ?? "-") } ?? "-") "
            + "gewaehlt=\(gewaehlteStaffel?.name ?? "-") "
            + "vorhanden=[\(staffeln.map { "\($0.name)=\($0.id)" }.joined(separator: " "))]")
        // Fuer den naechsten Weg auf dieselbe Serie — und fuer den Weg von
        // einer Folge aus, der sonst die Serie jedes Mal nachholt.
        Serienspeicher.geteilt.merken(serie)
        Serienspeicher.geteilt.merken(serie.id) { $0.staffeln = staffeln }
        gemerkt = serie.userData?.isFavorite ?? false
        gesehen = serie.userData?.played ?? false
        if let stand { plan = await model.plan(for: stand.id) }
        withAnimation(Stil.einblenden) { planDa = true }
        await folgenLaden()
        laedt = false
    }

    private func auffrischen() async { await laden() }

    // MARK: Teile

    private var hero: some View {
        Heldbild(url: model.kopfbildURL(for: serie))
            .overlay(alignment: .bottom) { Heldauslauf() }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(serie.name)
                        .font(Stil.titel)
                        .tracking(Stil.sperrungTitel)
                        .foregroundStyle(Stil.schrift)
                    Text(nebenzeile)
                        // Jahr, Staffeln, Genre sind eine Angabe: 12. Vorher
                        // 14, was in keiner Stufe vorkommt.
                        .font(Stil.klein)
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

    /// **Erst mit dem Plan, dann als Ganzes.** Sterne und FSK sind sofort da,
    /// die Direct-Play-Marke erst mit dem Wiedergabeplan — und schob sich dann
    /// links davor und die beiden anderen nach rechts. Jetzt hält die Zeile
    /// ihren Platz, bleibt aber unsichtbar, bis der Plan da ist, und blendet
    /// dann auf einmal ein. Kommt kein Plan, blendet sie trotzdem ein — dann
    /// eben ohne Marke.
    private var belegzeile: some View {
        Belegzeile(direktplay: plan?.isLossless ?? false,
                   hinweis: plan.map { $0.isLossless ? nil : $0.method.rawValue } ?? nil,
                   bewertung: serie.communityRating,
                   freigabe: serie.officialRating)
            // **Feste Höhe, auch leer.** Die Zeile kommt erst mit dem Plan —
            // und aus der Liste oft ohne Bewertung und Freigabe. Leer hatte sie
            // keine Höhe, der Knopf darunter saß höher und rutschte nach
            // unten, sobald sie sich füllte. So hoch wie eine Marke, immer.
            // `height`, nicht `minHeight`: der Umbau auf mitwachsende Schrift
            // hat daraus ein Mindestmass gemacht und damit die Begruendung
            // darueber entwertet — bei groesserer Systemschrift waere die Zeile
            // ueber 26 gewachsen und der Knopf haette genau so gesprungen, wie
            // es hier steht. Die Zeile traegt nur Plaketten, und Plaketten
            // bleiben fest (BRAND 2).
            .frame(height: 26, alignment: .leading)
            .opacity(planDa ? 1 : 0)
    }

    private var hauptknopf: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                if let stand { starte(stand) }
            } label: {
                // **Leer, bis die Folge feststeht — dann blendet der Inhalt an
                // seinem Platz ein.** Vorher stand dort „Lädt…" und wechselte
                // zur Folge; die Beschriftung wurde breiter, und das Symbol fuhr
                // aus der Mitte nach links. Jetzt kommt der ganze Inhalt auf
                // einmal, und nichts bewegt sich. Der unsichtbare Platzhalter
                // hält die Höhe, damit der Knopf dabei nicht wächst.
                ZStack {
                    Text(verbatim: " ").hidden()
                    if knopfBereit {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill").font(.system(size: 15))
                                .opacity(bereitet ? 0.5 : 1)
                            Text(knopftext)
                        }
                        .transition(.opacity)
                    }
                }
                .animation(Stil.einblenden, value: knopfBereit)
                .accessibilityLabel(Text(knopftext))
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
            .disabled(bereitet || (stand == nil && standGeklaert && !laedt))

            if let stand, let rest = restzeit(stand) {
                // Restzeit ist eine Angabe: 12. Vorher 11 — die Stufe gehoert
                // den Gruppentiteln in Versalien, nicht einer Zeile Fliesstext.
                Text(rest).mitwachsend(12).foregroundStyle(Stil.schriftLeise)
            }
            // Breit sitzt der Fortschritt am Poster im Kopf — hier wäre er
            // ein zweites Mal dasselbe, und zwar quer über die Seite.
            if !breit, let stand, let anteil = stand.userData?.playedPercentage,
               anteil > 0 {
                Fortschrittsbalken(anteil: anteil / 100)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
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
            // **Laden steht in der Reihe, nicht in einem versteckten Chip.**
            //
            // Vorher war Laden an drei Stellen verstreut, und die
            // auffaelligste davon war ein runder Chip neben der Staffelwahl,
            // an dem niemand sucht. Jetzt hat es einen Platz zwischen Merken
            // und Gesehen — wie am Mac und am Fernseher. Der Trailer weicht
            // dafuer in die Mehr-Tafel: ein Trailer ist etwas zum Abspielen,
            // kein Dauergast in einer Reihe mit vier Plaetzen.
            //
            // Sind Downloads aus, gibt es nichts zu laden, und der Trailer
            // behaelt seinen Platz.
            if model.downloadKnopfZeigen {
                Aktionsknopf(symbol: "arrow.down", titel: "Laden", dehnt: !weit) {
                    // **Immer das Auswahlblatt, auch bei einer Staffel.**
                    //
                    // Erst hing es an `staffeln.count > 1` — bei einer Serie mit
                    // einer Staffel ging es direkt ins Ladeblatt und nahm die
                    // ganze Staffel. Genau das war die Luecke: einzelne Folgen
                    // waehlen konnte man dann nicht. Eine Serie hat immer
                    // Folgen, also gibt es immer etwas zu waehlen.
                    auswahlOffen = true
                }
            } else {
                Aktionsknopf(symbol: "film", titel: "Trailer", dehnt: !weit) { trailerStarten() }
            }
            Aktionsknopf(symbol: gesehen ? "checkmark.circle.fill" : "checkmark.circle",
                         titel: "Gesehen", aktiv: gesehen, dehnt: !weit) {
                gesehen.toggle()
                Task {
                    if let grund = await model.setzeGesehen(serie, an: gesehen) {
                        gesehen.toggle()
                        meldung = grund
                    }
                    // Nachgeladen wird ueber `model.seitenAuffrischen`.
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
        if let text = serie.beschreibung {
            Klapptext(text: text)
        }
    }

    private var folgenbereich: some View {
        // Über die volle Breite, wie auf dem iPhone. Der Haken gehört an den
        // rechten Rand der Zeile; auf ein Lesemaß eingeschnürt stand er
        // mitten auf der Seite und sah aus, als gehöre er zu nichts.
        folgenliste
    }

    @ViewBuilder
    private var folgenliste: some View {
        VStack(alignment: .leading, spacing: 0) {
            if staffelnGestoert && staffeln.isEmpty {
                // Ohne Staffeln keine Folgen: die Stoerung gehoert an den Anfang
                // des Abschnitts, nicht unter eine leere Staffelwahl.
                Stoerhinweis(model: model) { Task { await laden() } }
            } else if !staffeln.isEmpty {
                // **Der Rückfall muss übersetzt werden, der Name nicht.**
                //
                // `beschriftung` ist ein `String`, weil links davon der
                // Staffelname vom Server steht — der wird nicht übersetzt.
                // Rechts vom `??` stand aber unser eigenes Wort, und ein
                // deutsches Wort in einem `String` landet nie im Katalog:
                // `Text(einString)` ist wörtlich. Eine Staffel ohne Namen
                // hieß damit auch auf Englisch „Staffel".
                //
                // Der Schlüssel gibt es längst („Staffel" → „Season"), er
                // wurde hier nur nicht nachgeschlagen.
                Aufklappliste(beschriftung: gewaehlteStaffel?.name
                                  ?? String(localized: "Staffel"),
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
            }

            // **Vier Zweige, wo vorher einer stand.** Ist der Abruf
            // gescheitert, sagt die Seite das; laeuft er noch, stehen
            // Platzhalter da (wie auf macOS); ist die Staffel wirklich leer,
            // steht es da. Vorher war alles drei dieselbe leere Flaeche.
            if folgenGestoert {
                Stoerhinweis(model: model) { Task { await folgenLaden() } }
            } else if folgenLaedt && folgen.isEmpty {
                VStack(spacing: 0) {
                    ForEach(0 ..< 3, id: \.self) { _ in
                        HStack(spacing: 12) {
                            Ladefeld().frame(width: 132, height: 74)
                            VStack(alignment: .leading, spacing: 8) {
                                Ladefeld(ecke: 3).frame(width: 170, height: 13)
                                Ladefeld(ecke: 3).frame(width: 80, height: 11)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .transition(.opacity)
            } else if folgen.isEmpty && !staffeln.isEmpty {
                // **Kein neuer Wortlaut.** „Keine Folgen in dieser Staffel" steht
                // seit Langem im Katalog (tvOS nutzt es); ein zweiter Satz
                // fuer dieselbe Lage waere ein zweiter Eintrag, der in einer
                // Sprache irgendwann anders klingt.
                leerhinweis("Keine Folgen in dieser Staffel")
            } else {
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
                        // **Kein Ladering je Folge mehr.**
                        //
                        // Er war einer von drei Wegen zum Laden, und mit dem
                        // Auswahlblatt ist er der schlechteste: eine Spalte am
                        // rechten Rand jeder Zeile, 26 Punkt, die bei
                        // fuenfundzwanzig Folgen fuenfundzwanzig Mal dasselbe
                        // anbietet. Wer eine einzelne Folge will, hakt sie im
                        // Blatt an — dort sieht er dabei auch, wie gross sie
                        // ist. Paul am 21.09.: „die ergeben natuerlich keinen
                        // Sinn, wenn man die jetzt ueber so ein extra Menue
                        // runterlaedt".
                        Folgenzeile(model: model, folge: folge,
                                    // **Nur im Player.** Dort sagt das groessere
                                    // Bild „das laeuft gerade"; auf der
                                    // Serienseite sagt es der grosse Knopf
                                    // oben, und eine Zeile, die aus der Reihe
                                    // faellt, waere dort eine zweite Auskunft.
                                    laufend: false)
                    }
                    // **Keine Trennlinie mehr.** Das Standbild trennt die
                    // Zeilen schon; eine Haarlinie daneben sagt dasselbe ein
                    // zweites Mal. Wo die Liste ueberhaupt eine Marke braucht —
                    // an der laufenden Folge —, traegt sie eine Flaeche, und
                    // die sitzt in `Folgenzeile`.
                }
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
                    NavigationLink(value: PersonRoute(person: person, herkunft: serie.name)) {
                        Besetzungskachel(bild: model.personBild(person),
                                         name: person.name, rolle: person.role)
                    }
                    .buttonStyle(Stil.Druckknopf())
                }
            }
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.top, 20)
        }
    }

    @ViewBuilder
    private var aehnlichesbereich: some View {
        if aehnlicheGestoert && aehnliche.isEmpty {
            Stoerhinweis(model: model) { Task { await laden() } }
        } else if aehnliche.isEmpty {
            leerhinweis("Nichts Ähnliches gefunden.")
        } else {
            // **Dieselbe Spaltenrechnung wie Bibliothek und Suche.** Hier stand
            // ein adaptives Raster mit fester Mindestbreite je Kachel. Auf dem
            // iPhone passten damit zwei nebeneinander, rechts blieb eine
            // Lücke — überall sonst stehen an derselben Stelle drei. Von einem
            // Tester gemeldet.
            let nutzbar = rasterbreite - 2 * Stil.rand(breit: breit)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Stil.kachelAbstand),
                                     count: Stil.spalten(nutzbar: nutzbar, breit: breit)),
                      alignment: .leading, spacing: 20) {
                ForEach(aehnliche) { titel in
                    NavigationLink(value: titel) {
                        PosterTile(model: model, item: titel, breite: nil)
                    }
                    .buttonStyle(Stil.Druckknopf())
                }
            }
            .padding(.horizontal, Stil.rand(breit: breit))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rasterbreite = $0 }
            .padding(.top, 20)
        }
    }

    /// **`LocalizedStringKey`, nicht `String`.** `Text(einString)` ist
    /// woertlich: Xcode zieht den Text nie in den Katalog, und er bleibt in
    /// jeder Sprache deutsch stehen. Genau so stand auf einem englischen
    /// Geraet „Keine Besetzung hinterlegt." mitten in einer englischen Seite.
    private func leerhinweis(_ text: LocalizedStringKey) -> some View {
        Text(text)
            // Leerzustaende folgen der Systemschrift (BRAND 2).
            .mitwachsend(15)
            .foregroundStyle(Stil.schriftSehrLeise)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
    }

    // MARK: Ableitungen

    /// Die Beschriftung steht fest: die Folge ist geklärt und, falls es keine
    /// gibt, auch das Laden der Staffel vorbei.
    private var knopfBereit: Bool { standGeklaert && (stand != nil || !laedt) }

    private var knopftext: String {
        Item.serienknopf(folge: stand, laedt: laedt || !standGeklaert)
    }

    private func restzeit(_ folge: Item) -> String? { folge.restzeitText }


    private func folgenLaden() async {
        folgenLaedt = true
        let geholt = await model.folgen(serie: serie.id, staffel: gewaehlteStaffel?.id)
        folgenLaedt = false
        folgenGestoert = geholt == nil
        // Gescheitert: die alte Liste bleibt stehen, und nichts kommt in den
        // Speicher — ein zwischengespeicherter Netzfehler waere schlimmer als
        // gar keiner.
        guard let geholt else { return }
        folgen = geholt
        if let id = gewaehlteStaffel?.id {
            Serienspeicher.geteilt.merken(serie.id) { $0.folgen[id] = geholt }
        }
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

    /// Das Plakat der Serie plus das Querbild jeder Folge, die geladen wird —
    /// und das grosse Kopfbild fuer die Serienseite in den Downloads.
    ///
    /// **Das Kopfbild in Bildschirmaufloesung.** `Heldbild` ist 300 hoch und
    /// fuellt die Breite; ein 16:9-Bild braucht dafuer mindestens 533 Punkt
    /// Breite, auf dem iPad die volle. Mal der Skalierung, damit es auf dem
    /// Geraet scharf ist. Das Plakat 600 hoch statt der 300 einer Kachel.
    private var ladebilder: [String: URL] {
        var karte: [String: URL] = [:]
        if let plakat = model.imageURL(for: serie, maxHeight: 600, hochkant: true) {
            karte[serie.id] = plakat
        }
        let punkte = max(seitenbreite, Stil.heldHoehe * 16 / 9)
        if let kopf = model.kopfbildURL(for: serie, breite: Int((punkte * pixelmass).rounded(.up))) {
            karte[Downloadverwaltung.kopfschluessel(serie.id)] = kopf
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
        let neue = offene.compactMap { posten($0) }
        guard !neue.isEmpty else { return }
        blattZeigen(neue, titel: gewaehlteStaffel?.name ?? serie.name)
    }

    /// **Erst den Inhalt setzen, dann zeigen — und zwar einen Durchgang
    /// spaeter.**
    ///
    /// Das Blatt faehrt um seine gemessene Hoehe herein. Wird der Inhalt im
    /// selben Durchgang gesetzt, in dem `offen` umspringt, gilt fuer die
    /// Bewegung noch die **alte** Messung: die Karte faehrt, die Texte darin
    /// wechseln waehrenddessen und stehen dann einfach da. Der `Task` schiebt
    /// das Zeigen um einen Durchgang; dazwischen wird die Karte einmal mit
    /// ihrem neuen Inhalt gemessen — geschlossen und unsichtbar.
    ///
    /// Dieselbe Stelle, dieselbe Loesung wie bei den Auswahlblaettern in
    /// `a6dab91`.
    private func blattZeigen(_ neue: [Downloadposten], titel: String) {
        ladeposten = neue
        ladetitel = titel
        // **Ein Blatt zur Zeit.** Kommt der Ruf aus dem Auswahlblatt, faehrt
        // das gerade hinunter — beide zugleich waeren zwei Karten, die sich
        // kreuzen. Ein Wimpernschlag Abstand reicht; die Feder braucht 0,35 s,
        // und 0,26 s davon sieht man als Uebergabe, nicht als Warten.
        Task { @MainActor in
            if auswahlOffen { try? await Task.sleep(for: .milliseconds(260)) }
            ladeblatt = true
        }
    }

    /// **Eine einzelne Folge laden — jetzt ueber das Auswahlblatt.**
    ///
    /// Aus einer Nutzermeldung: eine Anime-Staffel hat ueber hundert Folgen,
    /// und fuer die Bahnfahrt sollen zwei davon mit. Eine ganze Staffel ist
    /// dafuer die falsche Groessenordnung.
    ///
    /// Den Weg dafuer nimmt seit dem 21.09. `Ladeauswahl`: dort hakt man die
    /// Folgen an und sieht dabei, was sie zusammen wiegen. Der Ring an jeder
    /// Zeile, der dasselbe einzeln konnte, ist damit weggefallen — er bot bei
    /// fuenfundzwanzig Folgen fuenfundzwanzig Mal dasselbe an.

    private func starte(_ folge: Item) {
        guard !bereitet else { return }
        // Beim Druck, nicht nach dem Abruf: ein Ruck, der eine halbe
        // Sekunde spaeter kommt, gehoert gefuehlt zu nichts mehr.
        Stil.ruck(.mittel)
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
    /// Die Folge, die gerade laeuft — im Player die, die man gerade sieht.
    ///
    /// **Ein groesseres Bild, keine Flaeche.** Sie trug zuletzt eine Flaeche
    /// in weiss 8 %, und im Player lief die ueber die **volle Breite**: ein
    /// durchgehender Streifen bis an beide Kanten. Am iPhone faehrt der damit
    /// unter die Dynamic Island, und die wird sichtbar — in einer Ebene, in
    /// der man sie sonst gar nicht bemerkt. Paul am 22.09.: „dadurch sieht man
    /// die Dynamic Island, die man sonst ueberhaupt nicht sehen wuerde."
    ///
    /// Jetzt waechst das Vorschaubild nach rechts, links bleibt es mit den
    /// anderen buendig. Das sagt dasselbe, ohne eine Flaeche bis an den Rand
    /// zu ziehen — und es sagt es an dem Gegenstand, um den es geht.
    var laufend = false

    private var gesehen: Bool { folge.userData?.played ?? false }
    private var geladen: Downloadposten? { model.downloads.posten(fuer: folge.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            vorschau

            VStack(alignment: .leading, spacing: 3) {
                Text("\(folge.indexNumber.map { "\($0). " } ?? "")\(folge.name)")
                    // Titel einer Zeile mit Bild: 15 Semifett. Vorher 14
                    // Medium — der Grad stand in keiner Leiter, und die Zeile
                    // war damit leiser als jede gewoehnliche Listenzeile,
                    // obwohl sie dasselbe traegt.
                    // **Mitwachsend, nicht fest** (BRAND 2): eine Zeile mit
                    // Bild ist eine Listenzeile, und Listen folgen der
                    // Systemschrift. Fest bleiben auf dieser Seite das Plakat,
                    // die Plaketten und die tabellarischen Dateiangaben.
                    .mitwachsend(15, .semibold)
                    // **Gesehenes tritt zurueck, es verschwindet nicht.** Der
                    // gedaempfte Titel ist die dritte Auskunft neben dem
                    // abgedunkelten Bild und dem Haken darauf — zusammen liest
                    // man den Zustand, ohne ein Zeichen suchen zu muessen.
                    .foregroundStyle(gesehen ? Stil.schriftLeise : Stil.schrift)
                    .multilineTextAlignment(.leading)
                    // **Einzeilig.** Zwei Zeilen liessen die Zeilen einer
                    // Staffel verschieden hoch enden und schoben die Angabe
                    // darunter weg — dieselbe Entscheidung wie auf der Kachel.
                    .lineLimit(1)

                Text(nebenzeile)
                    // Die Angabe unter dem Titel waechst mit ihm — sonst
                    // folgte die halbe Zeile der Systemschrift und die
                    // andere Haelfte nicht.
                    .mitwachsend(12)
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
        }
        .padding(.horizontal, Stil.rand(breit: breit))
        .padding(.vertical, 12)
        // **Keine Flaeche.** Die Folge, auf die der grosse Knopf zeigt, trug
        // eine in weiss 8 % — am Geraet sah das aus wie eine Auswahl, die
        // niemand getroffen hat. Was `laufend` heute tut, steht am Feld: das
        // Bild waechst.
        .contentShape(Rectangle())
    }

    /// Das Vorschaubild traegt den Sehstand: angefangen als Balken, gesehen
    /// als Haken auf abgedunkeltem Grund. Dasselbe Abzeichen wie oben rechts
    /// auf einer Plakatkachel — kein neues Zeichen, nur an einem Ort mehr.
    /// 152 statt 116, bei gleichem Seitenverhaeltnis — gross genug, dass man
    /// es ohne Vergleich sieht, klein genug, dass die Zeile nicht springt.
    /// 134 statt 152 — gross genug, dass man es ohne Vergleich sieht, klein
    /// genug, dass die Zeile nicht aus der Liste faellt. Paul am 22.09.: „soll
    /// nicht so riesig sein, gerne ein wenig kleiner."
    private var bildbreite: CGFloat { laufend ? 134 : 116 }

    private var vorschau: some View {
        Bild(url: model.imageURL(for: folge, maxHeight: 220),
             breite: bildbreite, hoehe: bildbreite * 65 / 116, ecke: Stil.eckeKachel,
             // Ein voller Balken **und** ein Haken waeren dieselbe Auskunft
             // zweimal.
             fortschritt: gesehen ? nil
                                  : folge.userData?.playedPercentage.map { $0 / 100 })
            .opacity(gesehen ? 0.45 : 1)
            .overlay(alignment: .topTrailing) {
                if gesehen {
                    Image(systemName: "checkmark")
                        // Plakettengrad: 10 Semifett. Vorher 9 in `.heavy` —
                        // die Stufe gibt es nicht, und das Gewicht ist
                        // gestrichen; es sind drei, nicht fuenf.
                        .font(Stil.plakette)
                        .foregroundStyle(Stil.schrift)
                        .frame(width: 18, height: 18)
                        // **0,78 wie jede andere dunkle Scheibe auf einem
                        // Bild** — dieselbe Zahl, die die Kachelmarke traegt.
                        // Hier standen 0,72, im Technikschild 0,88: drei Werte
                        // fuer dieselbe Aufgabe, und dieser Haken liegt im
                        // Raster neben einer Kachelmarke.
                        .background(Stil.grund.opacity(0.78), in: Circle())
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
        // Nur die Laufzeit: die Dateigröße steht in der Ladeauswahl, an der
        // Folge ist sie eine Zahl ohne Frage dahinter (Paul, 22.09.2026).
        return folge.restzeitText ?? "\(Int(gesamt / 60)) min"
    }
}

/// Folgenliste einer Staffel — für den Weg über die Bibliothek.
struct SeasonView: View {
    let model: AppModel
    let serie: Item
    let staffel: Item

    @State private var folgen: [Item] = []
    @State private var laedt = true
    @State private var gestoert = false
    @State private var abspielen: Abspielwunsch?
    /// Sperre gegen den zweiten Tipp, während der Plan noch geholt wird.
    /// Fehlte hier — auf der Serienseite gab es sie, in der Staffelansicht nicht.
    @State private var bereitet = false

    @Environment(\.breit) private var breit
    @Environment(\.dismiss) private var zurueck

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()
            VStack(spacing: 0) {
            // **Unser Kopf, nicht Apples Leiste.**
            //
            // Diese Seite war die einzige von dreiundzwanzig, die Apples
            // Systemleiste zeigte — mit deren Zurueckpfeil, deren Grad und
            // deren Material. Jede andere Unterseite blendet sie aus und
            // traegt `Unterseitenkopf` oder `Detailkopf`. Aufgefallen ist es
            // erst im Abgleich aller Seiten nebeneinander; einzeln sieht so
            // etwas nie falsch aus.
            Unterseitenkopf(titel: staffel.name) { zurueck() }
            ScrollView {
                VStack(spacing: 0) {
                    // `laedt` stand hier bisher ungenutzt da — die Seite war
                    // waehrend des Abrufs, bei leerer Staffel und bei einem
                    // stummen Server dieselbe weisse Flaeche.
                    if gestoert {
                        Stoerhinweis(model: model) { Task { await folgenLaden() } }
                    } else if laedt {
                        VStack(spacing: 0) {
                            ForEach(0 ..< 4, id: \.self) { _ in
                                HStack(spacing: 12) {
                                    Ladefeld().frame(width: 132, height: 74)
                                    VStack(alignment: .leading, spacing: 8) {
                                        Ladefeld(ecke: 3).frame(width: 170, height: 13)
                                        Ladefeld(ecke: 3).frame(width: 80, height: 11)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 10)
                            }
                        }
                        .padding(.horizontal, Stil.rand(breit: breit))
                    } else if folgen.isEmpty {
                        Text("Keine Folgen in dieser Staffel")
                            .mitwachsend(15)
                            .foregroundStyle(Stil.schriftSehrLeise)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(folgen) { folge in
                        let gesehen = (folge.userData?.played ?? false)
                        Wischzeile(symbol: gesehen ? "arrow.uturn.backward" : "checkmark",
                                   beschriftung: gesehen ? "Ungesehen" : "Gesehen",
                                   aktion: { gesehenUmschalten(folge) },
                                   tippen: { starte(folge) }) {
                            Folgenzeile(model: model, folge: folge)
                        }
                        // Keine Trennlinie: das Standbild trennt schon. Hier
                        // stand dieselbe von Hand gebaute Linie wie auf der
                        // Serienseite — beide sind weg.
                    }
                }
            }
            .scrollIndicators(.hidden)
            }
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        #if os(iOS)
        .playerCover(item: $abspielen) { wunsch in
            PlayerScreen(model: model, item: wunsch.item,
                         plan: wunsch.plan, startAt: wunsch.startAt)
        }
        #endif
        .task(id: model.seitenAuffrischen) { await folgenLaden() }
    }

    private func folgenLaden() async {
        laedt = true
        let geholt = await model.folgen(serie: serie.id, staffel: staffel.id)
        laedt = false
        gestoert = geholt == nil
        if let geholt { folgen = geholt }
    }

    private func starte(_ folge: Item) {
        guard !bereitet else { return }
        // Beim Druck, nicht nach dem Abruf: ein Ruck, der eine halbe
        // Sekunde spaeter kommt, gehoert gefuehlt zu nichts mehr.
        Stil.ruck(.mittel)
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
            // Scheitert das Nachladen, bleibt die Liste stehen — der Haken ist
            // gesetzt, das ist die Auskunft, auf die es hier ankommt.
            if let frisch = await model.folgen(serie: serie.id, staffel: staffel.id) {
                folgen = frisch
            }
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

    func trailerStarten() {
        Trailerstart.starten(serie, model: model,
                             abspielen: { abspielen = $0 },
                             melden: { meldung = $0 })
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
        var liste = Titelhandlungen.fuerSerie(serie, stand: stand, staffel: gewaehlteStaffel,
                                              model: model,
                                              folgeStarten: { folgeStarten($0, ab: $1) },
                                              melden: { meldung = $0 },
                                              auffrischen: { await auffrischen() })
        // Der Trailer, wenn Laden seinen Platz in der Reihe hat. Nicht
        // andersherum: sonst stuende er zweimal da.
        if model.downloadKnopfZeigen {
            liste.insert(.init(symbol: "film", text: "Trailer") { trailerStarten() }, at: 0)
        }
        return liste
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
