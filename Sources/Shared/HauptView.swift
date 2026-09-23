import JellyfinKit
import SwiftUI

/// Der Rahmen um alles: vier Bereiche und die Leiste unten.
///
/// Ersetzt die frühere Startseite als Wurzel. Die Knöpfe „Filme" und „Serien"
/// sind von der Startseite verschwunden — dafür gibt es jetzt die Leiste.
struct HauptView: View {
    let model: AppModel

    @State private var bereich: Bereich = .start
    /// Nur besuchte Bereiche werden aufgebaut. Alle vier gleich beim Start
    /// anzulegen würde jede Bibliothek sofort laden.
    @State private var besucht: Set<Bereich> = [.start]
    /// Wohin der Wisch nach rechts aus der Suche zurueckfuehrt.
    @State private var vorigerBereich: Bereich = .start
    /// **Einer je Bereich — abgeleitet, nicht abgezaehlt.**
    ///
    /// Hier standen sie einzeln, mit der Begruendung, `allCases.count` wuerde
    /// still mitwachsen, ohne dass jemand die Stelle ansieht. Am 06.09.2026
    /// hat genau diese Vorsicht auf dem Fernseher einen Absturz gekostet:
    /// dort blieben es vier Eintraege, als die Merkliste den fuenften Bereich
    /// brachte, und der Klick auf „Suche" lief ins Leere. Still mitwachsen
    /// heisst: es funktioniert. Nicht mitwachsen heisst: es bricht, und zwar
    /// erst beim letzten Reiter.
    @State private var pfade = Array(repeating: NavigationPath(),
                                     count: Bereich.allCases.count)
    /// **Wo der Profilzweig beginnt** — in welchem Stapel, auf welcher Tiefe.
    /// `nil` heisst: zu. Nur für die Seitenleiste: solange er offen ist,
    /// trägt das Profilzeichen die Auswahl statt eines der Bereiche.
    ///
    /// Eigener Stand, weil sich ein `NavigationPath` nicht befragen lässt —
    /// man kann ihm nicht ansehen, was obenauf liegt. **Die Tiefe gehört
    /// dazu.** Vorher stand hier nur ein Schalter, und damit liess sich der
    /// Zweig nicht wieder abnehmen: ein Tipp auf „Start" bei offenem Profil
    /// setzte den Bereich, der es schon war, und nichts geschah. Wer über
    /// „Filme" auswich, fand das Profil beim Zurückkommen wieder obenauf.
    @State private var profilzweig: Profilzweig?
    private struct Profilzweig { let bereich: Bereich; let tiefe: Int }
    private var imProfil: Bool { profilzweig != nil }
    /// **Der zweite Tipp auf den schon offenen Reiter.** Siehe
    /// `reiterNochmal` in der Umgebung.
    @State private var nochmal = 0

    /// **Laeuft auf einem anderen Geraet etwas?** Siehe ``Uebernahmemodell``.
    ///
    /// Steht hier und nicht in der Startseite, weil das Abzeichen seit dem
    /// 10.09.2026 in ``Kopfziele`` sitzt und damit auf jeder Wurzelseite —
    /// **ein** Halter, der im Takt fragt, nicht fuenf. Der Player haengt aus
    /// demselben Grund hier: ein Tipp auf das Abzeichen startet ihn, und das
    /// muss aus jedem Bereich gehen.
    @State private var uebernahme = Uebernahmemodell()
    /// Bei mehr als einem Geraet wird gefragt statt geraten.
    @State private var auswahlOffen = false
    /// Was die Uebernahme starten soll. Eigener Stand neben den Playern der
    /// einzelnen Seiten — die starten aus ihrer Liste, dieser aus dem Kopf.
    @State private var uebernahmeWunsch: Abspielwunsch?

    @Environment(\.breit) private var breit

    /// Drueben beenden, hier an derselben Stelle weitermachen.
    ///
    /// Erst der Befehl, dann der Plan, dann der Start — geht das Beenden
    /// schief, passiert gar nichts. Sonst liefen zwei Tonspuren im Raum.
    private func hierWeiterschauen(_ sitzung: Fremdsitzung) {
        auswahlOffen = false
        Task { uebernahmeWunsch = await uebernahme.wunsch(fuer: sitzung, model: model) }
    }

    /// Das Profilzeichen in der Seitenleiste.
    ///
    /// **Ist der Zweig schon offen, geht es zurück aufs Profil** statt ein
    /// zweites Mal hinauf — vorher lag nach zwei Tipps Profil auf Profil.
    private func zumProfil() {
        let i = bereich.rawValue
        if let zweig = profilzweig, zweig.bereich == bereich {
            let darueber = pfade[i].count - (zweig.tiefe + 1)
            if darueber > 0 { pfade[i].removeLast(darueber) }
            return
        }
        profilzweigSchliessen()
        profilzweig = Profilzweig(bereich: bereich, tiefe: pfade[i].count)
        pfade[i].append(ProfilRoute())
    }

    /// Nimmt den Profilzweig ab; was darunter lag, bleibt liegen.
    private func profilzweigSchliessen() {
        guard let zweig = profilzweig else { return }
        let i = zweig.bereich.rawValue
        let darueber = pfade[i].count - zweig.tiefe
        if darueber > 0 { pfade[i].removeLast(darueber) }
        profilzweig = nil
    }


