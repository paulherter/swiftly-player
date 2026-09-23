import JellyfinKit
import OSLog
import SwiftUI

/// Die Bausteine für den Mac. Keine Apple-Standardsteuerelemente — kein
/// `List`, `Toggle`, `Picker`, `Menu`, `Slider`. Dieselbe Regel wie auf iPhone
/// und Fernseher, aus demselben Grund: sie bringen eigene Maße, eigene Ecken
/// und eigenes Material mit.
///
/// Neu gegenüber den anderen Plattformen ist nur eines: der **Schwebezustand**.
/// Ein Zeiger steht über einer Fläche, bevor er sie anklickt — dieser Zustand
/// existiert weder auf dem iPhone noch mit einer Fernbedienung.

// MARK: - Seitenleiste

/// Eine Zeile in der Seitenleiste. Tritt an die Stelle der Leiste unten:
/// dort war der Daumen die Grenze, hier die Fensterhöhe.
struct Seitenleistenzeile: View {
    let symbol: String
    var beschriftung: LocalizedStringKey = ""
    /// Für Zeilen, deren Text vom Server kommt — der Name einer Bibliothek
    /// ist keine Beschriftung aus dem Katalog. Als `LocalizedStringKey`
    /// übergeben, würde „Filme" als Schlüssel nachgeschlagen und ein
    /// englischer Nutzer bekäme dort etwas anderes zu lesen.
    var name: String?
    let aktiv: Bool
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(Stil.koerper.weight(.medium))
                    .frame(width: 17)
                Group {
                    if let name { Text(verbatim: name) } else { Text(beschriftung) }
                }
                .font(Stil.koerper.weight(.medium))
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: Stil.zeileHoehe)
            .foregroundStyle(vordergrund)
            .background(hintergrund,
                        in: RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckzeile())
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .accessibilityAddTraits(aktiv ? [.isButton, .isSelected] : .isButton)
    }

    private var vordergrund: Color {
        if aktiv { return Stil.akzent }
        return schwebt ? Stil.schrift : Stil.schriftLeise
    }

    /// Der Akzent trägt Auswahl — das ist dieselbe Regel wie auf iOS, wo der
    /// aktive Bereich der Leiste ihn ebenfalls trägt. Der Schwebezustand
    /// bekommt bewusst nur Weiß: er zeigt „hier steht der Zeiger", keine Wahl.
    private var hintergrund: Color {
        if aktiv { return Stil.akzent.opacity(0.10) }
        return schwebt ? Stil.schwebeflaeche : .clear
    }
}

/// Überschrift einer Gruppe in der Seitenleiste.
struct Seitenleistenrubrik: View {
    let text: LocalizedStringKey
    var body: some View {
        // **Normalschreibung, nicht Versalien.** Gesperrt wird nur, was in
        // Versalien steht (BAUTEILE 2) — und die fallen mit ihnen weg: sie
        // lesen sich schlechter, brauchen die Sperrung erst, um ueberhaupt
        // lesbar zu sein, und VoiceOver buchstabiert sie je nach Wort.
        // macOS setzt seine Seitenleistenrubriken seit Jahren genauso: 11
        // Semifett, gedaempft, normal geschrieben.
        Text(text)
            .font(Stil.gruppe)
            .foregroundStyle(Stil.schriftSehrLeise)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Chip

/// Filter- und Sortierchip. Aktiv ist er weiß mit schwarzer Schrift — dieselbe
/// Form wie der Hauptknopf, eine Nummer kleiner.
struct Chip: View {
    let beschriftung: String
    var symbol: String?
    let aktiv: Bool
    /// Countdown im Player: die Uhr der Füllung von links (`Fuellungsuhr`).
    var fuellung: Fuellungsuhr? = nil
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                // **Ein Gewicht, nicht zwei.** Semifett ist breiter als
                // Regular, und die Chips stehen waagerecht nebeneinander:
                // beim Umschalten verschob sich jeder Nachbar rechts davon.
                // 13 Medium gilt in beiden Zustaenden (BRAND 5).
                Text(beschriftung).font(Stil.kachel)
            }
            .padding(.horizontal, 13)
            // **30, nicht 28** — Pillen und Chips sind 30 hoch (BAUTEILE 6).
            .frame(height: 30)
            .foregroundStyle(aktiv ? Stil.schrift : Stil.schriftLeise)
            // **Kein zweiter Hauptknopf, und kein gezeichneter Rand.**
            //
            // Gewaehlt war hier `Stil.schrift` als Flaeche mit `grund` als
            // Schrift — Zeichen fuer Zeichen der Hauptknopf, und auf der
            // Bibliotheksseite stehen mehrere Chips nebeneinander. BRAND 5
            // laesst genau eine vollflaechig gefuellte Sache je Seite zu.
            // Gewaehlt ist jetzt eine Stufe der Leiter hoeher plus volle
            // Schrift; keines von beiden aendert ein Mass.
            .background {
                ZStack {
                    Capsule().fill(aktiv ? Stil.erhoeht : Stil.flaeche)
                    if let fuellung {
                        // Durchgehend aus der Uhr, in Akzentfarbe halb
                        // deckend — wie auf iOS (17.09.2026).
                        TimelineView(.animation) { zeit in
                            GeometryReader { g in
                                Rectangle()
                                    .fill(Stil.akzent.opacity(0.5))
                                    .frame(width: g.size.width * fuellung.anteil(jetzt: zeit.date))
                            }
                        }
                        .clipShape(Capsule())
                    }
                    // Der Schwebezustand: Flaeche weiss 6 % (BRAND 5). Er
                    // sagt „hier steht der Zeiger", nicht „gewaehlt".
                    if schwebt { Capsule().fill(Stil.schwebeflaeche) }
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(Stil.Druckknopf())
        .help(beschriftung)
        .accessibilityLabel(beschriftung)
        .accessibilityAddTraits(aktiv ? [.isButton, .isSelected] : .isButton)
        .onHover { schwebt = $0 }
        .animation(Stil.umschalten, value: aktiv)
        .animation(Stil.zeitSchweben, value: schwebt)
    }
}

// MARK: - Knöpfe

/// Der eine Hauptknopf je Seite: weiß, schwarze Schrift, 48 hoch.
///
/// Auf dem iPhone läuft er über die volle Breite. Hier nicht — die Breite war
/// eine Antwort auf den Daumen, und der Zeiger trifft auch einen schmalen
/// Knopf. Ein 1200 Punkt breiter Knopf sähe zudem aus wie ein Versehen.
struct Hauptknopf: View {
    let beschriftung: LocalizedStringKey
    var symbol: String = "play.fill"
    var kuerzel: String?
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            HStack(spacing: 9) {
                // **17 Semifett.** 16 steht in keiner Leiter; 17 ist die
                // Stufe der Blattrubrik, und ein Hauptknopf ist mindestens
                // so laut (BAUTEILE 6).
                Image(systemName: symbol).font(Stil.rubrikGross)
                Text(beschriftung).font(Stil.rubrikGross)
                if let kuerzel {
                    Text(kuerzel)
                        .font(Stil.kachel)
                        .foregroundStyle(Stil.aufAkzent.opacity(0.45))
                }
            }
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity)
            .frame(height: Stil.hauptknopfHoehe)
            // Schrift auf einer gefuellten Flaeche hat einen eigenen Ton.
            .foregroundStyle(Stil.aufAkzent)
            .background(schwebt ? Stil.hauptknopfSchwebt : Stil.schrift,
                        in: RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
            .contentShape(Rectangle())
        }
        // **Auch der Hauptknopf antwortet auf den Druck.** Er kannte nur den
        // Schwebezustand und war damit der einzige Knopf ohne Rueckmeldung
        // (BRAND 5: „an jedem Knopf").
        .buttonStyle(Stil.Druckknopf())
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
    }
}

