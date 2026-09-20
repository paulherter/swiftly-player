import JellyfinKit
import SwiftUI
import VLCKit

/// Maße des Players auf iPhone und iPad — **eine Stelle**, damit das X einer
/// Ebene genau dort sitzt, wo das X des Players saß, und der Titel der
/// Folgenliste genau dort, wo der Titel im Bild stand.
struct Playermass {
    let pad: Bool
    let imFenster: Bool
    /// iPhone im Hochformat (Querformat-Sperre aus): dann gilt oben der
    /// sichere Bereich — sonst läge der Kopf unter der Dynamic Island.
    var hochkant = false

    /// Oben den sicheren Bereich nur im Querformat übergehen; dort ist er
    /// ohnehin leer, im Hochformat trägt er die Insel.
    var obenUebergehen: Edge.Set { hochkant ? [] : .top }

    /// Rand links und rechts, innerhalb des sicheren Bereichs. Derselbe wie
    /// in `Folgenzeile` (`Stil.rand(breit:)`), damit Titel und Vorschaubilder
    /// der Folgenliste auf einer Linie stehen.
    var seite: CGFloat { Stil.rand(breit: pad) }
    /// Abstand oben; im Fenster liegt iPadOS' Ampel darüber.
    var oben: CGFloat { (pad ? 24 : 16) + (imFenster ? Fensterknoepfe.hoehe : 0) }
    /// Über dem sicheren Bereich unten. Auf dem iPhone direkt darauf: der
    /// sichere Bereich hält den Home-Indikator schon frei, mehr Abstand
    /// ließ die Leiste zu hoch schweben.
    /// Auf dem iPhone ragt die Trefferfläche etwas in den sicheren Bereich:
    /// die sichtbare Leiste sitzt so knapp über dem Home-Indikator.
    var unten: CGFloat { pad ? 22 : -10 }
    /// Trefferfläche der Symbolknöpfe.
    let knopf: CGFloat = 44
    var symbol: CGFloat { pad ? 21 : 19 }
    var titel: CGFloat { pad ? 22 : 19 }
    var meta: CGFloat { pad ? 15 : 14 }
    var zeit: CGFloat { pad ? 14 : 13 }
    /// Abstand der Überspringen-Pille über der Leiste.
    let ueberLeiste: CGFloat = 20
    /// Höhe der Zeitzeile — die Trefferfläche des Reglers.
    let leiste: CGFloat = 44
}

/// Die drei Ebenen über dem Bild.
enum Playerebene: Equatable {
    case spuren, folgen, einstellungen
}

/// Einer der runden Symbolknöpfe oben rechts — im Player wie auf den Ebenen.
struct Symbolknopf: View {
    let symbol: String
    let beschriftung: LocalizedStringKey
    let mass: Playermass
    let aktion: () -> Void

    var body: some View {
        Button(action: aktion) {
            Image(systemName: symbol)
                .font(.system(size: mass.symbol, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: mass.knopf, height: mass.knopf)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(beschriftung))
    }
}

/// **Grund jeder Ebene:** Weichzeichner und darüber dieselbe Abdunklung wie
/// im Entwurf, rgba(11,11,13,.72). Nimmt jeden Tipp an, damit darunter nichts
/// spult.
private struct Ebenengrund: View {
    var body: some View {
        ZStack {
            // **Über den Rand hinaus.** Ein Weichzeichner, der am
            // Bildschirmrand endet, holt sich dort Leere dazu: die Ecken
            // blitzten beim Einblenden hell auf. Größer gezogen liegt die
            // Kante außerhalb des Bildschirms.
            Rectangle().fill(.ultraThinMaterial)
                .padding(-60)
            // Reines Schwarz — siehe `Playerschleier`.
            Color.black.opacity(0.72)
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

/// Kopfzeile einer Ebene: links, was die Ebene dort zeigt, rechts das X —
/// mit denselben Maßen wie die Kopfzeile des Players.
private struct Ebenenkopf<Links: View>: View {
    let mass: Playermass
    let schliessen: () -> Void
    @ViewBuilder let links: Links

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            links
            Spacer(minLength: 0)
            Symbolknopf(symbol: "xmark", beschriftung: "Schließen", mass: mass, aktion: schliessen)
        }
        .padding(.horizontal, mass.seite)
        .padding(.top, mass.oben)
    }
}

// MARK: - Spalten

/// Eine Spalte mit fester Überschrift; nur die Zeilen darunter scrollen.
private struct Wahlspalte<Inhalt: View>: View {
    let titel: LocalizedStringKey
    let mass: Playermass
    @ViewBuilder let inhalt: Inhalt

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(titel)
                .font(.system(size: mass.pad ? 22 : 19, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) { inhalt }
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: mass.pad ? 260 : 210, alignment: .leading)
    }
}

/// Haken und Name. Gewählt weiß und halbfett, sonst 62 % Weiß.
private struct Ebenenzeile: View {
    let text: String
    let gewaehlt: Bool
    let mass: Playermass
    let aktion: () -> Void

