import JellyfinKit
import SwiftUI

// MARK: - Sammlungen

/// Eine Sammlung, geöffnet aus einem Bereich — `art` sagt, ob ihre Filme
/// oder ihre Serien gemeint sind. `nil`: alles, was in ihr steht.
struct SammlungRoute: Hashable {
    let sammlung: Item
    let art: String?
}

/// **Die Sammlungsseite ist eine Bibliotheksseite.**
///
/// Kein Heldbild, keine eigene Bauart: Pfeil, Name, Filter und Sortierung,
/// Raster — wie `GenreView` als Unterseite und wie `BibliothekView` in der
/// Steuerzeile. Sortiert ist voreingestellt nach Jahr, und zwar aufsteigend
/// (``Regalquelle/richtung(_:)``), damit eine Reihe in ihrer Folge steht.
///
/// Sortierung und Filter werden **nicht** gemerkt: eine Sammlung ist kein
/// Ort, an den man zurückkehrt, sondern ein Blick in eine Reihe. Wer sie
/// wieder öffnet, will sie wieder in ihrer Folge sehen.
struct SammlungView: View {
    let model: AppModel
    let sammlung: Item
    let art: String?

    @Environment(\.dismiss) private var zurueck
    @Environment(\.breit) private var breit
    @State private var stand: Bibliotheksmodell
    @State private var versatz: CGFloat = 0
    @State private var filterlisteOffen = false
    @State private var sortierlisteOffen = false

    init(model: AppModel, sammlung: Item, art: String?) {
        self.model = model
        self.sammlung = sammlung
        self.art = art
        let stand = Bibliotheksmodell()
        stand.sortierung = .erscheinung
        _stand = State(initialValue: stand)
    }

    private var quelle: Regalquelle {
        Regalquelle(eltern: sammlung.id, art: art, sammlung: true)
    }

    /// Bei Serien derselbe Satz wie auf der Serienbibliothek.
    private var filter: [Bibliotheksfilter] {
        art == "tvshows" ? [.alle, .angefangen, .merkliste] : Bibliotheksfilter.allCases
    }

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()
            GeometryReader { rahmen in
                raster(spalten: Stil.spalten(nutzbar: rahmen.size.width - 2 * Stil.rand(breit: breit),
                                             breit: breit))
            }
            if stand.gestoert {
                Leerzustand(
                    symbol: "externaldrive.badge.xmark",
                    kopfzeile: "Server ist abgetaucht",
                    text: "\(model.serverAdresse ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?",
                    hauptknopf: ("Erneut versuchen", { Task { await stand.laden(model, aus: quelle) } }))
            } else if stand.items.isEmpty, !stand.laedt {
                Leerzustand(
                    symbol: stand.filter == .alle ? "tray" : "line.3.horizontal.decrease",
                    kopfzeile: stand.filter == .alle ? "Hier ist noch nichts" : "Nichts gefunden",
                    text: stand.filter == .alle
                        ? "Sobald in dieser Sammlung etwas liegt, taucht es hier auf."
                        : "Unter \u{201E}\(stand.filter.beschriftung)\u{201C} liegt gerade nichts. Nimm einen anderen Filter.",
                    stillerKnopf: stand.filter == .alle
                        ? ("Aktualisieren", { Task { await stand.laden(model, aus: quelle) } })
                        : ("Filter zurücksetzen", { stand.filter = .alle }))
            }
        }
        .regalblaetter(stand: stand, filter: filter,
                       filterOffen: $filterlisteOffen, sortierungOffen: $sortierlisteOffen)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(WischZurueck())
        #endif
        .task(id: "\(stand.kennung)|\(model.kontowechsel)") { await stand.laden(model, aus: quelle) }
    }

    private var kopf: some View {
        Unschaerfekopf(versatz: versatz) {
            VStack(alignment: .leading, spacing: 0) {
                Unterseitenkopf(titel: sammlung.name, zurueck: { zurueck() }, unten: 0) {
                    if breit, stand.gesamt > 0 { Zaehlmarke(anzahl: stand.gesamt) }
                }
                .padding(.horizontal, -Stil.rand(breit: breit))
                Regalsteuerung(stand: stand, filter: filter,
                               filterOffen: $filterlisteOffen,
                               sortierungOffen: $sortierlisteOffen,
                               versatz: versatz)
            }
        }
    }

    private func raster(spalten: Int) -> some View {
        ScrollView {
            if stand.items.isEmpty, stand.laedt {
                Rasterplatzhalter(spalten: spalten)
                    .padding(.horizontal, Stil.rand(breit: breit))
                    .padding(.top, 8)
                    .transition(.opacity)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Stil.kachelAbstand),
                                     count: spalten),
                      alignment: .leading, spacing: 20) {
                ForEach(stand.items) { item in
                    NavigationLink(value: item) {
                        PosterTile(model: model, item: item, breite: nil)
                    }
                    .buttonStyle(Stil.Druckknopf())
                    .onAppear {
                        guard stand.loestNachladenAus(item.id, spalten: spalten) else { return }
                        Task { await stand.nachladen(model, aus: quelle) }
                    }
                }
            }
            .padding(.horizontal, Stil.rand(breit: breit))
            .padding(.top, 8)
            .padding(.bottom, 40)
            .opacity(stand.items.isEmpty ? 0 : 1)
        }
        .scrollIndicators(.hidden)
        .animation(Stil.einblenden, value: stand.items.isEmpty)
        // Dieselbe Messung wie in `BibliothekView` — dort steht, warum die
        // Summe aus Rand und Versatz der Scrollweg ist und warum der eine
        // Zwischenstand mit Versatz null übergangen wird.
        .onScrollGeometryChange(for: CGPoint.self) {
            CGPoint(x: $0.contentInsets.top, y: $0.contentOffset.y)
        } action: { _, neu in
            guard !(abs(neu.y) < 1 && neu.x > 1) else { return }
            versatz = neu.y + neu.x
        }
        .safeAreaInset(edge: .top, spacing: 0) { kopf }
    }
}