    var body: some View {
        ZStack(alignment: .bottom) {
            Stil.grund.ignoresSafeArea()

            // **Die Leiste steht ausserhalb des Inhalts — der Schalter muss
            // es auch.** Der Wert hing am inneren `ZStack`, also nur am
            // Inhalt; die `Seitenleiste` daneben bekam den Vorgabewert
            // („aus") und liess den Reiter Downloads breit einfach weg,
            // auch wenn er in den Einstellungen an war. Hier umschliesst er
            // beide.
            HStack(spacing: 0) {
                if breit {
                    // **Nicht `$bereich`.** Ein Tipp auf den schon offenen
                    // Bereich schreibt denselben Wert — nur eine eigene
                    // Bindung sieht ihn und kann das Profil schliessen.
                    Seitenleiste(gewaehlt: Binding(
                                     get: { bereich },
                                     set: { neu in
                                         if neu == bereich { profilzweigSchliessen() }
                                         bereich = neu
                                     }),
                                 imProfil: imProfil,
                                 name: model.session?.userName ?? "?",
                                 bild: model.benutzerbildURL()) { zumProfil() }
                    // Die Leiste steht fest; nur der Inhalt daneben weicht der
                    // Tastatur.
                    .ignoresSafeArea(.keyboard)
                }

                ZStack {
                    ForEach(Bereich.allCases) { b in
                        if besucht.contains(b) {
                            stapel(b)
                                .opacity(bereich == b ? 1 : 0)
                                // **Das Heranziehen liegt eine Ebene
                                // tiefer**, in `bereichsleiste()` — sonst
                                // wandert die Leiste mit. Hier steht nur, wer
                                // vorn ist.
                                .environment(\.bereichAktiv, bereich == b)
                                .allowsHitTesting(bereich == b)
                        }
                    }
                }
                // **Kein Überblenden.** Hier lief die Deckkraft über dieselbe
                // Kurve, und damit waren im Wechsel *beide* Seiten halb
                // durchsichtig: durch sie hindurch sah man den schwarzen Grund
                // darunter — oben um die Dynamic Island, unten schoben sich
                // Kacheln durch die Leiste.
                //
                // Ohne Animation schaltet die Deckkraft hart, und übrig bleibt
                // das, was gemeint war: die eintretende Seite zieht sich um
                // zwei Punkte heran. Man merkt sie, man sieht sie nicht. Die
                // Wurzelansichten legen sich die Leiste selbst an — siehe
                // `bereichsleiste()`. Hier steht nur, wohin ein Tippen darauf
                // geht.
                // **Nicht `$bereich`, sondern eine eigene Bindung.** Die
                // Leiste schreibt beim Tippen auch dann, wenn derselbe
                // Bereich schon offen ist — daran, und nur daran, laesst
                // sich der zweite Tipp erkennen. Mit `$bereich` faellt er
                // durch, weil sich der Wert nicht aendert.
                .environment(\.bereichswahl, Binding(
                    get: { bereich },
                    set: { neu in
                        if neu == bereich { nochmal += 1 } else { bereich = neu }
                    }))
                .environment(\.reiterNochmal, nochmal)
                // **Wer den Schalter umlegt, waehrend er auf der Seite
                // steht, darf nicht dort stehenbleiben.** Der Reiter
                // verschwindet, die Seite bliebe sonst ohne Weg zurueck.
                .onChange(of: model.downloadsAn) { _, an in
                    if !an, bereich == .downloads { bereich = .start }
                }
                // Dasselbe fuer die Merkliste: sie gibt es nur breit. Wer im
                // Querformat dort steht und das Fenster schmal zieht, stuende
                // sonst in einem Bereich, den die Leiste nicht mehr zeigt.
                .onChange(of: breit) { _, jetztBreit in
                    if !jetztBreit, bereich == .merkliste { bereich = .start }
                }
            }
            .environment(\.downloadleiste,
                         Downloadleiste(an: model.downloadsAn,
                                        laufen: model.downloads.posten
                                            .filter { $0.stand == .laedt || $0.stand == .wartet }
                                            .count))


            // **Eigenes Blatt statt `confirmationDialog`.** Der Systemdialog
            // legt seinen eigenen, sehr hellen Schleier auf; ueber einer
            // dunklen Seite voller Plakate hebt er sich kaum ab.
            if auswahlOffen {
                Uebernahmeauswahl(sitzungen: uebernahme.angebote,
                                  waehlen: { hierWeiterschauen($0) },
                                  abbrechen: { auswahlOffen = false })
                    .transition(.opacity)
                    .zIndex(5)
            }
        }
        .environment(uebernahme)
        .animation(.easeInOut(duration: 0.2), value: auswahlOffen)
        // Ein Schalter statt einer Schliessung durch die Umgebung — siehe
        // `Uebernahmemodell.angetippt`.
        .onChange(of: uebernahme.angetippt) { _, an in
            guard an else { return }
            uebernahme.angetippt = false
            if uebernahme.mehrereDa { auswahlOffen = true }
            else if let eine = uebernahme.angebot { hierWeiterschauen(eine) }
        }
        .task { uebernahme.starten(model) }
        #if DEBUG && os(iOS)
        .task {
            guard Sprunglauf.an else { return }
            try? await Task.sleep(for: .seconds(3))
            guard let wunsch = await Sprunglauf.wunsch(model) else { return }
            uebernahmeWunsch = wunsch
            await Sprunglauf.ablauf(model) { uebernahmeWunsch = nil }
        }
        #endif
        .onDisappear { uebernahme.beenden() }
        .playerCover(item: $uebernahmeWunsch) { wunsch in
            PlayerScreen(model: model, item: wunsch.item,
                         plan: wunsch.plan, startAt: wunsch.startAt)
        }
        // Bewusst ohne Übergang: die Leiste soll fest liegen und beim
        // Zurückkommen einfach wieder da sein, so wie der Inhalt dahinter
        // auch. Eingeblendet wirkte sie wie ein eigenes Blatt.
        .task { await model.fernsteuerungStarten() }
        // **Einmal beim Aufmachen, nicht laufend.** Eine Anfrage je Start
        // reicht: sie sagt, was gesehen ist (H6) und was der Server nicht
        // mehr hat (H9). Beides aendert sich nicht im Minutentakt, und
        // unterwegs schlaegt sie ohnehin fehl — dann bleibt alles stehen.
        .task { await model.downloadsNachziehen() }
        // Sonst bleibt der Socket offen, wenn die Ansicht weicht — etwa beim
        // Abmelden, wo `RootView` auf den Anmeldebildschirm wechselt.
        //
        // **Aber nicht, weil der Player darüber liegt.** Auf dem iPhone zeigt
        // UIKit den Player im eigenen Rahmen (`Playerrahmen`, `.fullScreen`),
        // und damit verschwindet diese Ansicht für SwiftUI. Bis 23.09. ging
        // dabei der Socket zu: ohne ihn führt der Server die Sitzung nicht
        // mehr als steuerbar, und die anderen Geräte sahen das iPhone genau
        // während der Wiedergabe gar nicht oder als „spielt nichts" — kein
        // „Hier weiterschauen". Auf dem iPad (`fullScreenCover`) trat das nie auf.
        .onDisappear {
            guard Playerrahmen.aktiv == nil else { return }
            Task { await model.fernsteuerungBeenden() }
        }
        .onChange(of: bereich) { alt, neu in
            besucht.insert(neu)
            if alt != .suche { vorigerBereich = alt }
            // **Das Profil bleibt nicht im alten Bereich liegen**, sonst
            // stand es beim Zurückkommen wieder obenauf. Der alte Stapel ist
            // jetzt ausgeblendet; was dort zurückfährt, sieht niemand.
            profilzweigSchliessen()
        }
        // **Zurück bis unter das Profil heisst: der Zweig ist zu.** Vorher
        // hiess es „der Stapel ist leer" — lag unter dem Profil noch eine
        // Detailseite, blieb das Zeichen hervorgehoben, obwohl das Profil
        // längst weg war.
        .onChange(of: pfade.map(\.count)) { _, zahlen in
            if let zweig = profilzweig, zahlen[zweig.bereich.rawValue] <= zweig.tiefe {
                profilzweig = nil
            }
        }
        // **VERHALTEN G4: der Seitenstapel wird beim Kontowechsel geleert.**
        //
        // Ein Stapel gehoert zu einem Konto; was darauf liegt, gehoert dem
        // vorigen. Eine Detailseite haengt an `.task(id: titel.id)`, eine
        // Serienseite an der Staffel, die Suche am Begriff — **keine** dieser
        // Kennungen aendert sich beim Wechsel. Ohne das Leeren staenden dort
        // Haken und Fortschrittsbalken des vorigen Kontos, und ein Druck auf
        // Abspielen setzte an dessen Stelle an und meldete sie dem neuen.
        //
        // Bewusst hier und nicht in jeder Seite: das waeren fuenf Stellen je
        // Plattform, und die naechste neue Seite vergisst es. Von der
        // Mac-Sitzung gefunden.
        .onChange(of: model.kontowechsel) { _, _ in
            for i in pfade.indices where !pfade[i].isEmpty {
                pfade[i] = NavigationPath()
            }
            profilzweig = nil
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func stapel(_ b: Bereich) -> some View {
        NavigationStack(path: $pfade[b.rawValue]) {
            Group {
                switch b {
                case .start:
                    HomeView(model: model)
                case .filme:
                    BibliothekView(model: model, art: "movies", titel: "Filme")
                case .serien:
                    BibliothekView(model: model, art: "tvshows", titel: "Serien",
                                   filter: [.alle, .angefangen, .merkliste])
                case .suche:
                    SucheView(model: model, aktiv: bereich == .suche) {
                        bereich = vorigerBereich
                    }
                case .downloads:
                    DownloadsView(model: model)
                case .merkliste:
                    // **Breit ist sie ein Ort, kein Weg.** Schmal faehrt sie
                    // als Seite von rechts herein, weil sie dort am Zeichen
                    // oben rechts haengt; breit steht sie in der Leiste, und
                    // was in einer Leiste steht, faehrt nicht herein. Deshalb
                    // ohne Zurueckpfeil
                    MerklisteView(model: model)
                }
            }
            .zielorte(model: model)
        }
    }

}

// MARK: - Gemeinsame Ziele

extension View {
    /// Die Sprungziele hängen am Stapel, nicht an der einzelnen Seite —
    /// sonst muss jeder Bereich sie einzeln kennen.
    func zielorte(model: AppModel) -> some View {
        self
            // **`LibraryRoute` hat hier kein Ziel mehr.**
            //
            // `ItemListView` hing daran und war toter Code: kein Aufrufer
            // erzeugte die Route je, und die Seite benutzte obendrein Apples
            // `ContentUnavailableView` statt unseres Leerzustands — sie waere
            // also auch inhaltlich aus der Reihe gefallen, haette sie jemand
            // geoeffnet. Der Typ selbst bleibt: Mac und Fernseher benutzen
            // ihn, dort fuehrt er auf eine eigene Bibliotheksseite.
            .navigationDestination(for: Seerrtreffer.self) { treffer in
                SeerrDetailView(model: model, treffer: treffer)
            }
            .navigationDestination(for: Item.self) { item in
                if item.type == "Series" {
                    SeriesDetailView(model: model, serie: item)
                } else if item.type == "BoxSet" {
                    // Eine Sammlung aus Suche oder Merkliste: ohne Bereich,
                    // also alles, was in ihr steht.
                    SammlungView(model: model, sammlung: item, art: nil)
                } else if item.type == "Episode" {
                    // Folgen bekommen keine eigene Seite — sie führen auf ihre
                    // Staffel. Eine Seite nur für eine Folge trägt nichts, was
                    // nicht in der Liste schon steht.
                    StaffelZiel(model: model, folge: item)
                } else {
                    ItemDetailView(model: model, item: item)
                }
            }
            .navigationDestination(for: SammlungRoute.self) { route in
                SammlungView(model: model, sammlung: route.sammlung, art: route.art)
            }
            .navigationDestination(for: MerklisteRoute.self) { _ in
                MerklisteView(model: model)
            }
            .navigationDestination(for: DownloadserieRoute.self) { route in
                DownloadserieView(model: model, route: route)
            }
            .navigationDestination(for: ProfilRoute.self) { _ in
                ProfilView(model: model)
            }
            .navigationDestination(for: QuickConnectRoute.self) { _ in
                QuickConnectView(model: model)
            }
            .navigationDestination(for: EinstellungenRoute.self) { _ in
                EinstellungenView(model: model)
            }
            .navigationDestination(for: SeerrRoute.self) { _ in
                SeerrEinstellungenView(model: model, seerr: model.seerr)
            }
            .navigationDestination(for: TraktRoute.self) { _ in
                TraktEinstellungenView(trakt: model.trakt)
            }
            .navigationDestination(for: WiedergabeRoute.self) { _ in
                WiedergabeEinstellungenView(model: model)
            }
            .navigationDestination(for: StaffelRoute.self) { route in
                SeasonView(model: model, serie: route.serie, staffel: route.staffel)
            }
            .navigationDestination(for: PersonRoute.self) { route in
                PersonView(model: model, route: route)
            }
            .navigationDestination(for: GenreRoute.self) { route in
                GenreView(model: model, name: route.name)
            }
            .navigationDestination(for: DarstellungRoute.self) { _ in
                DarstellungView(model: model)
            }
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            // Der Modifikator darueber gilt der Wurzel; die geschobenen Ziele
            // tragen ihn je einzeln. Das reicht nicht — er greift erst nach
            // dem ersten Bild, und so lange stand oben ein systemeigener
            // Zurueck-Knopf. `SystemleisteWeg` legt die Leiste am
            // Navigationsrechner still, also fuer den ganzen Stapel.
            .background(SystemleisteWeg())
            #endif
    }
}

// MARK: - Filme und Serien

/// Eine ganze Bibliothek als eigener Bereich.
struct BibliothekView: View {
    let model: AppModel
    let art: String
    let titel: LocalizedStringKey
    /// Bei Serien heißt der dritte Filter anders — „ungesehen" hilft dort
    /// wenig, „neue Folgen" ist die Frage, die man wirklich hat.
    var filter: [Bibliotheksfilter] = Bibliotheksfilter.allCases

    /// Blättern, Filtern und Sortieren stehen in `Bibliotheksmodell` —
    /// geteilt mit der tvOS-Fassung.
    @State private var stand: Bibliotheksmodell
    @State private var sortierlisteOffen = false
    @State private var filterlisteOffen = false

    /// **Der Merkname muss beim Anlegen feststehen.**
    ///
    /// Sortierung und Filter kommen aus der Ablage, und sie muessen schon im
    /// ersten Durchgang richtig stehen — sonst zeigt die Chipreihe einen
    /// Wimpernschlag lang „A–Z" und springt dann. Ein `@State` mit
    /// Anfangswert kann das, ein nachtraegliches Setzen nicht.
    init(model: AppModel, art: String, titel: LocalizedStringKey,
         filter: [Bibliotheksfilter] = Bibliotheksfilter.allCases) {
        self.model = model
        self.art = art
        self.titel = titel
        self.filter = filter
        _stand = State(initialValue: Bibliotheksmodell(merkname: art))
    }
    /// Wie weit gescrollt wurde — daran hängt die Haarlinie unter dem Kopf.
    @State private var versatz: CGFloat = 0
    /// Wie hoch der Kopf ist. **Gemessen, nicht getippt.**
    ///
    /// Hier stand `112`, für Titel plus Chipreihe gerechnet. Seit unter dem
    /// Titel der Servername steht, war die Zahl falsch, und sie wäre es beim
    /// nächsten Zusatz wieder — die erste Kachelreihe verschwand dann unter
    /// dem Kopf, ohne dass ein Bau es meldet.
    /// Welche Bibliothek dieser Gattung gezeigt wird.
    ///
    /// Ein Server kann mehrere Filmbibliotheken haben — im TestFlight eine
    /// auf einer externen Platte und eine lokale. Vorher nahm die Ansicht
    /// stumm die erste, und die zweite war nicht erreichbar.
    ///
    /// **Seit dem 22.09.2026 mehr als eine Bibliothek:** oben „Alle",
    /// darunter „Sammlungen", dann die Bibliotheken — die Regel steht in
    /// ``Bereichsangebot``. Wer nur eine Film- und eine Serienbibliothek und
    /// keine Sammlungen hat, bekommt kein Menü und sieht alles wie vorher.
    @State private var wahl: Bereichswahl = .alle
    @State private var bibliothekslisteOffen = false

    @Environment(\.breit) private var breit
    /// Ist dieser Bereich vorn? Nur dann gilt, was die Scrollflaeche meldet.
    @Environment(\.bereichAktiv) private var bereichAktiv

    /// Die Spaltenzahl folgt der Breite, die Kacheln füllen ihre Spalte.
    ///
    /// Vorher standen hier drei feste. `.adaptive` war schon einmal verworfen
    /// worden, und zu Recht: mit 112 Punkt Mindestbreite passten auf 390 nur
    /// zwei nebeneinander — 3 × 112 + 2 × 12 sind 360, der Inhalt hat aber nur
    /// 354. Rechts blieb eine Lücke von einer halben Kachel.
    ///
    /// `Stil.spalten(nutzbar:)` rechnet stattdessen mit einer Zielbreite und
    /// lässt die Kacheln dehnen. Auf jedem iPhone kommen dabei genau die
    /// bisherigen drei heraus.
    private func spalten(_ anzahl: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Stil.kachelAbstand),
              count: anzahl)
    }

