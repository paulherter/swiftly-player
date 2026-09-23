import JellyfinKit
import SwiftUI

struct PosterTile: View {
    let model: AppModel
    let item: Item
    /// Im Raster füllt die Kachel ihre Spalte, in einer Reihe hat sie ihr
    /// festes Maß. Fest gesetzt passten nur zwei Spalten nebeneinander und
    /// rechts blieb eine breite Lücke.
    var breite: CGFloat? = Stil.kachelBreite
    /// Vorgegebene Auskunft statt der eigenen.
    ///
    /// Die Trefferliste sagt mehr als eine Bibliothek — Art, Jahr, Staffeln,
    /// **Laufzeit**. Als das Raster die Zeilen ablöste, fiel die Laufzeit
    /// weg, und damit sagte dieselbe Suche auf dem iPad weniger als auf dem
    /// iPhone. D4 gilt auch für Trefferlisten.
    var auskunft: String?
    /// **Nur für eine Sammlungskachel:** Sammlung und Bereich, aus denen ein
    /// Ersatzplakat gebaut wird, falls die Sammlung selbst keins hat.
    var mosaikQuelle: (sammlung: Sammlung, art: String)? = nil

    /// Bei einer Folge steht oben die Serie und unten die Nummer — sonst
    /// Titel und Jahr.
    ///
    /// Dieselbe Regel wie in der Reihe auf der Startseite. Sie fehlte hier,
    /// solange dieses Plakat nur Filme und Serien zeigte; seit die Suche
    /// breit ein Raster statt Zeilen bringt, landen auch Folgen darin — und
    /// standen dort ohne jeden Hinweis, um welche es geht.
    private var titelzeile: String {
        item.type == "Episode" ? (item.seriesName ?? item.name) : item.name
    }

    private var unterzeile: String? {
        if let auskunft { return auskunft }
        if item.type == "Episode" { return item.folgenkuerzel }
        return item.productionYear.map(String.init)
    }

    /// **Plakat und Text blenden zusammen ein.**
    ///
    /// Das Bild blendet seit dem Umbau von selbst ein, der Titel darunter
    /// stand sofort da — beim Wechsel der Bibliothek sah man erst die
    /// Beschriftungen und dann die Plakate hineinlaufen. Die Kachel blendet
    /// deshalb als Ganzes ein, und das Bild darin bringt seinen eigenen
    /// weichen Wechsel mit.
    @State private var da = false

