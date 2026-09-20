import JellyfinKit
import SwiftUI
import VLCKit

/// Maße des Players auf dem Fernseher — **eine Stelle**, damit der Titel der
/// Folgenebene genau dort steht, wo er im Bild stand.
///
/// Abgeleitet vom Entwurf (Spalte „Apple TV", 960 × 540, also halbe Größe),
/// gerundet auf die Schriftstufen der Fernsehfassung. Die Ränder sind die
/// titelsicheren der ganzen App (`Stil.randSeite`, `Stil.randOben`), damit
/// Titel und Folgenkacheln auf einer Linie stehen.
enum Playermass {
    static let titel = Font.system(size: 57, weight: .bold)
    static let meta = Font.system(size: 31)
    static let zeit: CGFloat = 28
    /// Die Zielzeit unter dem Vorschaubild beim Spulen.
    static let vorschauZeit: CGFloat = 32
    /// Grund der Leiste, wie im Entwurf und im `Zeitregler` des iPhones.
    static let leisteGrund = Color.white.opacity(0.28)
    /// Zwischen Titel und Metazeile beziehungsweise Staffelpille.
    static let titelAbstand: CGFloat = 6
    /// Die Symbolknöpfe oben rechts.
    static let knopf: CGFloat = 88
    static let symbol: CGFloat = 38
    static let knopfAbstand: CGFloat = 20
    /// Abstand der Überspringen-Pille über der Leiste.
    static let ueberLeiste: CGFloat = 40
    /// Höhe der Zeitzeile.
    static let leiste: CGFloat = 40
    /// Spalten der Ebenen Audio & Untertitel und Einstellungen.
    static let spalte: CGFloat = 500
    static let spaltenAbstand: CGFloat = 114
    static let spaltenOben: CGFloat = 152

    /// Wie breit die Symbolreihe ist — der stehende Titel hält ihr den Platz frei.
    static func symbolreihe(anzahl: Int) -> CGFloat {
        CGFloat(anzahl) * knopf + CGFloat(max(anzahl - 1, 0)) * knopfAbstand
    }
}

/// Die drei Ebenen über dem Bild.
enum Playerebene: Equatable {
    case spuren, folgen, einstellungen
}

/// Einer der Symbolknöpfe oben rechts. Ruhend nur das Zeichen, fokussiert die
/// weiße Fläche von `KnopfStil`.
struct Symbolknopf: View {
    let symbol: String
    let beschriftung: LocalizedStringKey
    let aktion: () -> Void

    var body: some View {
        Button(action: aktion) {
            Image(systemName: symbol)
                .font(.system(size: Playermass.symbol, weight: .medium))
        }
        .buttonStyle(SymbolknopfStil())
        .accessibilityLabel(Text(beschriftung))
    }
}

/// Wie `KnopfStil(nurSymbol:)`, nur ruhend ohne Fläche — im Entwurf stehen die
/// Zeichen frei über dem Bild.
private struct SymbolknopfStil: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inhalt(configuration: configuration)
    }

    private struct Inhalt: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var fokus

        var body: some View {
            configuration.label
                .foregroundStyle(fokus ? Stil.grund : Stil.schrift)
                .frame(width: Playermass.knopf, height: Playermass.knopf)
                .background(fokus ? Color.white : .clear,
                            in: RoundedRectangle(cornerRadius: Stil.ecke))
                .scaleEffect(configuration.isPressed ? 0.97 : (fokus ? 1.04 : 1))
                .animation(Stil.fokusAnimation, value: fokus)
        }
    }
}

/// **Grund jeder Ebene:** Weichzeichner, kaum zusätzlich abgedunkelt.
///
/// Die Steuerung hat das Bild schon abgedunkelt; eine zweite kräftige
/// Abdunklung wirkte schwer. Der Weichzeichner allein trägt die Ebene.
/// Dunkler Stil aus UIKit — `.ultraThinMaterial` folgt auf dem Fernseher
/// dem hellen Erscheinungsbild des Systems. Darüber nur reines Schwarz,
/// nie `Stil.grund`: das hebt im HDR-Modus Schwarz zu Grau an.
private struct Ebenengrund: View {
    var body: some View {
        ZStack {
            DunklerWeichzeichner()
            Color.black.opacity(0.15)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct DunklerWeichzeichner: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    }

    func updateUIView(_ ansicht: UIVisualEffectView, context: Context) {}
}

// MARK: - Spalten

/// Eine Spalte mit fester Überschrift; nur die Zeilen darunter scrollen — per
/// Fokus, jede für sich. Fünfzig Untertitel laufen so unter der Überschrift
/// durch, statt sie zu überdecken.
private struct Wahlspalte<Inhalt: View>: View {
    let titel: LocalizedStringKey
    @ViewBuilder let inhalt: Inhalt

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(titel)
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                .padding(.horizontal, 26)
                .padding(.bottom, 22)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) { inhalt }
                    .padding(.bottom, Stil.randOben)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: Playermass.spalte, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        // Links und rechts wechselt die Spalte, statt quer durch die Zeilen
        // zu springen.
        .focusSection()
    }
}