    var body: some View {
        // Die Breite muss vor dem Raster feststehen — `LazyVGrid` bekommt
        // seine Spalten als Argument, nicht als Ergebnis.
        GeometryReader { rahmen in
            inhalt(nutzbar: rahmen.size.width - 2 * Stil.rand(breit: breit))
        }
        // **Vor den Blaettern.** Die Reihenfolge ist der ganze Punkt: Inhalt,
        // Leiste, Blatt. Die Begruendung steht an `bereichsleiste()`.
        .bereichsleiste()
        // **Die Blätter gehören an die Seite, nicht an die Kopfzeile.**
        //
        // Sie hingen an `kopf`. Eine Auflage bekommt den Rahmen dessen, worauf
        // sie liegt — und das war rund hundert Punkt hoch. Das Blatt saß
        // deshalb oben, ohne Schleier, und seine Liste bekam gar keine Höhe:
        // sichtbar waren nur „Sortieren" und „Abbrechen".
        //
        // Im Simulator nachgestellt. Der Fehler ist **älter** als der Umbau
        // der Blattbewegung von heute Abend — nach dem Zurücksetzen auf den
        // geprüften Stand war er unverändert da.
        // **Ohne `if` — der Behaelter bleibt, das Blatt gattert sich selbst.**
        // Nur so laufen die Uebergaenge von Schleier und Karte einzeln.
        .regalblaetter(stand: stand, filter: filter,
                       filterOffen: $filterlisteOffen, sortierungOffen: $sortierlisteOffen)
        // Kein `Menu` — E4 im Register. Dasselbe `Auswahlblatt` wie bei der
        // Sortierung; die Rubrik „Bibliotheken" trennt die Bibliotheken von
        // „Alle" und „Sammlungen", die keine sind.
        .overlay(alignment: .topTrailing) {
                Auswahlblatt(offen: $bibliothekslisteOffen,
                             titel: titel,
                             eintraege: angebot.eintraege,
                             beschriftung: { beschriftung($0) },
                             istGewaehlt: { $0 == wahl },
                             waehlen: { neu in
                                 guard neu != wahl else { return }
                                 model.bereichWaehlen(neu, art: art)
                                 wahl = neu
                                 Task { await laden() }
                             },
                             rubrik: { $0 == angebot.ersteBibliothek ? "Bibliotheken" : nil })
        }
        // **Die Bibliothek gehoert nicht in die Kennung.**
        //
        // Sie stand einmal darin, und das war ein Fehler: `laden()` setzt die
        // Wahl beim ersten Lauf selbst, aendert damit die Kennung und bricht
        // die eigene Aufgabe ab. Die abgebrochene Anfrage kam als
        // Fehlschlag zurueck, und die Seite zeigte „Kein Kontakt zum Server"
        // ueber den Plakaten, die der zweite Lauf gerade geladen hatte.
        //
        // Gewechselt wird nur durch Antippen — dort wird auch neu geladen.
        //
        // **Der Kontowechsel gehoert in die Kennung.** Sie trug nur Sortierung
        // und Filter; beim Wechsel aendert sich daran nichts, und die
        // Bibliothek zeigte weiter die Titel des vorigen Kontos. Auf dem Mac
        // ist genau das gelandet. `Bibliotheksmodell.veraltet(_:)` verweigert
        // seit `main` das Anhaengen — den Anstoss zum Neuladen muss die
        // Ansicht geben, und `.task(id:)` ist die Stelle, an der sie es schon
        // fuer Sortierung und Filter tut.
        //
        // Ueber die Kennung und nicht ueber ein zusaetzliches `onChange`: so
        // wird die laufende Anfrage des alten Kontos abgebrochen, statt neben
        // der neuen weiterzulaufen. Dass ein Abbruch hier kein Ausfall ist,
        // steht in `laden()`.
        .task(id: "\(stand.kennung)|\(model.kontowechsel)") { await laden() }
        // **Die Bibliotheken koennen nach der Seite eintreffen.**
        //
        // `laden()` waehlt sie beim ersten Lauf aus `model.views` — und wenn
        // die Liste zu dem Zeitpunkt noch leer ist (kalter Start, langsamer
        // Server), bleibt die Wahl `nil`: der Titel steht ohne Namen da und
        // die Seite zeigt alle Gattungen gemischt, bis jemand von Hand
        // umschaltet. Nichts stiess ein zweites Mal an.
        //
        // Ueber die Kennungen und nicht ueber die Anzahl: verschwindet eine
        // Bibliothek und kommt eine neue dazu, bleibt die Anzahl gleich.
        //
        // Dasselbe gilt für Sammlungen und gemischte Bibliotheken: sie kommen
        // aus `angebotLaden()` nach. Ändert sich damit, was „Alle" liest oder
        // was gewählt sein darf, wird neu geladen.
        .onChange(of: angebotskennung) { _, _ in
            let neu = model.bereichswahl(art: art)
            guard neu != wahl || quelle?.schluessel != geladeneQuelle else { return }
            wahl = neu
            Task { await laden() }
        }
    }