    var body: some View {
        Button(action: aktion) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: mass.pad ? 15 : 14, weight: .semibold))
                    .opacity(gewaehlt ? 1 : 0)
                    .frame(width: 18)
                // Spurnamen kommen aus der Datei — wörtlich, nicht nachschlagen.
                Text(verbatim: text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: mass.pad ? 17 : 15, weight: gewaehlt ? .semibold : .regular))
            .foregroundStyle(gewaehlt ? Stil.schrift : Stil.schriftLeise)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckzeile())
        .clipShape(RoundedRectangle(cornerRadius: Stil.eckeFeld))
        .accessibilityAddTraits(gewaehlt ? .isSelected : [])
    }
}

/// Spalten nebeneinander, mittig, unter der Kopfzeile. Jede scrollt für sich;
/// unten endet der Inhalt über dem sicheren Bereich.
private struct Spaltenreihe<Inhalt: View>: View {
    let mass: Playermass
    @ViewBuilder let inhalt: Inhalt

    var body: some View {
        // Hochkant ist die Breite knapp: enger stehen, sonst passen drei
        // Spalten nicht nebeneinander.
        HStack(alignment: .top, spacing: mass.pad ? 56 : (mass.hochkant ? 16 : 40)) { inhalt }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, mass.seite)
            // Unter der Zeile des X, damit keine Überschrift an ihm vorbeiläuft.
            .padding(.top, mass.oben + mass.knopf + 6)
    }
}

// MARK: - Audio & Untertitel

struct SpurenEbene: View {
    let surface: VLCPlayerView?
    let mass: Playermass
    let schliessen: () -> Void

    /// Die eigene Wahl, unabhängig von VLC.
    ///
    /// VLC übernimmt eine Spurwahl nicht sofort — liest man direkt danach
    /// `isSelected`, steht dort noch der alte Stand. Die Anzeige hing dadurch
    /// einen Klick hinterher, und beim Wechsel von „Aus" auf eine Spur trugen
    /// kurz **beide** einen Haken. Was angetippt wurde, wissen wir aber selbst.
    /// Die Ebene wird bei jedem Öffnen neu gebaut, dann gilt wieder VLCs Stand.
    @State private var tonWahl: String?
    @State private var untertitelWahl: String??

