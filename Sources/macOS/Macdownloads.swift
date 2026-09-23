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
    /// Der geschätzte Stand zwischen zwei Meldungen — derselbe Wert wie Zahl
    /// und Balken daneben. Ohne ihn der gemeldete.
    var anteilJetzt: Double? = nil
    var mass: CGFloat = 26
    let tippen: () -> Void

    @State private var schwebt = false

    var body: some View {
        // Dieselbe Falle wie auf dem iPhone: `frame` und `contentShape`
        // standen **hinter** dem Knopf, also an der Huelle. Ein Knopf nimmt
        // seine Flaeche von dem, was er zeichnet — und das sind hier Linien.
        // Beim Laden lag in der Mitte nur ein kleines Quadrat, alles daneben
        // ging ins Leere.
        Button(action: tippen) {
            zeichen
                .frame(width: mass + 10, height: mass + 10)
                .contentShape(Rectangle())
        }
            .buttonStyle(Stil.Druckknopf())
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
                bogen(anteil: anteilJetzt ?? posten?.anteil ?? 0, farbe: Stil.akzent)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
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
            // Die Spur ist hell — weiss 30 %, derselbe Ton wie unter dem
            // Fortschritt einer Kachel (BRAND 7).
            Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 2)
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
                .font(Stil.listentitel)
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
                abbrechen
            } else if !Downloadregeln.darfLaden(imWLAN: verwaltung.imWLAN,
                                               nurUeberWLAN: verwaltung.nurUeberWLAN) {
                angabe("internaldrive", "Größe", Downloadregeln.groesse(bytes))
                angabe("wifi.slash", "Kein WLAN", String(localized: "Mobilfunk"), warnend: true)
                knopf("In die Warteschlange") { starten() }
                abbrechen
            } else {
                angabe("internaldrive", "Größe", Downloadregeln.groesse(bytes))
                if let c = posten.first?.container {
                    angabe("sparkles", "Qualität", c.uppercased())
                }
                angabe("externaldrive", "Danach frei",
                       Downloadregeln.groesse(auskunft.freiDanach))
                knopf("Laden") { starten() }
                hinweis("Swiftly lädt die Originaldatei, in derselben Qualität wie beim Streamen.")
                abbrechen
            }
        }
        .frame(width: 320, alignment: .leading)
        // Kein Schatten — nirgends (BRAND 4).
        .background {
            let form = RoundedRectangle(cornerRadius: Stil.eckeFlaeche, style: .continuous)
            form.fill(Stil.erhoeht).overlay { form.strokeBorder(Stil.rand, lineWidth: 1) }
        }
    }

    /// Der Ausweg. **Immer da**, auch wenn die Lage schon einen zweiten Knopf
    /// hat — sonst haengt die Antwort „doch nicht" an der Frage, welche der
    /// drei Lagen gerade gilt.
    private var abbrechen: some View {
        Button { offen = false } label: {
            Text("Abbrechen")
                .font(Stil.koerper)
                .foregroundStyle(Stil.schriftLeise)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(Stil.Druckknopf())
        // **Escape, und zwar so.** `onExitCommand` haengt auf dem Mac an der
        // Antwortkette, und eine Tafel in einer Auflage steht nicht darin —
        // die Taste kam nie an. `cancelAction` bindet sie an diesen Knopf,
        // und das ist auf dem Schreibtisch ohnehin der uebliche Weg.
        .keyboardShortcut(.cancelAction)
        .padding(.bottom, 12)
    }

    private var kopf: String {
        auskunft.reicht ? String(localized: "\(titel) laden")
                        : String(localized: "Nicht genug Platz")
    }

    private func angabe(_ symbol: String, _ was: LocalizedStringKey,
                        _ wert: String, warnend: Bool = false) -> some View {
        HStack(spacing: 10) {
            // Zeile in einer Tafel: Zeichen und Text auf der Leiter, 20
            // breite Zeichenspalte. Hier stand dreimal die 13 ohne Rolle —
            // in der Leiter gibt es 13 nur als Medium (BAUTEILE 9.21).
            Image(systemName: symbol)
                .font(Stil.koerper)
                .foregroundStyle(warnend ? Stil.warnung : Stil.schriftLeise)
                .frame(width: 20)
            Text(was)
                .font(Stil.koerper)
                .foregroundStyle(warnend ? Stil.warnung : Stil.schrift)
            Spacer(minLength: 10)
            Text(verbatim: wert)
                .font(Stil.koerper)
                .monospacedDigit()
                .foregroundStyle(Stil.schriftLeise)
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
            .font(Stil.klein)
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

    @Environment(Navigator.self) private var navigator
    @Environment(\.bereich) private var bereich
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
                        // Dieselbe Luecke wie auf dem iPhone: was laeuft,
                        // liess sich nicht ankreuzen und damit nicht
                        // entfernen.
                        ForEach(laufend) { p in
                            MacDownloadzeile(model: model, posten: p,
                                             bearbeiten: bearbeiten,
                                             gewaehlt: bindung(fuer: [p.id]))
                            trenner(nachDem: p.id == laufend.last?.id)
                        }
                    }

                    if !fertige.isEmpty {
                        // **Keine Überschrift über dem Geladenen.** Hier
                        // stand „Auf diesem Mac" — auf der Downloadseite ist
                        // alles auf diesem Mac, der Satz sagte nichts. Wie
                        // auf dem iPhone bleibt der Abstand zu „Lädt gerade".
                        Color.clear.frame(height: laufend.isEmpty ? 4 : 26)
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
                // **Kein Knopf „Was kann ich laden".** Netflix hat einen,
                // weil dort nicht alles ladbar ist. Bei uns schon — der Knopf
                // fuehrte nur in die Bibliothek zurueck.
                //
                // Und der Wortlaut ist der des iPhones, woertlich: hier stand
                // ein zweiter, sachlicher Satz, den es dort gar nicht mehr
                // gibt. Ein Leerzustand sagt sachlich, was los ist, und der
                // zweite Satz darf Laune haben (BRAND 7) — zwei Wortlaute
                // fuer dieselbe Lage sind eine Abweichung.
                Leerzustand(symbol: "arrow.down.circle",
                            kopfzeile: "Noch nichts geladen",
                            text: "Lad was runter, bevor der Zug ins Funkloch fährt.")
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
        case let .serie(id, titel, folgen):
            // **Eine Serie öffnet ihre Seite**, wie auf dem iPhone: großes
            // Bild, Name, Abspielknopf, darunter die Folgen nach Staffel.
            // Hier klappte die Zeile vorher an Ort und Stelle auf — eine
            // Liste unter dem Namen, ohne Bild und ohne Abspielknopf.
            MacDownloadzeile(model: model, posten: folgen[0],
                             gruppe: (titel, folgen), bearbeiten: bearbeiten,
                             gewaehlt: bindung(fuer: folgen.map(\.id)),
                             auffalten: {
                                 navigator.oeffne(.downloadserie(id, titel: titel), in: bereich)
                             })
        }
    }

    private func bindung(fuer ids: [String]) -> Binding<Bool> {
        Binding(get: { !ids.isEmpty && ids.allSatisfy { gewaehlt.contains($0) } },
                set: { an in
                    if an { gewaehlt.formUnion(ids) } else { gewaehlt.subtract(ids) }
                })
    }

    private var kopf: some View {
        // **Derselbe Kopf wie jede andere Wurzelseite.**
        //
        // Er war der einzige mit zwei Zeilen und der einzige, der bei
        // `ampelHoehe` (40) statt bei `inhaltOben` (52) ansetzte — beides
        // zusammen machte ihn sichtbar hoeher als „Filme", „Serien",
        // „Merkliste" und „Suche", und Paul hat genau das gesehen.
        //
        // **Keine Zeile unter dem Titel.** Hier stand die Belegung —
        // Titelzahl, Groesse, freier Platz. Dieselbe Auskunft steht am
        // Speicherbalken weiter unten, und ein Seitentitel mit Unterbau sieht
        // anders aus als jede andere Wurzelseite. Ohne Netz sagt es der
        // Leerzustand. Auf dem iPhone ist die Zeile am 21.09. gefallen, auf
        // dem Mac stand sie noch.
        HStack(alignment: .center, spacing: 14) {
            Text("Downloads")
                .font(Stil.titelGross)
                .tracking(Stil.sperrungTitel)
            Spacer(minLength: 0)
            if !verwaltung.posten.isEmpty {
                if bearbeiten, !gewaehlt.isEmpty {
                    Aktionsknopf(mass: Stil.hauptknopfHoehe, symbol: "trash", titel: "Entfernen", aktiv: false) {
                        verwaltung.entfernen(Array(gewaehlt))
                        gewaehlt = []
                        bearbeiten = false
                    }
                }
                Bearbeitenknopf(bearbeiten: $bearbeiten, gewaehlt: $gewaehlt)
            }
        }
        .padding(.top, Stil.inhaltOben)
    }

}

