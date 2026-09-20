import JellyfinKit
import SwiftUI
import VLCKit

/// Maße des Players auf dem Mac — **eine Stelle**, damit das X einer Ebene
/// genau dort sitzt, wo das X des Players saß.
///
/// Wörtlich das Gegenstück zu `Playermass` auf iOS (`Sources/iOS/
/// PlayerEbenen.swift`), nur mit festen Werten statt `pad`/`imFenster`: ein
/// Fenster hat weder eine Diagonale noch eine Notch, an der sich der Rand
/// ausrichten müsste — er bleibt überall derselbe.
struct Playermass {
    /// Rand links und rechts.
    let seite: CGFloat = 40
    /// Abstand oben. Reicht über die Zone, in der die Fensterampel steht
    /// (`Stil.ampelzone`), damit Titel und Ampel sich nicht ins Gehege kommen.
    let oben: CGFloat = 28
    let unten: CGFloat = 24
    /// Trefferfläche der Symbolknöpfe.
    let knopf: CGFloat = 38
    let symbol: CGFloat = 18
    let titel: CGFloat = 22
    let meta: CGFloat = 14
    let zeit: CGFloat = 13
    /// Abstand der Überspringen-Pille über der Leiste.
    let ueberLeiste: CGFloat = 20
    /// Trefferfläche des Zeitreglers.
    let leiste: CGFloat = 32
}

/// Die drei Ebenen über dem Bild — dasselbe Angebot wie auf iOS.
enum Playerebene: Equatable {
    case spuren, folgen, einstellungen
}

/// Einer der runden Symbolknöpfe oben rechts — im Player wie auf den Ebenen.
///
/// Anders als auf iOS mit einer leisen Kreisfläche beim Überfahren: eine Maus
/// braucht die Rückmeldung, ein Finger trifft ohnehin, was er sieht.
struct Symbolknopf: View {
    let symbol: String
    let beschriftung: LocalizedStringKey
    let mass: Playermass
    let aktion: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: aktion) {
            Image(systemName: symbol)
                .font(.system(size: mass.symbol, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: mass.knopf, height: mass.knopf)
                .background(schwebt ? .white.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: Stil.eckeFeld))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(beschriftung)
        .accessibilityLabel(Text(beschriftung))
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
    }
}

/// **Grund jeder Ebene:** Weichzeichner und dieselbe Abdunklung wie im
/// Entwurf, rgba(11,11,13,.72). Nimmt jeden Klick an, damit darunter nichts
/// spult.
private struct Ebenengrund: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Stil.grund.opacity(0.72)
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

/// Kopfzeile einer Ebene: links, was die Ebene dort zeigt, rechts das X — mit
/// denselben Maßen wie die Kopfzeile des Players, damit beide X aufeinander
/// liegen.
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

/// Eine Spalte mit fester Überschrift; nur die Zeilen darunter scrollen für
/// sich — bei 50 und mehr Untertiteln bleibt die andere Spalte in Ruhe.
private struct Wahlspalte<Inhalt: View>: View {
    let titel: LocalizedStringKey
    @ViewBuilder let inhalt: Inhalt

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(titel)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) { inhalt }
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 200, alignment: .leading)
    }
}

/// Haken und Name. Gewählt weiß und halbfett, sonst 62 % Weiß — mit einer
/// leisen Fläche beim Überfahren, die es auf iOS ohne Zeiger nicht braucht.
private struct Ebenenzeile: View {
    let text: String
    let gewaehlt: Bool
    let aktion: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: aktion) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .opacity(gewaehlt ? 1 : 0)
                    .frame(width: 17)
                // Spurnamen kommen aus der Datei — wörtlich, nicht nachschlagen.
                Text(verbatim: text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 15, weight: gewaehlt ? .semibold : .regular))
            .foregroundStyle(gewaehlt ? Stil.schrift : Stil.schriftLeise)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(schwebt ? .white.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: Stil.eckeFeld))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { schwebt = $0 }
        .accessibilityAddTraits(gewaehlt ? .isSelected : [])
    }
}

/// Spalten nebeneinander, mittig, unter der Kopfzeile. Jede scrollt für sich.
private struct Spaltenreihe<Inhalt: View>: View {
    let mass: Playermass
    @ViewBuilder let inhalt: Inhalt

    var body: some View {
        HStack(alignment: .top, spacing: 45) { inhalt }
            .frame(maxWidth: .infinity)
            // Unter der Zeile des X, damit keine Überschrift an ihm vorbeiläuft.
            .padding(.top, mass.oben + mass.knopf + 6)
    }
}

