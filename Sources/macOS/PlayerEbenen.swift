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
    /// **Die Leiter der App, nicht eine eigene.**
    ///
    /// Hier standen Titel 22 und Angabe 14 — der Player war damit der
    /// einzige Ort der Mac-Fassung mit einer zweiten Schriftleiter, und 14
    /// steht in keiner von beiden. Jetzt dieselben Zahlen wie auf dem
    /// iPhone: Titel = Reihenueberschrift (20), Angabe = Angabe (12), Zeit
    /// 13 wie der Kacheltitel — die kleinste Stufe, die ueber Bild noch
    /// sicher lesbar ist.
    let titel: CGFloat = 20
    let meta: CGFloat = 12
    let zeit: CGFloat = 13
    /// Abstand der Überspringen-Pille über der Leiste.
    let ueberLeiste: CGFloat = 20
    /// Trefferfläche des Zeitreglers.
    let leiste: CGFloat = 32
    /// Einzug der Zeilen auf den Ebenen — Spaltentitel, Wahlzeile und
    /// Verzögerung stehen damit auf einer Textkante.
    static let einzug: CGFloat = 10
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
                .background(schwebt ? Stil.schwebeflaeche : .clear,
                            in: RoundedRectangle(cornerRadius: Stil.eckeFeld,
                                                 style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
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
            // Spaltenkopf = Blattrubrik: 17 Semifett mit ihrer Sperrung.
            // 18 Bold stand in keiner Leiter, und Bold steht genau einmal,
            // am Seitentitel (BRAND 2).
            Text(titel)
                .font(Stil.rubrikGross)
                .tracking(Stil.sperrungRubrik)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                .padding(.horizontal, Playermass.einzug)
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
                    .font(Stil.listentitel)
                    .opacity(gewaehlt ? 1 : 0)
                    .frame(width: 17)
                    // Der Haken ist nur Bild; gewählt sagt VoiceOver über
                    // das Merkmal der Zeile.
                    .accessibilityHidden(true)
                // Spurnamen kommen aus der Datei — wörtlich, nicht nachschlagen.
                Text(verbatim: text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // **Ein Gewicht.** Gewaehlt heisst voller Ton, nicht ein
            // zweiter Schnitt — der aendert die Breite (BRAND 5).
            .font(Stil.koerper)
            .foregroundStyle(gewaehlt ? Stil.schrift : Stil.schriftLeise)
            .padding(.horizontal, Playermass.einzug)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(schwebt ? Stil.schwebeflaeche : .clear,
                        in: RoundedRectangle(cornerRadius: Stil.eckeFeld,
                                             style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckzeile())
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
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

/// **Verzögerung — letzte Zeile der Spalten Audio und Untertitel.**
///
/// Gegenstück zu `Verzoegerungszeile` auf iOS (Begründung dort), mit
/// Schwebefläche für den Zeiger und den Maßen des Mac-Players. Über die
/// Tastatur geht es auch ohne Ebene: G/H für Untertitel, J/K für Ton, wie in
/// VLC (`PlayerScreen`).
struct Verzoegerungszeile: View {
    let wert: Verzoegerung
    let mass: Playermass
    let setzen: (Verzoegerung) -> Void
    @State private var halten = Verzoegerung.Haltezaehler()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Verzögerung")
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
                .padding(.horizontal, Playermass.einzug)
            HStack(spacing: 0) {
                Verzugstaste(symbol: "minus", mass: mass, gesperrt: wert.amAnfang) {
                    setzen(wert.verschoben(-1, schritte: halten.druck()))
                }
                Text(verbatim: wert.text())
                    .font(Stil.koerper.monospacedDigit())
                    .foregroundStyle(wert.istNull ? Stil.schriftLeise : Stil.schrift)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                Verzugstaste(symbol: "plus", mass: mass, gesperrt: wert.amEnde) {
                    setzen(wert.verschoben(1, schritte: halten.druck()))
                }
                Verzugstaste(symbol: "arrow.counterclockwise", mass: mass, gesperrt: false,
                             wiederholen: false) { setzen(.null) }
                    .help(Text("Zurücksetzen"))
                    // Platz bleibt stehen, damit − Wert + nicht springen.
                    .opacity(wert.istNull ? 0 : 1)
                    .disabled(wert.istNull)
                    .animation(Stil.umschalten, value: wert.istNull)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Verzögerung"))
        .accessibilityValue(Text(verbatim: wert.text()))
        .accessibilityAdjustableAction { richtung in
            switch richtung {
            case .increment: setzen(wert.verschoben(1))
            case .decrement: setzen(wert.verschoben(-1))
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text("Zurücksetzen")) { setzen(.null) }
    }
}

/// − / + / Zurücksetzen der Verzögerungszeile, mit Schwebefläche wie
/// `Symbolknopf`. Gehalten wiederholt das System.
private struct Verzugstaste: View {
    let symbol: String
    let mass: Playermass
    let gesperrt: Bool
    var wiederholen = true
    let aktion: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: aktion) {
            Image(systemName: symbol)
                .font(.system(size: mass.symbol - 3, weight: .semibold))
                .foregroundStyle(gesperrt ? Stil.schriftSehrLeise : Stil.schrift)
                .frame(width: mass.knopf, height: mass.knopf)
                .background(schwebt && !gesperrt ? Stil.schwebeflaeche : .clear,
                            in: RoundedRectangle(cornerRadius: Stil.eckeFeld, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
        .buttonRepeatBehavior(wiederholen ? .enabled : .disabled)
        .disabled(gesperrt)
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
    }
}

/// Ein Name in der Spalte „Gemeinsam" — eine Auskunft, kein Knopf. In den
/// Maßen der `Ebenenzeile`, damit die Namen mit den Zeilen daneben fluchten.
private struct Teilnehmerzeile: View {
    let name: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "person.fill")
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
                .frame(width: 17)
            // Ein Benutzername vom Server — wörtlich.
            Text(verbatim: name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(Stil.koerper)
        .foregroundStyle(Stil.schrift)
        .padding(.horizontal, Playermass.einzug)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
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
    @State private var tonVerzug: Verzoegerung?
    @State private var untertitelVerzug: Verzoegerung?

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
                    Verzoegerungszeile(wert: tonVerzug ?? flaeche?.tonVerzoegerung ?? .null,
                                       mass: mass) { neu in
                        tonVerzug = neu
                        flaeche?.tonVerzoegerung = neu
                    }
                    .padding(.top, Stil.kachelAbstand)
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
                    Verzoegerungszeile(wert: untertitelVerzug ?? flaeche?.untertitelVerzoegerung ?? .null,
                                       mass: mass) { neu in
                        untertitelVerzug = neu
                        flaeche?.untertitelVerzoegerung = neu
                    }
                    .padding(.top, Stil.kachelAbstand)
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
    /// Nur in einer Gruppe: wer dabei ist, und der Weg hinaus.
    var gemeinsam: Gemeinsammodell? = nil
    var gruppeVerlassen: () -> Void = {}
    let schliessen: () -> Void

    @AppStorage("technikschild") private var technikschild = false
    @AppStorage("bildfuellend") private var bildfuellend = false
    @State private var verlassenSchwebt = false

    var body: some View {
        ZStack(alignment: .top) {
            Ebenengrund()
            Spaltenreihe(mass: mass) {
                // **Gemeinsam zuerst** (Entwurf A): wer dabei ist, und
                // darunter der Ausgang. Die Namen tun nichts.
                if let gemeinsam, let gruppe = gemeinsam.gruppe {
                    Wahlspalte(titel: "Gemeinsam · \(gruppe.name)") {
                        ForEach(Array(gruppe.teilnehmer.enumerated()), id: \.offset) { paar in
                            Teilnehmerzeile(name: paar.element)
                        }
                        Button(action: gruppeVerlassen) {
                            HStack(spacing: 9) {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .font(Stil.listentitel)
                                    .frame(width: 17)
                                Text("Gruppe verlassen")
                            }
                            .font(Stil.koerper)
                            .foregroundStyle(Stil.akzent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(verlassenSchwebt ? Stil.schwebeflaeche : .clear,
                                        in: RoundedRectangle(cornerRadius: Stil.eckeFeld,
                                                             style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(Stil.Druckzeile())
                        .onHover { verlassenSchwebt = $0 }
                        .animation(Stil.zeitSchweben, value: verlassenSchwebt)
                    }
                }
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
                                // Abschlussblock.** Es war einmal nötig, weil
                                // `Folgenzeile` davor `ringtipp` trug und
                                // Swifts Regel für abschliessende Blöcke ihn
                                // dort gebunden hätte. Der Ring ist weg, der
                                // ausgeschriebene Name bleibt: er sagt, was
                                // der Block tut.
                                Folgenzeile(model: model, folge: folge,
                                            aktion: { gewaehlteFolge in starten(gewaehlteFolge) })
                                // `gewaehlt` ist genau dieser Wert — weiss
                                // mit acht Prozent, die Flaeche einer
                                // laufenden Zeile.
                                .background(folge.id == item.id ? Stil.gewaehlt : .clear)
                                // Rechtsklick: das Kachelmenü, im Player nur
                                // mit dem Sehstand (`Kachelmenue.imPlayer`).
                                .kachelmenue(folge, model: model, imPlayer: true,
                                             nachher: { await folgenLaden() })
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
            gewaehlteStaffel = Staffelwahlregel.waehle(aus: gemerkt.staffeln, stand: item)
            if let id = gewaehlteStaffel?.id, let liste = gemerkt.folgen[id] { folgen = liste }
        }
        // `nil` heisst gestoert: dann bleibt stehen, was der Speicher hatte.
        guard let frisch = await model.staffeln(serie), !frisch.isEmpty else { return }
        staffeln = frisch
        if gewaehlteStaffel == nil || !frisch.contains(where: { $0.id == gewaehlteStaffel?.id }) {
            gewaehlteStaffel = Staffelwahlregel.waehle(aus: frisch, stand: item)
        }
        await folgenLaden()
    }

    /// Überblendet wird nur beim Staffelwechsel; beim Öffnen steht die Liste
    /// sofort da.
    private func folgenLaden(staffelGewechselt: Bool = false) async {
        guard let serie = item.seriesId else { return }
        let staffel = gewaehlteStaffel?.id
        // Gescheitert heisst: die Liste bleibt, wie sie war. Sie leer zu
        // setzen hiesse behaupten, die Staffel habe keine Folgen.
        guard let geladen = await model.folgen(serie: serie, staffel: staffel) else { return }
        // Wer inzwischen eine andere Staffel gewählt hat, bekommt deren Folgen.
        guard staffel == gewaehlteStaffel?.id else { return }
        if staffelGewechselt {
            withAnimation(Stil.einblenden) { folgen = geladen }
        } else {
            folgen = geladen
        }
        if let staffel { Serienspeicher.geteilt.merken(serie) { $0.folgen[staffel] = geladen } }
    }
}
