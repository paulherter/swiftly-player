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

    @State private var reiter: Reiter = .folgen
    @State private var staffeln: [Item] = []
    @State private var gewaehlt: Item?
    @State private var folgen: [Item] = []
    @State private var aehnliche: [Item] = []
    @State private var staffelOffen = false
    @State private var laedt = true
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
        .task(id: gewaehlt?.id) { await folgenLaden() }
    }

    // MARK: Abschnitte

    @ViewBuilder
    private var abschnitt: some View {
        switch reiter {
        case .folgen:
            VStack(alignment: .leading, spacing: 0) {
                if staffeln.count > 1 {
                    Staffelwahl(staffeln: staffeln, gewaehlt: $gewaehlt, offen: $staffelOffen)
                        .padding(.bottom, 18)
                }
                if laedt {
                    Lader().frame(height: 200)
                } else if folgen.isEmpty {
                    Leerzustand(symbol: "tray", titel: "Keine Folgen")
                        .frame(height: 200)
                } else {
                    VStack(spacing: 0) {
                        ForEach(folgen, id: \.id) { folge in
                            Folgenzeile(model: model, folge: folge)
                            if folge.id != folgen.last?.id {
                                Rectangle().fill(Stil.linie).frame(height: 1)
                            }
                        }
                    }
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
        guard staffeln.isEmpty else { return }
        staffeln = await model.staffeln(serie)
        gewaehlt = staffeln.first { $0.id == startStaffelID } ?? staffeln.first
        if staffeln.isEmpty { await folgenLaden() }
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
                Bildflaeche(bild: model.querbildURL(for: folge, breite: 400),
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