/// Runder Aktionsknopf neben dem Hauptknopf — Merkliste, Trailer, Gesehen, Mehr.
///
/// Der `titel` steht nicht im Bild, sondern ist der Name für VoiceOver (E8).
/// Ein Knopf, der nur ein Symbol trägt, heißt sonst „Taste" und sonst nichts.
struct Aktionsknopf: View {
    /// **Das Mass, weil eine Reihe es vorgibt.**
    ///
    /// Neben dem Hauptknopf tragen alle Felder dessen Hoehe — „alle Felder
    /// einer Reihe tragen dieselben Masse" (BRAND 7). In einer Folgenzeile
    /// ist es das kleinere Feld. Zwei Werte, ein Baustein: `Nebenknopf` war
    /// derselbe Knopf ein zweites Mal, nur 48 statt 40 gross.
    var mass: CGFloat = Stil.knopfFeld
    let symbol: String
    var titel: LocalizedStringKey?
    var aktiv: Bool = false
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            // **Ein Feld, kein Kreis mit Umriss, und keine weisse
            // Fuellung.** Ein Knopf ohne Beschriftung ist quadratisch
            // (BRAND 7); er traegt eine Flaeche statt einer gezeichneten
            // Kante, und der eine vollflaechig gefuellte Gegenstand der Seite
            // bleibt der Hauptknopf (BRAND 5). Aktiv heisst deshalb Akzent
            // an der Schrift, nicht Weiss unter ihr.
            Image(systemName: symbol)
                .font(Stil.rubrikGross)
                .frame(width: mass, height: mass)
                .foregroundStyle(aktiv ? Stil.akzent : Stil.schrift)
                .background {
                    let form = RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous)
                    ZStack {
                        form.fill(Stil.flaeche)
                        if schwebt { form.fill(Stil.schwebeflaeche) }
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .accessibilityLabel(titel.map { Text($0) } ?? Text(verbatim: symbol))
        .accessibilityAddTraits(aktiv ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Kacheln

/// **`auswahl` ist wahlweise.** Ohne sie zeichnet die Kachel sich nur, ohne
/// eigenen Knopf — dann kann sie als Beschriftung in einem `NavigationLink`
/// stehen. Ein Knopf **in** einem Knopf schluckt den Klick: der innere nimmt
/// ihn an und tut nichts, der äußere erfährt nie davon. Genau daran waren
/// sämtliche Wege auf die Detailseiten tot.
///
/// Poster, 2 : 3. Beim Schweben vergrößert es sich leicht — **keine
/// Akzentumrandung:** der Akzent trägt Fortschritt, Auswahl und den
/// Direct-Play-Beleg (E2), und „hier steht der Zeiger" ist keine Auswahl.
struct Posterkachel: View {
    let titel: String
    let zweitzeile: String?
    let bild: URL?
    var fortschritt: Double?
    /// Was oben rechts steht: gesehen, offene Folgen, Staffelzahl.
    ///
    /// **Drei Zustände, drei Zeichen** (GESTALTUNG, Abschnitt H). Bis hierher
    /// gab es nur den Balken — und bei einer Serie sagt der gar nichts, weil
    /// er den Stand der angefangenen *Folge* zeigt und nicht den der Serie.
    /// Welche Auskunft gilt, entscheidet `Anzeigeregeln.kachelmarke`.
    var marke: Kachelmarke?
    /// Zeichen für den Fall, dass der Server kein Bild hat.
    var zeichen: String?
    var auswahl: (() -> Void)?
    /// `nil`, wenn es keine Übersicht dazu gibt (A6).
    var uebersicht: (() -> Void)?
    /// Wird beim Überfahren gerufen — siehe `Serienspeicher.vorholen(_:mit:)`.
    var vorholen: (() -> Void)?
    /// **Nur für eine Sammlungskachel ohne eigenes Bild:** woraus das
    /// Ersatzplakat (`Sammlungsmosaik`) gebaut wird. Überall sonst `nil`, und
    /// es steht genau das Plakat wie vorher.
    var mosaik: (model: AppModel, sammlung: Sammlung, art: String)? = nil

    @State private var schwebt = false {
        didSet { if schwebt, !oldValue { vorholen?() } }
    }
    /// Plakat und Text blenden **zusammen** ein. Das Bild blendet von selbst
    /// ein, der Titel stünde sofort da — beim Wechsel sähe man erst die
    /// Beschriftungen und dann die Plakate hineinlaufen.
    @State private var da = false

    var body: some View {
        Kachelhuelle(auswahl: auswahl, schwebt: $schwebt,
                     name: [titel, zweitzeile].compactMap { $0 }.joined(separator: ", ")) {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let mosaik {
                        Sammlungsmosaik(model: mosaik.model, sammlung: mosaik.sammlung,
                                        art: mosaik.art)
                    } else {
                        Bildflaeche(bild: bild, breite: Stil.kachelBreite, hoehe: Stil.kachelHoehe,
                                    fortschritt: fortschritt, zeichen: zeichen)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let marke { Kachelplakette(marke: marke) }
                }
                .scaleEffect(schwebt ? 1.04 : 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: titel)
                        .font(Stil.kachelTitel)
                        .foregroundStyle(Stil.schrift)
                        .lineLimit(1)
                    if let zweitzeile {
                        Text(verbatim: zweitzeile)
                            .font(Stil.zweitzeile)
                            .foregroundStyle(Stil.schriftLeise)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: Stil.kachelBreite, alignment: .leading)
        }
        .opacity(da ? 1 : 0)
        .onAppear {
            guard !da else { return }
            withAnimation(Stil.einblenden) { da = true }
        }
        .kontextmenue(uebersicht)
    }
}

/// Querkachel, 16 : 9 — nur für „Weiterschauen" und „Nächste Folge".
///
/// Ein Klick startet sofort (A1/A2). Der Weg zur Übersicht führt über die
/// rechte Maustaste (A6).
struct Querkachel: View {
    let titel: String
    let zweitzeile: String?
    let bild: URL?
    var fortschritt: Double?
    /// Zeichen für den Fall, dass der Server kein Bild hat.
    var zeichen: String?
    var auswahl: (() -> Void)?
    var uebersicht: (() -> Void)?
    /// Wird beim Überfahren gerufen — siehe `Serienspeicher.vorholen(_:mit:)`.
    var vorholen: (() -> Void)?

    @State private var schwebt = false {
        didSet { if schwebt, !oldValue { vorholen?() } }
    }

    var body: some View {
        Kachelhuelle(auswahl: auswahl, schwebt: $schwebt,
                     name: [titel, zweitzeile].compactMap { $0 }.joined(separator: ", ")) {
            VStack(alignment: .leading, spacing: 8) {
                Bildflaeche(bild: bild, breite: Stil.querBreite, hoehe: Stil.querHoehe,
                            fortschritt: fortschritt, zeichen: zeichen)
                    .scaleEffect(schwebt ? 1.04 : 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: titel)
                        .font(Stil.kachelTitel).foregroundStyle(Stil.schrift).lineLimit(1)
                    if let zweitzeile {
                        Text(verbatim: zweitzeile)
                            .font(Stil.zweitzeile).foregroundStyle(Stil.schriftLeise).lineLimit(1)
                    }
                }
            }
            .frame(width: Stil.querBreite, alignment: .leading)
        }
        .kontextmenue(uebersicht)
    }
}

/// Die Hülle beider Kacheln: Knopf nur, wenn es einen eigenen Klick gibt.
private struct Kachelhuelle<Inhalt: View>: View {
    let auswahl: (() -> Void)?
    @Binding var schwebt: Bool
    let name: String
    @ViewBuilder let inhalt: Inhalt

    var body: some View {
        Group {
            if let auswahl {
                Button(action: auswahl) { inhalt.contentShape(Rectangle()) }
                    .buttonStyle(Stil.Druckknopf())
            } else {
                inhalt.contentShape(Rectangle())
            }
        }
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(.isButton)
    }
}

/// Das Kontextmenü einer Kachel: der Weg zur Übersicht (A6).
///
/// `.contextMenu` ist Systemchrom, das nur beim Rechtsklick erscheint und
/// nichts in die Fläche einbringt — anders als `Menu`, das als Steuerelement
/// im Aufbau stünde.
extension View {
    @ViewBuilder
    func kontextmenue(_ uebersicht: (() -> Void)?) -> some View {
        if let uebersicht {
            contextMenu {
                Button("Übersicht öffnen", systemImage: "info.circle", action: uebersicht)
            }
        } else {
            self
        }
    }
}

/// Die Bildfläche einer Kachel samt Fortschritt.
///
/// Der Fortschritt liegt **in** der Maske, nicht als Auflage darüber — sonst
/// stehen seine eckigen Enden über die runden Ecken hinaus. Das ist einer der
/// Stolpersteine, die auf iOS schon einmal bezahlt wurden.
struct Bildflaeche: View {
    let bild: URL?
    let breite: CGFloat
    let hoehe: CGFloat
    var fortschritt: Double?

    /// Einstellungen → Darstellung. Siehe `EnvironmentValues.fortschrittAufKacheln`.
    @Environment(\.fortschrittAufKacheln) private var balkenZeigen
    /// Zeichen für den Fall, dass der Server kein Bild hat.
    var zeichen: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            Stil.flaeche
            // **Die Kachel kennt ihre Groesse, also sagt sie sie.** Ohne die
            // Angabe wird jedes Bild auf 1600 Punkt Kante entschluesselt.
            Netzbild(url: bild, zeichen: zeichen, anzeigekante: max(breite, hoehe))
            if let fortschritt, fortschritt > 0, balkenZeigen {
                GeometryReader { raum in
                    ZStack(alignment: .leading) {
                        // **Die Spur ist hell** (weiss 30 %), der Balken
                        // traegt den Akzent. Gelesen heisst die dunkle Spur
                        // „hier fehlt etwas", die helle „so lang ist das
                        // Ganze, und so weit bist du" (BRAND 7).
                        Rectangle().fill(Color.white.opacity(0.3))
                        Rectangle().fill(Stil.akzent)
                            .frame(width: raum.size.width * min(max(fortschritt, 0), 1))
                    }
                }
                // 4, nicht 3 — dasselbe Mass wie auf dem iPhone.
                .frame(height: 4)
            }
        }
        .frame(width: breite, height: hoehe)
        .clipShape(RoundedRectangle(cornerRadius: Stil.eckeKachel, style: .continuous))
    }
}

// MARK: - Platzhalter statt Ladering