    private func inhalt(nutzbar: CGFloat) -> some View {
        let anzahl = Stil.spalten(nutzbar: nutzbar, breit: breit)
        return ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                // **Platzhalter statt Ring.** Solange nichts da ist, steht
                // das Raster schon in seiner Form — die Seite ist dann leer,
                // nicht am Warten. Ueberblendet wird, sobald die Titel da
                // sind.
                if stand.items.isEmpty, stand.laedt, wahl != .sammlungen {
                    Rasterplatzhalter(spalten: anzahl)
                        .padding(.horizontal, Stil.rand(breit: breit))
                        .padding(.top, 8)
                        .transition(.opacity)
                }

                LazyVGrid(columns: spalten(anzahl), alignment: .leading, spacing: 20) {
                    if wahl == .sammlungen {
                        sammlungskacheln
                    } else {
                    ForEach(stand.items) { item in
                        NavigationLink(value: item) {
                            PosterTile(model: model, item: item, breite: nil)
                        }
                        .buttonStyle(Stil.Druckknopf())
                        // Nachladen, sobald die drittletzte Reihe auftaucht —
                        // dann steht der Nachschub schon, bevor man unten
                        // ankommt.
                        .onAppear {
                            guard stand.loestNachladenAus(item.id, spalten: anzahl),
                                  let quelle else { return }
                            Task { await stand.nachladen(model, aus: quelle) }
                        }
                    }
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 8)
                .opacity(stand.items.isEmpty && wahl != .sammlungen ? 0 : 1)

                // **Kein Ring beim Nachladen.** Die naechste Reihe kommt
                // ohnehin von selbst; ein Ring darunter sagt nur, dass
                // gerade etwas laeuft, und genau das soll man nicht merken.
                if stand.nochMehrDa, wahl != .sammlungen {
                    Rasterplatzhalter(spalten: anzahl, reihen: 1)
                        .padding(.horizontal, Stil.rand(breit: breit))
                        .padding(.top, 20)
                }
            }
            .scrollIndicators(.hidden)
            .animation(Stil.einblenden, value: stand.items.isEmpty)
            // Null im Ruhezustand: `contentOffset` beginnt bei minus dem
            // oberen Rand, den `contentMargins` gesetzt hat.
            // **Der rohe Versatz, nicht der um den Sicherheitsrand bereinigte.**
            //
            // Hier stand `contentOffset.y + contentInsets.top`, und das war
            // richtig, solange der Kopf immer gleich hoch war. Seit die
            // Wertreihe beim Scrollen zuklappt, ist er es nicht mehr — und
            // damit misst die Zeile ihr eigenes Ergebnis: Kopf schrumpft um
            // zehn, Sicherheitsrand schrumpft um zehn, der gemessene Versatz
            // faellt um zehn zurueck auf null, Kopf waechst wieder. Ein
            // Zweitakter, der nie zur Ruhe kommt.
            //
            // **Die Summe ist schon der Scrollweg.** Gemessen am 22.09.:
            //
            //     rand 130,8  versatz −130,3  ->  Summe 0,5
            //     rand 115,0  versatz −114,7  ->  Summe 0,3
            //
            // Dazwischen ist die Wertreihe von 28 auf 44 Punkt zugeklappt.
            // Der obere Rand faellt dabei um 15,8 — und der rohe Versatz
            // steigt um genau 15,6. **Beide wandern gemeinsam:** die
            // Scrollflaeche haelt den Inhalt fest, wenn sich ihr Rand aendert.
            // Die Summe bleibt davon unberuehrt und misst allein, was der
            // Finger getan hat.
            //
            // Drei Anlaeufe sind an der gegenteiligen Annahme gescheitert —
            // der Rand schrumpfe, der Versatz bleibe stehen, also muesse man
            // das Eingeklappte wieder draufrechnen. Genau dieses Draufrechnen
            // war der Fehler: es zaehlte den Weg ein zweites Mal, in jedem
            // Bild, und die Reihe klappte von selbst zu, ohne dass jemand
            // gescrollt hat. Zwei Vermutungen ueber die Ursache und eine
            // Messung: die Messung hat es in zwei Minuten entschieden.
            .onScrollGeometryChange(for: CGPoint.self) {
                CGPoint(x: $0.contentInsets.top, y: $0.contentOffset.y)
            } action: { _, neu in
                // Waehrend des Bereichswechsels rechnet die Scrollflaeche
                // ihre Geometrie neu; erst wenn dieser Bereich vorn ist, ist
                // die Messung etwas wert.
                guard bereichAktiv else { return }
                // **Der eine Zwischenstand, der auch dann noch kommt.**
                //
                // Die Messung zeigt, wie ein echter Wert aussieht: der rohe
                // Versatz ist **minus** dem oberen Rand (−130,3 bei Rand
                // 130,8), die Summe also nahe null. Waehrend die Flaeche ihre
                // Geometrie neu rechnet, meldet sie dagegen einmal Versatz
                // null bei schon gesetztem Rand — daraus wird rechnerisch die
                // ganze Kopfhoehe, die Reihe klappt fuer ein, zwei Bilder zu
                // und wieder auf, und genau das ruckelt mitten im Aufziehen.
                //
                // Echt vorkommen kann die Paarung nur an einer Stelle: wenn
                // man zufaellig um exakt die Randhoehe gescrollt hat. Dort
                // kostet ein uebersprungenes Bild nichts, das naechste kommt
                // sofort.
                guard !(abs(neu.y) < 1 && neu.x > 1) else { return }
                versatz = neu.y + neu.x
            }
            .contentMargins(.bottom, breit ? 24 : Stil.leisteHoehe + 12,
                            for: .scrollContent)
            // Nur die Scrollflaeche zieht sich beim Wechsel heran; der Kopf
            // darueber liegt fest wie die Leiste unten.
            .bereichsinhalt()
            // **Der Kopf sitzt als Sicherheitsrand, nicht als Auflage.**
            //
            // Vorher hing er als Auflage darueber, und sein oberer Rand kam
            // aus einer eigenen Messung: `onGeometryChange` schrieb die Hoehe
            // in einen Zustand, der als `contentMargins(.top,)` in
            // **dieselbe** Flaeche zurueckging. Das ist ein Kreis, und er
            // schwang: der Servername steht erst da, wenn er geholt ist, mit
            // ihm waechst der Kopf um eine Zeile, der Rand aendert sich, der
            // Inhalt rutscht, die Geometrie aendert sich wieder.
            //
            // Zwei Daempfungen habe ich davor probiert und beide waren falsch:
            // eine Schwelle greift nicht, weil der Sprung eine ganze Zeile
            // ist, und "nur wachsen" macht aus einer einzigen zu grossen
            // Messung einen bleibenden Riesenabstand — genau das war das Loch
            // danach.
            //
            // `safeAreaInset` misst nichts. SwiftUI legt den Kopf oben an,
            // zieht den Einzug selbst nach und laesst den Inhalt darunter
            // durchlaufen — dasselbe Bild, ohne Rueckkopplung. Es gibt keine
            // Zahl mehr, die falsch sein koennte.
            .safeAreaInset(edge: .top, spacing: 0) { kopf }


            if wahl == .sammlungen {
                // Die Liste steht schon im Speicher: „Sammlungen" gibt es im
                // Menü nur, wenn es welche gibt. Kein Laden, kein Leer.
            } else if stand.gestoert {
                // Derselbe Text wie auf der Startseite, samt Serveradresse.
                // Vorher stand hier „Hier ist noch nichts" — dieselbe Ursache,
                // zwei Diagnosen, und die falsche schickt einen zum Server
                // statt zum Netz.
                Leerzustand(
                    symbol: "externaldrive.badge.xmark",
                    kopfzeile: "Server ist abgetaucht",
                    text: "\(model.serverAdresse ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                    hauptknopf: ("Erneut versuchen", { Task { await laden() } }))
                    .padding(.bottom, Stil.leisteHoehe)
            } else if stand.items.isEmpty, !stand.laedt {
                // **`!laedt` ist nicht schmückend.** Es stand hier, solange
                // daneben ein Ladering hing; beim Ausbau ist es mit
                // weggefallen, und seither blitzte beim ersten Öffnen eine
                // Sekunde lang „Hier ist noch nichts" auf, bevor die Titel
                // kamen. Eine leere Bibliothek zu melden, bevor man gefragt
                // hat, ist eine falsche Auskunft.
                Leerzustand(
                    symbol: stand.filter == .alle ? "tray" : "line.3.horizontal.decrease",
                    kopfzeile: stand.filter == .alle ? "Hier ist noch nichts"
                                                 : "Nichts gefunden",
                    text: stand.filter == .alle
                        ? "Sobald in dieser Bibliothek etwas liegt, taucht es hier auf."
                        : "Unter \u{201E}\(stand.filter.beschriftung)\u{201C} liegt gerade nichts. Nimm einen anderen Filter.",
                    stillerKnopf: stand.filter == .alle
                        ? ("Aktualisieren", { Task { await laden() } })
                        : ("Filter zurücksetzen", { stand.filter = .alle }))
                    .padding(.bottom, breit ? 0 : Stil.leisteHoehe)
            }
        }
    }

