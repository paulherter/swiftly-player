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
    let zurueck: () -> Void
    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich
    @Environment(\.seiteRuht) private var ruht

    @State private var reiter: Reiter = .folgen
    @State private var staffeln: [Item] = []
    @State private var gewaehlt: Item?
    @State private var folgen: [Item] = []
    @State private var aehnliche: [Item] = []
    @State private var staffelOffen = false
    @State private var laedt = true
    /// Ob die Staffeln schon da sind. **Ohne das lief das Laden zweimal:**
    /// `.task(id: gewaehlt?.id)` feuert beim Erscheinen mit `nil` und holte
    /// alle Folgen der Serie; kurz darauf kam die Staffel an, der Lauf
    /// wiederholte sich, und die ganze Liste wurde ein zweites Mal mit
    /// anderem Inhalt gebaut — mitten im Hereinfahren.
    @State private var staffelnDa = false
    @State private var versatz: CGFloat = 0
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
                Heldenkopf(model: model, titel: serie)

                Reiterreihe(auswahl: $reiter)
                    .padding(.top, 26)

                abschnitt
                    .padding(.horizontal, Stil.randAbstand)
                    .padding(.top, 20)
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        // **Die milchige Leiste am oberen Rand.** macOS 26 legt sie von sich
        // aus über jede Scrollfläche — sie war nie in unserem Code, und
        // deshalb habe ich zweimal an der falschen Stelle gesucht. Über dem
        // Bild verlor sie sich, links auf blankem Grund stand sie als Balken.
        //
        // E4 wieder: was das Rahmenwerk ungefragt dazustellt, gehört ebenso
        // abgestellt wie das, was man selbst hinschreibt.
        .ohneKanteneffekt()
        // **Federn wie überall sonst.** Ohne die Angabe entscheidet das
        // Rahmenwerk selbst, und auf diesen Seiten fiel die Entscheidung
        // gegen das Federn aus — dann steht die Fläche am oberen Ende hart,
        // statt nachzugeben.
        .scrollBounceBehavior(.always)
        .background(alignment: .top) {
            LinearGradient(colors: [farbe.ton, Stil.grund],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Stil.heldHoehe + 260)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Stil.grund)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
            versatz = neu
        }
        .overlay(alignment: .top) {
            Detailkopf(titel: serie.name, versatz: versatz, zurueck: zurueck)
        }
        .task { await farbe.laden(model.backdropURL(for: serie)) }
        .task { await staffelnLaden() }
        .task(id: gewaehlt?.id) {
            guard staffelnDa else { return }
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
        abschnittsinhalt
            .animation(Stil.zeitEinblenden, value: laedt)
            .animation(Stil.zeitEinblenden, value: staffeln.count)
            .animation(Stil.zeitEinblenden, value: folgen.count)
    }

    @ViewBuilder
    private var abschnittsinhalt: some View {
        switch reiter {
        case .folgen:
            VStack(alignment: .leading, spacing: 0) {
                if staffeln.count > 1 {
                    Staffelwahl(staffeln: staffeln, gewaehlt: $gewaehlt, offen: $staffelOffen)
                        .padding(.bottom, 18)
                }
                if laedt {
                    Lader().frame(height: 200)
                        .transition(.opacity)
                } else if folgen.isEmpty {
                    Leerzustand(symbol: "tray", titel: "Keine Folgen")
                        .frame(height: 200)
                } else {
                    // **`LazyVStack`, nicht `VStack`.** Ein `VStack` in einer
                    // Scrollfläche baut jede Zeile sofort — bei zehn Folgen
                    // zehn Zeilen samt Bild, in einem einzigen Einzelbild.
                    // Genau dieselbe Sache wie in `Blätterreihe`, nur hier
                    // übersehen. Die Filmseite hat keine solche Liste; daher
                    // lief sie sauber und die Serienseite nicht.
                    LazyVStack(spacing: 0) {
                        ForEach(folgen, id: \.id) { folge in
                            Folgenzeile(model: model, folge: folge)
                            if folge.id != folgen.last?.id {
                                Rectangle().fill(Stil.linie).frame(height: 1)
                            }
                        }
                    }
                    .transition(.opacity)
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
                                         bild: model.imageURL(for: eintrag, hochkant: true))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Laden

    private func staffelnLaden() async {
        guard staffeln.isEmpty, !staffelnDa else { return }
        let neue = await model.staffeln(serie)
        // Erst die Wahl, dann die Liste, dann das Zeichen — alles in einem
        // Zug, damit `.task(id:)` nur einen Wechsel sieht.
        gewaehlt = neue.first { $0.id == startStaffelID } ?? neue.first
        staffeln = neue
        staffelnDa = true
        if neue.isEmpty { await folgenLaden() }
    }

    private func folgenLaden() async {
        laedt = true
        defer { laedt = false }
        folgen = await model.folgen(serie: serie.id, staffel: gewaehlt?.id)
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

    @State private var schwebt = false
    @State private var gesehen = false
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
                Bildflaeche(bild: model.imageURL(for: folge, maxHeight: 220),
                            breite: bildBreite, hoehe: bildHoehe,
                            fortschritt: fortschritt)
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
                        .foregroundStyle(Stil.schrift)
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
            ZStack {
                if schwebt {
                    Aktionsknopf(symbol: gesehen ? "checkmark.circle.fill" : "checkmark.circle",
                                 titel: "Gesehen", an: gesehen) {
                        gesehen.toggle()
                        Task { _ = await model.setzeGesehen(folge, an: gesehen) }
                    }
                } else if gesehen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Stil.schriftSehrLeise)
                }
            }
            .frame(width: Stil.knopfRund, alignment: .trailing)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        // **Feste Zeilenhöhe.** Ein `LazyVStack` baut nur, was zu sehen ist,
        // und schätzt den Rest. Schätzt er falsch, springt die Scrollfläche
        // beim schnellen Hochziehen — je mehr Folgen, desto weiter. Mit einer
        // festen Höhe gibt es nichts zu schätzen. 90 für das Bild, zweimal 12
        // Rand; Titel und Text bleiben mit ihren Zeilengrenzen darunter.
        .frame(height: bildHoehe + 24)
        .background(schwebt ? Stil.schrift.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        // Eine Folge startet an ihrer eigenen Position — nicht an der der
        // Serie. Wörtlich aus der iPhone-Fassung.
        .onTapGesture { steuerung.starte(folge) }
        .task { gesehen = folge.userData?.played ?? false }
    }

    private var kopfzeile: String {
        if let nummer = folge.indexNumber {
            return "\(nummer). \(folge.name)"
        }
        return folge.name
    }


    private var fortschritt: Double? {
        guard let anteil = folge.userData?.playedPercentage else { return nil }
        return anteil / 100
    }
}