/// Eine Fläche in der Form dessen, was gleich kommt.
///
/// **Warum kein drehender Ring.** Ein Ring sagt „warte"; ein Platzhalter
/// sagt, *was* kommt und wie viel — die Seite steht schon, sie ist nur noch
/// leer. GESTALTUNG, Abschnitt G.
///
/// Das Pulsieren läuft über `.opacity` mit `repeatForever`: das übernimmt
/// Core Animation und rechnet auf dem Renderserver weiter, ohne dass SwiftUI
/// je Bild etwas neu bauen muss.
struct Ladefeld: View {
    var ecke: CGFloat = Stil.eckeKachel
    @State private var hell = false

    var body: some View {
        RoundedRectangle(cornerRadius: ecke, style: .continuous)
            .fill(Stil.flaeche)
            // **Der Puls faellt bei reduzierter Bewegung weg.** Er lief
            // hier ohne Rueckfrage — und hundertfuenfzig Zeilen weiter
            // unten macht dieselbe Datei es im `Leerzustand` richtig.
            // „Nichts bewegt sich dekorativ" (BRAND 6), und ein dauernder
            // Puls ist genau das.
            .opacity(hell ? 1 : 0.5)
            .onAppear {
                guard !Stil.bewegungReduziert else { hell = true; return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    hell = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// Ein Plakat mit zwei Textzeilen darunter, alles als Platzhalter.
struct Kachelplatzhalter: View {
    var breite: CGFloat = Stil.kachelBreite

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Ladefeld()
                .frame(width: breite, height: breite * 1.5)
            Ladefeld(ecke: 3).frame(width: breite, height: 12)
            Ladefeld(ecke: 3).frame(width: 48, height: 10)
        }
    }
}

/// Ein Raster aus Plakat-Platzhaltern.
struct Rasterplatzhalter: View {
    let spalten: Int
    var reihen: Int = 3

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Stil.kachelAbstand),
                                 count: max(spalten, 1)),
                  alignment: .leading, spacing: 20) {
            ForEach(0 ..< (max(spalten, 1) * reihen), id: \.self) { _ in
                Kachelplatzhalter(breite: Stil.kachelBreite)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lädt")
    }
}

/// Eine Reihe aus Plakat-Platzhaltern, für die Startseite.
struct Reihenplatzhalter: View {
    var quer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Ladefeld(ecke: 4).frame(width: 168, height: 20)
            HStack(spacing: Stil.kachelAbstand) {
                ForEach(0 ..< 5, id: \.self) { _ in
                    Ladefeld()
                        .frame(width: quer ? Stil.kachelBreite * 2 : Stil.kachelBreite,
                               height: quer ? Stil.kachelBreite * 1.125 : Stil.kachelBreite * 1.5)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lädt")
    }
}

/// Wie viele Titel in dieser Bibliothek liegen.
///
/// **Eine Angabe, keine Handlung** — also leise Schrift und kein Kasten. Sie
/// beantwortet „bin ich hier durch?"; ohne sie scrollt man ins Ungewisse.
struct Zaehlmarke: View {
    let anzahl: Int

    var body: some View {
        Text(verbatim: anzahl.formatted())
            .font(Stil.kachel)
            .monospacedDigit()
            .foregroundStyle(Stil.schriftSehrLeise)
            .accessibilityLabel(Text("\(anzahl) Titel"))
    }
}

/// Die Plakette oben rechts auf einer Kachel.
///
/// **In Weiss auf Dunkel, nicht in Akzent** — der Akzent trägt Fortschritt
/// und Auswahl; eine Plakette ist eine Angabe. Welche Auskunft draufsteht,
/// entscheidet `Anzeigeregeln.kachelmarke` im Paket.
struct Kachelplakette: View {
    let marke: Kachelmarke

    var body: some View {
        // **10 Semifett, gesperrt** — die Stufe der Plakette (BAUTEILE 2).
        // 11 und ein fettes Haekchen standen in keiner Leiter; drei Gewichte
        // gibt es, und `.bold` ist keins davon.
        HStack(spacing: 3) {
            if marke == .gesehen {
                Image(systemName: "checkmark").font(Stil.plakette)
            }
            if let text = wortlaut {
                Text(verbatim: text).font(Stil.plakette).tracking(Stil.plaketteSperrung)
            }
        }
        .foregroundStyle(Stil.schrift)
        .padding(.horizontal, wortlaut == nil ? 5 : 6)
        .padding(.vertical, 3)
        .background {
            // Der Rand bleibt: eine Marke liegt auf einem Plakat, und dort
            // ist sie eine der wenigen Stellen, die wirklich eine Kante
            // brauchen (BAUTEILE 6).
            let form = RoundedRectangle(cornerRadius: 9, style: .continuous)
            form.fill(Stil.grund.opacity(0.78)).overlay { form.strokeBorder(Stil.rand) }
        }
        .padding(6)
    }

    private var wortlaut: String? {
        switch marke {
        case .gesehen: nil
        case .offen(let n): String(localized: "\(n) offen")
        case .staffeln(let n): n == 1 ? String(localized: "1 Staffel")
                                      : String(localized: "\(n) Staffeln")
        }
    }
}

// MARK: - Zustände



/// Fehler und Leeres stehen dort, wo sie entstehen — kein Hinweisfenster.
///
/// **Wörtlich die Anatomie der Vorlage** (BAUTEILE 6): Zeichen 44 in einem
/// Kreis von 78 in `flaeche` · 22 · Kopfzeile 20 Semibold · 7 · Text 15
/// `schriftLeise`, höchstens 262 breit · 24 · Hauptknopf · 16 · stiller
/// Knopf. Hier stand eine eigene, kleinere Bauart: Zeichen 30 in `.light`
/// ohne Kreis, Kopfzeile in 15, Text in 12 — dieselbe Rolle, drei Stufen
/// leiser, und `.light` gibt es in der Leiter gar nicht mehr.
///
/// **Ein Leerzustand bekommt nur dann einen Knopf, wenn es etwas zu tun
/// gibt.** Beide Knöpfe sind deshalb wahlweise.
struct Leerzustand: View {
    let symbol: String
    let kopfzeile: LocalizedStringKey
    var text: LocalizedStringKey?
    /// Lässt das Zeichen atmen — für „wird gerade versucht". Kein Ring:
    /// ein Ring sagt „warte", das Zeichen sagt weiter, worum es geht.
    var laedt = false
    var hauptknopf: (titel: LocalizedStringKey, tun: () -> Void)?
    var stillerKnopf: (titel: LocalizedStringKey, tun: () -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(Stil.flaeche)
                    .frame(width: 78, height: 78)
                Image(systemName: symbol)
                    .font(.system(size: 44))
                    .foregroundStyle(Stil.schriftLeise)
                    .animation(laedt && !Stil.bewegungReduziert
                               ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                               : Stil.einblenden) {
                        $0.opacity(laedt ? 0.45 : 1)
                    }
            }
            .padding(.bottom, 22)

            Text(kopfzeile)
                .font(Stil.reihe)
                .tracking(Stil.sperrungReihe)
                .foregroundStyle(Stil.schrift)
                .multilineTextAlignment(.center)
                .padding(.bottom, text == nil ? 0 : 7)

            if let text {
                Text(text)
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .lineSpacing(3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 262)
            }

            if let hauptknopf {
                Hauptknopf(beschriftung: hauptknopf.titel, symbol: "arrow.clockwise",
                           auswahl: hauptknopf.tun)
                    .fixedSize()
                    .padding(.top, 24)
            }
            if let stillerKnopf {
                Button(action: stillerKnopf.tun) {
                    Text(stillerKnopf.titel)
                        .font(Stil.koerper.weight(.medium))
                        // Der stille Knopf trägt den Akzent — er ist die
                        // zweite Handlung, und der Akzent markiert sie als
                        // eine.
                        .foregroundStyle(Stil.akzent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Stil.Druckknopf())
                .padding(.top, hauptknopf == nil ? 24 : 16)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 34)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}

/// **Ein leerer Abschnitt *innerhalb* einer Seite** — nicht die ganze Seite.
///
/// „Keine Folgen" unter der Staffelwahl, „Nichts Ähnliches gefunden" unter
/// den Reitern: dort steht der Kopf der Seite schon, und ein zweiter großer
/// Leerzustand mit Kreis und Kopfzeile wäre ein zweiter Seitenanfang.
/// Dieselbe Bauart wie `leerhinweis` in `Sources/Shared/SeriesView.swift`.
struct Leerhinweis: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(Stil.koerper)
            .foregroundStyle(Stil.schriftSehrLeise)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
    }
}

