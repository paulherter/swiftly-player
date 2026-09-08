import JellyfinKit
import SwiftUI

/// Die Serienseite. Derselbe Kopf wie beim Film, darunter drei Abschnitte:
/// Folgen · Besetzung · Ähnliches.
///
/// Verhalten wörtlich aus der iPhone-Fassung:
/// - Die Staffelpille klappt eine Liste **direkt darunter** auf — kein
///   eigenes Fenster, kein Blatt von unten. Haken bei der aktuellen.
/// - Die Reiter wechseln den Abschnitt darunter, **ohne zu scrollen**.
/// - Eine Folge startet an ihrer eigenen Position.
struct SerienView: View {
    let model: AppModel
    let serie: Item
    /// Welche Staffel beim Öffnen gewählt ist — gesetzt, wenn man über eine
    /// Folge hierhergekommen ist (A8).
    var startStaffelID: String?
    /// Die **Nummer** der Staffel, aus der man kommt — der verlaessliche Weg.
    ///
    /// Am Geraet gemessen: der Server kann an einer Folge kein `SeasonId`
    /// liefern. Dann greifen die Kennungsvergleiche ins Leere und die Wahl
    /// faellt auf die erste Staffel. Die Nummer steht dagegen immer da.
    var startStaffelNummer: Int?
    let zurueck: () -> Void
    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich

    @State private var reiter: Reiter = .folgen
    @State private var staffeln: [Item] = []
    @State private var gewaehlt: Item?
    @State private var folgen: [Item] = []
    @State private var aehnliche: [Item] = []
    @State private var staffelOffen = false
    @State private var staffeltafelOffen = false
    @State private var ladeposten: [Downloadposten] = []
    /// Was in der Tafel oben steht — „Staffel 5" oder der Name einer Folge.
    /// Er stand fest auf der Staffel, auch wenn nur eine Folge geladen wurde.
    @State private var ladetitel = ""
    /// Wo die Tafel aufgeht. Bei der Staffel unter dem Chip, bei einer Folge
    /// unter **dieser** Folge — sonst klappt sie irgendwo auf und man sucht,
    /// worauf sie sich bezieht.
    @State private var tafelOben: CGFloat?

    // MARK: Downloads

    /// Liegt schon jede Folge dieser Staffel auf der Platte? Dann faellt der
    /// Chip weg — ein Knopf, der nichts mehr tut, ist schlechter als keiner.
    private var staffelVollstaendig: Bool {
        !folgen.isEmpty && folgen.allSatisfy { model.downloads.posten(fuer: $0.id) != nil }
    }

