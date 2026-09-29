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
    /// Über dem sicheren Bereich unten. Auf dem iPhone **direkt darauf**: die
    /// Leiste sitzt knapp über dem Home-Indikator, und weil die Trefferfläche
    /// nie in den sicheren Bereich ragt, greift ein Wisch von ganz unten nicht
    /// in den Regler. Bei 12 saß die Leiste zu hoch und sah schwebend aus
    /// (Rückmeldung 29.09.); bei −10 ragte sie in die Home-Zone.
    var unten: CGFloat { pad ? 22 : 0 }
    /// Trefferfläche der Symbolknöpfe.
    let knopf: CGFloat = 44
    var symbol: CGFloat { pad ? 21 : 19 }
    /// **Die Leiter der App, nicht eine eigene.**
    ///
    /// Hier standen bis zum 21.09. vier Werte, die es in `Stil` nicht gibt:
    /// Titel 19 am iPhone und 22 am iPad, Angabe 14 und 15, Zeit 13 und 14.
    /// Der Player war damit der einzige Ort der App mit einer zweiten
    /// Schriftleiter — und 19 und 14 stehen in keiner von beiden.
    ///
    /// Jetzt: Titel = Reihenüberschrift (20), Angabe und Zeit = Angabe (12/13).
    /// Und **ein** Wert je Rolle statt zwei: die Leiter gilt am iPad 1:1 wie am
    /// iPhone (BRAND 2, Spaltenkopf „iPhone · iPad · Mac"). Die Maße darüber —
    /// Rand, Trefferfläche, Symbolgrad — spalten sich weiter, denn die hängen
    /// am Gerät und nicht an der Schrift.
    let titel: CGFloat = 20
    let meta: CGFloat = 12
    /// Laufzeit links und rechts der Leiste. 13, wie der Kacheltitel — die
    /// kleinste Stufe, die über Bild noch sicher lesbar ist.
    let zeit: CGFloat = 13
    /// Abstand der Überspringen-Pille über der Leiste.
    let ueberLeiste: CGFloat = 20
    /// Höhe der Zeitzeile — die Trefferfläche des Reglers.
    let leiste: CGFloat = 44
    /// Um so viel ragt die Trefferfläche des Reglers **nach oben** über die
    /// Zeitzeile hinaus — nach unten nie.
    let reglerOben: CGFloat = 16
    /// Einzug der Zeilen auf den Ebenen — Spaltentitel, Wahlzeile und
    /// Verzögerung stehen damit auf einer Textkante.
    static let einzug: CGFloat = 10
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
        .buttonStyle(Stil.Druckknopf())
        .accessibilityLabel(Text(beschriftung))
    }
}