// MARK: - Ersatzplakat

/// **Ersatzplakat einer Sammlung ohne eigenes Bild** — ein Mosaik aus den
/// Plakaten ihrer ersten Titel, im selben 2:3-Format und mit denselben
/// Ecken wie jedes andere Plakat. Ohne eigenes Bild stand hier bisher nur
/// das Filmsymbol; bei einer Sammlung mit mehreren Filmen eine Auskunft, die
/// nichts sagt, obwohl die Plakate längst da sind.
///
/// **Eine Reihe je nach Menge.** Ein einzelner Titel füllt das ganze Feld,
/// zwei stehen nebeneinander, ab drei wird daraus ein 2×2-Mosaik — die
/// zweite Reihe nimmt einfach, was von den ersten vier übrig bleibt.
///
/// Die Plakate kommen über denselben Lader wie jedes andere
/// (``Bild``/``Bildspeicher``), nur klein: eine Mosaikkachel braucht kein
/// Bild in Kachelgröße.
struct Sammlungsmosaik: View {
    let model: AppModel
    let sammlung: Sammlung
    let art: String
    /// `nil`: füllt die Spalte, wie ``PosterTile`` ohne feste Breite.
    var breite: CGFloat? = nil

    @State private var titel: [Item] = []

    private var reihen: [[Item]] {
        titel.isEmpty ? [] : (titel.count > 2 ? [Array(titel.prefix(2)), Array(titel[2...].prefix(2))]
                                               : [titel])
    }