    /// Ein `Downloadposten` aus einer Folge. **Dieselbe Quelle, die der
    /// Player naehme** — H2, es ist dieselbe Datei.
    private func posten(_ folge: Item) -> Downloadposten? {
        guard let konto = model.session?.userID else { return nil }
        let quelle = folge.mediaSources?.first
        return Downloadposten(
            id: folge.id, konto: konto, art: .folge, titel: folge.name,
            serie: serie.name, serienId: serie.id,
            staffel: folge.parentIndexNumber ?? gewaehlt?.indexNumber,
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

    /// **Die ganze Staffel, der Reihe nach.** H4 laesst immer nur einen
    /// laufen; was schon da ist, kommt nicht noch einmal in die Schlange.
    /// **Eine einzelne Folge laden** — wie auf dem iPhone seit `beb6a79`.
    ///
    /// Die Tafel sitzt an derselben Stelle wie bei einer Staffel: sie
    /// beantwortet dieselbe Frage, und ein zweiter Ort dafuer waere ein
    /// zweiter Ort zum Suchen.
    private func folgeGeklickt(_ folge: Item, unter kante: CGFloat) {
        ringGeklickt(model.downloads.posten(fuer: folge.id), model.downloads) {
            guard let p = posten(folge) else { return }
            ladeposten = [p]
            // **Der Titel ist die Folge, nicht die Staffel.** Er stand fest
            // auf `gewaehlt?.name` — in der Tafel las man dann „Staffel 5
            // laden", waehrend eine einzige Folge in der Schlange stand.
            ladetitel = folge.name
            tafelOben = kante
            withAnimation(Stil.zeitSprung) { staffeltafelOffen = true }
        }
    }

    private func staffelLaden() {
        let offene = folgen.filter { model.downloads.posten(fuer: $0.id) == nil }
        ladeposten = offene.compactMap { posten($0) }
        guard !ladeposten.isEmpty else { return }
        ladetitel = gewaehlt?.name ?? serie.name
        tafelOben = nil
        withAnimation(Stil.zeitSprung) { staffeltafelOffen.toggle() }
    }
    @State private var laedt = true
    /// Ob die Staffeln schon da sind. **Ohne das lief das Laden zweimal:**
    /// `.task(id: gewaehlt?.id)` feuert beim Erscheinen mit `nil` und holte
    /// alle Folgen der Serie; kurz darauf kam die Staffel an, der Lauf
    /// wiederholte sich, und die ganze Liste wurde ein zweites Mal mit
    /// anderem Inhalt gebaut — mitten im Hereinfahren.
    @State private var staffelnDa = false

    /// **Der Anfangsstand kommt aus dem Speicher, nicht aus dem Nichts.**
    ///
    /// Dieselbe Regel wie in `Netzbild` und auf tvOS: ein nachgereichter Wert
    /// kommt zu spät, der leere Durchgang hat dann schon stattgefunden — und
    /// genau der ist der Lader, der mitten in der Einfahrt von der Liste
    /// abgelöst wird.
    @MainActor init(model: AppModel, serie: Item,
                    startStaffelID: String? = nil, startStaffelNummer: Int? = nil,
                    zurueck: @escaping () -> Void) {
        self.model = model
        self.serie = serie
        self.startStaffelID = startStaffelID
        self.startStaffelNummer = startStaffelNummer
        self.zurueck = zurueck

        let gemerkt = Serienspeicher.geteilt.stand(serie.id, mit: model)
        let staffeln = gemerkt?.staffeln ?? []
        _staffeln = State(initialValue: staffeln)
        _staffelnDa = State(initialValue: !staffeln.isEmpty)

        // **Nur, was mitgekommen ist** (A10). Kommt ein Hinweis, gilt er
        // sofort — dann steht die richtige Staffel schon im ersten Bild.
        // Kommt keiner, bleibt die Wahl offen: `staffelnLaden` fragt dann,
        // in welcher Staffel man steckt, und die gilt. Hier `staffeln.first`
        // zu nehmen hiesse, Staffel 1 zu zeigen und sie einen Wimpernschlag
        // später gegen die laufende zu tauschen — genau das Zucken, das die
        // Regel vermeiden soll.
        let staffel = staffeln.first { $0.id == startStaffelID }
            ?? staffeln.first { $0.indexNumber != nil && $0.indexNumber == startStaffelNummer }
        _gewaehlt = State(initialValue: staffel)

        let folgen = staffel.flatMap { gemerkt?.folgen[$0.id] } ?? []
        _folgen = State(initialValue: folgen)
        _laedt = State(initialValue: folgen.isEmpty)
    }
    @State private var kopfstand = Kopfstand()
    @State private var farbe = Bildfarbe()

    enum Reiter: String, CaseIterable {
        case folgen, besetzung, aehnliches

        var beschriftung: LocalizedStringKey {
            switch self {
            case .folgen:     "Folgen"
            case .besetzung:  "Besetzung"
            case .aehnliches: "Ähnliches"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Heldenkopf(model: model, titel: serie, stand: kopfstand)
                    // **Der Kopf malt über das, was unter ihm steht.**
                    //
                    // Ohne das liegt das Mehr-Menü hinter Reiterreihe und
                    // Folgenliste: die kommen im Stapel nach dem Kopf, also
                    // malen sie später und damit darüber. Man sah beides
                    // ineinander.
                    .zIndex(1)

                Reiterreihe(auswahl: $reiter)
                    .padding(.top, 26)

                abschnitt
                    .padding(.horizontal, Stil.randAbstand)
                    .padding(.top, 20)
            }
            .padding(.bottom, 40)
            // **Die Ladetafel liegt im Inhalt, nicht auf der Seite.**
            //
            // Sie hing als Auflage ueber der ganzen Seite. Zwei Sachen waren
            // daran falsch: der Fang darunter deckte die Scrollflaeche zu,
            // also liess sich bei offener Tafel nicht mehr scrollen — und die
            // Tafel stand fest im Fenster, waehrend die Folge, zu der sie
            // gehoert, darunter wegwanderte.
            //
            // Im Inhalt loest sich beides von selbst: das Rad trifft die
            // Scrollflaeche, weil der Fang in ihr liegt, und die Tafel geht
            // mit der Zeile mit, weil sie an derselben Stelle des Inhalts
            // haengt. Ihr Platz ist dann ein Wert im Inhalt und keiner im
            // Fenster — deshalb sitzt der benannte Raum hier und nicht
            // aussen.
            .coordinateSpace(.named("serienseite"))
            .overlay(alignment: .topTrailing) {
                if staffeltafelOffen, !ladeposten.isEmpty {
                    ZStack(alignment: .topTrailing) {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(Stil.zeitSprung) { staffeltafelOffen = false }
                            }
                        Ladetafel(model: model, posten: ladeposten,
                                  titel: ladetitel,
                                  bilder: ladebilder,
                                  offen: $staffeltafelOffen)
                            // Unter dem Chip — oder unter der Folge, von der
                            // aus sie geoeffnet wurde.
                            .padding(.trailing, Stil.randAbstand)
                            .padding(.top, tafelOben ?? (Stil.heldHoehe + 92))
                    }
                    .transition(.opacity)
                }
            }
        }
        .scrollIndicators(.never)
        // **Die milchige Leiste am oberen Rand.** macOS 26 legt sie von sich
        // aus über jede Scrollfläche — sie war nie in unserem Code, und
        // deshalb habe ich zweimal an der falschen Stelle gesucht. Über dem
        // Bild verlor sie sich, links auf blankem Grund stand sie als Balken.
        //
        // E4 wieder: was das Rahmenwerk ungefragt dazustellt, gehört ebenso
        // abgestellt wie das, was man selbst hinschreibt.
        // Dieselbe Ansage ans Fenster wie die Filmseite. Fehlte sie hier,
        // wechselte die Fensterpräferenz beim Hin- und Herblättern zwischen
        // den beiden Seiten — und das rechnet AppKit jedes Mal nach.
        .toolbar(.hidden)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .ohneKanteneffekt()
        .background(alignment: .top) {
            LinearGradient(colors: [farbe.ton, Stil.grund],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Stil.heldHoehe + 260)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Stil.grund)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
            kopfstand.versatz = neu
        }
        .overlay(alignment: .top) {
            Detailkopf(titel: serie.name, stand: kopfstand, zurueck: zurueck)
        }
        .task { await farbe.laden(model.backdropURL(for: serie)) }
        .task { await staffelnLaden() }
        .task(id: gewaehlt?.id) {
            guard staffelnDa else { return }
            // **Und nicht, solange keine Staffel gewählt ist.** Seit A10
            // wählt der `init` ohne Hinweis keine mehr — kamen die Staffeln
            // dann aus dem Speicher, stand `staffelnDa` sofort auf wahr und
            // dieser Lauf holte mit `staffel: nil` **alle** Folgen der Serie.
            // Kurz darauf kam die Wahl, der Lauf wiederholte sich, und die
            // Liste wurde ein zweites Mal mit anderem Inhalt gebaut — mitten
            // im Hereinfahren. Genau das, wogegen `staffelnDa` einmal
            // eingeführt wurde; die Lücke habe ich mit A10 wieder aufgemacht.
            //
            // Hat die Serie gar keine Staffeln, ruft `staffelnLaden` das
            // Laden selbst — dann ist hier nichts zu tun.
            guard gewaehlt != nil else { return }
            await folgenLaden()
        }
    }