/// **Das Gegenstück zu `Leerhinweis`: „ich weiß es nicht".**
///
/// `Leerhinweis` sagt „hier liegt nichts". Bis zum 21.09.2026 sagte er das
/// auch, wenn der Server gar nicht geantwortet hatte — „Keine Folgen" und
/// „Nichts Ähnliches gefunden" standen dann als Tatsache da. Das ist
/// derselbe Baustein wie `Stoerhinweis` in `Sources/Shared/Stil.swift`,
/// mit den Maßen und Schriftstufen des Macs, und **mit demselben Wortlaut**:
/// zwei Sätze für dieselbe Lage wären zwei Antworten auf dieselbe Frage.
struct Stoerhinweis: View {
    let model: AppModel
    var erneut: (() -> Void)?
    var abstandOben: CGFloat = 40
    /// Wer nicht geantwortet hat. Ohne Angabe der eigene Jellyfin-Server; auf
    /// einer Seerr-Seite ist es Seerr, und die falsche Adresse im Satz wäre
    /// die falsche Fehlersuche.
    var adresse: String?

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.system(size: 30))
                .foregroundStyle(Stil.schriftLeise)
                .padding(.bottom, 14)

            Text("Server ist abgetaucht")
                .font(Stil.reihe)
                .tracking(Stil.sperrungReihe)
                .foregroundStyle(Stil.schrift)
                .padding(.bottom, 6)

            Text("\(adresse ?? model.serverAdresse ?? String(localized: "Der Server")) antwortet nicht. Läuft er noch, oder hängt das WLAN?")
                .font(Stil.koerper)
                .foregroundStyle(Stil.schriftSehrLeise)
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 262)

            if let erneut {
                Button(action: erneut) {
                    Text("Erneut versuchen")
                        .font(Stil.koerper.weight(.medium))
                        .foregroundStyle(Stil.akzent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Stil.Druckknopf())
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, abstandOben)
    }
}

// MARK: - Handlungsliste

/// Was auf dem iPhone das Blatt von unten ist.
///
/// Der Inhalt kommt aus `Titelhandlung` in `Sources/Shared` und ist auf allen
/// Plattformen derselbe — nur die Darreichung ist eigen. Hier klappt die Liste
/// **an Ort und Stelle** auf, direkt unter dem Knopf: „Auswahl bleibt am Ort",
/// dieselbe Regel wie bei der Staffelpille. Ein Blatt von unten wäre auf dem
/// Mac ein Fremdkörper, ein `Menu` bringt Systemmaße mit.
struct Handlungsliste: View {
    let handlungen: [Titelhandlung]
    @Binding var offen: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(handlungen) { handlung in
                Handlungszeile(handlung: handlung) {
                    handlung.tun()
                    withAnimation(Stil.sprung) { offen = false }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 260, alignment: .leading)
        // **Kein Schatten** — nirgends in dieser App (BRAND 4). Was die
        // Tafel vom Grund trennt, ist die Fläche und die eine Kante, für die
        // `rand` da ist. Ecke 16 wie jede andere eigene Fläche.
        .background {
            let form = RoundedRectangle(cornerRadius: Stil.eckeFlaeche, style: .continuous)
            form.fill(Stil.erhoeht).overlay { form.strokeBorder(Stil.rand, lineWidth: 1) }
        }
    }
}

struct Handlungszeile: View {
    let handlung: Titelhandlung
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            HStack(spacing: 10) {
                // Zeichen 15 in einer 20 breiten Spalte — 14 steht in
                // keiner Leiter (BAUTEILE 2, 6).
                Image(systemName: handlung.symbol)
                    .font(Stil.koerper)
                    .frame(width: 20)
                handlung.beschriftung.font(Stil.koerper)
                Spacer(minLength: 0)
            }
            .foregroundStyle(handlung.warnend ? Stil.warnung : Stil.schrift)
            .padding(.horizontal, 12)
            .frame(height: Stil.zeileHoehe)
            .background(schwebt ? Stil.schwebeflaeche : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckzeile())
        .onHover { schwebt = $0 }
    }
}

/// Eine kurze Meldung, die sich nach drei Sekunden von selbst zurückzieht.
/// Fehler stehen dort, wo sie entstehen — kein Hinweisfenster.
struct Hinweisstreifen: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Stil.koerper)
            .foregroundStyle(Stil.schrift)
            .padding(.horizontal, 14)
            .frame(height: 34)
            // Der Rand bleibt: der Streifen schwebt über der Seite und
            // gehört zu den wenigen Stellen, die eine Kante brauchen.
            .background(Stil.erhoeht, in: Capsule())
            .overlay(Capsule().strokeBorder(Stil.rand, lineWidth: 1))
    }
}

/// **Der Rückweg ist ein blanker Pfeil, kein runder Knopf** (BAUTEILE 7).
///
/// Er stand dreimal fast gleich da: als `Aktionsknopf` mit abgeschaltetem
/// Ring über den Einstellungsunterseiten, als loser Knopf im `Detailkopf`,
/// als dritter in der Bibliotheksleiste. Ein Baustein, eine Trefferfläche
/// (40 × 40), ein Grad (20 Semibold) — und der Schwebezustand als das
/// einzige, was er über sich verrät.
struct Rueckpfeil: View {
    let zurueck: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: zurueck) {
            Image(systemName: "chevron.left")
                .font(Stil.reihe)
                .foregroundStyle(schwebt ? Stil.schrift : Stil.schriftLeise)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .accessibilityLabel(Text("Zurück"))
    }
}

// MARK: - Detailseite

/// Der Kopf einer Detailseite: Pfeil links, Titel daneben.
///
/// **Kein Umriss, kein Kreis** — ein blanker Winkel in 20 semibold auf 40 × 40,
/// wie `Detailkopf` in `Sources/Shared/Stil.swift`. Der Titel blendet ein,
/// wenn weit genug gescrollt ist.
///
/// **Keine Glasleiste dahinter.** Auf dem iPhone trägt sie den Titel über dem
/// scrollenden Bild. Hier reicht die Kulisse nur über die rechten zwei
/// Drittel, also stand die Leiste links auf blankem Grund und war als
/// dunkler Balken zu sehen — rechts, wo das Bild liegt, verlor sie sich
/// darin. Ein Streifen, der nur halb da ist, ist schlimmer als keiner.
/// Wo die Seite gerade steht.
///
/// **Warum das ein eigenes Objekt ist und kein `@State` in der Seite.**
///
/// `onScrollGeometryChange` feuert bei jedem Takt des Scrollens. Schreibt es
/// in ein `@State` der Seite, wertet SwiftUI deren **ganzen Rumpf** neu aus —
/// bei einer Serienseite also Kopf, Reiterreihe und die Folgenliste, und das
/// sechzigmal in der Sekunde. Beim schnellen Ziehen kommt der Hauptlauf dann
/// nicht mehr nach, die Scrollfläche verliert den Anschluss und springt.
///
/// Als `@Observable` wird nur neu gezeichnet, wer den Wert **liest** — und
/// das ist einzig der `Detailkopf`. Die Seite gibt den Halter nur weiter.
@MainActor
@Observable
final class Kopfstand {
    var versatz: CGFloat = 0
}

struct Detailkopf: View {
    let titel: String
    /// Wo die Seite steht — siehe `Kopfstand`.
    let stand: Kopfstand
    private var versatz: CGFloat { stand.versatz }

    /// **Ab wo die Leiste kommt — hergeleitet, nicht geschätzt.**
    ///
    /// Sie soll genau dann da sein, wenn der große Titel unter ihr
    /// verschwindet. Aus der Geometrie des Heldenkopfes:
    ///
    /// - Der Titel beginnt `Stil.titelHoehe + 98` unter der Oberkante des
    ///   Heldenbildes und ist 42 Punkt hoch.
    /// - Die Leiste selbst ist `Stil.titelHoehe + 24` hoch.
    ///
    /// Die Oberkante des Titels erreicht die Unterkante der Leiste also bei
    /// 98 − 24 = **74**, und 42 Punkt später ist er ganz darunter. Genau über
    /// diese Strecke blendet die Leiste ein.
    ///
    /// Vorher stand hier `Stil.heldHoehe - 150` = 230 — ein Wert aus der
    /// iPhone-Fassung, wo Heldenbild und Titel anders sitzen. Auf dem Mac kam
    /// die Leiste damit erst, wenn der Titel längst weg war.
    var ab: CGFloat = 98 - 24
    /// Über welche Strecke sie einblendet: die Höhe des großen Titels.
    var ueber: CGFloat = 42
    let zurueck: () -> Void

    private var staerke: Double {
        guard ueber > 0 else { return 1 }
        return Double(min(max((versatz - ab) / ueber, 0), 1))
    }

