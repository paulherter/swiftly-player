import JellyfinKit
import SwiftUI

// **Die Mac-Fassung der Downloads.**
//
// Verhalten aus `VERHALTEN.md`, Abschnitt H — dasselbe wie auf dem iPhone,
// bis auf drei Dinge, und alle drei haben mit Eingabeart und Fenstergröße zu
// tun:
//
// 1. **Die Nachfrage ist eine Tafel am Knopf, kein Blatt von unten.** Auf dem
//    Schreibtisch gibt es einen Zeiger; was zu einem Knopf gehört, erscheint
//    bei ihm. Dieselbe Regel wie bei `Handlungsliste`.
// 2. **Der Reiter ist eine Zeile in der Seitenleiste**, weil es hier keine
//    Leiste unten gibt.
// 3. **Der Ring erscheint größer**, wie alle Zeichen dieser Fassung.
//
// Die Regeln selbst — wer als Nächstes lädt, ob der Platz reicht, was
// entbehrlich ist — stehen nicht hier, sondern als `Downloadregeln` im Paket.

/// Ein Zeichen, sechs Lagen. Wörtlich die Aussagen der iPhone-Fassung.
struct Downloadring: View {
    let posten: Downloadposten?
    var mass: CGFloat = 26
    let tippen: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: tippen) { zeichen }
            .buttonStyle(.plain)
            .frame(width: mass + 10, height: mass + 10)
            .contentShape(Rectangle())
            .onHover { schwebt = $0 }
            .help(hilfe)
            .accessibilityLabel(Text(hilfe))
    }

    @ViewBuilder private var zeichen: some View {
        ZStack {
            switch posten?.stand {
            case nil:
                Circle().strokeBorder(Stil.schriftLeise, lineWidth: 1.5)
                bild("arrow.down", 12, Stil.schrift)
            case .wartet:
                Circle().strokeBorder(Stil.schriftSehrLeise,
                                      style: StrokeStyle(lineWidth: 2, dash: [3, 4]))
                bild("pause.fill", 10, Stil.schriftSehrLeise)
            case .laedt:
                bogen(anteil: posten?.anteil ?? 0, farbe: Stil.akzent)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Stil.akzent)
                    .frame(width: mass * 0.32, height: mass * 0.32)
            case .angehalten:
                bogen(anteil: posten?.anteil ?? 0, farbe: Stil.schriftLeise)
                bild("play.fill", 10, Stil.schrift)
            case .fertig:
                // **Ein Pfeil, kein Haken** — der Haken gehört der Frage
                // „hab ich das gesehen", und in der Folgenliste steht er
                // direkt daneben.
                Circle().fill(Stil.akzent)
                bild("arrow.down", 12, Stil.grund)
            case .fehler:
                Circle().strokeBorder(Stil.warnung, lineWidth: 2)
                bild("exclamationmark", 12, Stil.warnung)
            }
        }
        .frame(width: mass, height: mass)
        .opacity(schwebt ? 1 : 0.9)
        .animation(Stil.einblenden, value: posten?.stand)
    }

    private func bogen(anteil: Double, farbe: Color) -> some View {
        ZStack {
            Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, anteil))
                .stroke(farbe, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(1)
        }
    }

    private func bild(_ name: String, _ groesse: CGFloat, _ farbe: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: groesse, weight: .semibold))
            .foregroundStyle(farbe)
    }

    private var hilfe: LocalizedStringKey {
        switch posten?.stand {
        case nil:          "Laden"
        case .wartet:      "Wartet"
        case .laedt:       "Lädt, anhalten"
        case .angehalten:  "Angehalten, fortsetzen"
        case .fertig:      "Auf diesem Mac"
        case .fehler:      "Fehlgeschlagen, erneut versuchen"
        }
    }
}

/// Was ein Klick auf den Ring tut — an allen Stellen dasselbe.
@MainActor
func ringGeklickt(_ posten: Downloadposten?, _ verwaltung: Downloadverwaltung,
                  anlegen: () -> Void) {
    switch posten?.stand {
    case nil:                            anlegen()
    case .laedt:                         verwaltung.anhalten(posten!.id)
    case .angehalten, .fehler, .wartet:  verwaltung.fortsetzen(posten!.id)
    case .fertig:                        break
    }
}

// MARK: - Die Nachfrage