/// Haken und Name. Gewählt weiß und halbfett, sonst 62 % Weiß; Fokus ist die
/// ruhige Fläche von `FolgenStil`.
private struct Ebenenzeile: View {
    let text: String
    let gewaehlt: Bool
    let aktion: () -> Void

    var body: some View {
        Button(action: aktion) {
            Zeilentext(text: text, gewaehlt: gewaehlt)
        }
        .buttonStyle(FolgenStil())
        .accessibilityAddTraits(gewaehlt ? .isSelected : [])
    }

    /// Eigene Ansicht, damit sie den Fokus des Knopfes lesen kann.
    private struct Zeilentext: View {
        let text: String
        let gewaehlt: Bool
        @Environment(\.isFocused) private var fokus

        var body: some View {
            HStack(spacing: 22) {
                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .semibold))
                    .opacity(gewaehlt ? 1 : 0)
                    .frame(width: 42)
                // Spurnamen kommen aus der Datei — wörtlich, nicht nachschlagen.
                Text(verbatim: text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 36, weight: gewaehlt ? .semibold : .regular))
            .foregroundStyle(gewaehlt || fokus ? Stil.schrift : Stil.schriftLeise)
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Spalten nebeneinander, mittig. Unten enden sie am Bildrand; was darüber
/// hinausgeht, scrollt in seiner Spalte.
private struct Spaltenreihe<Inhalt: View>: View {
    @ViewBuilder let inhalt: Inhalt

    var body: some View {
        HStack(alignment: .top, spacing: Playermass.spaltenAbstand) { inhalt }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, Playermass.spaltenOben)
    }
}

// MARK: - Audio & Untertitel

struct SpurenEbene: View {
    let flaeche: VLCPlayerView?

    /// Die eigene Wahl, unabhängig von VLC — VLC zieht die Auswahl erst einen
    /// Takt später nach, und die Haken hingen sonst einen Klick hinterher.
    @State private var tonWahl: String?
    @State private var untertitelWahl: String??
    @FocusState private var fokus: String?

    var body: some View {
        ZStack(alignment: .top) {
            Ebenengrund()
            Spaltenreihe {
                Wahlspalte(titel: "Audio") {
                    ForEach(flaeche?.tonspuren ?? [], id: \.trackId) { spur in
                        Ebenenzeile(text: spur.huebscherName, gewaehlt: tonJetzt == spur.trackId) {
                            tonWahl = spur.trackId
                            flaeche?.waehleTonspur(spur)
                        }
                        .focused($fokus, equals: "t" + spur.trackId)
                    }
                }
                Wahlspalte(titel: "Untertitel") {
                    Ebenenzeile(text: String(localized: "Aus"), gewaehlt: untertitelJetzt == nil) {
                        untertitelWahl = .some(nil)
                        flaeche?.waehleUntertitel(nil)
                    }
                    .focused($fokus, equals: "u")
                    let namen = flaeche?.untertitelnamen() ?? [:]
                    ForEach(flaeche?.untertitelspuren ?? [], id: \.trackId) { spur in
                        Ebenenzeile(text: namen[spur.trackId] ?? spur.trackName,
                                    gewaehlt: untertitelJetzt == spur.trackId) {
                            untertitelWahl = .some(spur.trackId)
                            flaeche?.waehleUntertitel(spur)
                        }
                        .focused($fokus, equals: "u" + spur.trackId)
                    }
                }
            }
        }
        .focusSection()
        // Beim Öffnen auf der gewählten Tonspur.
        .task { await Ebenenfokus.legen { fokus = fokus ?? startziel } }
    }

    private var startziel: String {
        if let ton = tonJetzt { return "t" + ton }
        return "u" + (untertitelJetzt ?? "")
    }