    var body: some View {
        ZStack(alignment: .top) {
            Ebenengrund()
            Spaltenreihe(mass: mass) {
                Wahlspalte(titel: "Audio", mass: mass) {
                    ForEach(surface?.tonspuren ?? [], id: \.trackId) { spur in
                        Ebenenzeile(text: spur.huebscherName, gewaehlt: tonJetzt == spur.trackId,
                                  mass: mass) {
                            tonWahl = spur.trackId
                            surface?.waehleTonspur(spur)
                        }
                    }
                }
                Wahlspalte(titel: "Untertitel", mass: mass) {
                    Ebenenzeile(text: String(localized: "Aus"), gewaehlt: untertitelJetzt == nil,
                              mass: mass) {
                        untertitelWahl = .some(nil)
                        surface?.waehleUntertitel(nil)
                    }
                    let namen = surface?.untertitelnamen() ?? [:]
                    ForEach(surface?.untertitelspuren ?? [], id: \.trackId) { spur in
                        Ebenenzeile(text: namen[spur.trackId] ?? spur.trackName,
                                  gewaehlt: untertitelJetzt == spur.trackId, mass: mass) {
                            untertitelWahl = .some(spur.trackId)
                            surface?.waehleUntertitel(spur)
                        }
                    }
                }
            }
            Ebenenkopf(mass: mass, schliessen: schliessen) { EmptyView() }
        }
        // Oben wie die Kopfzeile des Players: quer bis an den Rand,
        // hochkant unter der Insel (`Playermass.obenUebergehen`).
        .ignoresSafeArea(edges: mass.obenUebergehen)
        .accessibilityAction(.escape, schliessen)
    }

    /// Über `trackId`, nicht den Namen — zwei Spuren namens „Deutsch" trugen
    /// sonst beide den Haken (T1-N4).
    private var untertitelJetzt: String? {
        if let untertitelWahl { return untertitelWahl }
        return surface?.gewaehlterUntertitel?.trackId
    }

    private var tonJetzt: String? {
        tonWahl ?? surface?.gewaehlteTonspur?.trackId
    }
}

// MARK: - Einstellungen

struct EinstellungsEbene: View {
    let surface: VLCPlayerView?
    let mass: Playermass
    @Binding var schlafminuten: Int?
    /// Nur bei Wiedergabe vom Server — eine heruntergeladene Datei hat keine Wahl.
    let qualitaet: Qualitaetswahl?
    let schliessen: () -> Void

    @AppStorage("technikschild") private var technikschild = false
    @AppStorage("bildfuellend") private var bildfuellend = false

    var body: some View {
        ZStack(alignment: .top) {
            Ebenengrund()
            Spaltenreihe(mass: mass) {
                // **Zwei Bildformate, nicht drei.** Der Player kennt das ganze
                // Bild und formatfüllend (auch per Zwei-Finger-Geste); ein
                // gestrecktes Bild gibt es nicht.
                Wahlspalte(titel: "Bild", mass: mass) {
                    Ebenenzeile(text: String(localized: "Original"), gewaehlt: !bildfuellend, mass: mass) {
                        bildfuellend = false
                        surface?.bildfuellend(false)
                    }
                    Ebenenzeile(text: String(localized: "Füllen"), gewaehlt: bildfuellend, mass: mass) {
                        bildfuellend = true
                        surface?.bildfuellend(true)
                    }
                }
                Wahlspalte(titel: "Schlafzeit", mass: mass) {
                    Ebenenzeile(text: String(localized: "Aus"), gewaehlt: schlafminuten == nil, mass: mass) {
                        schlafminuten = nil
                    }
                    ForEach(Schlafzeiten.werte, id: \.self) { minuten in
                        Ebenenzeile(text: String(localized: "\(minuten) Min."),
                                  gewaehlt: schlafminuten == minuten, mass: mass) {
                            schlafminuten = minuten
                        }
                    }
                }
                Wahlspalte(titel: "Technikschild", mass: mass) {
                    Ebenenzeile(text: String(localized: "Aus"), gewaehlt: !technikschild, mass: mass) {
                        technikschild = false
                    }
                    Ebenenzeile(text: String(localized: "An"), gewaehlt: technikschild, mass: mass) {
                        technikschild = true
                    }
                }
                // **Qualität: Direct Play oder eine Obergrenze.** Eine Obergrenze
                // heißt, der Server darf umwandeln — Direct Play ist dann aus.
                // Gilt wie die Einstellung in der App und lädt den Film an
                // derselben Stelle neu.
                if let qualitaet {
                    Wahlspalte(titel: "Qualität", mass: mass) {
                        Ebenenzeile(text: String(localized: "Direct Play"),
                                    gewaehlt: qualitaet.directPlay, mass: mass) {
                            qualitaet.waehlen(nil)
                        }
                        ForEach(Bitrate.stufen) { stufe in
                            Ebenenzeile(text: Bitrate.text(stufe.wert),
                                        gewaehlt: !qualitaet.directPlay && qualitaet.grenze == stufe.wert,
                                        mass: mass) {
                                qualitaet.waehlen(stufe.wert)
                            }
                        }
                    }
                }
            }
            Ebenenkopf(mass: mass, schliessen: schliessen) { EmptyView() }
        }
        // Oben wie die Kopfzeile des Players: quer bis an den Rand,
        // hochkant unter der Insel (`Playermass.obenUebergehen`).
        .ignoresSafeArea(edges: mass.obenUebergehen)
        .accessibilityAction(.escape, schliessen)
    }
}