// MARK: - Audio & Untertitel

struct SpurenEbene: View {
    let flaeche: VLCPlayerView?
    let mass: Playermass
    let schliessen: () -> Void

    /// Die eigene Wahl, unabhängig von VLC — siehe die Begründung in der
    /// iOS-Fassung: VLC übernimmt eine Spurwahl nicht sofort, und ohne diesen
    /// Zwischenstand trüge beim Wechsel kurz keine oder sogar die falsche
    /// Spur den Haken.
    @State private var tonWahl: String?
    @State private var untertitelWahl: String??

    var body: some View {
        ZStack(alignment: .top) {
            Ebenengrund()
            Spaltenreihe(mass: mass) {
                Wahlspalte(titel: "Audio") {
                    ForEach(flaeche?.tonspuren ?? [], id: \.trackId) { spur in
                        Ebenenzeile(text: spur.huebscherName, gewaehlt: tonJetzt == spur.trackId) {
                            tonWahl = spur.trackId
                            flaeche?.waehleTonspur(spur)
                        }
                    }
                }
                Wahlspalte(titel: "Untertitel") {
                    Ebenenzeile(text: String(localized: "Aus"), gewaehlt: untertitelJetzt == nil) {
                        untertitelWahl = .some(nil)
                        flaeche?.waehleUntertitel(nil)
                    }
                    let namen = flaeche?.untertitelnamen() ?? [:]
                    ForEach(flaeche?.untertitelspuren ?? [], id: \.trackId) { spur in
                        Ebenenzeile(text: namen[spur.trackId] ?? spur.trackName,
                                  gewaehlt: untertitelJetzt == spur.trackId) {
                            untertitelWahl = .some(spur.trackId)
                            flaeche?.waehleUntertitel(spur)
                        }
                    }
                }
            }
            Ebenenkopf(mass: mass, schliessen: schliessen) { EmptyView() }
        }
        .accessibilityAction(.escape, schliessen)
    }

    /// Über `trackId`, nicht den Namen — zwei Spuren namens „Deutsch" trügen
    /// sonst beide den Haken.
    private var untertitelJetzt: String? {
        if let untertitelWahl { return untertitelWahl }
        return flaeche?.gewaehlterUntertitel?.trackId
    }

    private var tonJetzt: String? {
        tonWahl ?? flaeche?.gewaehlteTonspur?.trackId
    }
}

// MARK: - Einstellungen

struct EinstellungsEbene: View {
    let flaeche: VLCPlayerView?
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
                // **Zwei Bildformate, nicht drei** — wörtlich die Regel von
                // iOS: der Player kennt das ganze Bild und formatfüllend
                // (auch per Zusammenziehen); ein gestrecktes Bild gibt es
                // nicht.
                Wahlspalte(titel: "Bild") {
                    Ebenenzeile(text: String(localized: "Original"), gewaehlt: !bildfuellend) {
                        bildfuellend = false
                        flaeche?.bildfuellend(false)
                    }
                    Ebenenzeile(text: String(localized: "Füllen"), gewaehlt: bildfuellend) {
                        bildfuellend = true
                        flaeche?.bildfuellend(true)
                    }
                }
                Wahlspalte(titel: "Schlafzeit") {
                    Ebenenzeile(text: String(localized: "Aus"), gewaehlt: schlafminuten == nil) {
                        schlafminuten = nil
                    }
                    ForEach(Schlafzeiten.werte, id: \.self) { minuten in
                        Ebenenzeile(text: String(localized: "\(minuten) Min."),
                                  gewaehlt: schlafminuten == minuten) {
                            schlafminuten = minuten
                        }
                    }
                }
                Wahlspalte(titel: "Technikschild") {
                    Ebenenzeile(text: String(localized: "Aus"), gewaehlt: !technikschild) {
                        technikschild = false
                    }
                    Ebenenzeile(text: String(localized: "An"), gewaehlt: technikschild) {
                        technikschild = true
                    }
                }
                // **Qualität: Direct Play oder eine Obergrenze.** Eine Obergrenze
                // heißt, der Server darf umwandeln — Direct Play ist dann aus.
                // Gilt wie die Einstellung in der App und lädt den Film an
                // derselben Stelle neu.
                if let qualitaet {
                    Wahlspalte(titel: "Qualität") {
                        Ebenenzeile(text: String(localized: "Direct Play"),
                                    gewaehlt: qualitaet.directPlay) {
                            qualitaet.waehlen(nil)
                        }
                        ForEach(Bitrate.stufen) { stufe in
                            Ebenenzeile(text: Bitrate.text(stufe.wert),
                                        gewaehlt: !qualitaet.directPlay && qualitaet.grenze == stufe.wert) {
                                qualitaet.waehlen(stufe.wert)
                            }
                        }
                    }
                }
            }
            Ebenenkopf(mass: mass, schliessen: schliessen) { EmptyView() }
        }
        .accessibilityAction(.escape, schliessen)
    }
}