/// **H3, H5, H6** — dieselben drei Lagen wie auf dem iPhone, nur als Tafel
/// am Knopf statt als Blatt von unten.
struct Ladetafel: View {
    let model: AppModel
    let posten: [Downloadposten]
    let titel: String
    var bilder: [String: URL] = [:]
    @Binding var offen: Bool

    private var verwaltung: Downloadverwaltung { model.downloads }
    private var bytes: Int64 { posten.reduce(0) { $0 + $1.bytes } }
    private var auskunft: Downloadregeln.Platzauskunft { verwaltung.auskunft(fuer: bytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: kopf)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Stil.schrift)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Rectangle().fill(Stil.rand).frame(height: 1)

            if !auskunft.reicht {
                angabe("internaldrive", "Diese Datei", Downloadregeln.groesse(bytes))
                angabe("externaldrive", "Frei auf diesem Mac",
                       Downloadregeln.groesse(verwaltung.frei), warnend: true)
                if auskunft.reichtNachAufraeumen, !auskunft.entbehrlich.isEmpty {
                    angabe("checkmark.circle", "Gesehene Titel",
                           Downloadregeln.groesse(auskunft.entbehrlichBytes))
                    knopf("Gesehene entfernen und laden") {
                        verwaltung.entfernen(auskunft.entbehrlich.map(\.id))
                        starten()
                    }
                } else {
                    hinweis("Auch nach dem Entfernen der gesehenen Titel reicht der Platz nicht.")
                }
            } else if !Downloadregeln.darfLaden(imWLAN: verwaltung.imWLAN,
                                               nurUeberWLAN: verwaltung.nurUeberWLAN) {
                angabe("internaldrive", "Größe", Downloadregeln.groesse(bytes))
                angabe("wifi.slash", "Kein WLAN", String(localized: "Mobilfunk"), warnend: true)
                knopf("In die Warteschlange") { starten() }
            } else {
                angabe("internaldrive", "Größe", Downloadregeln.groesse(bytes))
                if let c = posten.first?.container {
                    angabe("sparkles", "Qualität", c.uppercased())
                }
                angabe("externaldrive", "Danach frei",
                       Downloadregeln.groesse(auskunft.freiDanach))
                knopf("Laden") { starten() }
                hinweis("Swiftly lädt die Originaldatei — dieselbe Qualität wie beim Streamen, weil nie umgerechnet wird.")
            }
        }
        .frame(width: 320, alignment: .leading)
        .background(Stil.erhoeht, in: RoundedRectangle(cornerRadius: Stil.eckeFeld))
        .overlay(RoundedRectangle(cornerRadius: Stil.eckeFeld)
            .strokeBorder(Stil.rand, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }

    private var kopf: String {
        auskunft.reicht ? String(localized: "\(titel) laden")
                        : String(localized: "Nicht genug Platz")
    }

    private func angabe(_ symbol: String, _ was: LocalizedStringKey,
                        _ wert: String, warnend: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(warnend ? Stil.warnung : Stil.schriftLeise)
                .frame(width: 18)
            Text(was)
                .font(.system(size: 13))
                .foregroundStyle(warnend ? Stil.warnung : Stil.schrift)
            Spacer(minLength: 10)
            Text(verbatim: wert)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Stil.schrift)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func knopf(_ text: LocalizedStringKey, tun: @escaping () -> Void) -> some View {
        Hauptknopf(beschriftung: text, symbol: "arrow.down", auswahl: tun)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 12)
    }

    private func hinweis(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Stil.schriftLeise)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
    }

    private func starten() {
        offen = false
        verwaltung.anstossen(posten, bilder: bilder)
    }
}

// MARK: - Die Seite

struct DownloadsView: View {
    let model: AppModel

    @State private var bearbeiten = false
    @State private var gewaehlt: Set<String> = []

    private var verwaltung: Downloadverwaltung { model.downloads }

    private var laufend: [Downloadposten] {
        verwaltung.posten.filter { $0.stand != .fertig }
    }
    private var fertige: [Downloadgruppe] {
        Downloadregeln.gruppiert(verwaltung.posten.filter { $0.stand == .fertig })
    }