    // MARK: Abschnitte

    private var abschnitt: some View {
        // **Hier stand ein Riegel, und der war falsch.**
        //
        // Ich hatte den ganzen Abschnitt zurückgehalten, bis die Seite steht
        // — damit während der Fahrt nichts umgebaut wird. Nachgemessen fährt
        // die Serienseite aber genauso weich wie die Filmseite: 107 Bilder in
        // 457 ms gegen 110 in 460, grösster Zeitsprung 26 gegen 14 ms.
        //
        // Der Riegel hat also nichts repariert, sondern etwas kaputtgemacht:
        // die Seite kam **leer** herein, mit einem Lader statt Inhalt, und
        // sprang eine halbe Sekunde später auf einmal voll. Deshalb sah es
        // aus, als bewege sie sich kurz und sei dann schlagartig da. Die
        // Filmseite hatte den Riegel nie — darum war sie perfekt.
        //
        // Was bleibt: das Wechseln selbst darf nicht springen. Der Lader
        // blendet in die Liste über, und die Staffelpille kommt nicht
        // schlagartig dazu.
        // **Keine Anweisung auf Datenankunft.** Hier standen drei
        // `.animation`-Zeilen, die ich eingebaut hatte, damit das Nachladen
        // nicht springt. Sie haben es schlimmer gemacht: der Wechsel vom
        // 200 Punkt hohen Lader auf die Folgenliste ist ein Höhensprung von
        // rund tausend Punkt, und über 250 ms **animiert** zwingt er den
        // `LazyVStack`, seine Zeilen schrittweise während der Einfahrt zu
        // bauen — jede mit eigenem Bildabruf. Die iPhone-Fassung animiert
        // bei Datenankunft gar nichts; die Liste wächst einfach.
        abschnittsinhalt
    }