/// Stift und Kreuz oben rechts — auf der Downloadliste und auf der Seite
/// einer geladenen Serie derselbe Knopf, wie auf dem iPhone.
struct Bearbeitenknopf: View {
    @Binding var bearbeiten: Bool
    @Binding var gewaehlt: Set<String>

    var body: some View {
        Aktionsknopf(mass: Stil.hauptknopfHoehe, symbol: bearbeiten ? "xmark" : "pencil",
                     titel: bearbeiten ? "Fertig" : "Bearbeiten",
                     aktiv: bearbeiten) {
            // Die Kurve der Tafeln am Mac: die Zeilen gleiten, der Kreis
            // schiebt sie von links.
            withAnimation(Stil.sprung) {
                bearbeiten.toggle()
                if !bearbeiten { gewaehlt = [] }
            }
        }
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
    /// Nur fuer eine Gruppenzeile: oeffnet die Seite der Serie.
    var auffalten: (() -> Void)?

    @State private var schwebt = false
    @Environment(Abspielsteuerung.self) private var steuerung
    private var verwaltung: Downloadverwaltung { model.downloads }
    /// Haelt den Schaetzer ueber die Neuzeichnungen; beobachtet wird er
    /// nicht, die Zeitleiste fragt ihn je Bild.
    @State private var schaetzer = Schaetzerhalter()

    /// **Waehrend geladen wird, zaehlt die Zeile je Bild weiter** — wie auf
    /// dem iPhone. Die Verwaltung meldet hoechstens einmal je Sekunde;
    /// dazwischen rechnet `Fortschrittsschaetzer` im Tempo der letzten
    /// Sekunden weiter. Zahl, Balken und Ring lesen **denselben** Wert.
    ///
    /// **Geschaetzt wird nur, solange wirklich Byte kommen.** Angehalten,
    /// wartend, fehlgeschlagen oder ohne Netz steht die Zahl sofort, dort,
    /// wo sie stand.
    var body: some View {
        Group {
            if kommtWas {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { takt in
                    zeile(geladen: schaetzer.s.wert(um: takt.date))
                }
            } else if posten.stand == .angehalten || posten.stand == .laedt {
                zeile(geladen: max(schaetzer.s.wert(um: Date()), posten.geladen))
            } else {
                zeile(geladen: posten.geladen)
            }
        }
        .onChange(of: posten.geladen, initial: true) { _, neu in
            schaetzer.s.melden(neu, gesamt: posten.bytes, um: Date())
            if !kommtWas { schaetzer.s.anhalten() }
        }
        .onChange(of: kommtWas) { _, an in
            if !an { schaetzer.s.anhalten() }
        }
    }

    private var kommtWas: Bool {
        gruppe == nil && posten.stand == .laedt && !verwaltung.keinNetz
    }

    private func anteil(_ geladen: Int64) -> Double? {
        posten.bytes > 0 ? Double(geladen) / Double(posten.bytes) : posten.anteil
    }

    private func zeile(geladen: Int64) -> some View {
        // **Ein Knopf, kein `onTapGesture`.**
        //
        // Abspielen, Auffalten und Auswaehlen hingen alle an einer
        // Tippgeste: mit VoiceOver oder reiner Tastatur war die ganze
        // Downloadliste tot. Der Knopf umfasst alles ausser der Spalte
        // rechts — der Downloadring ist selbst einer, und ein Knopf in
        // einem Knopf schluckt den Klick.
        HStack(spacing: 16) {
            Button(action: betaetigen) {
            HStack(spacing: 16) {
            if bearbeiten {
                Image(systemName: gewaehlt ? "checkmark.circle.fill" : "circle")
                    .font(Stil.rubrikGross.weight(.regular))
                    .foregroundStyle(gewaehlt ? Stil.akzent : Stil.schriftSehrLeise)
                    .accessibilityHidden(true)
                    // **Der Kreis kommt von links herein und schiebt die
                    // Zeile vor sich her**, wie auf dem iPhone. Bei
                    // reduzierter Bewegung bleibt es eine Blende.
                    .transition(Stil.bewegungReduziert
                                ? .opacity
                                : .move(edge: .leading).combined(with: .opacity))
            }

            Bildflaeche(bild: bildadresse,
                        breite: quer ? 142 : 76, hoehe: quer ? 80 : 114,
                        zeichen: quer ? "tv" : "film")

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: gruppe?.titel ?? posten.titel)
                    .font(Stil.listentitel)
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(1)
                Text(verbatim: unterzeile(geladen))
                    .font(Stil.zweitzeile.monospacedDigit())
                    .foregroundStyle(unterfarbe)
                    .lineLimit(1)
                if let anteil = anteil(geladen),
                   posten.stand == .laedt || posten.stand == .angehalten {
                    // Kein eigener Baustein: `Fortschrittsbalken` liegt in
                    // `Sources/Shared/Stil.swift` und die gehoert dem iPhone.
                    // Drei Zeilen abzuschreiben ist hier billiger als eine
                    // Datei umzuhaengen, die der Mac sonst nicht braucht.
                    GeometryReader { r in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.3))
                            Capsule().fill(Stil.akzent)
                                .frame(width: r.size.width * min(max(anteil, 0), 1))
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 3)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            }
            // **Ohne graue Fläche**, wie auf dem iPhone: hier klickt man nur,
            // um zu wählen oder abzuspielen. Der Inhalt dunkelt kurz ab.
            .buttonStyle(Abdunkeln())
            .accessibilityLabel(Text(verbatim: gruppe?.titel ?? posten.titel))
            .accessibilityValue(Text(verbatim: unterzeile(geladen)))
            .accessibilityAddTraits(bearbeiten && gewaehlt ? [.isButton, .isSelected]
                                                           : .isButton)

            if gruppe == nil {
                Downloadring(posten: posten, anteilJetzt: anteil(geladen)) {
                    ringGeklickt(posten, verwaltung) {}
                }
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .frame(width: 36)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(schwebt && bearbeiten ? Stil.flaeche : .clear,
                    in: RoundedRectangle(cornerRadius: Stil.eckeFeld, style: .continuous))
        .contentShape(Rectangle())
        .onHover { schwebt = $0 }
        .animation(Stil.sprung, value: bearbeiten)
    }

    /// **Abspielen und nicht die Detailseite:** die braucht den Server, und
    /// wer hier steht, hat womoeglich keinen. `model.plan` nimmt die Datei
    /// von der Platte, ohne zu fragen (H8), und das `Item` dafuer baut sich
    /// der Posten selbst.
    private func betaetigen() {
        if bearbeiten { gewaehlt.toggle() }
        else if let auffalten { auffalten() }
        else if posten.stand == .fertig { steuerung.starte(posten.alsItem) }
    }

    private var quer: Bool { gruppe == nil && posten.art == .folge }

    private var bildadresse: URL? {
        verwaltung.bild(fuer: posten, alsGruppe: gruppe != nil)
            ?? model.plakatURL(itemID: gruppe != nil ? (posten.serienId ?? posten.id) : posten.id)
    }

    private func unterzeile(_ geladen: Int64) -> String {
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
            // **Feste Einheit, feste Stellen.** `groesse` wechselte mitten im
            // Laden von „845 MB" auf „1 GB" und „1,01 GB" — die Zeile wurde
            // bei jedem Schritt anders breit. Die Gesamtgröße gibt die
            // Einheit vor.
            let f = Downloadregeln.fortschritt(geladen: geladen, von: posten.bytes)
            teile = [String(localized: "\(f.geladen) von \(f.gesamt)")]
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

// MARK: - Eine geladene Serie

/// **Die Serie auf diesem Mac, als Detailseite** — Vorlage ist
/// `DownloadserieView` in `Sources/Shared/DownloadsView.swift`.
///
/// Oben das große Bild, der Name mit Folgenzahl und Größe, ein Abspielknopf,
/// darunter die Folgen nach Staffel. Gebaut aus den Bausteinen der
/// Detailseite (`Kulisse`, `Detailkopf`, `Hauptknopf`) — keine eigene
/// Gestaltung.
///
/// **Alles von der Platte.** Wer hier steht, hat womöglich kein Netz: das
/// Bild ist das gesicherte Kopfbild der Serie, sonst das Querbild der
/// nächsten Folge oder das Plakat, und erst danach eine Serveradresse.
///
/// **Entfernen geht über das Kontextmenü einer Folge oder über Bearbeiten**
/// — Auswahlkreise, dann der Papierkorb oder die Entf-Taste. Auf dem iPhone
/// kommt dazu das Wischen; das gibt es mit Zeiger nicht (Abschnitt F).
struct Downloadserienseite: View {
    let model: AppModel
    let serienId: String
    let titel: String
    let zurueck: () -> Void

    @Environment(Abspielsteuerung.self) private var steuerung
    @Environment(\.displayScale) private var pixelmass
    @State private var kopfstand = Kopfstand()
    @State private var bearbeiten = false
    @State private var gewaehlt: Set<String> = []
    @State private var seitenbreite: CGFloat = 0
    /// Das nachgeholte Kopfbild, sobald es liegt.
    @State private var nachgeholt: URL?

    private var verwaltung: Downloadverwaltung { model.downloads }

    private var folgen: [Downloadposten] {
        verwaltung.posten
            .filter { $0.serienId == serienId }
            .sorted { ($0.staffel ?? 0, $0.folge ?? 0) < ($1.staffel ?? 0, $1.folge ?? 0) }
    }

    /// Nach Staffel, in der Reihenfolge der Staffeln.
    private var staffeln: [(nummer: Int?, folgen: [Downloadposten])] {
        var reihe: [Int?] = []
        var je: [Int?: [Downloadposten]] = [:]
        for p in folgen {
            if je[p.staffel] == nil { reihe.append(p.staffel) }
            je[p.staffel, default: []].append(p)
        }
        return reihe.map { ($0, je[$0] ?? []) }
    }

    private var naechste: Downloadposten? { Downloadregeln.naechsteFolge(aus: folgen) }

    private var kopfbild: URL? {
        guard let p = naechste ?? folgen.first else { return nil }
        if let gross = nachgeholt ?? verwaltung.kopfbild(serie: serienId, konto: p.konto) {
            return gross
        }
        return verwaltung.bild(fuer: p)
            ?? verwaltung.bild(fuer: p, alsGruppe: true)
            ?? model.plakatURL(itemID: p.serienId ?? p.id)
    }

    /// Wie breit das Kopfbild in Pixeln sein muss: die `Kulisse` nimmt 62 %
    /// der Breite und ist `heldHoehe * 1,62` hoch — ein 16:9-Bild braucht
    /// mindestens die Breite, die diese Höhe füllt.
    static func kopfpixel(seitenbreite: CGFloat, pixelmass: CGFloat) -> Int {
        let punkte = max(seitenbreite * 0.62, Stil.heldHoehe * 1.62 * 16 / 9)
        return Int((punkte * pixelmass).rounded(.up))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Kulisse(url: kopfbild, hoehe: Stil.heldHoehe * 1.62)
                    block
                        .padding(.leading, Stil.randAbstand)
                        .padding(.top, Stil.titelHoehe + 98)
                }
                .frame(height: Stil.heldHoehe, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(staffeln, id: \.nummer) { staffel in
                        if let n = staffel.nummer {
                            Gruppentitel(text: "Staffel \(n)")
                                .padding(.top, 26)
                                .padding(.bottom, 10)
                        }
                        ForEach(staffel.folgen) { p in
                            folgenzeile(p)
                            if p.id != staffel.folgen.last?.id {
                                Rectangle().fill(Stil.linie).frame(height: 1)
                            }
                        }
                    }
                }
                // Lesemaß wie die Liste der Downloads.
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.horizontal, Stil.randAbstand)
                .padding(.bottom, 40)
            }
        }
        .scrollIndicators(.never)
        .seitenscrollen()
        .toolbar(.hidden)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(Stil.grund)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { seitenbreite = $0 }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, neu in
            kopfstand.versatz = neu
        }
        .overlay(alignment: .top) {
            Detailkopf(titel: titel, stand: kopfstand, zurueck: zurueck)
        }
        .task(id: seitenbreite > 0) { await kopfbildNachholen() }
        // **Die letzte Folge weg, die Seite weg.** Eine Serienseite ohne
        // Folgen hat nichts mehr zu zeigen; zurück in die Liste.
        .onChange(of: folgen.isEmpty) { _, leer in if leer { zurueck() } }
    }

    /// Name und Angabe, darunter die Knöpfe — an der Stelle, an der die
    /// Detailseite sie trägt.
    private var block: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: titel)
                .font(Stil.titelGross)
                .tracking(Stil.sperrungTitel)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .frame(width: 640, height: 42, alignment: .leading)
            Text(verbatim: String(localized: "\(folgen.count) Folgen") + " · "
                 + Downloadregeln.groesse(folgen.reduce(0) { $0 + $1.bytes }))
                .font(Stil.klein)
                .monospacedDigit()
                .foregroundStyle(Stil.schriftLeise)
                .lineLimit(1)
                .padding(.top, 12)
            knopfreihe
                .padding(.top, 22)
        }
    }

    /// **Die nächste ungesehene Folge**, sonst von vorn — die Regel steht in
    /// `Downloadregeln.naechsteFolge`. Beschriftet wie auf der Serienseite
    /// („Abspielen S2 F6").
    private var knopfreihe: some View {
        HStack(spacing: 12) {
            Hauptknopf(beschriftung: LocalizedStringKey(
                           Item.serienknopf(folge: naechste?.alsItem, laedt: false))) {
                if let naechste { steuerung.starte(naechste.alsItem) }
            }
            .fixedSize()
            .frame(minWidth: Stil.hauptknopfBreite, alignment: .leading)
            .disabled(naechste == nil)
            Bearbeitenknopf(bearbeiten: $bearbeiten, gewaehlt: $gewaehlt)
            if bearbeiten, !gewaehlt.isEmpty {
                Aktionsknopf(mass: Stil.hauptknopfHoehe, symbol: "trash",
                             titel: "Entfernen") {
                    entfernenGewaehlt()
                }
                // **Die Entf-Taste tut dasselbe** — auf dem Schreibtisch der
                // übliche Weg, eine Auswahl wegzuwerfen.
                .keyboardShortcut(.delete, modifiers: [])
                .transition(.opacity)
            }
        }
        .animation(Stil.sprung, value: bearbeiten && !gewaehlt.isEmpty)
    }

    private func folgenzeile(_ p: Downloadposten) -> some View {
        MacDownloadzeile(model: model, posten: p, bearbeiten: bearbeiten,
                         gewaehlt: Binding(
                            get: { gewaehlt.contains(p.id) },
                            set: { an in if an { gewaehlt.insert(p.id) } else { gewaehlt.remove(p.id) } }))
            // Der Weg, der auf dem iPhone „lange drücken" heißt.
            .contextMenu {
                Button(role: .destructive) { entfernen([p.id]) } label: {
                    Label("Download entfernen", systemImage: "trash")
                }
            }
    }

    private func entfernenGewaehlt() {
        entfernen(Array(gewaehlt))
        gewaehlt = []
        withAnimation(Stil.sprung) { bearbeiten = false }
    }

    private func entfernen(_ ids: [String]) {
        withAnimation(Stil.einblenden) { verwaltung.entfernen(ids) }
    }

    /// **Downloads von vorher haben kein großes Kopfbild** — mit Netz wird es
    /// hier einmal nachgeholt. Ohne Netz scheitert die Abfrage still, und es
    /// bleibt beim Bild von der Platte.
    private func kopfbildNachholen() async {
        guard seitenbreite > 0, let p = folgen.first,
              verwaltung.kopfbild(serie: serienId, konto: p.konto) == nil,
              let serie = await model.item(id: serienId),
              let adresse = model.kopfbildURL(for: serie, breite: Self.kopfpixel(
                  seitenbreite: seitenbreite, pixelmass: pixelmass))
        else { return }
        nachgeholt = await verwaltung.kopfbildNachholen(serie: serienId, konto: p.konto, von: adresse)
    }
}

