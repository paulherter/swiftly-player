import JellyfinKit
import SwiftUI

/// Eine Bibliothek als Gitter — sieben Spalten auf 1920 Punkt.
///
/// **Eine Chipreihe, nicht zwei.** Die Sortierung stand daneben als zweiter
/// Chipsatz, mit dem Argument, ein Aufklappblatt koste auf der Fernbedienung
/// zwei Wege statt einem. Das stimmt — nur waren es vier Chips, von denen
/// immer genau einer an ist, und das ist eine Auswahl, kein Filter. Zwei
/// Reihen gleich aussehender Kapseln mit verschiedener Bedeutung haben die
/// Seite zugestellt.
///
/// Jetzt: vorn die Bibliothek als Kapsel (ab zwei), dann Filter und
/// Sortierung als je eine Kapsel mit Zeichen, rechts die Anzahl — die
/// Anordnung der iPhone-Pillen (`Wertpille`). Jede Kapsel nennt den
/// aktuellen Wert und klappt die Wahl dort auf, wo sie steht (E5).
///
/// **Keine Filterchips mehr.** Sie standen als Reihe „Alle · Angefangen ·
/// Ungesehen" da; am iPhone ist es seit je ein Knopf, der den Filter nennt
/// und ein Blatt oeffnet. Paul am 22.09.: „Das gefällt mir nicht. Wir müssen
/// das anders machen, wie auf dem Handy."
///
/// **Kein Kopfblock.** Startseite und Detailseiten tragen oben Titel,
/// Angabenzeile und Beschreibung des Titels, um den es geht. Eine Bibliothek
/// beschreibt keinen einzelnen Titel, sie zeigt einen Bestand — hier gibt es
/// nichts, was ein Heldenbild tragen muesste. Der Grund bleibt der Grund der
/// App — siehe `grundton`.
struct BibliothekView: View {
    let model: AppModel
    /// Entweder über die Gattung („movies", „tvshows") aus der Kopfleiste …
    var art: String?
    /// … oder als benannte Bibliothek über den Sprungpfad …
    var bibliothek: Item?
    /// … oder als Sammlung. **Die Sammlungsseite ist eine Bibliotheksseite**
    /// — wie am iPhone (`SammlungView`): Name, Filter und Sortierung, Raster.
    /// Sortiert nach Jahr, und zwar aufsteigend (``Regalquelle/richtung(_:)``),
    /// damit eine Reihe in ihrer Folge steht. Nichts davon wird gemerkt: eine
    /// Sammlung ist ein Blick in eine Reihe, kein Ort, an den man zurückkehrt.
    var sammlung: Item?
    var filter: [Bibliotheksfilter] = Bibliotheksfilter.allCases

    /// Blättern, Filtern und Sortieren stehen in `Bibliotheksmodell` —
    /// geteilt mit der iPhone-Fassung.
    @State private var stand: Bibliotheksmodell
    /// Welche Tafel offen ist — hoechstens eine. Dieselbe Kennung sagt beim
    /// Schliessen, auf welche Kapsel der Fokus zurueck muss.
    @State private var offeneTafel: Tafel?
    /// **Was die Kapsel vorn gewaehlt hat — seit dem 23.09.2026 mehr als
    /// eine Bibliothek:** „Alle", „Sammlungen", dann die Bibliotheken, wie
    /// das Titelmenue am iPhone. Die Regel steht in ``Bereichsangebot``. Nur
    /// wenn die Ansicht ueber die Gattung kam; ueber den Sprungpfad ist die
    /// Bibliothek benannt und es gibt nichts zu waehlen.
    @State private var wahl: Bereichswahl = .alle
    /// Woraus zuletzt geladen wurde — aendert sich die Quelle unter
    /// derselben Wahl (eine gemischte Bibliothek kommt nach), wird neu geladen.
    @State private var geladeneQuelle: String?
    @FocusState private var amAusloeser: Tafel?

    private enum Tafel: Hashable {
        case bibliothek, filter, sortierung

        /// Der Name des Knopfs, an dem die Tafel haengt — siehe `Tafelanker`.
        var ausloeser: String {
            switch self {
            case .bibliothek: "bibliothek"
            case .filter:     "filter"
            case .sortierung: "sortierung"
            }
        }
    }
    /// Welche Kachel den Fokus hat, und welche ihn zuletzt hatte — wie
    /// `zuletztAmTitel` in `HomeView`. `amTitel` wird `nil`, sobald eine
    /// Detailseite öffnet; `zuletztAmTitel` behält den Titel.
    @FocusState private var amTitel: String?
    @State private var zuletztAmTitel: String?