    /// **Das Plakat, oder sein Ersatz.**
    ///
    /// Eine Sammlung ohne eigenes Titelbild bekäme sonst nur das Filmsymbol
    /// — bei einer Sammlung mit fünf Filmen eine Auskunft, die nichts sagt.
    /// `mosaikQuelle` steht nur an der Sammlungskachel; überall sonst ist es
    /// `nil`, und hier steht genau das Plakat wie vorher.
    @ViewBuilder
    private var plakat: some View {
        if let mosaikQuelle, item.imageTags?["Primary"] == nil {
            Sammlungsmosaik(model: model, sammlung: mosaikQuelle.sammlung,
                            art: mosaikQuelle.art, breite: breite)
        } else {
            Bild(url: model.imageURL(for: item, maxHeight: 500, hochkant: true),
                 breite: breite,
                 hoehe: breite.map { $0 * 1.5 },
                 verhaeltnis: breite == nil ? 2.0 / 3.0 : nil,
                 ecke: Stil.eckeKachel,
                 fortschritt: item.userData?.playedPercentage.map { $0 / 100 }) {
                Stil.flaeche.overlay {
                    Image(systemName: "film").foregroundStyle(Stil.schriftSehrLeise)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Feste Breite: feste Höhe. Füllt die Kachel ihre Spalte, folgt
            // die Höhe der tatsächlichen Breite — 2 : 3, wie jedes Plakat.
            plakat
            // **Drei Zustaende, drei Zeichen.** Balken heisst angefangen,
            // Haken heisst gesehen, eine Zahl heisst: so viel liegt hier.
            // Bis hierher gab es nur den Balken — und bei einer Serie sagt
            // der gar nichts, weil er den Stand der angefangenen Folge zeigt
            // und nicht den der Serie.
            .overlay(alignment: .topTrailing) {
                if let marke = Anzeigeregeln.kachelmarke(
                    art: item.type,
                    staffeln: item.childCount,
                    gesehen: item.userData?.played,
                    offeneFolgen: item.userData?.unplayedItemCount) {
                    Kachelplakette(marke: marke)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                // **Einzeilig.** Zwei Zeilen liessen die Kacheln einer Reihe
                // verschieden hoch enden, und der laengere Titel schob seine
                // Angabe nach unten. Gekuerzt wird mit Punkten, nicht
                // umgebrochen.
                Text(titelzeile)
                    .font(Stil.kachel)
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                if let unterzeile {
                    Text(unterzeile)
                        .font(Stil.klein)
                        // Die Angabe unter einem Plakat ist der leiseste Ton,
                        // nicht der mittlere: `schriftLeise` traegt Fliesstext
                        // und Werte, eine Jahreszahl unter dem Titel nicht.
                        .foregroundStyle(Stil.schriftSehrLeise)
                        // Die volle Trefferauskunft braucht auf 138 Punkt
                        // zwei Zeilen. In der Bibliothek steht dort nur ein
                        // Jahr, da bleibt es bei einer.
                        .lineLimit(auskunft == nil ? 1 : 2)
                }
            }
            // **Der Text ist so breit wie das Plakat, nicht wie der Titel.**
            //
            // Hier stand keine Grenze. Ein `VStack` ist so breit wie sein
            // breitestes Kind, und ein einzeiliger Text kuerzt erst, wenn ihm
            // jemand eine Breite vorgibt — sonst waechst er. In einer Reihe
            // mit fester Kachelbreite wurde die Kachel dadurch breiter als
            // ihr Plakat, und „Obsession – Du sollst mich lieben" lief nach
            // rechts ueber die Reihe hinaus. Auffaellig wurde es nur bei der
            // letzten Kachel, weil dort rechts Platz ist; bei den anderen
            // schob sie sich hinter den Nachbarn.
            //
            // Im Raster gibt die Spalte die Breite vor, also `infinity`.
            .frame(maxWidth: breite ?? .infinity, alignment: .leading)
        }
        // Im Raster richtet SwiftUI die Zellen einer Zeile mittig aus. Bei
        // zweizeiligen Titeln rutschten die kürzeren Kacheln dadurch nach
        // unten und die Poster lagen nicht mehr auf einer Linie.
        .frame(maxHeight: .infinity, alignment: .top)
        .opacity(da ? 1 : 0)
        .onAppear {
            guard !da else { return }
            withAnimation(Stil.einblenden) { da = true }
        }
        // Eine Aussage je Kachel statt zweier Bruchstücke, und der
        // Fortschritt kommt mit — er ist eine Zeichnung im Bild und fiel für
        // VoiceOver bisher heraus.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.name))
        .accessibilityValue(item.gesehenerAnteil.map {
            Text("\(Int($0 * 100)) Prozent gesehen")
        } ?? Text(""))
    }
}


// MARK: - Einzelner Titel

struct ItemDetailView: View {
    let model: AppModel
    let item: Item

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit
    @Environment(\.weit) private var weit

    /// Wie weit gescrollt wurde — der Kopf blendet danach ein.
    ///
    /// **Nicht als `@State` hier.** Jeder Scrollschritt baute sonst den ganzen
    /// `body` neu: Kopfbild mit `GeometryReader`, Belegzeile, Knopfreihe, drei
    /// Reihen, Dateiauszug. Auf der Filmseite stockte das Scrollen sichtbar, auf
    /// der leichteren Serienseite nicht. Jetzt liest nur `Detailkopfleser` den Wert
    /// — dieselbe Behebung wie `Scrollweg` auf der Startseite.
    @State private var weg = Scrollweg()

    @State private var plan: PlaybackPlan?
    /// Der Plan ist beantwortet — mit oder ohne Ergebnis. Siehe `belegzeile`.
    @State private var planDa = false
    @State private var ladeblatt = false
    @State private var pruefe = true
    @State private var abspielen: Abspielwunsch?
    @State private var mehrOffen = false
    @State private var meldung: String?
    @State private var frisch: Item?
    @State private var aehnliche: [Item] = []
    /// **`[]` und „gescheitert" sind zwei Dinge.** Der Abschnitt „Ähnliche
    /// Titel" verschwand bei einem Netzfehler ersatzlos, waehrend die
    /// Serienseite zwei Dateien weiter „Nichts Ähnliches gefunden" sagte —
    /// zwei Antworten auf dieselbe Frage, und beide falsch.
    @State private var aehnlicheGestoert = false
    @State private var extras: [Item] = []
    @State private var gemerkt = false
    @State private var gesehen = false

    private var aktuell: Item { frisch ?? item }

    /// Was von diesem Titel schon auf dem Gerät liegt — `nil` heisst nichts.
    private var geladen: Downloadposten? { model.downloads.posten(fuer: aktuell.id) }

    /// Der Eintrag, den ein Download bekäme. Die Größe kommt aus derselben
    /// Quelle, die der Player nähme — **H2**, es ist dieselbe Datei.
    private var alsPosten: Downloadposten? {
        guard let konto = model.session?.userID else { return nil }
        let quelle = plan?.quelle ?? aktuell.mediaSources?.first
        return Downloadposten(
            id: aktuell.id, konto: konto, art: .film, titel: aktuell.name,
            laufzeitTicks: aktuell.runTimeTicks, container: quelle?.container,
            quelle: quelle?.id, bytes: quelle?.size ?? 0,
            gesehen: aktuell.userData?.played ?? false)
    }

    private var fortsetzenAb: Double? { aktuell.fortsetzenAb }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if breit {
                        Heldkopf(bild: model.kopfbildURL(for: aktuell),
                                 poster: model.imageURL(for: aktuell, maxHeight: 600,
                                                        hochkant: true),
                                 titel: aktuell.name, nebenzeile: nebenzeile,
                                 fortschritt: aktuell.userData?.playedPercentage
                                     .map { $0 / 100 }) {
                            VStack(alignment: .leading, spacing: 14) {
                                belegzeile
                                // Knöpfe und Aktionsreihe in einer Zeile: hier
                                // ist Breite da, und untereinander stünden sie
                                // in einer halbleeren Spalte.
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
                        // Fließtext bekommt ein Maß. Über die volle Breite
                        // gezogen sind das Zeilen mit 140 Zeichen.
                        beschreibung
                            .frame(maxWidth: Stil.lesebreite, alignment: .leading)
                            .padding(.horizontal, Stil.randSeiteBreit)
                            .padding(.top, 18)
                    } else {
                    hero
                    VStack(alignment: .leading, spacing: 14) {
                        // Doch über dem Knopf, direkt unter dem Namen: unter
                        // ihm stand sie zwischen Knopf und Aktionsreihe und
                        // trennte zwei Dinge, die zusammengehören.
                        belegzeile
                        // **Knopf und Reihe sind ein Block, also stehen sie
                        // dichter.** Der Abstand war 14, genauso gross wie der
                        // zu allem anderen — waagerecht stehen die Felder der
                        // Reihe aber nur 8 auseinander. Damit war der Abstand
                        // nach oben groesser als der zwischen den Feldern, und
                        // die Reihe las sich als eigene Sache statt als
                        // Fortsetzung des Knopfs. Rückmeldung vom 21.09.: „damit es
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
                    }

                    besetzung
                    extrasreihe
                    // Über „Ähnliche Titel": die Sammlung ist die nähere
                    // Verwandtschaft. Nur bei Titeln, die in einer stehen.
                    Sammlungsreihe(model: model, titel: item)
                    aehnlichesreihe
                    // Die Dateiangaben ganz nach unten: sie beantworten eine
                    // Frage, die man erst später stellt.
                    dateiauszug
                }
                // **Nie breiter als der Schirm.** Wird ein Kind breiter, ist es
                // sonst die ganze Seite — und eine Seite, die breiter ist als
                // ihre Scrollfläche, lässt sich seitwärts ziehen.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(.named("blatt"))
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
                weg.setzen(neu)
            }

            // Das Blatt haengt an einer leeren Flaeche; ohne `if` gaebe es
            // auf breiten Fenstern zwei Wege zu denselben Handlungen.
            if !breit {
                Handlungsblatt(offen: $mehrOffen, titel: aktuell.name,
                               handlungen: mehrHandlungen)
                    .zIndex(20)
            }
            if let posten = alsPosten {
                Ladeblatt(offen: $ladeblatt, model: model, posten: [posten],
                          titel: aktuell.name,
                          bilder: [aktuell.id: model.plakatURL(
                              itemID: aktuell.id,
                              marke: aktuell.imageTags?["Primary"])].compactMapValues { $0 })
                    .zIndex(20)
            }
            if let meldung {
                Hinweisstreifen(text: meldung) { self.meldung = nil }
                    .zIndex(21)
            }

            Detailkopfleser(titel: aktuell.name, weg: weg) { zurueck() }
        }

        // Breit hängt die Tafel am Knopf statt am unteren Bildrand. Der
        // Anker kommt aus `alsHandlungsanker()`; über feste Koordinaten
        // ginge es nicht, weil die Knopfreihe mit der Länge der
        // Beschriftung wandert.
        .overlayPreferenceValue(Handlungsanker.self) { anker in
            GeometryReader { raum in
                if breit, mehrOffen, let anker {
                    Handlungstafel(offen: $mehrOffen, titel: aktuell.name,
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
        .onChange(of: model.seitenAuffrischen) { _, _ in Task { await auffrischen() } }
        .task {
            async let frischerTitel = model.item(id: item.id)
            async let planung = model.plan(for: item.id)
            async let aehnlich = model.aehnliche(item)
            async let extra = model.extras(item)
            frisch = await frischerTitel
            plan = await planung
            withAnimation(Stil.einblenden) { planDa = true }
            // **Doppelte Kennungen raus.** Der Server liefert unter
            // „Aehnliches" denselben Titel gelegentlich zweimal, und `ForEach`
            // ordnet ueber die Kennung zu: zwei gleiche Kennungen heissen zwei
            // gleiche Kacheln und ein Tipp, der danebengreift. Dieselbe Regel
            // wie in Suche, Startseite und Merkliste — sie fehlte nur hier.
            let frischeAehnliche = await aehnlich
            aehnlicheGestoert = frischeAehnliche == nil
            if let frischeAehnliche {
                aehnliche = Listenregeln.ohneDoppelte(frischeAehnliche)
            }
            // Extras sind kein eigener Abschnitt mit Aussage: fehlen sie,
            // fehlt die Reihe. Ein zweiter Stoerhinweis unter dem ersten waere
            // dieselbe Auskunft zweimal.
            extras = (await extra) ?? []
            gemerkt = aktuell.userData?.isFavorite ?? false
            gesehen = aktuell.userData?.played ?? false
            pruefe = false
        }
    }

    /// Den Titel neu vom Server holen, nachdem sich sein Zustand geändert hat.
    /// Auch hier holt eine Funktion alles, was sich ändern kann.
    ///
    /// Der Plan fehlte. Er ändert sich beim Zurücksetzen des Fortschritts
    /// zwar nicht — die Abspielart hängt nicht daran —, aber die Auslassung
    /// war dieselbe wie auf der Serienseite, wo sie sichtbar wurde. Zwei
    /// Wege, die dasselbe holen sollen, und einer weiß weniger.
    private func auffrischen() async {
        async let frischerTitel = model.item(id: item.id)
        async let planung = model.plan(for: item.id)
        frisch = await frischerTitel
        plan = await planung
        gemerkt = aktuell.userData?.isFavorite ?? false
        gesehen = aktuell.userData?.played ?? false
    }

    // MARK: Teile

    /// Gleiche Höhe wie auf der Serienseite — vorher waren es 260 gegen 300.
    private var hero: some View {
        Heldbild(url: model.kopfbildURL(for: aktuell))
            .overlay(alignment: .bottom) { Heldauslauf() }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(aktuell.name)
                        .font(Stil.titel)
                        .tracking(Stil.sperrungTitel)
                        .foregroundStyle(Stil.schrift)
                    Text(nebenzeile)
                        // Jahr, Laufzeit, Genre sind eine Angabe: 12. Vorher
                        // 14, was in keiner Stufe vorkommt.
                        .font(Stil.klein)
                        .foregroundStyle(Stil.schriftLeise)
                        .lineLimit(1)
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.bottom, 16)
            }
    }

    /// Jahr, Laufzeit und Genre — im Heldenbild, nicht mehr in einer eigenen
    /// Zeile darunter.
    private var nebenzeile: String { aktuell.nebenzeile }

    /// **Erst mit dem Plan, dann als Ganzes.** Sterne und FSK sind sofort da,
    /// die Direct-Play-Marke erst mit dem Wiedergabeplan — und schob sich dann
    /// links davor und die beiden anderen nach rechts. Jetzt hält die Zeile
    /// ihren Platz, bleibt aber unsichtbar, bis der Plan da ist, und blendet
    /// dann auf einmal ein. Kommt kein Plan, blendet sie trotzdem ein — dann
    /// eben ohne Marke.
    private var belegzeile: some View {
        Belegzeile(direktplay: plan?.isLossless ?? false,
                   hinweis: plan.map { $0.isLossless ? nil : $0.method.rawValue } ?? nil,
                   bewertung: aktuell.communityRating,
                   freigabe: aktuell.officialRating)
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

    /// **Ein Knopf, nicht zwei.**
    ///
    /// Unter „Fortsetzen" stand ein zweiter, gleich breiter Knopf „Von vorn" —
    /// bei einem angefangenen Film also zwei volle Zeilen Knopf ueber dem
    /// Inhalt. Und er war doppelt: „Von vorn abspielen" steht seit jeher in
    /// der Mehr-Tafel (`Titelhandlungen.fuerFilm`), genau wie
    /// „Fortschritt zuruecksetzen" daneben. Rückmeldung vom 22.09.: „mach den weg, der
    /// ist ja sowieso in dem Menue."
    ///
    /// Die Seite hat damit wieder **eine** Hauptsache, und die Reihe darunter
    /// faengt 60 Punkt weiter oben an.
    private var hauptknopf: some View {
        // **Restzeit und Balken wie auf der Serienseite.**
        //
        // Dort stehen sie seit jeher unter dem Fortsetzen-Knopf; ein
        // angefangener Film zeigte dagegen nur „Fortsetzen ab 51:10" und
        // liess offen, wie viel noch kommt. Dieselbe Frage, dieselbe Antwort —
        // Aufbau und Abstand zeichengleich mit `SeriesView.hauptknopf`.
        VStack(alignment: .leading, spacing: 9) {
            Button { starte(ab: fortsetzenAb ?? 0) } label: {
                if let ab = fortsetzenAb {
                    Label("Fortsetzen ab \(zeitText(ab))", systemImage: "play.fill")
                } else {
                    Label("Abspielen", systemImage: "play.fill")
                }
            }
            .buttonStyle(HauptknopfStil(dehnt: !breit))
            .disabled(plan == nil)

            if let rest = aktuell.restzeitText {
                // Restzeit ist eine Angabe: 12.
                Text(rest).mitwachsend(12).foregroundStyle(Stil.schriftLeise)
            }
            // Breit sitzt der Fortschritt am Poster im Kopf — hier waere er
            // ein zweites Mal dasselbe, und zwar quer ueber die Seite.
            if !breit, let anteil = aktuell.userData?.playedPercentage, anteil > 0 {
                Fortschrittsbalken(anteil: anteil / 100)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
        }
    }

    private var aktionsreihe: some View {
        // Schmal verteilen die Spacer die Knöpfe über die Zeile; breit
        // stehen sie neben dem Abspielknopf und sollen zusammenbleiben.
        HStack(spacing: 8) {
            Aktionsknopf(symbol: gemerkt ? "bookmark.fill" : "bookmark",
                         titel: "Merkliste", aktiv: gemerkt, dehnt: !weit) {
                gemerkt.toggle()
                Stil.ruck(.leicht)
                // Sofort umschalten, damit der Knopf antwortet — aber
                // zurückdrehen, wenn der Server nein sagt. Vorher blieb die
                // Anzeige stehen und log.
                Task {
                    if let grund = await model.setzeMerkliste(aktuell, an: gemerkt) {
                        gemerkt.toggle()
                        meldung = grund
                    }
                }
            }
            // **Das fünfte Feld, und nur wenn die Funktion an ist.**
            //
            // An zweiter Stelle, nicht am Ende: Merkliste und Download sind
            // das Paar „für später" und gehören nebeneinander. Fünf Felder
            // auf 354 Punkt ergeben 62 je Feld — über den 44, die eine
            // Trefferfläche braucht.
            //
            // Wer die Funktion nie einschaltet, sieht die Reihe unverändert
            // mit ihren vier Feldern; deshalb wächst sie hier statt eine
            // fünfte Stelle immer freizuhalten.
            if model.downloadKnopfZeigen, aktuell.type != "Series" {
                Downloadfeld(posten: geladen, dehnt: !weit) {
                    ringGetippt(geladen, model.downloads) { ladeblatt = true }
                }
            }

            Aktionsknopf(symbol: "film", titel: "Trailer", dehnt: !weit) { trailerStarten() }
            Aktionsknopf(symbol: gesehen ? "checkmark.circle.fill" : "checkmark.circle",
                         titel: "Gesehen", aktiv: gesehen, dehnt: !weit) {
                gesehen.toggle()
                Task {
                    if let grund = await model.setzeGesehen(aktuell, an: gesehen) {
                        gesehen.toggle()
                        meldung = grund
                    }
                }
            }
            Aktionsknopf(symbol: "ellipsis", titel: "Mehr", dehnt: !weit) { mehrOffen = true }
                .alsHandlungsanker()
        }
        // Kein eigener Rand mehr: die vier Felder teilen sich die Zeile und
        // enden dort, wo der Knopf darüber endet.
    }

    @ViewBuilder
    private var beschreibung: some View {
        if let text = aktuell.beschreibung {
            VStack(alignment: .leading, spacing: 8) {
                // Einzeilig mit Auslassung, Antippen klappt auf. Der volle
                // Text war auf dieser Seite zu wuchtig.
                Klapptext(text: text)

                if !aktuell.regie.isEmpty {
                    HStack(spacing: 5) {
                        Text("Regie").foregroundStyle(Stil.schriftLeise)
                        Text(aktuell.regie.joined(separator: ", "))
                            .foregroundStyle(Stil.schrift)
                    }
                    // Eine Rolle ist eine Angabe: 12. Vorher 13 — der Grad
                    // traegt in der Leiter Medium und gehoert dem Titel unter
                    // einem Plakat.
                    //
                    // **Mitwachsend:** sie steht unter dem Beschreibungstext,
                    // und der folgt der Systemschrift schon (`Klapptext`). Mit
                    // fester Zeile darunter lief die Haelfte des Absatzes mit
                    // und die andere nicht.
                    .mitwachsend(12)
                }
            }
        }
    }

    /// Der Auszug, um den es in dieser App geht.
    @ViewBuilder
    private var dateiauszug: some View {
        if let quelle = plan?.quelle {
            VStack(alignment: .leading, spacing: 0) {
                Gruppentitel(text: "Datei").padding(.top, 22)
                Rectangle().fill(Stil.linie).frame(height: 1)
                if quelle.container != nil {
                    Dateizeile(bezeichnung: "Container", wert: Dateiangaben.container(quelle) ?? "")
                    Rectangle().fill(Stil.linie).frame(height: 1)
                }
                if let video = quelle.mediaStreams?.first(where: { $0.type == "Video" }) {
                    Dateizeile(bezeichnung: "Video", wert: Dateiangaben.video(video, quelle))
                    Rectangle().fill(Stil.linie).frame(height: 1)
                }
                ForEach(Array((quelle.mediaStreams ?? []).filter { $0.type == "Audio" }.prefix(2).enumerated()),
                        id: \.offset) { paar in
                    Dateizeile(bezeichnung: paar.offset == 0 ? "Ton" : " ",
                               wert: paar.element.kurz)
                    Rectangle().fill(Stil.linie).frame(height: 1)
                }
                let untertitel = (quelle.mediaStreams ?? []).filter { $0.type == "Subtitle" }
                Dateizeile(bezeichnung: "Untertitel",
                           wert: Dateiangaben.untertitel(untertitel))
                Rectangle().fill(Stil.linie).frame(height: 1)
            }
            .padding(.horizontal, Stil.rand(breit: breit))
        }
    }

    @ViewBuilder
    private var besetzung: some View {
        let leute = aktuell.darsteller
        if !leute.isEmpty {
            // **Jetzt antippbar**, und der Pfeil ist weg: er versprach eine
            // Gesamtliste, die es nie gab. Ein Tipp öffnet die Person — was es
            // mit ihr auf dem Server gibt, und mit Seerr, was sich anfragen
            // lässt. Von einem Tester gemeldet.
            Abschnitt(titel: "Besetzung") {
                HStack(spacing: 14) {
                    ForEach(leute.prefix(12)) { person in
                        NavigationLink(value: PersonRoute(person: person, herkunft: aktuell.name)) {
                            Besetzungskachel(bild: model.personBild(person),
                                             name: person.name, rolle: person.role)
                        }
                        .buttonStyle(Stil.Druckknopf())
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
            }
        }
    }

    @ViewBuilder
    private var extrasreihe: some View {
        if !extras.isEmpty {
            Abschnitt(titel: "Extras") {
                HStack(spacing: 12) {
                    ForEach(extras) { extra in
                        VStack(alignment: .leading, spacing: 7) {
                            Bild(url: model.imageURL(for: extra, maxHeight: 300),
                                 breite: 210, hoehe: 118)
                            Text(extra.name)
                                .font(Stil.kachel).foregroundStyle(Stil.schrift).lineLimit(1)
                            // Ein Extra ohne Laufzeit meldet 0, nicht nichts —
                            // ohne die Regel stünde dort „0 Min.".
                            if Anzeigeregeln.laufzeitZeigen(sekunden: extra.runtimeSeconds),
                               let s = extra.runtimeSeconds {
                                // Derselbe leiseste Ton wie unter jedem
                                // anderen Plakat — ein Extra ist eine Kachel.
                                Text(laufzeit(s)).font(Stil.klein)
                                    .foregroundStyle(Stil.schriftSehrLeise)
                            }
                        }
                        .frame(width: 210, alignment: .leading)
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
            }
        }
    }

    @ViewBuilder
    private var aehnlichesreihe: some View {
        if aehnliche.isEmpty {
            // Nur wenn der Abruf gescheitert ist. Eine Sammlung ohne
            // Verwandtes braucht keinen Abschnitt.
            if aehnlicheGestoert {
                // **Kein `Abschnitt`.** Der legt seinen Inhalt in eine
                // waagerechte Scrollflaeche, und darin faellt ein Hinweis, der
                // die Breite nehmen soll, auf seine Textbreite zusammen.
                VStack(alignment: .leading, spacing: 12) {
                    Reihentitel(text: "Ähnliche Titel")
                        .padding(.horizontal, Stil.rand(breit: breit))
                    Stoerhinweis(model: model, erneut: { erneutAehnliche() },
                                 abstandOben: 0)
                }
                .padding(.top, Stil.reihenAbstand)
            }
        } else {
            Abschnitt(titel: "Ähnliche Titel") {
                HStack(spacing: Stil.kachelAbstand) {
                    ForEach(aehnliche) { titel in
                        NavigationLink(value: titel) {
                            PosterTile(model: model, item: titel)
                        }
                        .buttonStyle(Stil.Druckknopf())
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
            }
        }
    }

    private func starte(ab: Double) {
        guard let plan else { return }
        Stil.ruck(.mittel)
        abspielen = Abspielwunsch(item: aktuell, plan: plan, startAt: ab)
    }

    /// Nur die eine Reihe nachholen — die ganze Seite neu zu laden waere fuer
    /// einen gescheiterten Abschnitt zu viel.
    private func erneutAehnliche() {
        Task {
            let frisch = await model.aehnliche(item)
            aehnlicheGestoert = frisch == nil
            if let frisch { aehnliche = Listenregeln.ohneDoppelte(frisch) }
        }
    }

}

/// Abschnitt mit Überschrift und waagerecht scrollendem Inhalt.
struct Abschnitt<Inhalt: View>: View {
    @Environment(\.breit) private var breit
    let titel: LocalizedStringKey
    var pfeil = false
    @ViewBuilder var inhalt: () -> Inhalt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                // **Nicht selbst gesetzt.** Der Grad war derselbe, die
                // Sperrung fehlte — „Weiterschauen" auf der Startseite steht
                // auf −0,3, „Besetzung" hier stand auf null. Auf der
                // Seerr-Seite treffen inzwischen beide Formen aufeinander.
                Reihentitel(text: titel)
                if pfeil {
                    Image(systemName: "chevron.right")
                        // Ein Winkel ist 13 Semifett. Vorher 12 Semifett — auf
                        // 12 steht in der Leiter Regular, und ein halbfetter
                        // Winkel in einem Regular-Grad ist keine der Stufen.
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Stil.schriftSehrLeise)
                }
            }
            .padding(.horizontal, Stil.rand(breit: breit))

            ScrollView(.horizontal, showsIndicators: false) { inhalt() }
        }
        // 28, nicht 26: „Reihe zu Reihe" ist eine Zahl, und die
                        // Startseite nimmt 28. Zwei Rhythmen fuer dieselbe
                        // Bauart merkt man beim Durchtippen.
                        .padding(.top, Stil.reihenAbstand)
    }
}

extension ItemDetailView {

    func trailerStarten() {
        Trailerstart.starten(aktuell, model: model,
                             abspielen: { abspielen = $0 },
                             melden: { meldung = $0 })
    }

    var mehrHandlungen: [Titelhandlung] {
        Titelhandlungen.fuerFilm(aktuell, plan: plan, model: model,
                                 starten: { starte(ab: $0) },
                                 melden: { meldung = $0 },
                                 auffrischen: { await auffrischen() })
    }
}