    /// Über `trackId`, nicht den Namen — zwei Spuren namens „Deutsch" trugen
    /// sonst beide den Haken (T1-N4).
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
    @Binding var schlafminuten: Int?
    /// Nur bei Wiedergabe vom Server — eine heruntergeladene Datei hat keine Wahl.
    let qualitaet: Qualitaetswahl?

    @AppStorage("technikschild") private var technikschild = false
    @AppStorage("bildfuellend") private var bildfuellend = false
    @FocusState private var fokus: String?

    var body: some View {
        ZStack(alignment: .top) {
            Ebenengrund()
            Spaltenreihe {
                // Zwei Bildformate wie auf dem iPhone: das ganze Bild und
                // formatfüllend. Ein gestrecktes Bild gibt es nicht.
                Wahlspalte(titel: "Bild") {
                    Ebenenzeile(text: String(localized: "Original"), gewaehlt: !bildfuellend) {
                        bildfuellend = false
                        flaeche?.bildfuellend(false)
                    }
                    .focused($fokus, equals: "b0")
                    Ebenenzeile(text: String(localized: "Füllen"), gewaehlt: bildfuellend) {
                        bildfuellend = true
                        flaeche?.bildfuellend(true)
                    }
                    .focused($fokus, equals: "b1")
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
        }
        .focusSection()
        .task { await Ebenenfokus.legen { fokus = fokus ?? (bildfuellend ? "b1" : "b0") } }
    }
}

/// Die Qualitätswahl im Player: Direct Play oder eine Obergrenze in Mbit/s.
/// `waehlen(nil)` heißt Direct Play.
struct Qualitaetswahl {
    let directPlay: Bool
    let grenze: Int
    let waehlen: (Int?) -> Void
}

/// **Der Fokus kommt nicht von selbst in eine Ebene** — dieselbe Lehre wie im
/// Player: die erste Zuweisung fällt in den Durchlauf, in dem die Ebene erst
/// eingehängt wird, und SwiftUI verwirft sie. Also sofort und einen Takt
/// später noch einmal.
enum Ebenenfokus {
    @MainActor
    static func legen(_ setzen: () -> Void) async {
        setzen()
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return }
        setzen()
    }
}

// MARK: - Folgen

/// Die Folgen der Serie — derselbe Kachelstreifen wie auf der Serienseite.
///
/// Der Titel steht genau dort, wo er im Player stand (`stehenderTitel` im
/// Player, hier nur als Platzhalter); an Stelle der Metazeile sitzt die
/// Staffelpille der Serienseite, darunter die Kacheln.
struct FolgenEbene: View {
    let model: AppModel
    /// Die laufende Folge.
    let item: Item
    let titel: String
    let starten: (Item) -> Void

    @State private var staffeln: [Item] = []
    @State private var gewaehlteStaffel: Item?
    @State private var folgen: [Item] = []
    @State private var staffelwahlOffen = false
    /// **Die Einträge der offenen Staffelwahl, einmal gebaut.** Jede
    /// `Titelhandlung` trägt eine neue Kennung; aus dem `body` gerechnet
    /// entstand die Liste bei jedem Takt des Players (alle 0,5 s) neu, die
    /// Zeilen wurden ersetzt, und der Fokus sprang zwischen Liste und Pille
    /// hin und her — die Pille flackerte, solange die Wahl offen war.
    @State private var tafelhandlungen: [Titelhandlung] = []
    @FocusState private var amFolge: String?
    @FocusState private var amStaffelpille: Bool