    var body: some View {
        Group {
            if let breite {
                inhalt(breite: breite, hoehe: breite * 1.5)
            } else {
                GeometryReader { rahmen in
                    inhalt(breite: rahmen.size.width, hoehe: rahmen.size.height)
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Stil.eckeKachel, style: .continuous))
        .task(id: sammlung.id) {
            let gefunden = await model.sammlungstitel(sammlung, art: art)
            withAnimation(Stil.einblenden) { titel = Array((gefunden ?? []).prefix(4)) }
        }
    }

    private func inhalt(breite: CGFloat, hoehe: CGFloat) -> some View {
        let platz = reihen.isEmpty ? [[]] : reihen
        let reihenHoehe = (hoehe - CGFloat(platz.count - 1) * 2) / CGFloat(platz.count)
        return VStack(spacing: 2) {
            ForEach(Array(platz.enumerated()), id: \.offset) { _, stapel in
                zeile(stapel, breite: breite, hoehe: reihenHoehe)
            }
        }
    }

    private func zeile(_ stapel: [Item], breite: CGFloat, hoehe: CGFloat) -> some View {
        let feldbreite = stapel.isEmpty ? breite : (breite - CGFloat(stapel.count - 1) * 2) / CGFloat(stapel.count)
        return HStack(spacing: 2) {
            if stapel.isEmpty {
                feld(url: nil, breite: feldbreite, hoehe: hoehe)
            } else {
                ForEach(stapel) { eintrag in
                    feld(url: model.imageURL(for: eintrag, maxHeight: 260, hochkant: true),
                        breite: feldbreite, hoehe: hoehe)
                }
            }
        }
    }

    private func feld(url: URL?, breite: CGFloat, hoehe: CGFloat) -> some View {
        Bild(url: url, breite: breite, hoehe: hoehe, ecke: 0) {
            Stil.flaeche.overlay {
                Image(systemName: "film").foregroundStyle(Stil.schriftSehrLeise)
            }
        }
    }
}

// MARK: - Filter und Sortierung, geteilt mit der Bibliotheksseite

/// Die Steuerzeile unter dem Titel einer Rasterseite. Stand in
/// `BibliothekView`; die Sammlungsseite braucht genau dieselbe, und zwei
/// Fassungen derselben Zeile laufen auseinander.
///
/// **Werte, keine Möglichkeiten.**
///
/// Hier stand eine waagerecht scrollende Reihe Filterchips plus eine
/// Sortierpille: drei Wörter, von denen eines leuchtet, und man muss die
/// Farbe deuten, um den Zustand zu lesen. Dazu trug der aktive Chip
/// Akzent und die Pille daneben nicht — zwei Fragen, zwei Grammatiken.
///
/// Jetzt zwei Pillen, die ihren **Wert** zeigen, und rechts die Anzahl.
/// Der Preis ist ehrlich: filtern kostet zwei Tipp statt einem. Dafür
/// passt die Zeile auf jedes iPhone, egal wie viele Filter dazukommen,
/// und die Ausblendmaske am rechten Rand fällt ersatzlos weg.
///
/// **Breit bleibt es offen.** Dort ist Platz, und ein Blatt für etwas,
/// das daneben hinpasst, ist ein Umweg — dieselbe Begründung wie vorher.
///
/// **Die Sortierung steht breit rechts aussen** — wie auf dem Mac, wo
/// dasselbe Fenster dieselbe Breite hat. Hochkant bleibt es bei den Pillen,
/// dort ist der Platz nicht da.
struct Regalsteuerung: View {
    let stand: Bibliotheksmodell
    let filter: [Bibliotheksfilter]
    @Binding var filterOffen: Bool
    @Binding var sortierungOffen: Bool
    let versatz: CGFloat
    /// Statt Filter und Sortierung nur die Anzahl — für die Liste der
    /// Sammlungen, die man weder filtern noch umsortieren muss.
    var nurAnzahl: Int?

    @Environment(\.breit) private var breit

    var body: some View {
        if breit {
            zeile.padding(.top, 14)
        } else {
            Wertreihe(versatz: versatz) { zeile }
        }
    }