    private var kopf: some View {
        Unschaerfekopf(versatz: versatz) {
            // Kein Abstand im Stapel: die 14 zwischen Titel und Wertreihe
            // traegt `Wertreihe` selbst, damit sie mit ihr verschwinden.
            VStack(alignment: .leading, spacing: 0) {
                // **Mittig, nicht oben.** Solange unter dem Titel noch der
                // Servername stand, war `.top` richtig: der Block war zwei
                // Zeilen hoch, und die Zeichen rechts sollten an der ersten
                // haengen. Ohne die zweite Zeile sitzt der Titel damit oben und
                // die Zeichen daneben tiefer — auf verschiedenen Linien. Paul
                // am 21.09.: „die sind nicht auf der gleichen Linie wie das
                // Profilbild".
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        // **Nur ab zwei Bibliotheken ein Menü.**
                        //
                        // Wer eine hat — und das sind fast alle — sieht genau
                        // das Gleiche wie vorher: eine Überschrift, kein
                        // Zeichen, kein Tippziel. Ein Umschalter, der nichts
                        // umzuschalten hat, ist eine Frage ohne Antwort.
                        if angebot.istMenue {
                            // Kein `Menu` — E4 im Register. Dasselbe
                            // `Auswahlblatt` wie bei der Sortierung, und es
                            // nimmt die Beschriftung als `String`, was hier
                            // nötig ist: Bibliotheksnamen kommen vom Server.
                            //
                            // **„Alle" heißt einfach „Filme".** Der Titel sagt,
                            // wo man ist; „Alle Filme" steht nur im Menü.
                            Button { bibliothekslisteOffen = true } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Group {
                                        if wahl == .alle { Text(titel) }
                                        else { Text(verbatim: beschriftung(wahl)) }
                                    }
                                        .font(Stil.titelGross).tracking(Stil.sperrungTitel)
                                    Image(systemName: "chevron.down")
                                        .font(Stil.listentitel)
                                        .foregroundStyle(Stil.schriftLeise)
                                }
                            }
                            .buttonStyle(Stil.Druckknopf())
                        } else {
                            Text(titel).font(Stil.titelGross).tracking(Stil.sperrungTitel)
                        }

                        // **Kein Servername unter dem Titel.**
                        //
                        // Er stand hier, damit man bei zwei Konten die
                        // Bibliotheken unterscheiden kann. Am Geraet kostet die
                        // Zeile aber mehr, als sie bringt: sie drueckt die
                        // Filterpillen und das Raster nach unten, und der
                        // Seitentitel bekommt einen Unterbau, den keine andere
                        // Wurzelseite hat. Wer wissen will, auf welchem Server
                        // er ist, findet es im Profil — dort steht es ohnehin.
                        // Paul am 21.09. am Geraet.
                    }
                    Spacer(minLength: 0)
                    // **Breit steht die Zahl hier oben, nicht in der
                    // Chipreihe** — genau wie auf dem Mac, wo sie neben dem
                    // Titel sitzt. Blieb sie unten, stand hinter den
                    // Sortierchips noch etwas, und die zwei Zwischenraeume
                    // teilten sich den Platz zu gleichen Teilen: die Chips
                    // landeten in der Mitte statt rechts.
                    if breit, gezeigt > 0 {
                        Zaehlmarke(anzahl: gezeigt)
                    }
                    // Breit steht das Profilzeichen in der Seitenleiste, und
                    // zwar für alle vier Bereiche. Hier wäre es das zweite.
                    // Dieselbe Gruppe wie auf der Startseite — Merkliste
                    // und Profil gehoeren zusammen, also stehen sie ueberall
                    // zusammen. Das Angebot „hier weiterschauen" bleibt der
                    // Startseite: ein Tipp darauf startet die Wiedergabe, und
                    // der Player haengt dort.
                    if !breit {
                        Kopfziele(name: model.session?.userName ?? "?",
                                  bild: model.benutzerbildURL())
                    }
                }
                .foregroundStyle(Stil.schrift)

                // **Breit bleibt sie stehen.** Dort sind es Chips statt
                // Pillen, sie stehen in einer Seitenleiste-Komposition mit
                // viel Platz, und der Kopf nimmt keine halbe Kachelreihe weg.
                // Das Zuklappen loest ein Problem, das es breit nicht gibt.
                Regalsteuerung(stand: stand, filter: filter,
                               filterOffen: $filterlisteOffen,
                               sortierungOffen: $sortierlisteOffen,
                               versatz: versatz,
                               nurAnzahl: wahl == .sammlungen ? sammlungsliste.count : nil)
            }
        }
    }

    // Die Steuerzeile steht in `Regalsteuerung` (Sammlungsseite.swift) —
    // die Sammlungsseite braucht dieselbe.

    private func laden() async {
        if model.views.isEmpty { await model.loadViews() }
        // Sammlungen und gemischte Bibliotheken kommen nebenher: die Seite
        // wartet nicht auf sie. Treffen sie ein, meldet `angebotskennung`
        // es, und die Wahl wird neu geprüft.
        Task { await model.angebotLaden() }
        // **Die gemerkte Wahl gehört einem Konto.** Sie wird bei jedem Laden
        // gegen das Angebot des angemeldeten Kontos geprüft; eine Bibliothek
        // des vorigen Kontos gibt es darin nicht, und die Seite fällt auf
        // „Alle" zurück, statt eine fremde Kennung abzufragen.
        wahl = model.bereichswahl(art: art)
        guard wahl != .sammlungen else { return }
        geladeneQuelle = quelle?.schluessel
        await stand.laden(model, aus: quelle)
    }

    /// Was der Titel zur Wahl anbietet. Ab zwei Einträgen wird er zum Menü.
    private var angebot: Bereichsangebot { model.bereichsangebot(art: art) }

    /// Ändert sich das, wird die Wahl neu geprüft — über die Kennungen und
    /// nicht über die Anzahl: verschwindet eine Bibliothek und kommt eine
    /// neue dazu, bleibt die Anzahl gleich.
    private var angebotskennung: String {
        angebot.eintraege.map(\.merkwert).joined(separator: ",") + "|"
            + angebot.alleQuellen.joined(separator: "+")
    }

    /// Woraus das Raster liest. `nil`: in diesem Bereich gibt es nichts.
    private var quelle: Regalquelle? {
        switch wahl {
        case .alle:
            // Aus einer Bibliothek wie vor dem Umbau; aus mehreren gesiebt,
            // je Titel einmal (``Titelsieb``).
            angebot.hatBestand
                ? Regalquelle(eltern: angebot.alleAus, art: art,
                              nurAus: angebot.alleAus == nil ? angebot.alleQuellen : [])
                : nil
        case .bibliothek(let id):
            Regalquelle(eltern: id, art: art)
        case .sammlungen:
            nil
        }
    }
    @State private var geladeneQuelle: String?

    private var sammlungsliste: [Sammlung] {
        model.sammlungsverzeichnis?.sammlungen(art: art) ?? []
    }

    /// Was die Zählmarke zeigt.
    private var gezeigt: Int { wahl == .sammlungen ? sammlungsliste.count : stand.gesamt }

    /// **Sammlungen im selben Raster, mit derselben Kachel.** Unter dem
    /// Namen steht statt des Jahres, wie viele Filme bzw. Serien darin sind.
    @ViewBuilder
    private var sammlungskacheln: some View {
        ForEach(sammlungsliste) { sammlung in
            NavigationLink(value: SammlungRoute(sammlung: sammlung.item, art: art)) {
                PosterTile(model: model, item: sammlung.item, breite: nil,
                           auskunft: anzahltext(sammlung.anzahl(art: art)),
                           mosaikQuelle: (sammlung, art))
            }
            .buttonStyle(Stil.Druckknopf())
        }
    }

    private func anzahltext(_ n: Int) -> String {
        Sammlung.anzahltext(art: art, anzahl: n)
    }

    private func beschriftung(_ w: Bereichswahl) -> String {
        switch w {
        case .alle:
            art == "tvshows" ? String(localized: "Alle Serien") : String(localized: "Alle Filme")
        case .sammlungen:
            String(localized: "Sammlungen")
        case .bibliothek(let id):
            angebot.bibliothek(id)?.name ?? ""
        }
    }
}