    var body: some View {
        ZStack(alignment: .top) {
            Stil.grund.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    kopf

                    if !laufend.isEmpty {
                        rubrik(verwaltung.keinNetz ? "Wartet auf Netz" : "Lädt gerade")
                        ForEach(laufend) { p in
                            MacDownloadzeile(model: model, posten: p,
                                             gewaehlt: .constant(false))
                            trenner(nachDem: p.id == laufend.last?.id)
                        }
                    }

                    if !fertige.isEmpty {
                        rubrik("Auf diesem Mac")
                        ForEach(fertige) { g in
                            zeileFuer(g)
                            trenner(nachDem: g.id == fertige.last?.id)
                        }
                    }
                }
                // **Lesemaß, nicht Fensterbreite.** Eine Zeile aus Bild,
                // Titel und einem Ring, über 1600 Punkt gezogen, hat in der
                // Mitte nichts zu sagen. Dieselbe Grenze wie überall.
                // **Lesemaß, nicht Fensterbreite.** Eine Zeile aus Bild,
                // Titel und einem Ring, über 1600 Punkt gezogen, hat in der
                // Mitte nichts zu sagen.
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.horizontal, Stil.randAbstand)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if verwaltung.posten.isEmpty {
                Leerzustand(symbol: "arrow.down.circle",
                            titel: "Noch nichts geladen",
                            text: "Auf jeder Film- und Serienseite gibt es einen Knopf zum Laden. Geladene Titel laufen auch ohne Netz — in voller Qualität, weil Swiftly nie umrechnet.")
            }
        }
    }

    private func rubrik(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Stil.reihe)
            .foregroundStyle(Stil.schrift)
            .padding(.top, 26)
            .padding(.bottom, 10)
    }

    @ViewBuilder
    private func trenner(nachDem letzte: Bool) -> some View {
        if !letzte { Rectangle().fill(Stil.linie).frame(height: 1) }
    }

    @ViewBuilder
    private func zeileFuer(_ g: Downloadgruppe) -> some View {
        switch g {
        case let .einzeln(p):
            MacDownloadzeile(model: model, posten: p, bearbeiten: bearbeiten,
                             gewaehlt: bindung(fuer: [p.id]))
        case let .serie(_, titel, folgen):
            MacDownloadzeile(model: model, posten: folgen[0],
                             gruppe: (titel, folgen), bearbeiten: bearbeiten,
                             gewaehlt: bindung(fuer: folgen.map(\.id)))
        }
    }

    private func bindung(fuer ids: [String]) -> Binding<Bool> {
        Binding(get: { !ids.isEmpty && ids.allSatisfy { gewaehlt.contains($0) } },
                set: { an in
                    if an { gewaehlt.formUnion(ids) } else { gewaehlt.subtract(ids) }
                })
    }

    private var kopf: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloads").font(Stil.titelGross)
                Text(verbatim: belegungszeile)
                    .font(Stil.zweitzeile)
                    .foregroundStyle(verwaltung.keinNetz ? Stil.warnung : Stil.schriftSehrLeise)
            }
            Spacer(minLength: 0)
            if !verwaltung.posten.isEmpty {
                if bearbeiten, !gewaehlt.isEmpty {
                    Nebenknopf(symbol: "trash", titel: "Entfernen", aktiv: false) {
                        verwaltung.entfernen(Array(gewaehlt))
                        gewaehlt = []
                        bearbeiten = false
                    }
                }
                Nebenknopf(symbol: bearbeiten ? "xmark" : "pencil",
                           titel: bearbeiten ? "Fertig" : "Bearbeiten",
                           aktiv: bearbeiten) {
                    withAnimation(Stil.einblenden) {
                        bearbeiten.toggle()
                        if !bearbeiten { gewaehlt = [] }
                    }
                }
            }
        }
        .padding(.top, Stil.ampelHoehe)
    }

    private var loeschtitel: String {
        let bytes = verwaltung.posten.filter { gewaehlt.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.bytes }
        return String(localized: "\(gewaehlt.count) entfernen")
            + " · " + Downloadregeln.groesse(bytes)
    }

    private var belegungszeile: String {
        let b = Downloadregeln.belegung(verwaltung.posten)
        if verwaltung.keinNetz {
            return String(localized: "Kein Netz") + " · "
                + String(localized: "\(b.anzahl) Titel spielbar")
        }
        guard b.anzahl > 0 || !laufend.isEmpty else {
            return String(localized: "Nichts auf diesem Mac")
        }
        return String(localized: "\(b.anzahl) Titel") + " · "
            + Downloadregeln.groesse(b.bytes) + " · "
            + Downloadregeln.groesse(verwaltung.frei) + " " + String(localized: "frei")
    }
}