/// Die Qualitätswahl im Player: Direct Play oder eine Obergrenze in Mbit/s.
/// `waehlen(nil)` heißt Direct Play.
struct Qualitaetswahl {
    let directPlay: Bool
    let grenze: Int
    let waehlen: (Int?) -> Void
}

// MARK: - Folgen

/// Die Folgen der Serie — dieselben Zeilen wie auf der Mac-Serienseite
/// (`Folgenzeile` in `SerienView.swift`), nicht nachgebaut.
///
/// Der Titel steht genau dort, wo er im Player stand (`stehenderTitel` in
/// `PlayerScreen.swift`); an Stelle der Metazeile sitzt die Staffelwahl der
/// Serienseite (`Staffelwahl`, ebenfalls dort).
///
/// **Das Laden ist wörtlich die iOS-Fassung** (`FolgenEbene` in
/// `Sources/iOS/PlayerEbenen.swift`): erst der Speicher der Serienseite, dann
/// frisch vom Server, Überblendung nur beim Staffelwechsel. Eigener Typ statt
/// geteilter Funktion, weil beide Fassungen an eigene `@State`-Werte hängen
/// und eine Übernahme nach `JellyfinKit` hier über den Auftrag hinausginge,
/// der ausdrücklich nur macOS-Dateien anfasst.
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
                            Staffelwahl(staffeln: staffeln, gewaehlt: $gewaehlteStaffel,
                                        offen: $staffellisteOffen)
                                .onChange(of: gewaehlteStaffel?.id) { _, _ in
                                    Task { await folgenLaden(staffelGewechselt: true) }
                                }
                        }
                    }
                }
                // Die aufgeklappte Staffelliste liegt über den Folgen.
                .zIndex(1)

                ScrollViewReader { leser in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(folgen) { folge in
                                // **`aktion:` ausgeschrieben, nicht als
                                // Abschlussblock** — sonst bindet Swifts
                                // Regel für abschliessende Blöcke ihn an
                                // `ringtipp` (auch optional, mit Vorbelegung)
                                // statt an `aktion`, und ein Klick riefe
                                // `starten` mit der Unterkante als `Item` auf.
                                Folgenzeile(model: model, folge: folge,
                                            aktion: { gewaehlteFolge in starten(gewaehlteFolge) })
                                .background(folge.id == item.id ? Color.white.opacity(0.08) : .clear)
                                .accessibilityAddTraits(folge.id == item.id ? .isSelected : [])
                                .id(folge.id)
                                .transition(.opacity)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .scrollIndicators(.hidden)
                    // **Die laufende Folge in Sicht**, sobald die Liste steht.
                    .onChange(of: folgen.map(\.id), initial: true) { _, ids in
                        guard ids.contains(item.id) else { return }
                        leser.scrollTo(item.id, anchor: .center)
                    }
                }
                .padding(.top, 10)
            }
        }
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
        liste.first { $0.id == item.seasonId }
            ?? liste.first { $0.indexNumber != nil && $0.indexNumber == item.parentIndexNumber }
            ?? liste.first
    }

    /// Überblendet wird nur beim Staffelwechsel; beim Öffnen steht die Liste
    /// sofort da.
    private func folgenLaden(staffelGewechselt: Bool = false) async {
        guard let serie = item.seriesId else { return }
        let staffel = gewaehlteStaffel?.id
        let geladen = await model.folgen(serie: serie, staffel: staffel)
        // Wer inzwischen eine andere Staffel gewählt hat, bekommt deren Folgen.
        guard staffel == gewaehlteStaffel?.id else { return }
        if staffelGewechselt {
            withAnimation(.easeOut(duration: 0.25)) { folgen = geladen }
        } else {
            folgen = geladen
        }
        if let staffel { Serienspeicher.geteilt.merken(serie) { $0.folgen[staffel] = geladen } }
    }
}