/// Der Druck einer Downloadzeile: der Inhalt dunkelt kurz ab, statt eine
/// Fläche hinter die Zeile zu legen. Die Tastaturmarke bleibt — ohne sie
/// sähe man mit reiner Tastatur nicht, wo man steht.
private struct Abdunkeln: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Rumpf(gedrueckt: configuration.isPressed) { configuration.label }
    }

    private struct Rumpf<Inhalt: View>: View {
        let gedrueckt: Bool
        @ViewBuilder let inhalt: Inhalt
        @Environment(\.isFocused) private var fokussiert

        var body: some View {
            inhalt
                .opacity(gedrueckt ? 0.6 : 1)
                .background(Stil.schwebeflaeche.opacity(fokussiert ? 1 : 0),
                            in: RoundedRectangle(cornerRadius: Stil.ecke, style: .continuous))
                .animation(Stil.druckkurve(gedrueckt), value: gedrueckt)
                .animation(Stil.zeitSchweben, value: fokussiert)
        }
    }
}

/// Eine Hülle, damit der Schätzer die Neuzeichnungen überlebt, ohne dass
/// jede Schätzung eine neue auslöst.
private final class Schaetzerhalter {
    var s = Fortschrittsschaetzer()
}

// MARK: - Was geladen wird, wird ausgewählt