/// Eine Zeile. Heißt `MacDownloadzeile` und nicht `Downloadzeile`, weil in
/// demselben Ziel keine zwei gleichnamigen Bausteine stehen dürfen — der
/// Grund steht in `CLAUDE.md` unter „Zwei Dateien gleichen Namens".
struct MacDownloadzeile: View {
    let model: AppModel
    let posten: Downloadposten
    var gruppe: (titel: String, folgen: [Downloadposten])?
    var bearbeiten = false
    @Binding var gewaehlt: Bool

    @State private var schwebt = false
    private var verwaltung: Downloadverwaltung { model.downloads }

    var body: some View {
        HStack(spacing: 16) {
            if bearbeiten {
                Image(systemName: gewaehlt ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(gewaehlt ? Stil.akzent : Stil.schriftSehrLeise)
            }

            Bildflaeche(bild: bildadresse,
                        breite: quer ? 142 : 76, hoehe: quer ? 80 : 114,
                        zeichen: quer ? "tv" : "film")

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: gruppe?.titel ?? posten.titel)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(1)
                Text(verbatim: unterzeile)
                    .font(Stil.zweitzeile)
                    .foregroundStyle(unterfarbe)
                    .lineLimit(1)
                if let anteil = posten.anteil,
                   posten.stand == .laedt || posten.stand == .angehalten {
                    // Kein eigener Baustein: `Fortschrittsbalken` liegt in
                    // `Sources/Shared/Stil.swift` und die gehoert dem iPhone.
                    // Drei Zeilen abzuschreiben ist hier billiger als eine
                    // Datei umzuhaengen, die der Mac sonst nicht braucht.
                    GeometryReader { r in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.16))
                            Capsule().fill(Stil.akzent)
                                .frame(width: r.size.width * anteil)
                        }
                    }
                    .frame(height: 3)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)

            if gruppe == nil {
                Downloadring(posten: posten) {
                    ringGeklickt(posten, verwaltung) {}
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(schwebt && bearbeiten ? Stil.flaeche : .clear,
                    in: RoundedRectangle(cornerRadius: Stil.eckeFeld))
        .contentShape(Rectangle())
        .onHover { schwebt = $0 }
        .onTapGesture { if bearbeiten { gewaehlt.toggle() } }
    }

    private var quer: Bool { gruppe == nil && posten.art == .folge }

    private var bildadresse: URL? {
        verwaltung.bild(fuer: posten, alsGruppe: gruppe != nil)
            ?? model.plakatURL(itemID: gruppe != nil ? (posten.serienId ?? posten.id) : posten.id)
    }

    private var unterzeile: String {
        if let g = gruppe {
            let bytes = g.folgen.reduce(Int64(0)) { $0 + $1.bytes }
            return String(localized: "\(g.folgen.count) Folgen") + " · "
                + Downloadregeln.groesse(bytes)
        }
        var teile: [String] = []
        if let s = posten.staffel, let f = posten.folge { teile.append("S\(s) F\(f)") }
        else if let t = posten.laufzeitTicks, t > 0 {
            teile.append(laufzeit(Double(t) / 10_000_000))
        }
        switch posten.stand {
        case .laedt:
            teile = [Downloadregeln.groesse(posten.geladen) + " "
                     + String(localized: "von") + " " + Downloadregeln.groesse(posten.bytes)]
        case .wartet:      teile.append(String(localized: "wartet"))
        case .angehalten:  teile.append(String(localized: "angehalten"))
        case .fehler:      teile = [posten.grund ?? String(localized: "Fehlgeschlagen")]
        case .fertig:
            teile.append(Downloadregeln.groesse(posten.bytes))
            if let c = posten.container { teile.append(c.uppercased()) }
            if !posten.nochAufDemServer {
                teile.append(String(localized: "nicht mehr auf dem Server"))
            }
        }
        return teile.joined(separator: " · ")
    }

    private var unterfarbe: Color {
        switch posten.stand {
        case .laedt:  Stil.akzent
        case .fehler: Stil.warnung
        default:      Stil.schriftLeise
        }
    }
}