    @ViewBuilder
    private var abschnittsinhalt: some View {
        switch reiter {
        case .folgen:
            VStack(alignment: .leading, spacing: 0) {
                if staffeln.count > 1 || (model.downloadsAn && !folgen.isEmpty) {
                    HStack(alignment: .top, spacing: 12) {
                        if staffeln.count > 1 {
                            Staffelwahl(staffeln: staffeln, gewaehlt: $gewaehlt,
                                        offen: $staffelOffen)
                        }
                        Spacer(minLength: 0)
                        // **Neben der Staffelwahl**, dieselbe Höhe, dieselbe
                        // Form. Ist die Staffel schon vollständig da, steht
                        // dort nichts mehr statt eines Knopfs, der nichts tut.
                        if model.downloadsAn, !staffelVollstaendig, !folgen.isEmpty {
                            Chip(beschriftung: String(localized: "Staffel laden"),
                                 symbol: "arrow.down", aktiv: false) {
                                staffelLaden()
                            }
                        }
                    }
                    .padding(.bottom, 18)
                    .zIndex(10)
                }
                if laedt {
                    // Drei Zeilen in ihrer Form statt eines Rings.
                    VStack(spacing: 0) {
                        ForEach(0 ..< 3, id: \.self) { _ in
                            HStack(spacing: 16) {
                                Ladefeld().frame(width: 160, height: 90)
                                VStack(alignment: .leading, spacing: 8) {
                                    Ladefeld(ecke: 3).frame(width: 220, height: 14)
                                    Ladefeld(ecke: 3).frame(width: 90, height: 11)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 10)
                        }
                    }
                    .transition(.opacity)
                } else if folgen.isEmpty {
                    Leerzustand(symbol: "tray", titel: "Keine Folgen")
                        .frame(height: 200)
                } else {
                    // **`VStack`, nicht `LazyVStack` — zurückgenommen.**
                    //
                    // Ich hatte auf faul umgestellt, weil ein `VStack` alle
                    // Zeilen auf einmal baut und das die Einfahrt der Seite
                    // störte. Der Grund ist inzwischen weg: die Bilder werden
                    // abseits des Hauptlaufs entschlüsselt, und die drei
                    // `.animation`-Zeilen, die den Höhensprung mitbewegten,
                    // sind raus.
                    //
                    // Geblieben war dafür der Preis: eine faule Liste kennt
                    // die Höhe dessen nicht, was sie nicht gebaut hat. Beim
                    // Hochziehen über zweiundzwanzig Folgen springt die
                    // Fläche deshalb ans Ende, statt den Weg zu nehmen — und
                    // eine feste Zeilenhöhe hilft nicht, weil die Liste sie
                    // erst erfährt, wenn sie die Zeile baut.
                    //
                    // Zweiundzwanzig Zeilen sind kein Aufwand. Der genaue
                    // Inhalt ist hier mehr wert als das Sparen.
                    //
                    // **Bis an den Fensterrand.** Der Abschnitt setzt seinen
                    // seitlichen Rand aussen; damit endete auch die graue
                    // Fläche beim Überfahren dort. Eine Zeile in einer Liste
                    // leuchtet aber über die **ganze** Breite — den Rand
                    // trägt deshalb die Zeile selbst, siehe `Folgenzeile`.
                    VStack(spacing: 0) {
                        ForEach(folgen, id: \.id) { folge in
                            Folgenzeile(model: model, folge: folge) { kante in
                                folgeGeklickt(folge, unter: kante)
                            }
                            if folge.id != folgen.last?.id {
                                Rectangle().fill(Stil.linie).frame(height: 1)
                            }
                        }
                    }
                    .transition(.opacity)
                    .padding(.horizontal, -Stil.randAbstand)
                }
            }

        case .besetzung:
            Besetzungsreihe(model: model, leute: serie.darsteller)

        case .aehnliches:
            if aehnliche.isEmpty {
                Leerzustand(symbol: "tray", titel: "Nichts Ähnliches gefunden")
                    .frame(height: 200)
                    .task { aehnliche = await model.aehnliche(serie) }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Stil.kachelBreite,
                                                       maximum: Stil.kachelBreite),
                                             spacing: Stil.kachelAbstand,
                                             alignment: .topLeading)],
                          alignment: .leading, spacing: 20) {
                    ForEach(aehnliche, id: \.id) { eintrag in
                        Button { navigator.oeffne(.titel(eintrag), in: bereich) } label: {
                            Posterkachel(titel: eintrag.name,
                                         zweitzeile: eintrag.productionYear.map { "\($0)" },
                                         bild: model.imageURL(for: eintrag, hochkant: true),
                                         zeichen: "tv")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Laden

    private func staffelnLaden() async {
        // **Auch wenn die Staffeln schon dastehen.** Sie koennen aus dem
        // Speicher kommen, die Wahl aber offen sein — ohne Hinweis trifft der
        // `init` keine mehr (A10). Dann wird hier nur noch gewaehlt.
        if staffelnDa, !staffeln.isEmpty {
            if gewaehlt == nil { gewaehlt = await gewaehlteStaffel(aus: staffeln) }
            return
        }
        guard staffeln.isEmpty else { return }

        // **Nebeneinander, weil sie einander nicht brauchen.** Die Liste
        // braucht die Staffeln, die Wahl den Stand — und den nur, wenn kein
        // Hinweis mitkam. Hintereinander lägen die zwei Fristen aufeinander;
        // dieselbe Rechnung wie beim Folgenwechsel im Player.
        async let stand: Item? = ohneHinweis ? await model.standInSerie(serie) : nil
        let neue = await model.staffeln(serie)
        // Erst die Wahl, dann die Liste, dann das Zeichen — alles in einem
        // Zug, damit `.task(id:)` nur einen Wechsel sieht.
        //
        gewaehlt = waehle(aus: neue, stand: await stand)
        staffeln = neue
        staffelnDa = true
        Serienspeicher.geteilt.merken(serie.id) { $0.staffeln = neue }
        if neue.isEmpty { await folgenLaden() }
    }

    /// Welche Staffel dasteht — **A10**, und die Kette ist wörtlich die der
    /// geteilten Fassung.
    ///
    /// Erst der Hinweis, mit dem man gekommen ist: Kennung, dann **Nummer**.
    /// Die Nummer ist kein Gurt zu viel — am Gerät gemessen liefert der
    /// Server an einer Folge nicht immer eine `SeasonId`, und dann greift der
    /// Kennungsvergleich ins Leere.
    ///
    /// Kam kein Hinweis — aus der Bibliothek, aus der Suche —, gilt die
    /// **laufende** Staffel, nicht Staffel 1. Dafür muss gefragt werden, wo
    /// man in der Serie steht; deshalb wird der Stand nur dann geholt.
    private var ohneHinweis: Bool { startStaffelID == nil && startStaffelNummer == nil }

    /// Reine Rechnung, ohne Abruf — damit der Aufrufer entscheidet, wann er
    /// den Stand holt, und ihn nebenher holen kann.
    private func waehle(aus liste: [Item], stand: Item?) -> Item? {
        liste.first { $0.id == startStaffelID }
            ?? liste.first { $0.indexNumber != nil && $0.indexNumber == startStaffelNummer }
            ?? liste.first { $0.id == stand?.seasonId }
            ?? liste.first { $0.indexNumber != nil && $0.indexNumber == stand?.parentIndexNumber }
            ?? liste.first
    }

    /// Für den Fall, dass die Staffeln schon aus dem Speicher kamen: dann
    /// gibt es nichts zu parallelisieren, es fehlt nur noch die Wahl.
    private func gewaehlteStaffel(aus liste: [Item]) async -> Item? {
        waehle(aus: liste, stand: ohneHinweis ? await model.standInSerie(serie) : nil)
    }

    private func folgenLaden() async {
        // Steht schon etwas aus dem Speicher, wird nicht auf leer
        // zurückgestellt — sonst blitzt der Lader trotzdem auf.
        laedt = folgen.isEmpty
        defer { laedt = false }
        let neue = await model.folgen(serie: serie.id, staffel: gewaehlt?.id)
        folgen = neue
        if let staffel = gewaehlt?.id {
            Serienspeicher.geteilt.merken(serie.id) { $0.folgen[staffel] = neue }
        }
    }
}

// MARK: - Reiter

/// Folgen · Besetzung · Ähnliches. Aktiv ist semibold mit einem 2 Punkt
/// starken Akzentstrich darunter, die Haarlinie läuft über die volle Breite —
/// dieselben Werte wie auf dem iPhone.
struct Reiterreihe: View {
    @Binding var auswahl: SerienView.Reiter

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 26) {
                ForEach(SerienView.Reiter.allCases, id: \.self) { fall in
                    Reiterknopf(beschriftung: fall.beschriftung,
                                aktiv: auswahl == fall) { auswahl = fall }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Stil.randAbstand)

            Rectangle().fill(Stil.linie).frame(height: 1)
        }
    }
}

struct Reiterknopf: View {
    let beschriftung: LocalizedStringKey
    let aktiv: Bool
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            VStack(spacing: 8) {
                Text(beschriftung)
                    .font(.system(size: 15, weight: aktiv ? .semibold : .regular))
                    .foregroundStyle(aktiv ? Stil.schrift
                                     : (schwebt ? Stil.schrift : Stil.schriftLeise))
                Rectangle()
                    .fill(aktiv ? Stil.akzent : .clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { schwebt = $0 }
        .animation(Stil.zeitUmschalten, value: aktiv)
        .animation(Stil.zeitSchweben, value: schwebt)
    }
}

// MARK: - Staffelwahl

/// Die Staffelpille. Klappt die Liste **an Ort und Stelle** auf — kein `Menu`,
/// kein Blatt. Ein Menu wäre hier das Naheliegende und genau deshalb falsch:
/// es bringt Systemmaße, Systemecken und ein Systemmaterial mit.
struct Staffelwahl: View {
    let staffeln: [Item]
    @Binding var gewaehlt: Item?
    @Binding var offen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Chip(beschriftung: gewaehlt?.name ?? String(localized: "Staffel"),
                 symbol: offen ? "chevron.up" : "chevron.down",
                 aktiv: false) {
                withAnimation(Stil.zeitSprung) { offen.toggle() }
            }

