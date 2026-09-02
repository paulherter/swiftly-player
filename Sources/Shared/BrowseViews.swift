import JellyfinKit
import SwiftUI

// MARK: - Inhalt einer Bibliothek

struct ItemListView: View {
    @Environment(\.breit) private var breit
    let model: AppModel
    let library: Item

    @State private var items: [Item] = []
    @State private var laedt = true

    private let spalten = [GridItem(.adaptive(minimum: Stil.kachelBreite,
                                              maximum: Stil.kachelBreite + 30),
                                    spacing: Stil.kachelAbstand)]

    @Environment(\.dismiss) private var zurueck

    var body: some View {
        ZStack {
            Stil.grund.ignoresSafeArea()

            VStack(spacing: 0) {
                Unterseitenkopf(titel: library.name) { zurueck() }

                ScrollView {
                    LazyVGrid(columns: spalten, alignment: .leading, spacing: 20) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            PosterTile(model: model, item: item)
                        }
                        .buttonStyle(.plain)
                    }
                    }
                    .padding(.horizontal, Stil.rand(breit: breit))
                    .padding(.bottom, Stil.randAbstand)
                }
                .scrollIndicators(.hidden)
            }

            if laedt {
                Lader()
            } else if items.isEmpty {
                ContentUnavailableView("Nichts gefunden", systemImage: "tray")
            }
        }