// MARK: - Folgen

/// Die Folgen der Serie — dieselben Zeilen wie auf der Serienseite.
///
/// Der Titel steht genau dort, wo er im Player stand; an Stelle der
/// Metazeile sitzt die Staffelwahl der Serienseite.
struct FolgenEbene: View {
    let model: AppModel
    /// Die laufende Folge.
    let item: Item
    let titel: String
    let mass: Playermass
    let schliessen: () -> Void
    let starten: (Item) -> Void

    @State private var staffeln: [Item] = []
    @State private var gewaehlteStaffel: Item?
    @State private var folgen: [Item] = []
    @State private var staffellisteOffen = false

    /// **Beim Öffnen steht die Liste schon da.** Was der Speicher hat —
    /// der Player lädt es beim Start vor (`vorladen`) —, liegt vor dem
    /// ersten Bild in den Zuständen; die Folgen ploppten sonst erst nach
    /// dem Einblenden auf.
    init(model: AppModel, item: Item, titel: String, mass: Playermass,
         schliessen: @escaping () -> Void, starten: @escaping (Item) -> Void) {
        self.model = model
        self.item = item
        self.titel = titel
        self.mass = mass
        self.schliessen = schliessen
        self.starten = starten
        guard let serie = item.seriesId,
              let gemerkt = Serienspeicher.geteilt.stand(serie, mit: model),
              !gemerkt.staffeln.isEmpty else { return }
        let staffel = Self.passendeStaffel(zu: item, in: gemerkt.staffeln)
        _staffeln = State(initialValue: gemerkt.staffeln)
        _gewaehlteStaffel = State(initialValue: staffel)
        _folgen = State(initialValue: staffel.flatMap { gemerkt.folgen[$0.id] } ?? [])
    }