/// **Die Ladeauswahl — Mac-Fassung von `Sources/Shared/Ladeauswahl.swift`.**
///
/// Hier stand ein Chip „Staffel laden": er nahm genau eine Staffel, und zwar
/// die gerade gewählte. Wer zwei wollte, klickte zweimal; wer die Serie
/// wollte, sieben Mal. Paul am 22.09.: „der Chip Staffel laden kommt doch
/// weg. Wir machen doch dann einen neuen Knopf, auf den man drückt, wo ein
/// Menü kommt, wo man dann einzelne Staffeln auswählen kann. Die ganze Serie
/// und so. So wie auf dem iPhone halt."
///
/// Ein Baum mit drei Ebenen — **ganze Serie, Staffel, Folge** —, und jede
/// Ebene trägt denselben runden Kasten in drei Zuständen: leer, teilweise,
/// voll. Wer eine Staffel hakt, hakt ihre Folgen mit; wer eine Folge abwählt,
/// macht die Staffel teilweise.
///
/// **Der Schalter wählt nichts aus.** „Nur ungesehene" entscheidet, *was* ein
/// Haken auswählt. Wer ihn umlegt, verliert seine Auswahl nicht — sie wird
/// neu gerechnet.
///
/// **Und sie kommt als Tafel am Ort, nicht als Blatt von unten.** Auf dem Mac
/// fährt nichts von unten herein; dieselbe Entscheidung wie bei Staffelwahl,
/// Mehr-Liste und Ladetafel. Alles andere ist die iPhone-Fassung: die
/// Zeilenhöhen 58 für die Staffel und 52 für die eingerückte Folge sind
/// **Absicht** und keine zwei Antworten auf dieselbe Frage — die Folge soll
/// flacher stehen als die Staffel, zu der sie gehört.
struct MacLadeauswahl: View {
    let model: AppModel
    let serie: Item
    let staffeln: [Item]
    /// Die Folgen, die die Serienseite schon hat — meist die gewählte Staffel.
    let vorgeladen: [String: [Item]]
    @Binding var offen: Bool
    /// Was die Auswahl hergibt: die Folgen, die geladen werden sollen.
    let weiter: ([Item]) -> Void