    /// Der Merkname steht beim Anlegen fest — siehe `Bibliotheksmodell`.
    /// Eine benannte Bibliothek merkt sich ihre eigene Sortierung, eine
    /// Gattung die ihrer Gattung.
    init(model: AppModel, art: String? = nil, bibliothek: Item? = nil,
         sammlung: Item? = nil,
         filter: [Bibliotheksfilter] = Bibliotheksfilter.allCases) {
        self.model = model
        self.art = art
        self.bibliothek = bibliothek
        self.sammlung = sammlung
        // Bei Serien derselbe Satz wie auf der Serienbibliothek.
        self.filter = sammlung != nil && art == "tvshows"
            ? [.alle, .angefangen, .merkliste] : filter
        let stand = Bibliotheksmodell(merkname: sammlung == nil ? (bibliothek?.id ?? art) : nil)
        if sammlung != nil { stand.sortierung = .erscheinung }
        _stand = State(initialValue: stand)
    }
    @Environment(\.tafelOffen) private var tafelOffen

    private var spalten: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Stil.gitterSpalte),
              count: Stil.gitterSpalten)
    }

    var body: some View {
        ZStack {
            if stand.laedt, wahl != .sammlungen {
                // Kein Ladering: das Raster steht schon in seiner Form und
                // wird ueberblendet, sobald die Titel da sind.
                Rasterplatzhalter()
                    .padding(.horizontal, Stil.randSeite)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, Stil.leisteUnten + 90)
                    .transition(.opacity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        if let sammlung {
                            // Der Name kommt vom Server und wird nicht
                            // übersetzt — wie der Titel der Genreseite.
                            Reihentitel(name: sammlung.name)
                                .padding(.horizontal, Stil.randSeite)
                        }
                        chipreihe

                        if wahl == .sammlungen {
                            // Die Liste steht schon im Speicher: „Sammlungen"
                            // gibt es in der Tafel nur, wenn es welche gibt.
                            sammlungsgitter
                        } else if stand.items.isEmpty {
                            leer
                        } else {
                            gitter
                        }
                    }
                    // **Die Chipreihe endet bei 264**, wie das oberste
                    // Element jeder anderen Seite — siehe `Stil.erstesEnde`.
                    //
                    // Zurueckgerechnet aus ihrer eigenen Hoehe: 264 − 48 =
                    // 216, davon der obere sichere Rand ab, an dem die
                    // Scrollflaeche beginnt.
                    //
                    // Vorher stand hier der Anfang (190). Bei verschieden
                    // hohen Elementen richtet ein gemeinsamer Anfang nichts
                    // aus — die Chips endeten 26 Punkt hoeher als der Titel
                    // der Startseite.
                    //
                    // Die Sammlungsseite traegt ihren Namen darueber und
                    // beginnt deshalb wie die Genreseite.
                    .padding(.top, sammlung != nil
                             ? Stil.kopfversatzDetail + 40 - Stil.randOben
                             : bibliothek == nil
                             ? Stil.erstesEnde - Stil.chipHoehe - Stil.randOben
                             : Stil.randOben)
                    .padding(.bottom, 60)
                }
                .scrollIndicators(.hidden)
                // **Zurück heißt: auf den Titel, der offen war.**
                //
                // Ohne Vorgabe sucht tvOS beim Wiedererscheinen selbst eine
                // Kachel aus, und zwar oben im sichtbaren Ausschnitt — ein bis
                // zwei Reihen über dem geöffneten Titel. Dieselbe Lösung wie
                // in `HomeView`: gemerkter Titel, `userInitiated` sticht die
                // Wahl des Systems. Beim ersten Öffnen ist nichts gemerkt,
                // dann bleibt es beim Systemfokus.
                .defaultFocus($amTitel, zuletztAmTitel,
                              priority: zuletztAmTitel == nil ? .automatic : .userInitiated)
                .onChange(of: amTitel) { _, jetzt in
                    if let jetzt { zuletztAmTitel = jetzt }
                }
            }
        }
        // Eine andere Liste — der gemerkte Titel gehört nicht mehr dazu.
        .onChange(of: stand.kennung) { zuletztAmTitel = nil }
        .onChange(of: wahl) { zuletztAmTitel = nil }
        // **Sammlungen und gemischte Bibliotheken kommen nach** (aus
        // `angebotLaden()`). Aendert sich damit, was „Alle" liest oder was
        // gewaehlt sein darf, wird neu geladen — wie am iPhone.
        .onChange(of: angebotskennung) { _, _ in
            guard ueberGattung else { return }
            let neu = model.bereichswahl(art: art ?? "")
            guard neu != wahl || quelle?.schluessel != geladeneQuelle else { return }
            wahl = neu
            Task { await laden() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(grundton.ignoresSafeArea())
        // Seitlicher Rand: siehe `HomeView` — der Systemrand faellt weg,
        // damit `randSeite` nicht darauf sitzt und sich verdoppelt.
        .ignoresSafeArea(edges: .horizontal)
        // Hinter der offenen Tafel ist nichts fokussierbar — siehe die
        // Detailseiten, dort war es derselbe Fehler.
        .disabled(offeneTafel != nil)
        // **Unter ihrem Ausloeser, an seiner Kante** — siehe `Tafelanker`.
        //
        // Hier standen zwei Auflagen mit festen Abstaenden: `Stil.randSeite`
        // zur Seite, `Stil.erstesEnde + 16` nach unten. Beide Zahlen sind von
        // der **Bildkante** gedacht, eine Auflage rechnet aber vom sicheren
        // Bereich — 80 Punkt zur Seite, 60 nach oben. Gemessen im Simulator:
        // der Knopf „Videothek" steht bei 76…266, seine Tafel stand bei
        // 160…779 und 76 Punkt zu tief; die Sortiertafel endete bei 1760,
        // ihr Knopf bei 1842. Beides genau um den sicheren Rand daneben.
        .tafel(unter: offeneTafel?.ausloeser) {
            Handlungstafel(handlungen: tafelinhalt.handlungen,
                           offen: tafelBindung,
                           gewaehlt: tafelinhalt.gewaehlt,
                           rubrik: tafelrubrik)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.18), value: offeneTafel)
        // Die Seite schaltet sich selbst ab, die Kopfleiste gehoert ihr aber
        // nicht — die muss `HauptView` stilllegen. Sonst stieg der Fokus aus
        // der offenen Tafel nach oben auf die Bereichsknoepfe.
        //
        // Nach dem Schliessen zurueck auf die Kapsel, die sie geoeffnet hat.
        .onChange(of: offeneTafel) { alt, neu in
            tafelOffen.wrappedValue = neu != nil
            if neu == nil, let alt { amAusloeser = alt }
        }
        // Wer die Seite mit offener Tafel verlaesst, liesse die Leiste tot
        // zurueck.
        .onDisappear { tafelOffen.wrappedValue = false }
        .animation(Stil.einblenden, value: stand.laedt)
        // **Und der Kontowechsel gehoert in die Kennung.** Er stand nur
        // hier nicht: `stand.kennung` traegt Bibliothek, Filter und
        // Sortierung — alles Werte, die sich beim Wechsel nicht aendern.
        // Die Seite behielt damit die Titel des vorigen Kontos, samt deren
        // Haken. iPhone und iPad haengen den Zaehler seit je an.
        .task(id: "\(stand.kennung)|\(model.kontowechsel)") { await laden() }
    }

    /// **Ein Grund fuer alle Bestandsseiten, und zwar unserer.**
    ///
    /// Hier stand ein Netzverlauf je Bereich: Serien im Akzent (171 Grad),
    /// Filme in der Komplementaeren (351 Grad), damit man am Grund sieht, wo
    /// man ist, bevor man die Leiste liest. Das war aus der Zeit, in der die
    /// Palette noch getoent war.
    ///
    /// Zwei Gruende, es fallen zu lassen. Die Leiste oben sagt ohnehin, wo
    /// man ist, und sie sagt es in Worten. Und die Merkliste — dieselbe Art
    /// Seite, derselbe Aufbau, dasselbe Gitter — hatte nie einen Verlauf;
    /// nebeneinander sahen drei Bestandsseiten nach drei verschiedenen Apps
    /// aus. Paul am 23.09.: „einfach nur unser Grau, so wie bei Watchlist.
    /// Das ist konsistent."
    ///
    /// Die Farbe bleibt dort, wo sie etwas aussagt: am gewaehlten Filter, am
    /// Fortschritt, am Beleg. Nicht unter allem.
    private var grundton: some View {
        Stil.grund.ignoresSafeArea()
    }

    /// Was die offene Tafel zeigt, und welche Zeile davon gilt.
    private var tafelinhalt: (handlungen: [Titelhandlung], gewaehlt: Int?) {
        switch offeneTafel {
        case .filter:
            (filterhandlungen, filter.firstIndex(of: stand.filter))
        case .sortierung:
            (sortierhandlungen, Sortierung.allCases.firstIndex(of: stand.sortierung))
        case .bibliothek, nil:
            (bibliothekshandlungen, angebot.eintraege.firstIndex(of: wahl))
        }
    }

    /// Die Filter als Tafel — dieselben Zeichen wie Sortierung und
    /// Bibliothekswahl daneben, dieselben Eintraege wie am iPhone.
    private var filterhandlungen: [Titelhandlung] {
        filter.map { f in
            Titelhandlung(symbol: stand.filter == f ? "checkmark.circle.fill" : "circle",
                          text: "\(f.beschriftung)") { stand.filter = f }
        }
    }

    /// Die Sortierungen als Handlungstafel — kein zweiter Chipsatz.
    private var sortierhandlungen: [Titelhandlung] {
        Sortierung.allCases.map { s in
            Titelhandlung(symbol: stand.sortierung == s ? "checkmark.circle.fill" : "circle",
                          text: "\(s.beschriftung)") { stand.sortierung = s }
        }
    }

    /// Das Titelmenue als Tafel: Alle · Sammlungen · Strich · Bibliotheken.
    /// Die Namen der Bibliotheken kommen vom Server und stehen **wörtlich** —
    /// siehe `Titelhandlung.wortlaut`.
    private var bibliothekshandlungen: [Titelhandlung] {
        angebot.eintraege.map { eintrag in
            Titelhandlung(symbol: eintrag == wahl ? "checkmark.circle.fill" : "circle",
                          wortlaut: beschriftung(eintrag)) {
                guard eintrag != wahl else { return }
                model.bereichWaehlen(eintrag, art: art ?? "")
                wahl = eintrag
                Task { await laden() }
            }
        }
    }

    /// Wo in der Tafel die Rubrik „Bibliotheken" steht.
    private func tafelrubrik(_ zeile: Int) -> LocalizedStringKey? {
        guard offeneTafel == .bibliothek,
              angebot.eintraege.indices.contains(zeile),
              angebot.eintraege[zeile] == angebot.ersteBibliothek else { return nil }
        return "Bibliotheken"
    }

    /// `Handlungstafel` kennt nur offen oder zu; zu heisst hier: keine Tafel.
    private var tafelBindung: Binding<Bool> {
        Binding(get: { offeneTafel != nil },
                set: { if !$0 { offeneTafel = nil } })
    }

    // MARK: Teile

    private var chipreihe: some View {
        HStack(alignment: .center, spacing: 20) {
            // **Die Bibliothek steht vorn, als Kapsel, und nur ab zwei** (D9).
            //
            // Vorher je Bibliothek ein Chip. Bei acht Bibliotheken fuellten
            // die allein die Reihe, und zwei Chipsaetze mit verschiedener
            // Bedeutung sahen gleich aus. Jetzt nennt die Kapsel die gewaehlte
            // und klappt die uebrigen als Tafel auf — wie die Sortierung.
            // Entwurf: `Gestaltung/Bibliothekswahl-tvOS`, Variante A2.
            //
            // **Seit dem 23.09.2026 das Titelmenue des iPhones:** Alle,
            // Sammlungen, Strich, Bibliotheken. Die Kapsel nennt den Wert —
            // „Alle Filme", nicht wie am iPhone nur „Filme": dort ist es der
            // Seitentitel, hier sagt die Kopfleiste schon, wo man ist, und
            // die Kapsel ist eine Wahl neben Filter und Sortierung.
            if ueberGattung, angebot.istMenue {
                Button { offeneTafel = .bibliothek } label: {
                    Text(verbatim: beschriftung(wahl))
                }
                .buttonStyle(KapselStil())
                .focused($amAusloeser, equals: .bibliothek)
                .tafelausloeser(Tafel.bibliothek.ausloeser)
                .accessibilityLabel(Text("Bibliothek, \(beschriftung(wahl))"))

                // Senkrechter Strich statt Abstand: Wahl und Filter
                // nebeneinander sehen sonst aus wie eine Reihe. Ohne Filter
                // („Sammlungen") trennt er nichts und faellt weg.
                if wahl != .sammlungen {
                    Rectangle()
                        .fill(Stil.rand)
                        .frame(width: 2, height: Stil.chipHoehe * 0.6)
                }
            }

            // **Filter und Sortierung nebeneinander, mit Zeichen — wie die
            // zwei `Wertpille`n am iPhone**, dieselben Zeichen in derselben
            // Reihenfolge. Die Sortierung stand rechts aussen neben der
            // Anzahl; am iPhone steht rechts nur die Anzahl.
            // **Bei „Sammlungen" nur die Anzahl** — die Liste muss man weder
            // filtern noch umsortieren (`Regalsteuerung.nurAnzahl` am iPhone).
            // Die Reihe behaelt ihre Hoehe, siehe unten.
            if wahl != .sammlungen {
                Button { offeneTafel = .filter } label: {
                    Text(verbatim: stand.filter.beschriftung)
                }
                .buttonStyle(KapselStil(symbol: "line.3.horizontal.decrease"))
                .focused($amAusloeser, equals: .filter)
                .tafelausloeser(Tafel.filter.ausloeser)
                .accessibilityLabel(Text("Filter, \(stand.filter.beschriftung)"))

                Button { offeneTafel = .sortierung } label: {
                    Text(verbatim: stand.sortierung.beschriftung)
                }
                .buttonStyle(KapselStil(symbol: "arrow.up.arrow.down"))
                .focused($amAusloeser, equals: .sortierung)
                .tafelausloeser(Tafel.sortierung.ausloeser)
                .accessibilityLabel(Text("Sortierung, \(stand.sortierung.beschriftung)"))
            }

            Spacer(minLength: 40)

            // Die Anzahl stand bisher nirgends — sie ist die einzige Auskunft,
            // die eine Bibliothek ueber sich selbst geben kann.
            if wahl == .sammlungen {
                if !sammlungsliste.isEmpty {
                    Text("\(sammlungsliste.count) Sammlungen")
                        .font(Stil.klein)
                        .foregroundStyle(Stil.schriftSehrLeise)
                }
            } else if stand.gesamt > 0 {
                Text("\(stand.gesamt) Titel")
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
            }
        }
        // **Dieselbe Hoehe mit und ohne Kapseln.** Bei „Sammlungen" fehlen
        // Filter und Sortierung; ohne feste Hoehe rutschte die Reihe beim
        // Wechsel nach oben und das Raster sprang mit — derselbe Fehler, den
        // `Regalsteuerung` am iPhone mit `minHeight` abfaengt.
        .frame(height: Stil.chipHoehe)
        .focusSection()
        .padding(.horizontal, Stil.randSeite)
    }

    private var gitter: some View {
        LazyVGrid(columns: spalten, alignment: .leading, spacing: Stil.gitterZeile) {
            ForEach(stand.items) { item in
                NavigationLink(value: item) {
                    Kachelinhalt(bild: model.imageURL(for: item, maxHeight: 600,
                                                      hochkant: true),
                                 titel: item.name,
                                 fortschritt: item.userData?.playedPercentage
                                     .map { $0 / 100 },
                                 mitUnterzeile: false,
                                 marke: Anzeigeregeln.kachelmarke(
                                    art: item.type,
                                    staffeln: item.childCount,
                                    gesehen: item.userData?.played,
                                    offeneFolgen: item.userData?.unplayedItemCount))
                }
                .buttonStyle(KachelStil())
                .focused($amTitel, equals: item.id)
                // Nachladen, sobald eine der letzten drei Reihen auftaucht —
                // dann steht der Nachschub, bevor der Fokus unten ankommt.
                .onAppear {
                    guard stand.loestNachladenAus(item.id, spalten: Stil.gitterSpalten)
                    else { return }
                    Task { await nachladen() }
                }
            }
        }
        .padding(.horizontal, Stil.randSeite)
        // Der Fokusring der äußeren Spalten liegt sonst unter dem Rand.
        .scrollClipDisabled()
    }

    /// **Gestoert ist nicht leer.**
    ///
    /// `Bibliotheksmodell.gestoert` steht seit der iPhone-Fassung im Modell
    /// und wurde hier nicht gelesen: antwortete der Server nicht, stand
    /// „Hier ist noch nichts" — eine Behauptung ueber den Serverinhalt, die
    /// niemand geprueft hat. Die eigene Startseite macht es nebenan richtig
    /// (`HomeView`), dieselbe Formel steht jetzt auch hier: die
    /// Serveradresse und die Frage, die weiterhilft.
    @ViewBuilder
    private var leer: some View {
        if stand.gestoert {
            Leerzustand(
                symbol: "externaldrive.badge.xmark",
                titel: "Server ist abgetaucht",
                hinweis: "\(model.serverAdresse ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                knopf: ("Erneut versuchen", { Task { await laden() } }))
            .frame(height: 500)
        } else {
            Leerzustand(
                symbol: stand.filter == .alle ? "tray" : "line.3.horizontal.decrease",
                titel: stand.filter == .alle ? "Hier ist noch nichts" : "Nichts gefunden",
                hinweis: stand.filter != .alle
                    ? "Unter diesem Filter liegt gerade nichts."
                    : sammlung != nil
                    ? "Sobald in dieser Sammlung etwas liegt, taucht es hier auf."
                    : "Sobald in dieser Bibliothek etwas liegt, taucht es hier auf.",
                knopf: stand.filter == .alle
                    ? ("Aktualisieren", { Task { await laden() } })
                    : ("Filter zurücksetzen", { stand.filter = .alle }))
            .frame(height: 500)
        }
    }

    // MARK: Sammlungen

    /// **Sammlungen im selben Raster, mit derselben Kachel.** Unter dem Namen
    /// steht, wie viele Filme bzw. Serien darin sind — wie am iPhone. Ohne
    /// eigenes Bild traegt die Kachel ein Mosaik aus den ersten Plakaten
    /// (`Sammlungsmosaik`).
    private var sammlungsgitter: some View {
        LazyVGrid(columns: spalten, alignment: .leading, spacing: Stil.gitterZeile) {
            ForEach(sammlungsliste) { eintrag in
                NavigationLink(value: SammlungRoute(sammlung: eintrag.item, art: art)) {
                    Kachelinhalt(bild: model.imageURL(for: eintrag.item, maxHeight: 600,
                                                      hochkant: true),
                                 titel: eintrag.item.name,
                                 unterzeile: anzahltext(eintrag.anzahl(art: art ?? "")),
                                 ersatz: eintrag.item.imageTags?["Primary"] == nil
                                     ? AnyView(Sammlungsmosaik(model: model, sammlung: eintrag,
                                                               art: art ?? ""))
                                     : nil)
                }
                .buttonStyle(KachelStil())
                .focused($amTitel, equals: eintrag.id)
            }
        }
        .padding(.horizontal, Stil.randSeite)
        .scrollClipDisabled()
    }

    private var sammlungsliste: [Sammlung] {
        model.sammlungsverzeichnis?.sammlungen(art: art ?? "") ?? []
    }

    private func anzahltext(_ n: Int) -> String {
        art == "tvshows" ? String(localized: "\(n) Serien") : String(localized: "\(n) Filme")
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

    // MARK: Laden

    /// Nur ueber die Gattung gibt es etwas zu waehlen.
    private var ueberGattung: Bool { bibliothek == nil && sammlung == nil && art != nil }

    /// Was die Kapsel zur Wahl anbietet. Ab zwei Eintraegen steht sie da.
    private var angebot: Bereichsangebot { model.bereichsangebot(art: art ?? "") }

    /// Aendert sich das, wird die Wahl neu geprueft — ueber die Kennungen,
    /// nicht ueber die Anzahl (siehe `BibliothekView` am iPhone).
    private var angebotskennung: String {
        angebot.eintraege.map(\.merkwert).joined(separator: ",") + "|"
            + angebot.alleQuellen.joined(separator: "+")
    }

    /// Woraus das Raster liest. `nil`: in diesem Bereich gibt es nichts.
    private var quelle: Regalquelle? {
        if let sammlung { return Regalquelle(eltern: sammlung.id, art: art, sammlung: true) }
        if let bibliothek {
            return Regalquelle(eltern: bibliothek.id, art: art ?? bibliothek.collectionType)
        }
        guard let art else { return nil }
        switch wahl {
        case .alle:
            // Aus einer Bibliothek wie vor dem Umbau; aus mehreren gesiebt,
            // je Titel einmal (``Titelsieb``).
            return angebot.hatBestand
                ? Regalquelle(eltern: angebot.alleAus, art: art,
                              nurAus: angebot.alleAus == nil ? angebot.alleQuellen : [])
                : nil
        case .bibliothek(let id):
            return Regalquelle(eltern: id, art: art)
        case .sammlungen:
            return nil
        }
    }

    private func laden() async {
        if bibliothek == nil, model.views.isEmpty { await model.loadViews() }
        if ueberGattung {
            // Sammlungen und gemischte Bibliotheken kommen nebenher: die
            // Seite wartet nicht auf sie. Treffen sie ein, meldet
            // `angebotskennung` es, und die Wahl wird neu geprueft.
            Task { await model.angebotLaden() }
            // **Die gemerkte Wahl gehoert einem Konto.** Bei jedem Laden gegen
            // das Angebot des angemeldeten Kontos geprueft; eine Bibliothek
            // des vorigen Kontos gibt es darin nicht, und die Seite faellt
            // auf „Alle" zurueck, statt eine fremde Kennung abzufragen.
            wahl = model.bereichswahl(art: art ?? "")
            guard wahl != .sammlungen else { return }
        }
        geladeneQuelle = quelle?.schluessel
        await stand.laden(model, aus: quelle)
    }

    private func nachladen() async {
        guard let quelle else { return }
        await stand.nachladen(model, aus: quelle)
    }
}

// MARK: - Sammlungen

/// Eine Sammlung, geöffnet aus einem Bereich — `art` sagt, ob ihre Filme
/// oder ihre Serien gemeint sind. `nil`: alles, was in ihr steht. Derselbe
/// Weg wie am iPhone (`Sammlungsseite.swift`, dort nicht im Fernsehziel).
struct SammlungRoute: Hashable {
    let sammlung: Item
    let art: String?
}

/// **Ersatzplakat einer Sammlung ohne eigenes Bild** — ein Mosaik aus den
/// Plakaten ihrer ersten Titel, im selben 2:3-Format und mit denselben Ecken
/// wie jedes andere Plakat. Dieselbe Regel wie am iPhone: ein Titel füllt das
/// Feld, zwei stehen nebeneinander, ab drei wird daraus ein 2×2-Mosaik.
///
/// Die Fugen sind doppelt so breit wie am iPhone (2 → 4), wie jedes Mass auf
/// dem Fernseher; die Plakate kommen in halber Kachelgroesse.
struct Sammlungsmosaik: View {
    let model: AppModel
    let sammlung: Sammlung
    let art: String

    @State private var titel: [Item] = []

    private static let fuge: CGFloat = 4

    private var reihen: [[Item]] {
        titel.isEmpty ? [] : (titel.count > 2 ? [Array(titel.prefix(2)), Array(titel[2...].prefix(2))]
                                               : [titel])
    }

    var body: some View {
        GeometryReader { rahmen in
            let platz = reihen.isEmpty ? [[]] : reihen
            let hoehe = (rahmen.size.height - CGFloat(platz.count - 1) * Self.fuge)
                / CGFloat(platz.count)
            VStack(spacing: Self.fuge) {
                ForEach(Array(platz.enumerated()), id: \.offset) { _, stapel in
                    zeile(stapel, breite: rahmen.size.width, hoehe: hoehe)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Stil.eckeKachel, style: .continuous))
        .task(id: sammlung.id) {
            let gefunden = await model.sammlungstitel(sammlung, art: art)
            withAnimation(Stil.einblenden) { titel = Array((gefunden ?? []).prefix(4)) }
        }
    }

    private func zeile(_ stapel: [Item], breite: CGFloat, hoehe: CGFloat) -> some View {
        let feldbreite = stapel.isEmpty ? breite
            : (breite - CGFloat(stapel.count - 1) * Self.fuge) / CGFloat(stapel.count)
        return HStack(spacing: Self.fuge) {
            if stapel.isEmpty {
                Bild(url: nil, breite: feldbreite, hoehe: hoehe, ecke: 0)
            } else {
                ForEach(stapel) { eintrag in
                    Bild(url: model.imageURL(for: eintrag, maxHeight: 300, hochkant: true),
                         breite: feldbreite, hoehe: hoehe, ecke: 0)
                }
            }
        }
    }
}