    var body: some View {
        HStack(spacing: 4) {
            Rueckpfeil(zurueck: zurueck)

            Text(verbatim: titel)
                .font(Stil.rubrikGross)
                .tracking(Stil.sperrungRubrik)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                .opacity(staerke)

            Spacer(minLength: 0)
        }
        // **Bündig mit dem Inhalt.** Die Fensterampel sitzt über der
        // Seitenleiste, nicht über dem Inhaltsbereich — der Abstand, den ich
        // hier freigehalten hatte, war nie nötig. Der Pfeil steht jetzt auf
        // derselben Linie wie „Weiterschauen" auf der Startseite; die 8 Punkt
        // Ausgleich sind der Innenabstand des Knopfes selbst.
        .padding(.leading, Stil.randAbstand - 8)
        .padding(.trailing, Stil.randAbstand)
        // Seit der Inhalt unter der Titelleiste durchläuft, sitzt der Pfeil
        // sonst auf der Fensterkante. 24 setzt ihn auf dieselbe Höhe wie die
        // Seitenleiste ihre Wortmarke.
        .padding(.top, 24)
        // **Luft unter dem Text.** Die Leiste reicht ein Stück tiefer als
        // ihr Inhalt; sonst klebt der Titel auf der Haarlinie. Der Betrag
        // steht zweimal: einmal als Abstand, damit der Text an seinem Platz
        // bleibt, und einmal in der Höhe, damit die Leiste nach unten wächst
        // statt den Text mitzunehmen.
        .padding(.bottom, 10)
        .frame(height: Stil.titelHoehe + 24 + 10, alignment: .bottom)
        // **Die Leiste, die beim Scrollen kommt** — unten eine Haarlinie,
        // dahinter der Grund, der mit dem Scrollweg deckend wird.
        //
        // Sie deckt zugleich den Kanteneffekt ab, den macOS 26 oben an jede
        // Scrollfläche zeichnet. Der war einmal über `scrollEdgeEffectHidden`
        // abgestellt — und das war die Ursache dafür, dass eine laufende
        // Trackpad-Geste am Rand klebte (siehe `seitenscrollen`). Seitdem ist
        // diese Leiste die Antwort darauf: sie liegt ohnehin dort, und sie
        // gehört uns.
        .background(alignment: .bottom) {
            Rectangle().fill(Stil.linie).frame(height: 1).opacity(staerke)
        }
        .background {
            ZStack {
                // **Der weiche Verlauf im Ruhezustand ist weg.**
                //
                // Er stand hier, damit der Rueckweg auf einem hellen Heldbild
                // lesbar bleibt — so ist es auf dem iPhone, wo das Bild bis
                // an beide Kanten reicht. Auf dem Mac reicht die `Kulisse`
                // nur ueber die rechten zwei Drittel; der Pfeil steht links
                // auf blankem Grund, und der Verlauf war dort ein dunkler
                // Schein ohne Aufgabe. Rückmeldung vom 22.09.: „da muss einfach
                // dieser andere Verlauf weg." Was bleibt, ist die Leiste, die
                // beim Scrollen kommt.
                // **Nur wenn sie etwas tut.**
                //
                // `Leistenglas` ist eine *lebende* Unschärfe: sie verwischt,
                // was darunter durchläuft, und rechnet das bei jedem Bild neu
                // — auch dann, wenn die Maske sie auf null stellt und man
                // nichts sieht. Über einer scrollenden Seite ist das die
                // teuerste Fläche im Fenster, und sie stand dort dauerhaft.
                //
                // Steht sie erst ab einem Hauch Sichtbarkeit in der Ansicht,
                // kostet das Scrollen im Heldenbild gar nichts.
                //
                // **Und seit dem 07.09.2026 gar nicht mehr.** Apples
                // Materialien tragen alle eine helle Schicht — auch das
                // duennste. Ueber unserem Grund und bunten Plakaten wird
                // daraus ein grauer Block, heller als die Seite; beim Federn
                // blitzt er obendrein auf, weil die Staerke ueber eine Maske
                // geregelt wird, die je Bild neu gerechnet wird. Auf dem
                // iPhone war beides zu sehen, hier gilt dieselbe Physik.
                //
                // Eine Flaeche kann nicht aufblitzen, ist genau so dunkel wie
                // die Seite und kostet nichts. GESTALTUNG, Abschnitt D.
                Stil.grund.opacity(staerke)
            }
            .ignoresSafeArea(edges: .top)
        }
    }
}

/// Eine waagerechte Reihe mit Pfeilen zum Durchblättern.
///
/// **Nur auf dem Mac.** Auf iPhone und Fernseher wischt oder drückt man; hier
/// gibt es Zeiger und womöglich kein Trackpad, und dann ist eine waagerechte
/// Reihe ohne Pfeile nicht erreichbar. Der Grund ist die Eingabeart — genau
/// die Sorte Abweichung, die Abschnitt F erlaubt.
///
/// Die Pfeile erscheinen beim Schweben und nur dort, wo es etwas zu holen
/// gibt: am linken Rand keiner nach links, am rechten keiner nach rechts.
struct Blätterreihe<Inhalt: View>: View {
    /// Der seitliche Rand. **Null, wenn der Aufrufer schon einen setzt** —
    /// sonst stehen die Kacheln 48 Punkt eingerückt unter einer Überschrift,
    /// die bei 24 beginnt, und die Linie stimmt nicht mehr.
    var rand: CGFloat = Stil.randAbstand
    var schrittweite: CGFloat = 3
    var breiteJeStueck: CGFloat = Stil.kachelBreite + Stil.kachelAbstand
    /// Wie hoch das **Bild** einer Kachel ist — nicht die ganze Kachel.
    ///
    /// Die Blätterpfeile gehören optisch in die Mitte des Bildes. Mittig über
    /// der ganzen Reihe sitzen sie zu tief, weil unter jedem Bild noch zwei
    /// Textzeilen stehen; bei einem Poster sind das rund 45 Punkt Versatz,
    /// und die sieht man.
    var bildHoehe: CGFloat = Stil.kachelHoehe
    @ViewBuilder let inhalt: Inhalt

    @State private var schwebt = false
    /// **Die rohen Zahlen liegen in einem Halter, der nicht beobachtet wird.**
    ///
    /// Hier standen drei `@State`. Jeder Takt des Scrollens schrieb alle drei
    /// — also sechzigmal in der Sekunde eine neue Auswertung des Rumpfes samt
    /// Auslegevorgang, und der naechste Takt lag schon an. Genau das ist das
    /// „Haengenbleiben" beim schnellen Wisch: die Bewegung verliert Bilder,
    /// weil daneben die Reihe neu ausgelegt wird, und ein Schwung, der Bilder
    /// verliert, kommt nicht wieder in Gang. Rückmeldung vom 22.09.: „wenn ich ganz
    /// schnell wische, bleibe ich haengen — ich komme nicht wieder hoch mit
    /// dem gleichen Wisch."
    ///
    /// Eine schlichte Klasse ist kein `@Observable`: das Schreiben macht
    /// nichts ungueltig. Gelesen wird sie nur im Augenblick des Blaetterns.
    @State private var masse = Reihenmasse()
    /// **Nur die Entscheidung ist Zustand, nicht die Zahl.** Ob es links oder
    /// rechts noch etwas zu holen gibt, aendert sich zweimal je Reihe — nicht
    /// sechzigmal in der Sekunde.
    @State private var kannLinks = false
    @State private var kannRechts = false

    @MainActor final class Reihenmasse {
        var versatz: CGFloat = 0
        var gesamt: CGFloat = 0
        var sichtbar: CGFloat = 0
    }

    /// Was ein Takt über die Reihe verrät — in einem Wert, damit ein
    /// Beobachter genügt.
    private struct Messwerte: Equatable {
        let versatz: CGFloat
        let gesamt: CGFloat
        let sichtbar: CGFloat
    }