    @State private var folgen: [String: [Item]] = [:]
    @State private var gewaehlt: Set<String> = []
    @State private var offeneStaffel: String?
    @State private var nurUngesehene = false
    @State private var laedt = true
    /// **Der Fehlfall gehört dazu.** Scheitert der Abruf, darf die Auswahl
    /// nicht leer dastehen — dann wüsste niemand, ob die Serie keine Folgen
    /// hat oder der Server nicht antwortet.
    @State private var gestoert = false

    private var alleFolgen: [Item] { staffeln.compactMap { folgen[$0.id] }.flatMap { $0 } }

    var body: some View {
        VStack(spacing: 0) {
            // Blattrubrik: 17 Semibold ohne Linie darunter (BAUTEILE 6).
            Text(verbatim: serie.name)
                .font(Stil.rubrikGross)
                .tracking(Stil.sperrungRubrik)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            if gestoert, alleFolgen.isEmpty {
                Stoerhinweis(model: model, erneut: { Task { await alleLaden() } },
                             abstandOben: 10)
                    .padding(.bottom, 16)
            } else {
                ScrollView {
                    VStack(spacing: 12) { serienkarte; staffelkarte }
                        .padding(.bottom, 12)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height }
                            action: { hoeheSetzen($0) }
                }
                // **So hoch wie die Karten, höchstens 360.** Ohne Deckel
                // wächst die Tafel bei fünfzehn Staffeln über das Fenster
                // hinaus. Der Deckel allein reicht nicht: eine `ScrollView`
                // ist senkrecht gierig und nähme sich die 360 auch bei zwei
                // Staffeln — dann klaffte unter der letzten Karte ein
                // Hohlraum. Dieselbe Rechnung wie auf dem iPhone.
                .frame(height: min(max(inhaltshoehe, 58), 360))
                .scrollIndicators(.hidden)

                fuss
            }
        }
        .frame(width: 420, alignment: .leading)
        // Kein Schatten — nirgends (BRAND 4).
        .background {
            let form = RoundedRectangle(cornerRadius: Stil.eckeFlaeche, style: .continuous)
            form.fill(Stil.erhoeht).overlay { form.strokeBorder(Stil.rand, lineWidth: 1) }
        }
        .task(id: offen) { if offen { await alleLaden() } }
    }

    @State private var inhaltshoehe: CGFloat = 0

    /// **Die Tafel wächst mit, statt zu springen** — wie auf dem iPhone
    /// (`Ladeauswahl.hoeheSetzen`). Die Zeilen klappten in einer Kurve auf,
    /// die Höhe darüber kam aber erst nach dem Aufklappen und ohne Kurve an:
    /// die Tafel stand schlagartig hoch, und die Zeilen schoben sich danach
    /// hinein. Jetzt läuft die Höhe in derselben Kurve wie die Zeilen
    /// (`sprung`, die Kurve der Tafeln am Mac). Nur die erste Messung setzt
    /// hart, sonst wüchse die Tafel beim Öffnen aus null.
    private func hoeheSetzen(_ neu: CGFloat) {
        guard inhaltshoehe > 0, offen else { inhaltshoehe = neu; return }
        withAnimation(Stil.sprung) { inhaltshoehe = neu }
    }

    /// **Was ein Haken nimmt.** Ohne Schalter alles, mit Schalter nur, was
    /// offen ist — und was schon auf der Platte liegt, nie.
    private func nehmbar(_ liste: [Item]) -> [Item] {
        liste.filter { folge in
            guard model.downloads.posten(fuer: folge.id) == nil else { return false }
            guard nurUngesehene else { return true }
            return !(folge.userData?.played ?? false)
        }
    }

    private var gewaehlteFolgen: [Item] { alleFolgen.filter { gewaehlt.contains($0.id) } }
    private var bytes: Int64 {
        gewaehlteFolgen.reduce(0) { $0 + Int64($1.mediaSources?.first?.size ?? 0) }
    }

    // MARK: Die Karten

    private var serienkarte: some View {
        VStack(spacing: 0) {
            zeile(kasten: standAlle, titel: Text("Ganze Serie"),
                  rechts: serienRechts) {
                umschalten(alleFolgen)
            }
            Blattlinie()
            VStack(alignment: .leading, spacing: 3) {
                // Ein Knopf, keine Tippgeste: sonst ist der Schalter ohne
                // Maus nicht erreichbar und VoiceOver liest ihn nicht.
                Button { nurUngesehene.toggle() } label: {
                    HStack(spacing: 13) {
                        Text("Nur ungesehene")
                            .font(Stil.listentitel)
                            .foregroundStyle(Stil.schrift)
                        Spacer(minLength: 12)
                        Schalter(an: nurUngesehene)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(Stil.Druckzeile())
                .accessibilityRepresentation { Toggle(isOn: $nurUngesehene) { Text("Nur ungesehene") } }
                Text("Entscheidet, was ein Haken auswählt.")
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Stil.flaeche,
                    in: RoundedRectangle(cornerRadius: Stil.eckeKarte, style: .continuous))
        .padding(.horizontal, 16)
        // Legt man den Schalter um, ändert sich nicht die Auswahl, sondern
        // ihre Grundmenge — also wird sie neu gerechnet.
        .onChange(of: nurUngesehene) { _, _ in neuRechnen() }
    }

    /// **„Ganze Serie" nennt nur, was noch fehlt.** Was schon auf dem Mac
    /// liegt, zählt nicht mit.
    private var serienRechts: String {
        if laedt { return String(localized: "wird gelesen …") }
        if standAlle == .da { return String(localized: "alles da") }
        if !alleFolgen.isEmpty, sichtbar(alleFolgen).isEmpty {
            return String(localized: "alles gesehen")
        }
        return zahlUndGroesse(nehmbar(alleFolgen).count, bytesVon(alleFolgen))
    }

    private var staffelkarte: some View {
        VStack(spacing: 0) {
            ForEach(Array(staffeln.enumerated()), id: \.element.id) { nr, staffel in
                let eigene = sichtbar(folgen[staffel.id] ?? [])
                let kasten = stand(eigene)
                zeile(kasten: kasten, titel: Text(verbatim: staffel.name),
                      rechts: staffelRechts(folgen[staffel.id], sichtbar: eigene, kasten),
                      aufgeklappt: offeneStaffel == staffel.id) {
                    umschalten(eigene)
                } aufklappen: {
                    withAnimation(Stil.sprung) {
                        offeneStaffel = offeneStaffel == staffel.id ? nil : staffel.id
                    }
                }
                if offeneStaffel == staffel.id {
                    // **Nur eingerückt, keine zweite Fläche.** Im Dunkelmodus
                    // geht Tiefe nach oben; etwas Dunkleres in einer hellen
                    // Karte sieht aus wie ein Loch.
                    ForEach(eigene) { folge in
                        Blattlinie()
                        let posten = model.downloads.posten(fuer: folge.id)
                        zeile(kasten: posten != nil ? .da
                                      : (gewaehlt.contains(folge.id) ? .voll : .leer),
                              titel: Text(verbatim: folge.name),
                              rechts: posten.map(ladestand) ?? folgenRechts(folge),
                              klein: true, einzug: 38,
                              leise: gesehen(folge)) {
                            umschalten([folge])
                        }
                    }
                }
                if nr < staffeln.count - 1 { Blattlinie() }
            }
        }
        .background(Stil.flaeche,
                    in: RoundedRectangle(cornerRadius: Stil.eckeKarte, style: .continuous))
        .padding(.horizontal, 16)
        // Der Schalter nimmt Folgen aus der Liste — sie gehen weich, nicht
        // schlagartig, und die Tafel schrumpft in derselben Kurve.
        .animation(Stil.sprung, value: nurUngesehene)
    }

    /// **Was in der Liste steht.** Mit „Nur ungesehene" stehen gesehene
    /// Folgen gar nicht erst da und zählen nirgends mit — vorher blieben sie
    /// sichtbar und waren nur nicht mehr wählbar. Wie auf dem iPhone.
    private func sichtbar(_ liste: [Item]) -> [Item] {
        nurUngesehene ? liste.filter { !gesehen($0) } : liste
    }

    private func gesehen(_ folge: Item) -> Bool { folge.userData?.played ?? false }

    /// **Gesehen steht dabei, bevor man wählt.** Ohne Schalter bleiben
    /// gesehene Folgen wählbar — Kreis wie jede andere, aber Titel leise und
    /// rechts „gesehen" vor der Größe. Vom leisen Haken der geladenen Folgen
    /// unterscheidet sie der Kreis.
    private func folgenRechts(_ folge: Item) -> String {
        gesehen(folge) ? String(localized: "gesehen") + " · " + groesse(folge)
                       : groesse(folge)
    }

    /// Rechts in der Staffelzeile: was ein Haken dort noch nehmen würde.
    /// **„alles da" nur, wenn es stimmt** — nicht, solange die Staffel noch
    /// gelesen wird, und nicht, wenn „Nur ungesehene" alles ausschließt.
    private func staffelRechts(_ alle: [Item]?, sichtbar eigene: [Item],
                               _ kasten: Kasten) -> String {
        guard let alle else {
            return laedt ? String(localized: "wird gelesen …") : "—"
        }
        if alle.isEmpty { return String(localized: "Keine Folgen") }
        if eigene.isEmpty { return String(localized: "alles gesehen") }
        if kasten == .da { return String(localized: "alles da") }
        let frei = nehmbar(eigene)
        if frei.isEmpty { return String(localized: "alles da") }
        return String(localized: "\(frei.count) Folgen")
    }

    /// **Eine geladene Folge sagt, dass sie da ist.** Vorher stand dort ein
    /// leerer Kreis, der auf Klicken nichts tat.
    private func ladestand(_ posten: Downloadposten) -> String {
        switch posten.stand {
        case .fertig: String(localized: "geladen")
        case .laedt: String(localized: "lädt")
        default: String(localized: "wartet")
        }
    }

    /// **Der Fuß rechnet mit.** Links, was gewählt ist; rechts, was danach
    /// frei bleibt — nicht, was jetzt frei ist. Die Zahl, die man wissen
    /// will, ist die nach dem Laden.
    private var fuss: some View {
        VStack(spacing: 10) {
            Blattlinie()
            HStack(spacing: 10) {
                Text(verbatim: gewaehlt.isEmpty
                     ? String(localized: "Nichts gewählt")
                     : zahlUndGroesse(gewaehlt.count, bytes))
                    .font(Stil.kachel)
                    .monospacedDigit()
                    .foregroundStyle(Stil.schrift)
                Spacer(minLength: 8)
                platzangabe
            }
            .padding(.horizontal, 16)
            // **Die Qualität steht dabei, nicht im Kleingedruckten.** Swiftly
            // lädt die Originaldatei — bei 35 GB ist das die Erklärung für
            // die Zahl darüber und kein Nebensatz.
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                Text("Direct Play · Originalqualität").font(Stil.klein)
            }
            .foregroundStyle(Stil.akzent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Stil.akzent.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: Stil.eckeKlein, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)

            Hauptknopf(beschriftung: gewaehlt.isEmpty ? "Laden"
                                                     : LocalizedStringKey("\(gewaehltZahl) laden"),
                       symbol: "arrow.down") {
                offen = false
                weiter(gewaehlteFolgen)
            }
            .disabled(gewaehlt.isEmpty)
            .padding(.horizontal, 16)
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    /// **Rechts im Fuß: frei danach, oder was fehlt.** Bei zu wenig Platz
    /// stand hier „Danach 0 GB frei" — richtig gerechnet und trotzdem falsch,
    /// denn es sagte nicht, dass es nicht reicht. Ob es reicht, entscheidet
    /// `Downloadregeln.fussplatz`, mit derselben Reserve wie der Hinweis
    /// danach. Wie auf dem iPhone.
    @ViewBuilder
    private var platzangabe: some View {
        switch Downloadregeln.fussplatz(fuer: bytes, frei: model.downloads.frei) {
        case .frei(let rest):
            Text(verbatim: String(localized: "Danach \(Downloadregeln.groesse(rest)) frei"))
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
                .monospacedDigit()
        case .zuWenig(let fehlt):
            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                Text(verbatim: String(localized: "\(Downloadregeln.groesse(fehlt)) zu wenig"))
                    .font(Stil.klein)
                    .monospacedDigit()
            }
            .foregroundStyle(Stil.warnung)
        }
    }

    private var gewaehltZahl: String {
        let n = gewaehlt.count
        return n == 1 ? String(localized: "1 Folge") : String(localized: "\(n) Folgen")
    }

    private func zahlUndGroesse(_ anzahl: Int, _ bytes: Int64) -> String {
        let zahl = anzahl == 1 ? String(localized: "1 Folge")
                               : String(localized: "\(anzahl) Folgen")
        return zahl + " · " + Downloadregeln.groesse(bytes)
    }

    // MARK: Der Kasten und die Zeile

    /// Vier Zustände: die drei der Auswahl, und **da** für das, was schon
    /// auf dem Mac liegt und nicht mehr gewählt werden kann.
    private enum Kasten { case leer, teil, voll, da }

    private func stand(_ alle: [Item], daZaehlt: Bool = true) -> Kasten {
        let liste = sichtbar(alle)
        if daZaehlt, !liste.isEmpty,
           liste.allSatisfy({ model.downloads.posten(fuer: $0.id) != nil }) {
            return .da
        }
        let frei = nehmbar(liste)
        guard !frei.isEmpty else { return .leer }
        let an = frei.filter { gewaehlt.contains($0.id) }.count
        return an == 0 ? .leer : (an == frei.count ? .voll : .teil)
    }
    /// Solange nicht jede Staffel gelesen ist, ist die Serie nicht „da" —
    /// auch wenn die erste gelesene zufällig ganz geladen ist.
    private var standAlle: Kasten { stand(alleFolgen, daZaehlt: !laedt) }

    private func zeile(kasten: Kasten, titel: Text, rechts: String,
                       klein: Bool = false, einzug: CGFloat = 16,
                       aufgeklappt: Bool? = nil,
                       leise: Bool = false,
                       tun: @escaping () -> Void,
                       aufklappen: (() -> Void)? = nil) -> some View {
        HStack(spacing: 13) {
            Button(action: tun) { kastenbild(kasten) }
                .buttonStyle(Stil.Druckknopf())
                .disabled(kasten == .da)
                .accessibilityLabel(Text("Auswählen"))
                .accessibilityValue(kastenwert(kasten))
                .accessibilityAddTraits(kasten == .voll ? .isSelected : [])
            Button { (aufklappen ?? tun)() } label: {
                HStack(spacing: 10) {
                    titel
                        .font(klein ? Stil.kachel : Stil.listentitel)
                        .foregroundStyle(kasten == .da || leise ? Stil.schriftLeise : Stil.schrift)
                        .lineLimit(1)
                    Spacer(minLength: 10)
                    Text(verbatim: rechts)
                        .font(Stil.klein)
                        .foregroundStyle(Stil.schriftSehrLeise)
                        .monospacedDigit()
                    if let aufgeklappt {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Stil.schriftSehrLeise)
                            .rotationEffect(.degrees(aufgeklappt ? 0 : -90))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(Stil.Druckzeile())
        }
        .padding(.leading, einzug)
        .padding(.trailing, 16)
        // **Die eingerückte Folgenzeile trägt die 52 der übrigen Blätter, die
        // Staffelzeile eine Stufe darüber.** Die 58 sind die gewollte
        // Ausnahme, nicht ein zweiter Wert für dieselbe Rolle: die Folge soll
        // flacher stehen als die Staffel, zu der sie gehört. Paul hat beide
        // Werte am 22.09. bestätigt.
        .frame(minHeight: klein ? 52 : 58)
    }

    @ViewBuilder
    private func kastenbild(_ k: Kasten) -> some View {
        ZStack {
            switch k {
            case .leer:
                // Bedienzeichen brauchen 3:1. `rand` wäre mit 12 % zu wenig;
                // `schriftSehrLeise` trägt 4,71:1 auf `flaeche`.
                Circle().strokeBorder(Stil.schriftSehrLeise, lineWidth: 1.6)
            case .teil:
                Circle().fill(Stil.akzent)
                Image(systemName: "minus").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Stil.aufAkzent)
            case .voll:
                Circle().fill(Stil.akzent)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Stil.aufAkzent)
            case .da:
                // **Leise, ohne Kreis.** Ein Haken in Akzent hiesse
                // „gewählt"; dieser sagt nur, dass nichts mehr zu tun ist.
                Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Stil.schriftSehrLeise)
            }
        }
        .frame(width: 22, height: 22)
        .animation(Stil.umschalten, value: k)
    }

    /// Was VoiceOver zum Kreis sagt. „Gewählt" sagt `isSelected` selbst.
    private func kastenwert(_ k: Kasten) -> Text {
        switch k {
        case .leer, .voll: Text(verbatim: "")
        case .teil: Text("teilweise")
        case .da: Text("geladen")
        }
    }

    // MARK: Auswahl und Daten

    private func umschalten(_ liste: [Item]) {
        let frei = nehmbar(liste)
        guard !frei.isEmpty else { return }
        let alleAn = frei.allSatisfy { gewaehlt.contains($0.id) }
        withAnimation(Stil.umschalten) {
            for f in frei {
                if alleAn { gewaehlt.remove(f.id) } else { gewaehlt.insert(f.id) }
            }
        }
    }

    /// Nach dem Schalter: alles, was nicht mehr nehmbar ist, fällt heraus.
    private func neuRechnen() {
        let erlaubt = Set(nehmbar(alleFolgen).map(\.id))
        withAnimation(Stil.umschalten) { gewaehlt.formIntersection(erlaubt) }
    }

    private func bytesVon(_ liste: [Item]) -> Int64 {
        nehmbar(liste).reduce(0) { $0 + Int64($1.mediaSources?.first?.size ?? 0) }
    }

    private func groesse(_ folge: Item) -> String {
        guard let b = folge.mediaSources?.first?.size, b > 0 else { return "—" }
        return Downloadregeln.groesse(Int64(b))
    }

    /// **Jede Staffel einmal, und der Speicher zählt.**
    ///
    /// Die Serienseite hat nur die gewählte Staffel geladen. Für „ganze
    /// Serie" braucht die Tafel jede — sonst stünde dort eine Zahl, die nicht
    /// stimmt. Geholt wird nacheinander, damit der Server nicht sieben
    /// Anfragen auf einmal bekommt, und was schon da ist, wird nicht neu
    /// geholt.
    ///
    /// **`nil` heißt gestört, `[]` heißt leer.** Gescheiterte Abrufe werden
    /// nicht gemerkt — sonst stünde die leere Liste später als Tatsache da.
    private func alleLaden() async {
        laedt = true
        gestoert = false
        model.downloads.platzAuffrischen()
        folgen = vorgeladen
        for staffel in staffeln where folgen[staffel.id] == nil {
            guard let liste = await model.folgen(serie: serie.id, staffel: staffel.id) else {
                gestoert = true
                continue
            }
            folgen[staffel.id] = liste
            Serienspeicher.geteilt.merken(serie.id) { $0.folgen[staffel.id] = liste }
        }
        laedt = false
        // Was seit dem letzten Öffnen geladen wurde, ist nicht mehr wählbar —
        // sonst zählte der Fuß es noch mit.
        neuRechnen()
    }
}