// MARK: - Umweg von einer Folge auf ihre Serie

/// Holt die Serie zur Folge nach und zeigt die **Serienseite** — mit der
/// Staffel der Folge schon ausgewählt.
///
/// Nicht die nackte Folgenliste: gemeint war dieselbe Seite wie aus „Zuletzt
/// hinzugefügt", mit Heldenbild, Abspielknopf, Direct Play und den Reitern.
/// Die Listeneinträge tragen nur `seriesId`, nicht die Serie selbst — deshalb
/// dieser Zwischenschritt.
struct StaffelZiel: View {
    let model: AppModel
    let folge: Item

    @State private var serie: Item?

    /// **Was vorgeholt ist, steht sofort** — dann gibt es die leere Seite gar
    /// nicht erst.
    ///
    /// Nachgereicht kaeme der Wert zu spaet: der leere Durchgang hat dann
    /// schon stattgefunden, und der ist genau das, was man sieht. Dieselbe
    /// Ueberlegung wie bei `Kulisse` auf dem Fernseher, und woertlich der Weg,
    /// den die Mac-Fassung seit `2fc501c` geht.
    @MainActor init(model: AppModel, folge: Item) {
        self.model = model
        self.folge = folge
        _serie = State(initialValue: Serienspeicher.geteilt.serie(fuer: folge, mit: model))
    }
    /// **Die Staffel frisch holen, nicht die der Kachel glauben.**
    ///
    /// Der Listeneintrag traegt die Staffel, die er beim Laden der Startseite
    /// hatte. Wer eine Staffel zu Ende sieht und die naechste dazulegt, hat
    /// dort weiter die alte stehen — die Seite oeffnete dann mit „Abspielen
    /// S6E1" oben und Staffel 5 in der Folgenliste. Dasselbe Muster wie bei
    /// der Fortsetzstelle in `HomeView.starte`, und dieselbe Abhilfe.
    @State private var frischeStaffelID: String?

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()
            if let serie {
                SeriesDetailView(model: model, serie: serie,
                                 startStaffelID: frischeStaffelID ?? folge.seasonId,
                                 startStaffelNummer: folge.parentIndexNumber)
            } else {
                // Kein Ring: die Seite kommt gleich von selbst.
                Color.clear
            }
        }
        #if os(iOS)
        // **Muss hier stehen, nicht erst in der Serienseite.**
        //
        // Diese Ansicht ist ein Zwischenschritt: sie zeigt einen Ladering,
        // bis die Serie nachgeholt ist. Ohne die Zeile steht in dieser Zeit
        // Apples Leiste da — man sieht den Systemknopf aufblitzen, bevor
        // unserer ihn ablöst. Jedes Sprungziel muss sie selbst setzen; ein
        // Ziel, das es vergisst, blitzt.
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        .task {
            guard let id = folge.seriesId else { return }
            async let frisch = model.item(id: folge.id)
            if serie == nil {
                let geholt = await model.item(id: id)
                // Damit der naechste Weg auf dieselbe Serie ihn nicht wieder
                // geht — Suche, „Aehnliches", ein zweiter Anlauf.
                if let geholt { Serienspeicher.geteilt.merken(geholt) }
                serie = geholt
            }
            frischeStaffelID = await frisch?.seasonId
        }
    }
}