    var body: some View {
        ScrollView(.horizontal) {
            // **`LazyHStack`, nicht `HStack`.** Ein `HStack` baut jede Kachel
            // sofort — die Besetzungsreihe elf Bilder, die Ähnliches-Reihe
            // ebenso viele —, und zwar in demselben Bild, in dem die Seite
            // hereinfährt. Das war das Ruckeln: nicht die Bewegung war hart,
            // sondern sie verlor Bilder, weil daneben die halbe Seite gebaut
            // wurde. Beim Hinausfahren stand alles längst, deshalb lief es
            // dort weich.
            LazyHStack(alignment: .top, spacing: Stil.kachelAbstand) { inhalt }
                .padding(.horizontal, rand)
                // Damit die Kacheln beim Schweben oben nicht abgeschnitten
                // werden, wenn sie sich vergrößern.
                .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
        .seitenscrollen()
        .scrollPosition($stelle, anchor: .leading)
        // **Ein Beobachter statt zweier Geometrieleser.** Die beiden
        // `GeometryReader` schrieben beim Auslegen in den Zustand und lösten
        // damit weitere Auslegevorgänge aus — auch das kostete Bilder.
        .onScrollGeometryChange(for: Messwerte.self) {
            Messwerte(versatz: $0.contentOffset.x,
                      gesamt: $0.contentSize.width,
                      sichtbar: $0.containerSize.width)
        } action: { _, neu in
            masse.versatz = neu.versatz
            masse.gesamt = neu.gesamt
            masse.sichtbar = neu.sichtbar
            #if DEBUG
            // Gemessen, weil man den Linkspfeil auf einer gerade geoeffneten
            // Seite sieht: steht die Reihe wirklich auf null?
            Reihenprobe.melden(versatz: neu.versatz, gesamt: neu.gesamt,
                               sichtbar: neu.sichtbar)
            #endif
            // **Eine Schwelle von vier Punkten, nicht von einem.**
            //
            // Rückmeldung vom 22.09.: der Pfeil nach links steht schon da, wenn die
            // Seite gerade aufgegangen ist, und ein Klick bewegt die Reihe
            // „einen Millimeter". Gemessen habe ich die Ruhelage mit
            // **Versatz 0,00** — an dieser Stelle also nicht reproduziert.
            // Ein Punkt ist aber ohnehin zu knapp: `anchor: .leading` haelt
            // die Reihe an ihrer Kante, und waehrend das Fenster seine Breite
            // findet (gemessen: 172 → 1131) kann dabei ein Bruchteil eines
            // Punktes stehenbleiben. Vier Punkte sind unter der Wahrnehmung
            // und ueber dem Rauschen.
            //
            // **Und nichts zu blaettern heisst kein Pfeil.** Ist die Reihe
            // schmaler als ihr Fenster — gemessen: gesamt 328 in 1131 —, gibt
            // es weder links noch rechts etwas zu holen.
            let passt = neu.gesamt <= neu.sichtbar + 4
            let links = !passt && neu.versatz > 4
            let rechts = !passt && neu.versatz + neu.sichtbar < neu.gesamt - 4
            if links != kannLinks { kannLinks = links }
            if rechts != kannRechts { kannRechts = rechts }
        }
        // Oben ausgerichtet und von Hand gesetzt: die 4 Punkt sind der
        // senkrechte Rand der Reihe, 17 die halbe Knopfhöhe.
        .overlay(alignment: .topLeading) {
            if schwebt, kannLinks {
                pfeil("chevron.left", "Zurückblättern") { blättern(-1) }
                    .offset(y: 4 + bildHoehe / 2 - 17)
            }
        }
        .overlay(alignment: .topTrailing) {
            if schwebt, kannRechts {
                pfeil("chevron.right", "Weiterblättern") { blättern(1) }
                    .offset(y: 4 + bildHoehe / 2 - 17)
            }
        }
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        #if DEBUG
        .task {
            try? await Task.sleep(for: .seconds(4))
            Reihenprobe.ruhelage(versatz: masse.versatz, gesamt: masse.gesamt,
                                 sichtbar: masse.sichtbar)
        }
        #endif
    }

    @State private var stelle: ScrollPosition = .init(idType: CGFloat.self)

    private func blättern(_ richtung: CGFloat) {
        let weite = breiteJeStueck * schrittweite
        let ziel = max(0, min(masse.gesamt - masse.sichtbar,
                              masse.versatz + richtung * weite))
        withAnimation(Stil.einblenden) {
            stelle.scrollTo(x: ziel)
        }
    }

    private func pfeil(_ symbol: String, _ name: LocalizedStringKey,
                       _ auswahl: @escaping () -> Void) -> some View {
        Button(action: auswahl) {
            Image(systemName: symbol)
                .font(Stil.listentitel)
                .foregroundStyle(Stil.schrift)
                .frame(width: 34, height: 34)
                // Eine Fläche ohne gezeichnete Kante, und ein Feld statt
                // eines Kreises: ein Knopf ohne Beschriftung ist quadratisch
                // (BRAND 7). Unter 34 Punkt gilt die kleine Ecke.
                .background(Stil.flaeche,
                            in: RoundedRectangle(cornerRadius: Stil.eckeKlein,
                                                 style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
        .accessibilityLabel(Text(name))
        .padding(.horizontal, 6)
        .transition(.opacity)
    }
}


/// **Was für jede Seiten-Scrollfläche gilt.**
///
/// **Der Kanteneffekt ist nicht mehr abgeschaltet — er war die Ursache des
/// Klebens.** Hier stand `scrollEdgeEffectHidden(true, for: .all)`, eine
/// Schnittstelle aus macOS 26, und sie lag auf **jeder** Scrollfläche der App.
/// Rückmeldung vom 22.09.2026 nach dem A/B-Vergleich zweier Fassungen desselben Baus:
/// „das Hängenbleiben ist weg. Ich kann jetzt normal hoch und runter scrollen,
/// ohne irgendwo hängen zu bleiben."
///
/// Das ist belegt, nicht vermutet — und es war das Muster, das ihn vorher
/// beschrieben hat: eine laufende Trackpad-Geste klebte an einem Ende und
/// griff erst nach dem Absetzen wieder. Gemessen war die Zeichenlast dabei
/// **nicht** die Grenze: eine Fahrt über 313 Punkt bei 120 Hertz durch AppKits
/// eigene Schnittansicht lief mit 0 bis 3 Prozent ausgefallenen Bildern
/// (`Bildtakt`, `Scrollprobe`).
///
/// **Was die Zeile sollte, löst jetzt die Leiste.** macOS 26 zeichnet an den
/// Rändern einer Scrollfläche einen weichen Verlauf. Oben deckt ihn
/// `Bestandsleiste` beziehungsweise `Detailkopf` ohnehin ab — dort liegt seit
/// dem 22.09. eine eigene Leiste in `grund`, und die ist deckend, sobald
/// gescrollt wird. Unten und an den Seiten bleibt er stehen; über einem Grund
/// von `#101010` fällt ein Verlauf gegen dieselbe Farbe nicht auf. Eine
/// gestalterische Antwort statt einer abgeschalteten Schnittstelle.
///
/// **Und sie federt nur, wenn es etwas zu federn gibt** — selbst
/// entschieden, nicht `.basedOnSize` überlassen.
///
/// Gemessen am 22.09.: eine Seite trug **446 Punkt Inhalt in einem Fenster von
/// 833** und nahm trotzdem Scrollgesten an; sie federte, wo es nichts zu
/// scrollen gab. `.basedOnSize` allein hat das nicht getroffen — auf langen,
/// wirklich scrollbaren Seiten fiel damit das Federn **ganz** weg. Rückmeldung:
/// „wenn ich oben bin, kann ich nicht mehr weiter runterziehen." Das Federn
/// ist auf Apple-Plattformen die Rückmeldung „hier ist das Ende", und die
/// gehört dazu.
///
/// Also wird gemessen: ist der Inhalt höher als sein Fenster, federt sie wie
/// gewohnt; passt er hinein, federt sie nicht. Der Anfangswert ist
/// `.automatic` — bis die erste Messung da ist, verhält sie sich wie jede
/// andere Scrollfläche des Systems, und keine lange Seite verliert ihr Federn.
extension View {
    func seitenscrollen() -> some View { modifier(Seitenscrollen()) }
}

private extension View {
    /// Trennt die Verfuegbarkeitspruefung vom Rumpf — sonst muesste der
    /// ganze Modifikator zweimal dastehen.
    @ViewBuilder
    func kanteObenFrei() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}

private struct Seitenscrollen: ViewModifier {
    /// Gibt es etwas zu scrollen? Bis zur ersten Messung: ja.
    @State private var lang = true

    func body(content: Content) -> some View {
        content
            .scrollBounceBehavior(lang ? .automatic : .basedOnSize)
            // **Der Kanteneffekt nur oben weg, nicht rundum.**
            //
            // macOS 26 legt an jede Kante einer Scrollflaeche einen weichen
            // Schleier. Oben liegt unsere eigene Leiste mit dem Seitentitel —
            // und der Schleier liegt darueber: „ueber dem Text Serien ist
            // noch so ein Schleier, oben ist er nicht ganz weiss."
            //
            // Abgeschaltet war er schon einmal, fuer **alle** Kanten, und
            // genau das war die Ursache des Klebens beim Scrollen (belegt
            // ueber eine Probe am 22.09.). Deshalb hier nur `.top`: die
            // Kante, an der wir etwas Eigenes zeichnen. Unten und seitlich
            // bleibt der Effekt, wo er niemandem im Weg ist.
            .kanteObenFrei()
            // **Nur die Antwort ist Zustand, nicht die Höhe.** Sie ändert sich
            // zweimal je Seite, nicht sechzigmal in der Sekunde.
            .onScrollGeometryChange(for: Bool.self) {
                $0.contentSize.height > $0.containerSize.height + 4
            } action: { _, neu in
                if neu != lang { lang = neu }
            }
    }
}


// MARK: - Übernahme

/// „Läuft auf dem iPhone — hier weiterschauen", in der Form der Seitenleiste.
///
/// **`Mac`-eigene Fassung, weil die Leiste schmal ist.** Auf dem Fernseher
/// trägt das Abzeichen zwei Zeilen nebeneinander, hier stehen sie
/// untereinander und der Titel darf umbrechen. Gleicher Zweck, andere Breite
/// — die Benennung (`titelzeile`, `geraetezeichen`) teilen sich beide.
struct Uebernahmezeile: View {
    let sitzung: Fremdsitzung
    @State private var schwebt = false

    var body: some View {
        HStack(spacing: 10) {
            // **Der Akzent, und das Zeichen macht den Unterschied.**
            //
            // Hier stand `kuehl`, ein eigenes Blau fuer „woanders laeuft was".
            // Die Farbe ist am 21.09.2026 gestrichen: der Akzent traegt
            // Zustand, und „laeuft woanders" ist einer. Was die Zeile von
            // einem Fortschrittsbalken unterscheidet, ist das Geraetezeichen
            // links davon — das sagt es deutlicher als ein zweiter Blauton.
            Image(systemName: sitzung.geraetezeichen)
                .font(Stil.kachel)
                .foregroundStyle(Stil.akzent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hier weiterschauen")
                    .font(Stil.kachelTitel)
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(1)
                Text(verbatim: sitzung.titelzeile)
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        // **`akzentLeise` statt zweier roher Deckkräfte, und kein Rand.**
        // Der Token ist genau dieser Ton, schon ausgerechnet; der Rand sagte
        // ein zweites Mal, was die Fläche schon sagt.
        .background {
            let form = RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous)
            ZStack {
                form.fill(Stil.akzentLeise)
                if schwebt { form.fill(Stil.schwebeflaeche) }
            }
        }
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
    }
}

// MARK: - Wahl über eine Tafel

/// **Ein Wert, ein Knopf, eine Tafel darunter.**
///
/// Rückmeldung vom 22.09. über die Bibliotheksseite: „wir haben da acht verschiedene
/// Sachen. Wir machen das wie auf dem iPhone: einen Alle-Knopf und einen
/// A-bis-Z-Knopf, da drückt man drauf, dann kommt ein Pop-up, und da kann man
/// die Sachen umstellen. Das ist deutlich cleaner."
///
/// Genau das: der Knopf trägt den **gewählten Wert**, nicht eine von acht
/// Möglichkeiten. Was zur Wahl steht, steht in der Tafel — und die klappt
/// **an Ort und Stelle** auf, wie Staffelwahl, Mehr-Liste und Ladetafel. Ein
/// `Menu` wäre hier das Naheliegende und genau deshalb falsch: es bringt
/// Systemmaße, Systemecken und ein Systemmaterial mit.
///
/// Auf dem iPhone ist die Entsprechung `Wertpille` plus `Auswahlblatt` — dort
/// kommt es von unten, hier bleibt es am Ort. Das ist die Abweichung, die
/// Abschnitt F zulässt: von unten kommen auf dem Mac keine Blätter.
/// **Von allen Wahlknoepfen ist hoechstens einer offen.**
///
/// Jeder Knopf hatte seinen eigenen Zustand und wusste von den anderen
/// nichts. Dazu lag der Fang fuer „Klick daneben" hinter dem eigenen Knopf,
/// und der Nachbar in derselben Reihe lag darueber. Rückmeldung vom 22.09.: „Wenn ich
/// auf Alle druecke und dann auf Zuletzt, kommt das Zuletzt-Pop-up da
/// drueber. Aber eigentlich ist das, als wuerde ich ins Nichts druecken, und
/// es muesste sich einfach das andere schliessen."
///
/// Eine gemeinsame Aufsicht statt eines Zustands je Seite: so gilt die Regel
/// fuer jede Stelle, an der Wahlknoepfe nebeneinander stehen, ohne dass eine
/// Aufrufstelle davon wissen muss.
@MainActor
@Observable
final class Wahlaufsicht {
    static let geteilt = Wahlaufsicht()
    var offen: UUID?
}

struct Wahlknopf<Eintrag: Identifiable>: View {
    let symbol: String
    /// Was gerade gilt — die Beschriftung des Knopfes.
    let wert: String
    let eintraege: [Eintrag]
    let beschriftung: (Eintrag) -> String
    let istGewaehlt: (Eintrag) -> Bool
    let waehlen: (Eintrag) -> Void
    var tafelbreite: CGFloat = 220

    /// Wer bin ich unter den Wahlknoepfen — siehe `Wahlaufsicht`.
    @State private var kennung = UUID()
    private var aufsicht: Wahlaufsicht { .geteilt }
    private var offen: Bool { aufsicht.offen == kennung }

    var body: some View {
        Chip(beschriftung: wert, symbol: offen ? "chevron.up" : symbol, aktiv: offen) {
            withAnimation(Stil.sprung) {
                // **Steht ein anderer offen, ist dieser Klick ein Klick
                // daneben.** Er schliesst den anderen und tut sonst nichts —
                // so, wie ein Menue auf dem Mac sich verhaelt.
                if let andere = aufsicht.offen, andere != kennung {
                    aufsicht.offen = nil
                } else {
                    aufsicht.offen = offen ? nil : kennung
                }
            }
        }
        // Der Fang liegt **unter** der Tafel, nicht darüber: ein Klick daneben
        // schließt, ein Klick in die Tafel wählt. Dieselbe Bauart wie bei der
        // Ladetafel auf der Filmseite.
        .background {
            if offen {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .frame(width: 4000, height: 4000)
                    .onTapGesture { withAnimation(Stil.sprung) { aufsicht.offen = nil } }
            }
        }
        .overlay(alignment: .topLeading) {
            if offen {
                tafel
                    .offset(y: 38)
                    .transition(.aufklappen(von: .topLeading))
                    .zIndex(40)
            }
        }
        // Wer die Seite mit offener Tafel verlaesst, soll die naechste nicht
        // mit einem verschluckten ersten Klick empfangen.
        .onDisappear { if offen { aufsicht.offen = nil } }
    }

    private var tafel: some View {
        Wahltafel(eintraege: eintraege, beschriftung: beschriftung,
                  istGewaehlt: istGewaehlt, breite: tafelbreite) { eintrag in
            waehlen(eintrag)
            withAnimation(Stil.sprung) { aufsicht.offen = nil }
        }
    }
}

/// Die Tafel unter einem `Wahlknopf` oder einer `Titelwahl`.
struct Wahltafel<Eintrag: Identifiable>: View {
    let eintraege: [Eintrag]
    let beschriftung: (Eintrag) -> String
    let istGewaehlt: (Eintrag) -> Bool
    var breite: CGFloat = 220
    /// **Eine Rubrik vor einem Eintrag** — Trennlinie, darunter die
    /// Überschrift. Im Titelmenü von Filme und Serien steht so
    /// „Bibliotheken" über den einzelnen Bibliotheken, abgesetzt von „Alle"
    /// und „Sammlungen", die keine sind. Wie `Auswahlblatt.rubrik` auf dem
    /// iPhone; geschrieben wie die Rubriken der Seitenleiste, also ohne
    /// Versalien.
    var rubrik: (Eintrag) -> LocalizedStringKey? = { _ in nil }
    let waehlen: (Eintrag) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(eintraege) { eintrag in
                if let ueber = rubrik(eintrag) {
                    VStack(alignment: .leading, spacing: 0) {
                        Blattlinie().padding(.vertical, 4)
                        Seitenleistenrubrik(text: ueber)
                            .padding(.horizontal, 2)
                            .padding(.top, 4)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                Wahltafelzeile(text: beschriftung(eintrag),
                               gewaehlt: istGewaehlt(eintrag)) {
                    waehlen(eintrag)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: breite, alignment: .leading)
        // Kein Schatten — nirgends (BRAND 4). Fläche und die eine Kante, für
        // die `rand` da ist, trennen die Tafel vom Grund.
        .background {
            let form = RoundedRectangle(cornerRadius: Stil.eckeFlaeche, style: .continuous)
            form.fill(Stil.erhoeht).overlay { form.strokeBorder(Stil.rand, lineWidth: 1) }
        }
    }
}

/// **Der Seitentitel als Menü** — Filme ▾ und Serien ▾, wie auf dem iPhone.
///
/// Ab zwei Einträgen im ``Bereichsangebot`` wird der Titel zum Knopf: oben
/// „Alle", darunter „Sammlungen", nach einem Strich die Bibliotheken. Damit
/// entfällt die Rubrik „Bibliotheken" in der Seitenleiste — sie war ein
/// zweiter Weg zur selben Sache, und einer, der den Bereich verließ.
///
/// Auf dem iPhone kommt die Wahl als Blatt von unten; hier klappt sie am Ort
/// auf wie jeder `Wahlknopf` (Abschnitt F: von unten kommen auf dem Mac keine
/// Blätter), und sie teilt deren Aufsicht — höchstens eine Tafel ist offen.
struct Titelwahl<Eintrag: Identifiable>: View {
    /// Was im Titel steht.
    let titel: Text
    let eintraege: [Eintrag]
    let beschriftung: (Eintrag) -> String
    let istGewaehlt: (Eintrag) -> Bool
    var rubrik: (Eintrag) -> LocalizedStringKey? = { _ in nil }
    let waehlen: (Eintrag) -> Void

    @State private var kennung = UUID()
    @State private var schwebt = false
    private var aufsicht: Wahlaufsicht { .geteilt }
    private var offen: Bool { aufsicht.offen == kennung }

    var body: some View {
        Button {
            withAnimation(Stil.sprung) {
                if let andere = aufsicht.offen, andere != kennung {
                    aufsicht.offen = nil
                } else {
                    aufsicht.offen = offen ? nil : kennung
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                titel
                    .font(Stil.titelGross)
                    .tracking(Stil.sperrungTitel)
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(1)
                Image(systemName: offen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(schwebt || offen ? Stil.schrift : Stil.schriftLeise)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .background {
            if offen {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .frame(width: 4000, height: 4000)
                    .onTapGesture { withAnimation(Stil.sprung) { aufsicht.offen = nil } }
            }
        }
        .overlay(alignment: .topLeading) {
            if offen {
                Wahltafel(eintraege: eintraege, beschriftung: beschriftung,
                          istGewaehlt: istGewaehlt, breite: 260, rubrik: rubrik) { eintrag in
                    waehlen(eintrag)
                    withAnimation(Stil.sprung) { aufsicht.offen = nil }
                }
                .offset(y: 44)
                .transition(.aufklappen(von: .topLeading))
                .zIndex(40)
            }
        }
        .onDisappear { if offen { aufsicht.offen = nil } }
    }
}

/// Eine Zeile in einer `Wahlknopf`-Tafel. **Gewählt heißt Weiß, nicht
/// Akzent** (BRAND 1): eine Wahl unter Geschwistern ist Rangfolge, und
/// Rangfolge tragen Ton und Fläche.
private struct Wahltafelzeile: View {
    let text: String
    let gewaehlt: Bool
    let auswahl: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: auswahl) {
            HStack(spacing: 8) {
                Text(verbatim: text)
                    .font(Stil.koerper)
                    .foregroundStyle(gewaehlt ? Stil.schrift : Stil.schriftLeise)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if gewaehlt {
                    Image(systemName: "checkmark")
                        .font(Stil.listentitel)
                        .foregroundStyle(Stil.schrift)
                        .frame(width: 14)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Stil.zeileHoehe)
            .background(schwebt ? Stil.schwebeflaeche : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckzeile())
        .onHover { schwebt = $0 }
        .accessibilityAddTraits(gewaehlt ? [.isButton, .isSelected] : .isButton)
    }
}

/// **Die Leiste, die beim Scrollen kommt — auf einer Bestandsseite.**
///
/// Rückmeldung vom 22.09.: der Titel „Filme" soll beim Scrollen oben stehen bleiben,
/// mit dem Verlauf dahinter, und die Filterelemente sollen wegblenden.
///
/// **Sie hängt nicht an einer Höhe, nur an einer Deckkraft.** Genau daran ist
/// der iPhone-Kopf schon einmal in eine Schleife geraten: wer die Höhe eines
/// Kopfes am Scrollversatz aufhängt, ändert damit den Sicherheitsrand, der in
/// der Messung steckt — Kopf schrumpft, Rand schrumpft, Versatz fällt zurück,
/// Kopf wächst (BAUTEILE 10, erste Falle). Hier bleibt die Leiste immer gleich
/// hoch und liegt als Auflage über der Scrollfläche; gemessen wird nur, wie
/// stark sie zu sehen ist. Ein Layout kann daraus nicht zurückschlagen.
///
/// Der große Titel scrollt mit dem Inhalt weg, der kleine blendet ein — die
/// beiden sind nie zugleich zu sehen. Dieselbe Bauart wie `Detailkopf`, und
/// **ein Verlauf, kein Glas**: der Grund ist `#101010`, der Verlauf läuft
/// gegen die Farbe aus, die darunter liegt (BRAND 4).
struct Bestandsleiste: View {
    let titel: LocalizedStringKey
    /// Wenn die Überschrift vom Server kommt — ein Bibliotheksname wird nicht
    /// übersetzt.
    var name: String?
    let stand: Kopfstand
    /// **Ab wo sie einblendet — hergeleitet, nicht geschätzt.**
    ///
    /// Der große Titel beginnt `Stil.inhaltOben` unter der Oberkante des
    /// Inhalts und ist rund 33 Punkt hoch (28 Punkt Bold); die Leiste ist
    /// `Stil.kopfleisteHoehe` hoch. Seine Unterkante erreicht deren Unterkante
    /// also bei `inhaltOben + 33 − kopfleisteHoehe` — dann ist er ganz
    /// darunter. Über die nächsten 26 Punkt blendet die Leiste ein; die beiden
    /// Titel sind damit nie zugleich zu sehen.
    ///
    /// Gerechnet und nicht getippt: ändert sich der obere Rand, wandert der
    /// Punkt mit.
    var ab: CGFloat = max(Stil.inhaltOben + 33 - Stil.kopfleisteHoehe, 0)
    var ueber: CGFloat = 26
    /// **Der Rückweg bleibt stehen, wenn es einen gibt.**
    ///
    /// Auf einer Bibliotheksunterseite steht der Pfeil im Inhalt und scrollte
    /// damit unter die Leiste — wer weit unten war, kam nur noch über ⌘[
    /// zurück. Er gehört in die Leiste, und anders als der Titel blendet er
    /// nicht ein: ein Ausweg, der erst ab einem Scrollweg da ist, ist keiner.
    var zurueck: (() -> Void)?

    private var staerke: Double {
        guard ueber > 0 else { return 1 }
        return Double(min(max((stand.versatz - ab) / ueber, 0), 1))
    }

    var body: some View {
        HStack(spacing: 4) {
            if let zurueck {
                Rueckpfeil(zurueck: zurueck)
                    .padding(.leading, -8)
            }
            Group {
                if let name { Text(verbatim: name) } else { Text(titel) }
            }
            .font(Stil.rubrikGross)
            .tracking(Stil.sperrungRubrik)
            .foregroundStyle(Stil.schrift)
            .lineLimit(1)
            .opacity(staerke)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Stil.randAbstand)
        .frame(height: Stil.kopfleisteHoehe, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            Rectangle().fill(Stil.linie).frame(height: 1).opacity(staerke)
        }
        // **Kein Dauerverlauf — der Grund kommt erst beim Scrollen.**
        //
        // Hier lag ein `LinearGradient` von `grund` nach durchsichtig, und er
        // haing an nichts: nur die deckende Flaeche darunter folgte
        // `staerke`. Der Verlauf stand also **immer** ueber dem Titel, auch
        // auf einer Seite, die gar nicht gescrollt war. Rückmeldung vom 22.09.:
        // „ueber dem Text Filme ist immer noch so ein Schein drueber, der
        // auch schon ohne Scrollen ueber den Text geht."
        //
        // Auf dem iPhone hat er eine Aufgabe: dort laeuft der Inhalt unter
        // Uhrzeit und Akku durch, und die brauchen Halt. Auf dem Mac gibt es
        // darueber die Fensterleiste — es gibt nichts abzudecken.
        //
        // Nebenbei war er eine durchsichtige Lage ueber einer Flaeche, die
        // sich bewegt: so etwas muss bei jedem Bild neu zusammengerechnet
        // werden, und zwar auch dann, wenn man nichts davon sieht.
        .background {
            Stil.grund.opacity(staerke)
                .ignoresSafeArea(edges: .top)
                // Der Grund nimmt keine Klicks — nur der Pfeil darin.
                .allowsHitTesting(false)
        }
    }
}


#if DEBUG
/// **Steht eine Reihe wirklich auf null, wenn sie erscheint?**
///
/// Rückmeldung vom 22.09.: der Pfeil zum Nach-links-Blättern steht schon da, wenn die
/// Seite gerade aufgegangen ist, und ein Klick darauf bewegt die Reihe „einen
/// Millimeter". Beides heisst: der gemessene Versatz ist nicht null. Diese
/// Probe schreibt die ersten Messwerte jeder Reihe ins Protokoll — nur die
/// ersten, sonst stünde dort eine Zeile je Bild.
@MainActor
enum Reihenprobe {
    private static let log = Logger(subsystem: "de.paulherter.swiftly", category: "reihe")
    private static var gemeldet = 0

    /// Nur die Faelle, die etwas aussagen: **wann wird der Linkspfeil
    /// freigegeben** und bei welchem Versatz. Eine Zeile je Bild waere
    /// unlesbar, und die ersten zwoelf Messwerte fielen alle in den
    /// Startvorgang, als die Reihe noch 172 Punkt breit war.
    static func melden(versatz: CGFloat, gesamt: CGFloat, sichtbar: CGFloat) {
        guard versatz > 1, gemeldet < 20 else { return }
        gemeldet += 1
        let zeile = String(format: "LINKSPFEIL frei #%d · Versatz %.2f · gesamt %.0f · sichtbar %.0f",
                           gemeldet, versatz, gesamt, sichtbar)
        log.notice("\(zeile, privacy: .public)")
    }

    /// Wie eine Reihe nach dem Auslegen dasteht — einmal je Reihe, spaet.
    static func ruhelage(versatz: CGFloat, gesamt: CGFloat, sichtbar: CGFloat) {
        guard ruhig < 8 else { return }
        ruhig += 1
        let zeile = String(format: "Ruhelage #%d · Versatz %.2f · gesamt %.0f · sichtbar %.0f",
                           ruhig, versatz, gesamt, sichtbar)
        log.notice("\(zeile, privacy: .public)")
    }
    private static var ruhig = 0
}
#endif

// MARK: - Aufklappen

extension AnyTransition {
    /// **Eine Tafel waechst aus ihrem Knopf, sie fliegt nicht herein.**
    ///
    /// Hier stand an fuenf Stellen `.move(edge: .top)`. Das verschiebt eine
    /// Ansicht um ihre **eigene volle Hoehe** — eine 200 Punkt hohe Liste kam
    /// also aus 200 Punkt ueber ihrer Endlage, lag auf dem Weg ueber den
    /// Elementen darueber und hatte mit dem Knopf, der sie oeffnet, nichts
    /// zu tun. Rückmeldung vom 22.09.: „Das kommt nicht aus diesen drei Punkten raus,
    /// sondern so drei Meter da drueber. Es fliegt so aus dem Nichts rein."
    ///
    /// Die Regel steht in BRAND unter Bewegung: was aufgeht, geht **dort**
    /// auf, wo man es ausgeloest hat, und geht auf demselben Weg wieder zu.
    /// Deshalb ein Anker — die Ecke der Tafel, die am Knopf liegt — und ein
    /// kleiner Massstab statt einer Strecke. 0,94 ist genug, dass man die
    /// Herkunft sieht, und wenig genug, dass nichts ploppt.
    ///
    /// Bei reduzierter Bewegung bleibt nur das Einblenden: kein Weg, keine
    /// Groessenaenderung.
    static func aufklappen(von anker: UnitPoint) -> AnyTransition {
        Stil.bewegungReduziert
            ? .opacity
            : .scale(scale: 0.94, anchor: anker).combined(with: .opacity)
    }
}