            if offen {
                VStack(spacing: 0) {
                    ForEach(staffeln, id: \.id) { staffel in
                        Staffelzeile(staffel: staffel,
                                     gewaehlt: staffel.id == gewaehlt?.id) {
                            gewaehlt = staffel
                            withAnimation(Stil.zeitSprung) { offen = false }
                        }
                    }
                }
                .padding(.vertical, 4)
                .frame(width: 220, alignment: .leading)
                .background(Stil.erhoeht, in: RoundedRectangle(cornerRadius: Stil.eckeFeld))
                .overlay(RoundedRectangle(cornerRadius: Stil.eckeFeld)
                    .strokeBorder(Stil.rand, lineWidth: 1))
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct Staffelzeile: View {
    let staffel: Item
    let gewaehlt: Bool
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            HStack(spacing: 8) {
                Text(verbatim: staffel.name)
                    .font(Stil.koerper)
                    .foregroundStyle(gewaehlt ? Stil.akzent : Stil.schrift)
                Spacer(minLength: 0)
                if gewaehlt {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Stil.akzent)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Stil.zeileHoehe)
            .background(schwebt ? Stil.schrift.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { schwebt = $0 }
    }
}

// MARK: - Folgenzeile

/// Eine Folge.
///
/// Auf dem iPhone liegen Merkliste, Gesehen und Abspielen unter einer
/// Wischgeste. Mit einem Zeiger gibt es kein Wischen — dieselben Handlungen
/// erscheinen deshalb beim Schweben. Der Grund ist die Eingabeart, nicht der
/// Geschmack.
struct Folgenzeile: View {
    let model: AppModel
    let folge: Item
    /// Was ein Klick auf den Ring tut — mit der Unterkante der Zeile, damit
    /// die Tafel darunter aufgeht und nicht irgendwo.
    var ringtipp: ((CGFloat) -> Void)?

    @State private var schwebt = false
    @State private var gesehen = false
    /// Wo die Zeile endet, im Raum der Seite — die Tafel geht darunter auf.
    @State private var unterkante: CGFloat = 0
    @Environment(Abspielsteuerung.self) private var steuerung

    /// 16 : 9 — dasselbe Verhältnis wie die 116 × 65 des iPhones.
    private let bildBreite: CGFloat = 160
    private let bildHoehe: CGFloat = 90

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                // **Das Bild der Folge, nicht das der Serie.**
                //
                // `querbildURL` nimmt absichtlich `item.seriesId ?? item.id`
                // — für die Kacheln unter „Weiterschauen" ist das richtig,
                // dort will man das Serienbild. In einer Folgenliste liefert
                // es für jede Zeile **dasselbe** Bild. Die iPhone-Fassung
                // nimmt hier `imageURL(for: folge, maxHeight: 220)`, also das
                // eigene Vorschaubild der Folge.
                // **Das Vorschaubild traegt den Sehstand** — wie auf dem
                // iPhone seit `beb6a79`. Es zeigte schon den
                // Fortschrittsbalken, also „wie weit bin ich"; der Haken ist
                // dessen Ende. Damit steht der Sehstand an einer Stelle statt
                // an zweien, und die Spalte rechts gehoert dem Download.
                Bildflaeche(bild: model.imageURL(for: folge, maxHeight: 220),
                            breite: bildBreite, hoehe: bildHoehe,
                            // Ein voller Balken **und** ein Haken waeren
                            // dieselbe Auskunft zweimal.
                            fortschritt: gesehen ? nil : fortschritt,
                            zeichen: "tv")
                    .opacity(gesehen ? 0.45 : 1)
                    .overlay(alignment: .topTrailing) {
                        if gesehen {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(Stil.schrift)
                                .frame(width: 20, height: 20)
                                .background(Stil.grund.opacity(0.72), in: Circle())
                                .padding(6)
                        }
                    }
                    .animation(Stil.einblenden, value: gesehen)
                if schwebt {
                    Circle()
                        .fill(.black.opacity(0.45))
                        .frame(width: 38, height: 38)
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(Stil.schrift)
                        }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(verbatim: kopfzeile)
                        .font(.system(size: 14, weight: .medium))
                        // Gesehenes tritt zurueck, es verschwindet nicht.
                        .foregroundStyle(gesehen ? Stil.schriftLeise : Stil.schrift)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if let sekunden = folge.runtimeSeconds {
                        Text(verbatim: laufzeit(sekunden))
                            .font(Stil.zweitzeile)
                            .foregroundStyle(Stil.schriftSehrLeise)
                    }
                }
                if let text = folge.overview, !text.isEmpty {
                    Text(verbatim: text)
                        .font(Stil.zweitzeile)
                        .foregroundStyle(Stil.schriftLeise)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }

            // **Der Haken steht immer, wenn die Folge gesehen ist** — auf
            // dem iPhone genauso. Vorher erschien er erst beim Schweben, und
            // damit war beim Überfliegen der Liste nicht zu erkennen, wie
            // weit man ist. Zum *Ändern* braucht es den Zeiger, zum *Sehen*
            // nicht.
            // **Rechts steht der Zustand des Downloads, nicht der des
            // Sehens.** Der Haken als *Auskunft* ist auf das Bild gezogen;
            // was hier bleibt, ist der Haken als *Handlung* — und der
            // erscheint wie eh nur unter dem Zeiger. Das ist der eine
            // erlaubte Unterschied zum iPhone: dort ist die Handlung ein
            // Wisch, hier das Schweben (VERHALTEN F, Eingabeart).
            HStack(spacing: 6) {
                if schwebt {
                    Aktionsknopf(symbol: gesehen ? "checkmark.circle.fill" : "checkmark.circle",
                                 titel: "Gesehen", an: gesehen) {
                        gesehen.toggle()
                        Task { _ = await model.setzeGesehen(folge, an: gesehen) }
                    }
                }
                if let ringtipp, model.downloadsAn {
                    Downloadring(posten: model.downloads.posten(fuer: folge.id),
                                 mass: 24) { ringtipp(unterkante) }
                }
            }
            .frame(width: breiteRechts, alignment: .trailing)

        }
        .padding(.vertical, 12)
        // Der Rand des Abschnitts, hier innen — damit die Fläche beim
        // Überfahren bis an den Fensterrand reicht, der Inhalt aber auf
        // derselben Linie steht wie überall sonst. Die 6 Punkt Ausgleich
        // sind der Innenabstand der Zeile selbst.
        .padding(.horizontal, Stil.randAbstand - 6)
        // **Feste Zeilenhöhe.** Ein `LazyVStack` baut nur, was zu sehen ist,
        // und schätzt den Rest. Schätzt er falsch, springt die Scrollfläche
        // beim schnellen Hochziehen — je mehr Folgen, desto weiter. Mit einer
        // festen Höhe gibt es nichts zu schätzen. 90 für das Bild, zweimal 12
        // Rand; Titel und Text bleiben mit ihren Zeilengrenzen darunter.
        .frame(height: bildHoehe + 24)
        .background(schwebt ? Stil.schrift.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) {
            $0.frame(in: .named("serienseite")).maxY
        } action: { unterkante = $0 }
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        // Eine Folge startet an ihrer eigenen Position — nicht an der der
        // Serie. Wörtlich aus der iPhone-Fassung.
        .onTapGesture { steuerung.starte(folge) }
        .task { gesehen = folge.istGesehen }
    }

    private var kopfzeile: String {
        if let nummer = folge.indexNumber {
            return "\(nummer). \(folge.name)"
        }
        return folge.name
    }


    /// Aus `Item.gesehenerAnteil` — siehe die Begründung in `HomeView`.
    private var fortschritt: Double? { folge.gesehenerAnteil }

    /// Platz fuer beide Zeichen, wenn es beide gibt — sonst bleibt die Zeile
    /// beim Ueberfahren nicht ruhig, sondern rueckt.
    private var breiteRechts: CGFloat {
        (ringtipp != nil && model.downloadsAn) ? Stil.knopfRund * 2 + 6
                                               : Stil.knopfRund
    }
}