/// **Grund jeder Ebene:** reines Schwarz mit 0,72. Nimmt jeden Tipp an, damit
/// darunter nichts spult.
private struct Ebenengrund: View {
    var body: some View {
        // **Weichzeichner und Schwarz darueber — beides.**
        //
        // Der Weichzeichner war einen Tag lang weg, mit zwei Begruendungen.
        // Die eine war falsch: „im Player gilt reines Schwarz" meint den
        // **Schleier ueber dem laufenden Bild**, wo ein Material ueber HDR
        // anhebt. Eine Ebene laeuft nicht, sie steht — und hinter ihr soll man
        // sehen, dass der Film noch da ist. Die andere stimmte: unter 0,72
        // Schwarz war vom Weichzeichner nichts mehr zu sehen, er kostete nur
        // Rechenzeit.
        //
        // Also beides, mit passenden Anteilen: das Material traegt, und die
        // Abdunklung darueber ist auf 0,45 zurueck — genug, damit die
        // Spaltentitel stehen, wenig genug, dass der Weichzeichner sichtbar
        // wird. Rückmeldung vom 22.09.: „auf iOS gibt es ja den Blur, den hatten wir
        // schon, den einfach wieder reinnehmen."
        ZStack {
            // **Ueber den Rand hinaus.** Ein Weichzeichner, der am
            // Bildschirmrand endet, holt sich dort Leere dazu: die Ecken
            // blitzten beim Einblenden hell auf. Groesser gezogen liegt die
            // Kante ausserhalb des Bildschirms.
            Unschaerfe(staerke: 1)
                .padding(-60)
            Color.black.opacity(0.45)
        }
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
                // Genau der Grad des Player-Titels — er rechnet mit der
                // Fenstergröße. Vorher standen dieselben Zahlen von Hand hier
                // (22/19); eine Rolle mit zwei Quellen läuft irgendwann
                // auseinander.
                // Semifett, nicht Bold: 20 ist die Reihenueberschrift, und
                // Bold steht genau einmal — am Seitentitel (BRAND 2).
                .font(.system(size: mass.titel, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                // Vorher rohes `.white`; gelesen wird `schrift`.
                .foregroundStyle(Stil.schrift)
                .padding(.horizontal, Playermass.einzug)
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

/// Haken und Name. Gewählt `Stil.schrift` und halbfett, sonst
/// `Stil.schriftLeise`. Hier stand „62 % Weiß" — über einem Bild ist eine
/// Deckkraft keine Schriftfarbe, sie wird mit der Szene heller und dunkler.
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
                    .accessibilityHidden(true)
                // Spurnamen kommen aus der Datei — wörtlich, nicht nachschlagen.
                Text(verbatim: text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // **Ein Grad, ein Gewicht.**
            //
            // Hier stand `pad ? 17 : 15` und dazu `gewaehlt ? .semibold :
            // .regular`. Der erste Teil war eine zweite Leiter — 15 ist die
            // Listenzeile, am iPad wie am iPhone (BRAND 2). Der zweite war
            // schlimmer: die Spalte ist 210 Punkt breit und die Zeile traegt
            // `lineLimit(1)`, also **kuerzte ein langer Spurname beim
            // Auswaehlen mehr als vorher**. Gewaehlt sagt jetzt der Ton.
            .font(Stil.listentitel)
            .foregroundStyle(gewaehlt ? Stil.schrift : Stil.schriftLeise)
            // Der Haken wandert weich von Zeile zu Zeile, statt zu springen.
            .animation(Stil.umschalten, value: gewaehlt)
            .padding(.horizontal, Playermass.einzug)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckzeile())
        .clipShape(RoundedRectangle(cornerRadius: Stil.eckeFeld, style: .continuous))
        .accessibilityAddTraits(gewaehlt ? .isSelected : [])
    }
}

/// Ein Name in der Spalte „Gemeinsam" — eine Auskunft, kein Knopf.
private struct Teilnehmerzeile: View {
    let name: String
    let mass: Playermass

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .font(.system(size: mass.pad ? 15 : 14))
                .foregroundStyle(Stil.schriftSehrLeise)
                .frame(width: 18)
            // Ein Benutzername vom Server — wörtlich.
            Text(verbatim: name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(Stil.listentitel)
        .foregroundStyle(Stil.schriftLeise)
        .padding(.horizontal, Playermass.einzug)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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

/// **Verzögerung — letzte Zeile der Spalten Audio und Untertitel.**
///
/// Kein eigener Knopf in der Leiste: wer eine Spur verschiebt, hat gerade
/// die Spur gewählt, und genau dort steht die Zeile. − und + schieben um
/// 50 ms, gehalten wiederholen sie und werden schneller
/// (`Verzoegerung.Haltezaehler`); das Rund-Pfeil-Symbol setzt auf null.
/// Für VoiceOver ist die Zeile ein Element, das man nach oben und unten
/// wischt.
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
                taste("minus", richtung: -1, gesperrt: wert.amAnfang)
                Text(verbatim: wert.text())
                    .font(Stil.listentitel.monospacedDigit())
                    .foregroundStyle(wert.istNull ? Stil.schriftLeise : Stil.schrift)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                taste("plus", richtung: 1, gesperrt: wert.amEnde)
                Button { setzen(.null) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: mass.symbol - 3, weight: .medium))
                        .foregroundStyle(Stil.schriftLeise)
                        .frame(width: mass.knopf, height: mass.knopf)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Stil.Druckknopf())
                // Platz bleibt stehen, damit − Wert + beim Zurücksetzen nicht
                // seitlich springen.
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

    private func taste(_ symbol: String, richtung: Int, gesperrt: Bool) -> some View {
        Button {
            setzen(wert.verschoben(richtung, schritte: halten.druck()))
        } label: {
            Image(systemName: symbol)
                .font(.system(size: mass.symbol - 2, weight: .semibold))
                .foregroundStyle(gesperrt ? Stil.schriftSehrLeise : Stil.schrift)
                .frame(width: mass.knopf, height: mass.knopf)
                .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
        // Gehalten wiederholt das System; schneller wird es über den Zähler.
        .buttonRepeatBehavior(.enabled)
        .disabled(gesperrt)
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
    /// Wie bei der Spurwahl: was eingestellt wurde, wissen wir selbst —
    /// die Fläche ist keine beobachtete Größe.
    @State private var tonVerzug: Verzoegerung?
    @State private var untertitelVerzug: Verzoegerung?

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
                    Verzoegerungszeile(wert: tonVerzug ?? surface?.tonVerzoegerung ?? .null,
                                       mass: mass) { neu in
                        tonVerzug = neu
                        surface?.tonVerzoegerung = neu
                    }
                    .padding(.top, Stil.kachelAbstand)
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
                    Verzoegerungszeile(wert: untertitelVerzug ?? surface?.untertitelVerzoegerung ?? .null,
                                       mass: mass) { neu in
                        untertitelVerzug = neu
                        surface?.untertitelVerzoegerung = neu
                    }
                    .padding(.top, Stil.kachelAbstand)
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
    /// Nur in einer Gruppe: wer dabei ist, und der Weg hinaus.
    var gemeinsam: Gemeinsammodell? = nil
    var gruppeVerlassen: () -> Void = {}
    let schliessen: () -> Void

    @AppStorage("technikschild") private var technikschild = false
    @AppStorage("bildfuellend") private var bildfuellend = false

    var body: some View {
        ZStack(alignment: .top) {
            Ebenengrund()
            Spaltenreihe(mass: mass) {
                // **Gemeinsam zuerst** (Entwurf A, Schritt 5): wer dabei ist,
                // und darunter der Ausgang. Die Namen tun nichts.
                if let gemeinsam, let gruppe = gemeinsam.gruppe {
                    Wahlspalte(titel: "Gemeinsam · \(gruppe.name)", mass: mass) {
                        ForEach(Array(gruppe.teilnehmer.enumerated()), id: \.offset) { paar in
                            Teilnehmerzeile(name: paar.element, mass: mass)
                        }
                        Button(action: gruppeVerlassen) {
                            HStack(spacing: 8) {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 18)
                                Text("Gruppe verlassen")
                            }
                            .font(Stil.listentitel)
                            .foregroundStyle(Stil.akzent)
                            .padding(.horizontal, Playermass.einzug)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(Stil.Druckzeile())
                        .clipShape(RoundedRectangle(cornerRadius: Stil.eckeFeld, style: .continuous))
                    }
                }
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
        let staffel = Staffelwahlregel.waehle(aus: gemerkt.staffeln, stand: item)
        _staffeln = State(initialValue: gemerkt.staffeln)
        _gewaehlteStaffel = State(initialValue: staffel)
        _folgen = State(initialValue: staffel.flatMap { gemerkt.folgen[$0.id] } ?? [])
    }

    /// Staffeln und die Folgen der laufenden Staffel in den Speicher —
    /// aufgerufen, sobald der Player eine Folge zeigt.
    static func vorladen(model: AppModel, item: Item) async {
        guard let serieID = item.seriesId, let serie = Item.vorlaeufigeSerie(zu: item) else { return }
        // **Ein gescheiterter Abruf kommt nicht in den Speicher.** `staffeln`
        // und `folgen` geben seit dem 21.09.2026 `nil` zurueck, wenn der
        // Server geschwiegen hat. Frueher stand dann eine leere Liste im
        // `Serienspeicher`, und die naechste Ansicht hielt sie fuer die
        // Wahrheit — ein zwischengespeicherter Netzfehler.
        guard let staffeln = await model.staffeln(serie), !staffeln.isEmpty else { return }
        Serienspeicher.geteilt.merken(serieID) { $0.staffeln = staffeln }
        guard let staffel = Staffelwahlregel.waehle(aus: staffeln, stand: item) else { return }
        guard let folgen = await model.folgen(serie: serieID, staffel: staffel.id) else { return }
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
                            .font(.system(size: mass.titel, weight: .semibold))
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
                                          hoehe: 28,
                                          // Im Player keine Flaeche: sie sitzt dort an
                                          // Stelle der Metazeile, und die traegt keine.
                                          alsFeld: false)
                        }
                    }
                }
                // Die aufgeklappte Staffelliste liegt über den Folgen.
                .zIndex(1)

                ScrollViewReader { leser in
                    ScrollView {
                        // Lazy: eine Staffel mit vielen Folgen baute sonst
                        // jede Zeile samt Standbild schon beim Öffnen.
                        LazyVStack(spacing: 0) {
                            ForEach(folgen) { folge in
                                Button { starten(folge) } label: {
                                    // Die laufende Folge traegt ein groesseres
                                    // Bild, keine Flaeche — die lief hier ueber
                                    // die volle Breite und machte die Dynamic
                                    // Island sichtbar. Begruendung an
                                    // `Folgenzeile.laufend`.
                                    Folgenzeile(model: model, folge: folge,
                                                laufend: folge.id == item.id)
                                }
                                // Eine Zeile drückt wie eine Zeile: Fläche
                                // statt Maßstab. Vorher `Druckknopf` — der zog
                                // das ganze Standbild auf 0,97, und in einer
                                // Liste sieht das nach Verrutschen aus. So hält
                                // es auch `Wischzeile` auf der Serienseite.
                                .buttonStyle(Stil.Druckzeile())
                                // Langer Druck: das Kachelmenü, im Player nur
                                // mit dem Sehstand (`Kachelmenue.imPlayer`).
                                .kachelmenue(folge, model: model, quer: true, imPlayer: true,
                                             nachher: { await folgenLaden() })
                                .accessibilityAddTraits(folge.id == item.id ? .isSelected : [])
                                .id(folge.id)
                                .transition(.opacity)
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .scrollIndicators(.hidden)
                    // **Die laufende Folge in Sicht**, sobald die Liste steht.
                    // Beim Öffnen steht sie gleich dort; kommt die Liste
                    // später (Server, Staffelwechsel), gleitet sie hin —
                    // mit reduzierter Bewegung springt sie.
                    .onChange(of: folgen.map(\.id), initial: true) { alt, ids in
                        guard ids.contains(item.id) else { return }
                        if alt == ids || alt.isEmpty || Stil.bewegungReduziert {
                            leser.scrollTo(item.id, anchor: .center)
                        } else {
                            withAnimation(.smooth(duration: 0.35)) {
                                leser.scrollTo(item.id, anchor: .center)
                            }
                        }
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

    /// Überblendet wird nur beim Staffelwechsel; beim Öffnen steht die
    /// Liste sofort da.
    private func folgenLaden(staffelGewechselt: Bool = false) async {
        guard let serie = item.seriesId else { return }
        let staffel = gewaehlteStaffel?.id
        // Gescheitert heisst: die Liste bleibt, wie sie war. Sie leer zu
        // setzen hiesse behaupten, die Staffel habe keine Folgen.
        guard let geladen = await model.folgen(serie: serie, staffel: staffel) else { return }
        // Wer inzwischen eine andere Staffel gewählt hat, bekommt deren Folgen.
        guard staffel == gewaehlteStaffel?.id else { return }
        if staffelGewechselt {
            // Die neue Staffel blendet ein, statt hart dazustehen.
            // Inhalt, der ankommt, blendet in 0,28 ein (BRAND 6). Vorher
            // easeOut 0,25 — dieselbe Absicht, eine eigene Zahl.
            withAnimation(Stil.einblenden) { folgen = geladen }
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