    private var zeile: some View {
        HStack(spacing: 8) {
            if let nurAnzahl {
                Spacer(minLength: 0)
                if !breit { Zaehlmarke(anzahl: nurAnzahl) }
            } else if breit {
                ForEach(filter) { f in
                    Wahlchip(text: f.beschriftung, an: stand.filter == f) {
                        stand.filter = f
                    }
                }
                Spacer(minLength: 12)
                ForEach(Sortierung.allCases) { s in
                    Wahlchip(text: s.beschriftung,
                             symbol: s == stand.sortierung ? "line.3.horizontal.decrease" : nil,
                             an: stand.sortierung == s) {
                        stand.sortierung = s
                    }
                }
            } else {
                Wertpille(symbol: "line.3.horizontal.decrease",
                          text: stand.filter.beschriftung) { filterOffen = true }
                Wertpille(symbol: "arrow.up.arrow.down",
                          text: stand.sortierung.beschriftung) { sortierungOffen = true }
                Spacer(minLength: 8)
                // Erst wenn wir sie kennen. Eine Null, die noch keine ist,
                // wäre eine falsche Auskunft.
                if stand.gesamt > 0 { Zaehlmarke(anzahl: stand.gesamt) }
            }
        }
        // **Dieselbe Höhe wie mit Pillen — auch ohne sie.**
        //
        // „Sammlungen" zeigt hier nur die Zahl; ihr Text ist niedriger als
        // eine `Wertpille` (`minHeight: 30`). Ohne diese Grenze sprang die
        // Zeile beim Wechsel zwischen „Alle Filme" und „Sammlungen" ein
        // paar Punkt nach oben, und die Zahl rechts sprang mit — derselbe
        // Platz bleibt jetzt stehen, mit oder ohne Pillen.
        .frame(minHeight: 30)
    }
}

extension View {
    /// Die beiden Blätter zu `Regalsteuerung`. **An die Seite, nicht an die
    /// Kopfzeile** — die Begründung steht an `BibliothekView.body`.
    func regalblaetter(stand: Bibliotheksmodell, filter: [Bibliotheksfilter],
                       filterOffen: Binding<Bool>, sortierungOffen: Binding<Bool>) -> some View {
        self
            .overlay(alignment: .topTrailing) {
                Auswahlblatt(offen: filterOffen,
                             titel: "Filtern",
                             eintraege: filter,
                             beschriftung: { $0.beschriftung },
                             istGewaehlt: { $0 == stand.filter },
                             waehlen: { stand.filter = $0 })
            }
            .overlay(alignment: .topTrailing) {
                Auswahlblatt(offen: sortierungOffen,
                             titel: "Sortieren",
                             eintraege: Sortierung.allCases,
                             beschriftung: { $0.beschriftung },
                             istGewaehlt: { $0 == stand.sortierung },
                             waehlen: { stand.sortierung = $0 })
            }
    }
}

// MARK: - Detailseite: Teil der Sammlung

/// **Die Reihe „Teil der Sammlung" auf der Filmseite** — die anderen Titel
/// der Sammlung, in ihrer Folge. Ihr Kopf öffnet die Sammlungsseite.
///
/// Gefragt wird nicht je Titel: Jellyfin 10 kennt kein Feld dafür. Die
/// Mitgliedschaft steht im ``Sammlungsverzeichnis``, das einmal je Konto
/// geladen wird; nur die Plakate der Reihe kommen frisch vom Server.
///
/// Fehlt die Sammlung, fehlt die Reihe — wie bei den Extras. Ein Hinweis
/// „gehört zu keiner Sammlung" wäre eine Auskunft, nach der niemand fragt.
///
/// **Geladen wird auf der Filmseite, nicht hier.** Die Reihe holte sich ihre
/// Titel selbst und drückte sich später als alles andere in die Seite; jetzt
/// wartet die Filmseite auf sie wie auf Extras und Ähnliches und blendet alles
/// zusammen ein (24.09.2026).
struct Sammlungsreihe: View {
    typealias Reihe = (sammlung: Sammlung, titel: [Item])

    let model: AppModel
    let titel: Item
    let reihen: [Reihe]

    @Environment(\.breit) private var breit

    private var art: String? { Bibliotheksgattung.art(zuTyp: titel.type) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(reihen, id: \.sammlung.id) { reihe in
                VStack(alignment: .leading, spacing: 12) {
                    NavigationLink(value: SammlungRoute(sammlung: reihe.sammlung.item, art: art)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Reihentitel(text: "Teil der Sammlung")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Stil.schriftSehrLeise)
                            }
                            Text(verbatim: reihe.sammlung.item.name)
                                .font(Stil.koerper)
                                .foregroundStyle(Stil.schriftLeise)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(Stil.Druckknopf())
                    .padding(.horizontal, Stil.rand(breit: breit))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Stil.kachelAbstand) {
                            ForEach(reihe.titel) { anderer in
                                NavigationLink(value: anderer) {
                                    PosterTile(model: model, item: anderer)
                                }
                                .buttonStyle(Stil.Druckknopf())
                            }
                        }
                        .padding(.horizontal, Stil.rand(breit: breit))
                    }
                }
                .padding(.top, Stil.reihenAbstand)
            }
        }
    }

    /// Die Reihen zu einem Titel — leer, wenn er in keiner Sammlung steht.
    static func laden(model: AppModel, titel: Item) async -> [Reihe] {
        guard let art = Bibliotheksgattung.art(zuTyp: titel.type) else { return [] }
        await model.angebotLaden()
        var gefunden: [Reihe] = []
        // Höchstens zwei Reihen. Steht ein Film in mehr Sammlungen, sind die
        // übrigen meist automatisch angelegte Doppel.
        for sammlung in model.sammlungen(mit: titel).prefix(2) {
            guard let liste = await model.sammlungstitel(sammlung, art: art) else { continue }
            let andere = Listenregeln.ohneDoppelte(liste).filter { $0.id != titel.id }
            if !andere.isEmpty { gefunden.append((sammlung, andere)) }
        }
        return gefunden
    }
}