    /// Staffeln und die Folgen der laufenden Staffel in den Speicher —
    /// aufgerufen, sobald der Player eine Folge zeigt.
    static func vorladen(model: AppModel, item: Item) async {
        guard let serieID = item.seriesId, let serie = Item.vorlaeufigeSerie(zu: item) else { return }
        let staffeln = await model.staffeln(serie)
        guard !staffeln.isEmpty else { return }
        Serienspeicher.geteilt.merken(serieID) { $0.staffeln = staffeln }
        guard let staffel = passendeStaffel(zu: item, in: staffeln) else { return }
        let folgen = await model.folgen(serie: serieID, staffel: staffel.id)
        Serienspeicher.geteilt.merken(serieID) { $0.folgen[staffel.id] = folgen }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Ebenengrund()
            VStack(alignment: .leading, spacing: 0) {
                Ebenenkopf(mass: mass, schliessen: schliessen) {
                    VStack(alignment: .leading, spacing: 3) {
                        // Platzhalter: der Titel selbst steht im Player
                        // (`stehenderTitel`) und blendet nicht mit.
                        Text(verbatim: titel)
                            .font(.system(size: mass.titel, weight: .bold))
                            .lineLimit(1)
                            .hidden()
                        if !staffeln.isEmpty {
                            Aufklappliste(beschriftung: gewaehlteStaffel?.name
                                              ?? String(localized: "Staffel"),
                                          eintraege: staffeln,
                                          text: { $0.name },
                                          istGewaehlt: { $0.id == gewaehlteStaffel?.id },
                                          waehlen: { staffel in
                                              gewaehlteStaffel = staffel
                                              Task { await folgenLaden(staffelGewechselt: true) }
                                          },
                                          offen: $staffellisteOffen,
                                          schrift: .system(size: mass.meta + 1, weight: .semibold),
                                          hoehe: 28)
                        }
                    }
                }
                // Die aufgeklappte Staffelliste liegt über den Folgen.
                .zIndex(1)

                ScrollViewReader { leser in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(folgen) { folge in
                                Button { starten(folge) } label: {
                                    Folgenzeile(model: model, folge: folge)
                                        .background(folge.id == item.id ? Color.white.opacity(0.08) : .clear)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(folge.id == item.id ? .isSelected : [])
                                .id(folge.id)
                                .transition(.opacity)
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .scrollIndicators(.hidden)
                    // **Die laufende Folge in Sicht**, sobald die Liste steht.
                    .onChange(of: folgen.map(\.id), initial: true) { _, ids in
                        guard ids.contains(item.id) else { return }
                        leser.scrollTo(item.id, anchor: .center)
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in
                        if staffellisteOffen { staffellisteOffen = false }
                    })
                }
                .padding(.top, 10)
            }
        }
        .ignoresSafeArea(edges: mass.obenUebergehen)
        .environment(\.breit, mass.pad)
        .accessibilityAction(.escape, schliessen)
        .task { await laden() }
    }

    /// Erst was der Speicher der Serienseite schon hat, dann frisch vom Server.
    private func laden() async {
        guard let serie = Item.vorlaeufigeSerie(zu: item) else { return }
        if let gemerkt = Serienspeicher.geteilt.stand(serie.id, mit: model), !gemerkt.staffeln.isEmpty {
            staffeln = gemerkt.staffeln
            gewaehlteStaffel = passendeStaffel(in: gemerkt.staffeln)
            if let id = gewaehlteStaffel?.id, let liste = gemerkt.folgen[id] { folgen = liste }
        }
        let frisch = await model.staffeln(serie)
        guard !frisch.isEmpty else { return }
        staffeln = frisch
        if gewaehlteStaffel == nil || !frisch.contains(where: { $0.id == gewaehlteStaffel?.id }) {
            gewaehlteStaffel = passendeStaffel(in: frisch)
        }
        await folgenLaden()
    }

    private func passendeStaffel(in liste: [Item]) -> Item? {
        Self.passendeStaffel(zu: item, in: liste)
    }

    private static func passendeStaffel(zu item: Item, in liste: [Item]) -> Item? {
        liste.first { $0.id == item.seasonId }
            ?? liste.first { $0.indexNumber != nil && $0.indexNumber == item.parentIndexNumber }
            ?? liste.first
    }

    /// Überblendet wird nur beim Staffelwechsel; beim Öffnen steht die
    /// Liste sofort da.
    private func folgenLaden(staffelGewechselt: Bool = false) async {
        guard let serie = item.seriesId else { return }
        let staffel = gewaehlteStaffel?.id
        let geladen = await model.folgen(serie: serie, staffel: staffel)
        // Wer inzwischen eine andere Staffel gewählt hat, bekommt deren Folgen.
        guard staffel == gewaehlteStaffel?.id else { return }
        if staffelGewechselt {
            // Die neue Staffel blendet ein, statt hart dazustehen.
            withAnimation(.easeOut(duration: 0.25)) { folgen = geladen }
        } else {
            folgen = geladen
        }
        if let staffel { Serienspeicher.geteilt.merken(serie) { $0.folgen[staffel] = geladen } }
    }
}

/// Die Qualitätswahl im Player: Direct Play oder eine Obergrenze in Mbit/s.
/// `waehlen(nil)` heißt Direct Play.
struct Qualitaetswahl {
    let directPlay: Bool
    let grenze: Int
    let waehlen: (Int?) -> Void
}