    /// **Beim Öffnen steht die Reihe schon da.** Was der Speicher hat — der
    /// Player lädt es beim Start vor (`vorladen`) —, liegt vor dem ersten
    /// Bild in den Zuständen; die Kacheln ploppten sonst erst nach dem
    /// Einblenden auf, und der Fokus fände die laufende Folge nicht.
    init(model: AppModel, item: Item, titel: String, starten: @escaping (Item) -> Void) {
        self.model = model
        self.item = item
        self.titel = titel
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
        ZStack(alignment: .topLeading) {
            Ebenengrund()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Playermass.titelAbstand) {
                    // Platzhalter: der Titel selbst steht im Player und
                    // blendet nicht mit.
                    Text(verbatim: titel)
                        .font(Playermass.titel)
                        .lineLimit(1)
                        .hidden()
                        .accessibilityHidden(true)
                    if !staffeln.isEmpty {
                        Staffelpille(name: gewaehlteStaffel?.name ?? String(localized: "Staffel"),
                                     offen: $staffelwahlOffen)
                            .focused($amStaffelpille)
                            .tafelausloeser("staffel")
                    }
                }
                .padding(.horizontal, Stil.randSeite)
                .padding(.top, Stil.randOben)

                // Alte und neue Reihe liegen beim Staffelwechsel übereinander
                // und blenden über — wie auf der Serienseite.
                ZStack(alignment: .topLeading) {
                    if !folgen.isEmpty {
                        Folgenstreifen(model: model, folgen: folgen,
                                       weiterMit: folgen.contains { $0.id == item.id } ? item.id : nil,
                                       amFolge: $amFolge) { folge in
                            starten(folge)
                        }
                        .id(folgen.first?.id ?? "leer")
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // Deutlich Luft zur Staffelpille — sonst klebte die Reihe daran.
                .padding(.top, 44)

                Spacer(minLength: 0)
            }
            // Solange die Staffelwahl offen ist, ist der Rest kein Fokusziel —
            // siehe `SerienView`.
            .disabled(staffelwahlOffen)
            .tafel(unter: staffelwahlOffen && !tafelhandlungen.isEmpty ? "staffel" : nil) {
                Handlungstafel(handlungen: tafelhandlungen, offen: $staffelwahlOffen)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.18), value: staffelwahlOffen)
        }
        .focusSection()
        // **Der Fokus liegt beim Öffnen auf der laufenden Folge.**
        .defaultFocus($amFolge, item.id, priority: .userInitiated)
        .onChange(of: staffelwahlOffen) { _, offen in
            if offen {
                tafelhandlungen = staffelhandlungen
            } else {
                tafelhandlungen = []
                amStaffelpille = true
            }
        }
        .task {
            await Ebenenfokus.legen { if amFolge == nil, !amStaffelpille { amFolge = startfolge } }
            await laden()
        }
    }

    /// Die laufende Folge, sonst die erste der Reihe.
    private var startfolge: String? {
        folgen.contains { $0.id == item.id } ? item.id : folgen.first?.id
    }

    /// Die Staffeln als Handlungstafel — kein `Menu`, wie überall in der App.
    private var staffelhandlungen: [Titelhandlung] {
        staffeln.map { staffel in
            Titelhandlung(symbol: gewaehlteStaffel?.id == staffel.id
                                  ? "checkmark.circle.fill" : "circle",
                          text: "\(staffel.name)") {
                gewaehlteStaffel = staffel
                Task { await folgenLaden(staffelGewechselt: true) }
            }
        }
    }

    /// Erst was der Speicher hat (steht schon aus `init`), dann frisch vom Server.
    private func laden() async {
        guard let serie = Item.vorlaeufigeSerie(zu: item) else { return }
        let frisch = await model.staffeln(serie)
        guard !frisch.isEmpty else { return }
        staffeln = frisch
        if gewaehlteStaffel == nil || !frisch.contains(where: { $0.id == gewaehlteStaffel?.id }) {
            gewaehlteStaffel = Self.passendeStaffel(zu: item, in: frisch)
        }
        let leerGeoeffnet = folgen.isEmpty
        await folgenLaden()
        // Kam die Reihe erst jetzt, gehört der Fokus trotzdem der laufenden Folge.
        if leerGeoeffnet, amFolge == nil, !amStaffelpille, !staffelwahlOffen {
            await Ebenenfokus.legen { amFolge = startfolge }
        }
    }

    private static func passendeStaffel(zu item: Item, in liste: [Item]) -> Item? {
        liste.first { $0.id == item.seasonId }
            ?? liste.first { $0.indexNumber != nil && $0.indexNumber == item.parentIndexNumber }
            ?? liste.first
    }

    /// Überblendet wird nur beim Staffelwechsel; beim Öffnen steht die
    /// Reihe sofort da.
    private func folgenLaden(staffelGewechselt: Bool = false) async {
        guard let serie = item.seriesId else { return }
        let staffel = gewaehlteStaffel?.id
        let geladen = await model.folgen(serie: serie, staffel: staffel)
        // Wer inzwischen eine andere Staffel gewählt hat, bekommt deren Folgen.
        guard staffel == gewaehlteStaffel?.id else { return }
        if staffelGewechselt {
            withAnimation(.easeOut(duration: 0.25)) { folgen = geladen }
        } else {
            // Dieselbe erste Folge heißt dieselbe `id` des Streifens: er wird
            // nicht neu aufgebaut und behält den Fokus.
            folgen = geladen
        }
        if let staffel { Serienspeicher.geteilt.merken(serie) { $0.folgen[staffel] = geladen } }
    }
}
