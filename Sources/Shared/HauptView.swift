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
    @State private var pfade = [NavigationPath(), NavigationPath(),
                                NavigationPath(), NavigationPath()]
    /// Der Profilzweig ist offen. Nur für die Seitenleiste: dort trägt dann
    /// das Profilzeichen die Auswahl statt eines der vier Bereiche.
    ///
    /// Eigener Stand, weil sich ein `NavigationPath` nicht befragen lässt —
    /// man kann ihm nicht ansehen, was obenauf liegt. Gesetzt beim Tippen,
    /// zurückgenommen, sobald der Stapel wieder leer ist.
    @State private var imProfil = false

    @Environment(\.breit) private var breit
    @Environment(\.fensterknoepfe) private var fensterknoepfe

    /// Auf Unterseiten weicht die Leiste — dort zählt der Inhalt, und der
    /// Zurückweg ist der Wisch von links. **Nur unten**: die Seitenleiste
    /// bleibt stehen, siehe `Seitenleiste`.
    private var anDerWurzel: Bool { pfade[bereich.rawValue].isEmpty }

    var body: some View {
        ZStack(alignment: .bottom) {
            Stil.grund.ignoresSafeArea()

            HStack(spacing: 0) {
                if breit {
                    Seitenleiste(gewaehlt: $bereich, imProfil: imProfil,
                                 name: model.session?.userName ?? "?",
                                 bild: model.benutzerbildURL()) {
                        imProfil = true
                        pfade[bereich.rawValue].append(ProfilRoute())
                    }
                    // Die Leiste steht fest; nur der Inhalt daneben weicht der
                    // Tastatur.
                    .ignoresSafeArea(.keyboard)
                }

                ZStack {
                    ForEach(Bereich.allCases) { b in
                        if besucht.contains(b) {
                            stapel(b)
                                .opacity(bereich == b ? 1 : 0)
                                .allowsHitTesting(bereich == b)
                        }
                    }
                }
            }

            if !breit, anDerWurzel {
                Navileiste(gewaehlt: $bereich)
                    // Der Tastaturbereich muss *hier* ignoriert werden, nicht
                    // in der Leiste selbst: schrumpfen tut der Stapel drumherum,
                    // und ein ignoresSafeArea im Kind haelt den Elternteil nicht
                    // davon ab. Der volle Rahmen davor sorgt dafuer, dass die
                    // Leiste am echten unteren Rand haengt.
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }
        // Bewusst ohne Übergang: die Leiste soll fest liegen und beim
        // Zurückkommen einfach wieder da sein, so wie der Inhalt dahinter
        // auch. Eingeblendet wirkte sie wie ein eigenes Blatt.
        .task { await model.fernsteuerungStarten() }
        // Sonst bleibt der Socket offen, wenn die Ansicht weicht — etwa beim
        // Abmelden, wo `RootView` auf den Anmeldebildschirm wechselt.
        .onDisappear { Task { await model.fernsteuerungBeenden() } }
        .onChange(of: bereich) { alt, neu in
            besucht.insert(neu)
            if alt != .suche { vorigerBereich = alt }
            imProfil = false
        }
        // Zurück an der Wurzel heißt: der Profilzweig ist zu.
        .onChange(of: anDerWurzel) { _, wurzel in
            if wurzel { imProfil = false }
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
            .navigationDestination(for: LibraryRoute.self) { route in
                ItemListView(model: model, library: route.item)
            }
            .navigationDestination(for: Item.self) { item in
                if item.type == "Series" {
                    SeriesDetailView(model: model, serie: item)
                } else if item.type == "Episode" {
                    // Folgen bekommen keine eigene Seite — sie führen auf ihre
                    // Staffel. Eine Seite nur für eine Folge trägt nichts, was
                    // nicht in der Liste schon steht.
                    StaffelZiel(model: model, folge: item)
                } else {
                    ItemDetailView(model: model, item: item)
                }
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
            .navigationDestination(for: WiedergabeRoute.self) { _ in
                WiedergabeEinstellungenView(model: model)
            }
            .navigationDestination(for: StaffelRoute.self) { route in
                SeasonView(model: model, serie: route.serie, staffel: route.staffel)
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
    @State private var stand = Bibliotheksmodell()
    @State private var sortierlisteOffen = false
    /// Welche Bibliothek dieser Gattung gezeigt wird.
    ///
    /// Ein Server kann mehrere Filmbibliotheken haben — im TestFlight eine
    /// auf einer externen Platte und eine lokale. Vorher nahm die Ansicht
    /// stumm die erste, und die zweite war nicht erreichbar.
    @State private var gewaehlt: Item?
    @State private var bibliothekslisteOffen = false

    @Environment(\.breit) private var breit
    @Environment(\.fensterknoepfe) private var fensterknoepfe

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
        .overlay(alignment: .topTrailing) {
            if sortierlisteOffen {
                Auswahlblatt(offen: $sortierlisteOffen, titel: "Sortieren",
                             eintraege: Sortierung.allCases,
                             beschriftung: { $0.beschriftung },
                             istGewaehlt: { $0 == stand.sortierung },
                             waehlen: { stand.sortierung = $0 })
            }
        }
        .overlay(alignment: .topTrailing) {
            if bibliothekslisteOffen {
                Auswahlblatt(offen: $bibliothekslisteOffen, titel: "Bibliothek",
                             eintraege: auswahl,
                             beschriftung: { $0.name },
                             istGewaehlt: { $0.id == gewaehlt?.id },
                             waehlen: { bib in
                                 guard bib.id != gewaehlt?.id else { return }
                                 model.bibliothekWaehlen(bib, art: art)
                                 gewaehlt = bib
                                 Task { await laden() }
                             })
            }
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
        .task(id: stand.kennung) { await laden() }
    }

    private func inhalt(nutzbar: CGFloat) -> some View {
        let anzahl = Stil.spalten(nutzbar: nutzbar, breit: breit)
        return ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                LazyVGrid(columns: spalten(anzahl), alignment: .leading, spacing: 20) {
                    ForEach(stand.items) { item in
                        NavigationLink(value: item) {
                            PosterTile(model: model, item: item, breite: nil)
                        }
                        .buttonStyle(.plain)
                        // Nachladen, sobald die drittletzte Reihe auftaucht —
                        // dann steht der Nachschub schon, bevor man unten
                        // ankommt.
                        .onAppear {
                            guard item.id == stand.nachladenAb(spalten: anzahl) else { return }
                            Task { await stand.nachladen(model, art: art, bibliothek: gewaehlt) }
                        }
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
                .padding(.top, 8)

                if stand.nochMehrDa {
                    Lader(groesse: 22, staerke: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.top, (breit ? 118 + Stil.kopfOben : 112)
                            + (fensterknoepfe ? Fensterknoepfe.hoehe : 0),
                            for: .scrollContent)
            .contentMargins(.bottom, breit ? 24 : Stil.leisteHoehe + 12,
                            for: .scrollContent)

            kopf

            if stand.laedt {
                Lader()
            } else if stand.gestoert {
                // Derselbe Text wie auf der Startseite, samt Serveradresse.
                // Vorher stand hier „Hier ist noch nichts" — dieselbe Ursache,
                // zwei Diagnosen, und die falsche schickt einen zum Server
                // statt zum Netz.
                Leerzustand(
                    symbol: "externaldrive.badge.xmark",
                    kopfzeile: "Kein Kontakt zum Server",
                    text: "\(model.serverAdresse ?? String(localized: "Der Server")) hat nicht geantwortet. Läuft der Server, und bist du im selben Netz?",
                    hauptknopf: ("Erneut versuchen", { Task { await laden() } }))
                    .padding(.bottom, Stil.leisteHoehe)
            } else if stand.items.isEmpty {
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
        Unschaerfekopf {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom) {
                    // **Nur ab zwei Bibliotheken ein Menü.**
                    //
                    // Wer eine hat — und das sind fast alle — sieht genau das
                    // Gleiche wie vorher: eine Überschrift, kein Zeichen, kein
                    // Tippziel. Ein Umschalter, der nichts umzuschalten hat,
                    // ist eine Frage ohne Antwort.
                    if auswahl.count > 1 {
                        // Kein `Menu` — E4 im Register: keine
                        // Apple-Standardsteuerelemente. Dasselbe
                        // `Auswahlblatt` wie bei der Sortierung, und es
                        // nimmt die Beschriftung als `String`, was hier
                        // noetig ist: Bibliotheksnamen kommen vom Server.
                        Button { bibliothekslisteOffen = true } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(gewaehlt?.name ?? "")
                                    .font(Stil.titelGross).tracking(-0.6)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Stil.schriftLeise)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(titel).font(Stil.titelGross).tracking(-0.6)
                    }
                    Spacer(minLength: 0)
                    // Breit steht das Profilzeichen in der Seitenleiste, und
                    // zwar für alle vier Bereiche. Hier wäre es das zweite.
                    if !breit {
                        NavigationLink(value: ProfilRoute()) {
                            Profilzeichen(name: model.session?.userName ?? "?",
                                          bild: model.benutzerbildURL())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(Stil.schrift)

                // Filter links, Sortierung rechts abgesetzt: das eine grenzt
                // ein, das andere ordnet nur um — zwei verschiedene Fragen.
                HStack(spacing: 8) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(filter) { f in
                                Wahlchip(text: f.beschriftung, an: stand.filter == f) {
                                    stand.filter = f
                                }
                            }
                        }
                        // Platz für das Ausblenden am Rand, damit der letzte
                        // Chip nicht unter der Sortierpille klebt.
                        .padding(.trailing, 18)
                    }
                    .scrollIndicators(.hidden)
                    // Am rechten Rand ausblenden statt hart abschneiden — so
                    // sieht man auch, dass dort noch etwas weitergeht.
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.88),
                            .init(color: .clear, location: 1),
                        ], startPoint: .leading, endPoint: .trailing)
                    }

                    // Schmal: eine Pille, die ein Blatt öffnet — für vier
                    // Möglichkeiten ist auf 390 Punkt kein Platz.
                    //
                    // Breit: die Möglichkeiten stehen offen nebeneinander, wie
                    // auf dem Fernseher. Ein Blatt für etwas, das daneben
                    // hinpasst, ist ein Umweg. Das Zeichen davor ist nötig,
                    // sonst stehen zwei Akzentchips in einer Reihe und man
                    // sieht nicht, welche Frage welche ist.
                    if breit {
                        // Aufbau wie auf dem iPhone: die Filterreihe scrollt,
                        // die Sortierung steht rechts abgesetzt und weicht
                        // nicht. Dort ist sie eine Pille, hier stehen die
                        // Möglichkeiten offen — aber die Rangfolge beim
                        // Platzmangel ist dieselbe, sonst wurden hochkant
                        // beide Reihen gestaucht.
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Stil.schriftSehrLeise)
                            ForEach(Sortierung.allCases) { s in
                                Wahlchip(text: s.beschriftung, an: stand.sortierung == s) {
                                    stand.sortierung = s
                                }
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                    } else {
                        Button { sortierlisteOffen = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "line.3.horizontal.decrease")
                                    .font(.system(size: 12, weight: .medium))
                                Text(stand.sortierung.beschriftung)
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(Stil.schrift)
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .background(Stil.erhoeht, in: Capsule())
                            .overlay { Capsule().strokeBorder(Stil.rand) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func laden() async {
        if model.views.isEmpty { await model.loadViews() }
        if gewaehlt == nil { gewaehlt = model.gewaehlteBibliothek(art: art) }
        await stand.laden(model, art: art, bibliothek: gewaehlt)
    }

    /// Alle Bibliotheken dieser Gattung. Ab zwei wird der Titel zum Menü.
    private var auswahl: [Item] { model.bibliotheken(art: art) }
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
                Lader()
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
            if serie == nil { serie = await model.item(id: id) }
            frischeStaffelID = await frisch?.seasonId
        }
    }
}