#if os(iOS)
        .background(WischZurueck())
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task {
            items = await model.items(in: library.id)?.titel ?? []
            laedt = false
        }
    }
}

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

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Feste Breite: feste Höhe. Füllt die Kachel ihre Spalte, folgt
            // die Höhe der tatsächlichen Breite — 2 : 3, wie jedes Plakat.
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

            VStack(alignment: .leading, spacing: 1) {
                Text(titelzeile)
                    .font(Stil.kachel)
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let unterzeile {
                    Text(unterzeile)
                        .font(Stil.klein)
                        .foregroundStyle(Stil.schriftLeise)
                        // Die volle Trefferauskunft braucht auf 138 Punkt
                        // zwei Zeilen. In der Bibliothek steht dort nur ein
                        // Jahr, da bleibt es bei einer.
                        .lineLimit(auskunft == nil ? 1 : 2)
                }
            }
        }
        // Im Raster richtet SwiftUI die Zellen einer Zeile mittig aus. Bei
        // zweizeiligen Titeln rutschten die kürzeren Kacheln dadurch nach
        // unten und die Poster lagen nicht mehr auf einer Linie.
        .frame(maxHeight: .infinity, alignment: .top)
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
    @State private var versatz: CGFloat = 0

    @State private var plan: PlaybackPlan?
    @State private var pruefe = true
    @State private var abspielen: Abspielwunsch?
    @State private var mehrOffen = false
    @State private var meldung: String?
    @State private var frisch: Item?
    @State private var aehnliche: [Item] = []
    @State private var extras: [Item] = []
    @State private var gemerkt = false
    @State private var gesehen = false

    private var aktuell: Item { frisch ?? item }

    private var fortsetzenAb: Double? { aktuell.fortsetzenAb }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if breit {
                        Heldkopf(bild: model.backdropURL(for: aktuell),
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
                    }

                    besetzung
                    extrasreihe
                    aehnlichesreihe
                    // Die Dateiangaben ganz nach unten: sie beantworten eine
                    // Frage, die man erst später stellt.
                    dateiauszug
                }
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(.named("blatt"))
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
                versatz = neu
            }

            if mehrOffen, !breit {
                Handlungsblatt(offen: $mehrOffen, titel: aktuell.name,
                               handlungen: mehrHandlungen)
                    .zIndex(20)
            }
            if let meldung {
                Hinweisstreifen(text: meldung) { self.meldung = nil }
                    .zIndex(21)
            }

            Detailkopf(titel: aktuell.name, versatz: versatz) { zurueck() }
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
        .fullScreenCover(item: $abspielen) { wunsch in
            PlayerScreen(model: model, item: wunsch.item,
                         plan: wunsch.plan, startAt: wunsch.startAt)
        }
        #endif
        .task {
            async let frischerTitel = model.item(id: item.id)
            async let planung = model.plan(for: item.id)
            async let aehnlich = model.aehnliche(item)
            async let extra = model.extras(item)
            frisch = await frischerTitel
            plan = await planung
            aehnliche = await aehnlich
            extras = await extra
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
        Heldbild(url: model.backdropURL(for: aktuell))
            .overlay(alignment: .bottom) { Heldauslauf() }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(aktuell.name)
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

    /// Jahr, Laufzeit und Genre — im Heldenbild, nicht mehr in einer eigenen
    /// Zeile darunter.
    private var nebenzeile: String { aktuell.nebenzeile }

    private var belegzeile: some View {
        Belegzeile(direktplay: plan?.isLossless ?? false,
                   hinweis: plan.map { $0.isLossless ? nil : $0.method.rawValue } ?? nil,
                   bewertung: aktuell.communityRating,
                   freigabe: aktuell.officialRating)
    }

    @ViewBuilder
    private var hauptknopf: some View {
        // Schmal untereinander über die volle Breite, breit nebeneinander und
        // nur so breit wie ihre Beschriftung.
        let stapel = weit ? AnyLayout(HStackLayout(spacing: 12))
                          : AnyLayout(VStackLayout(spacing: 10))
        stapel {
            if let ab = fortsetzenAb {
                Button { starte(ab: ab) } label: {
                    Label("Fortsetzen ab \(zeitText(ab))", systemImage: "play.fill")
                }
                .buttonStyle(HauptknopfStil(dehnt: !breit))
                .disabled(plan == nil)

                Button { starte(ab: 0) } label: {
                    Label("Von vorn", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(NebenknopfStil(dehnt: !breit))
                .disabled(plan == nil)
            } else {
                Button { starte(ab: 0) } label: {
                    Label("Abspielen", systemImage: "play.fill")
                }
                .buttonStyle(HauptknopfStil(dehnt: !breit))
                .disabled(plan == nil)
            }
        }
    }

    private var aktionsreihe: some View {
        // Schmal verteilen die Spacer die vier Knöpfe über die Zeile; breit
        // stehen sie neben dem Abspielknopf und sollen zusammenbleiben.
        HStack(spacing: weit ? 4 : 0) {
            Aktionsknopf(symbol: gemerkt ? "bookmark.fill" : "bookmark",
                         titel: "Merkliste", aktiv: gemerkt) {
                gemerkt.toggle()
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
            if !weit { Spacer(minLength: 0) }
            Aktionsknopf(symbol: "film", titel: "Trailer") { trailerStarten() }
            if !weit { Spacer(minLength: 0) }
            Aktionsknopf(symbol: gesehen ? "checkmark.circle.fill" : "checkmark.circle",
                         titel: "Gesehen", aktiv: gesehen) {
                gesehen.toggle()
                Task {
                    if let grund = await model.setzeGesehen(aktuell, an: gesehen) {
                        gesehen.toggle()
                        meldung = grund
                    }
                }
            }
            if !weit { Spacer(minLength: 0) }
            Aktionsknopf(symbol: "ellipsis", titel: "Mehr") { withAnimation(.snappy(duration: 0.22)) { mehrOffen = true } }
                .alsHandlungsanker()
        }
        .padding(.horizontal, weit ? 0 : 6)
    }

    @ViewBuilder
    private var beschreibung: some View {
        if let text = aktuell.overview {
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
                    .font(.system(size: 13))
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
                               wert: paar.element.kurz, hervorgehoben: true)
                    Rectangle().fill(Stil.linie).frame(height: 1)
                }
                let untertitel = (quelle.mediaStreams ?? []).filter { $0.type == "Subtitle" }
                Dateizeile(bezeichnung: "Untertitel",
                           wert: Dateiangaben.untertitel(untertitel),
                           hervorgehoben: !untertitel.isEmpty)
                Rectangle().fill(Stil.linie).frame(height: 1)
            }
            .padding(.horizontal, Stil.rand(breit: breit))
        }
    }

    @ViewBuilder
    private var besetzung: some View {
        let leute = aktuell.darsteller
        if !leute.isEmpty {
            Abschnitt(titel: "Besetzung", pfeil: true) {
                HStack(spacing: 14) {
                    ForEach(leute.prefix(12)) { person in
                        Besetzungskachel(bild: model.personBild(person),
                                         name: person.name, rolle: person.role)
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
                            if let s = extra.runtimeSeconds {
                                Text(laufzeit(s)).font(Stil.klein).foregroundStyle(Stil.schriftLeise)
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
        if !aehnliche.isEmpty {
            Abschnitt(titel: "Ähnliche Titel") {
                HStack(spacing: Stil.kachelAbstand) {
                    ForEach(aehnliche) { titel in
                        NavigationLink(value: titel) {
                            PosterTile(model: model, item: titel)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Stil.rand(breit: breit))
            }
        }
    }

    private func starte(ab: Double) {
        guard let plan else { return }
        abspielen = Abspielwunsch(item: aktuell, plan: plan, startAt: ab)
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
                Text(titel).font(Stil.reihe).foregroundStyle(Stil.schrift)
                if pfeil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Stil.schriftSehrLeise)
                }
            }
            .padding(.horizontal, Stil.rand(breit: breit))

            ScrollView(.horizontal, showsIndicators: false) { inhalt() }
        }
        .padding(.top, 26)
    }
}

/// Auslieferungsart als Haken oder Warnung — steht in der Kopfzeile.
struct Wiedergabebeleg: View {
    let plan: PlaybackPlan
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: plan.isLossless ? "checkmark" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
            Text(plan.method.rawValue)
        }
        .foregroundStyle(plan.isLossless ? Stil.akzent : Stil.warnung)
    }
}

/// Trennpunkt zwischen Metadaten — steht nur zwischen vorhandenen Angaben.
struct Trennpunkt: View {
    var body: some View { Text("·").opacity(0.45) }
}

extension ItemDetailView {

    /// Erst der Trailer vom Server, dann der verlinkte.
    ///
    /// Liegt er als Datei vor, läuft er im eigenen Player — mit Direct Play
    /// wie alles andere. Sonst bleibt nur die verlinkte Adresse, und die führt
    /// bei Jellyfin fast immer zu YouTube; die kann nur der Browser öffnen.
    func trailerStarten() {
        Task {
            if let film = await model.trailer(zu: aktuell),
               let plan = await model.plan(for: film.id) {
                abspielen = Abspielwunsch(item: film, plan: plan, startAt: 0)
                return
            }
            #if os(iOS)
            if let adresse = aktuell.remoteTrailers?.compactMap(\.url).first,
               let ziel = URL(string: adresse) {
                await UIApplication.shared.open(ziel)
                return
            }
            #endif
            meldung = String(localized: "Für diesen Titel liegt kein Trailer vor.")
        }
    }

    var mehrHandlungen: [Titelhandlung] {
        Titelhandlungen.fuerFilm(aktuell, plan: plan, model: model,
                                 starten: { starte(ab: $0) },
                                 melden: { meldung = $0 },
                                 auffrischen: { await auffrischen() })
    }
}
