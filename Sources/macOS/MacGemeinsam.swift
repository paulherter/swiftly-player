import JellyfinKit
import SwiftUI

// „Gemeinsam schauen" auf dem Mac.
//
// **Die Vorlage ist iOS** (`Sources/iOS/Gemeinsamansichten.swift`), der
// Ablauf steht im Paket (`SyncPlaySitzung`), der Spiegel dafür in
// `Sources/Shared/Gemeinsammodell.swift`. Hier liegt nur die Darreichung,
// angepasst an Zeiger, Tastatur und Fenster (VERHALTEN F):
// - Das Abzeichen ist die Zeile unten in der Seitenleiste, dieselbe Stelle
//   wie „Hier weiterschauen" — dort, wo auf dem iPhone der Kopf rechts sitzt.
// - Anlegen, Beitreten und die Auswahl kommen nicht von unten, sondern als
//   Tafel mitten im Fenster über einem Schleier, wie die Geräteauswahl der
//   Übernahme (`Uebernahmeauswahl`). Blätter von unten gibt es am Mac nicht.
// - Eingabetaste bestätigt, Escape bricht ab.

// MARK: - Im Player

/// „Filmabend · mit Paul und Tom" unter dem Titel — wo sonst Jahr und
/// Laufzeit stehen. Der Name trägt den Akzent: in einer Gruppe zu sein ist
/// ein Zustand. Wörtlich die iPhone-Fassung.
struct Gruppenzeile: View {
    let name: String
    let mitWem: String
    let groesse: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.fill")
                .font(.system(size: groesse + 1))
                .foregroundStyle(Stil.akzent)
            // Name und Teilnehmer kommen vom Server — wörtlich.
            Text(verbatim: name)
                .fontWeight(.semibold)
                .foregroundStyle(Stil.akzent)
            Text(verbatim: "· \(mitWem)")
        }
        .font(.system(size: groesse))
        .accessibilityElement(children: .combine)
    }
}

/// Kurz oben im Bild: wer kam, wer ging, warum der Film steht.
///
/// In der Form des `Hinweisstreifen` — die Kapsel, die am Mac über einer
/// Fläche schwebt. Auf dem iPhone ist sie 44 hoch, weil dort jede Kapsel
/// eine Fingerfläche ist; hier nimmt sie keinen Klick an.
struct Gruppenereignis: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(Stil.listentitel)
                .foregroundStyle(Stil.akzent)
            Text(verbatim: text)
                .font(Stil.koerper)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: Stil.knopfFeld)
        .background(Stil.erhoeht, in: Capsule())
        .overlay(Capsule().strokeBorder(Stil.rand, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Die Zeile in der Seitenleiste

/// **Eine Zeile für alles, was gerade woanders läuft** (Entwurf A).
///
/// Hieß bis 1.0.5 `Uebernahmezeile` und kannte nur „Hier weiterschauen".
/// **`Mac`-eigene Fassung, weil die Leiste schmal ist.** Auf dem Fernseher
/// trägt das Abzeichen zwei Zeilen nebeneinander, hier stehen sie
/// untereinander.
///
/// Dieselbe Stelle wie „Hier weiterschauen" — sie *ist* diese Zeile. Läuft
/// woanders etwas **und** gibt es eine Gruppe, steht ein Zähler am Zeichen,
/// und ein Klick öffnet die Auswahl mit beidem — nicht zwei Zeilen
/// untereinander, die das Konto nach oben schieben.
struct Angebotszeile: View {
    let weiterschauen: [Fremdsitzung]
    let gruppen: [SyncPlayGruppe]

    @State private var schwebt = false

    /// Wie viele Einträge die Auswahl hätte.
    var anzahl: Int { weiterschauen.count + gruppen.count }

    var body: some View {
        // **Die Form des Fernsehers** (`Angebotsabzeichen`, `AbzeichenStil`
        // mit `anderesGeraet`): eine Kapsel in Akzent zu 18 % über `grund`,
        // Zeichen und Titel im Akzent, der Zähler als eigene Kapsel hinten.
        // Vorher ein abgerundetes Rechteck in `akzentLeise` mit dem Zähler
        // am Zeichen — eine zweite Form für dieselbe Sache.
        HStack(spacing: 10) {
            // **Der Akzent, und das Zeichen macht den Unterschied** — kein
            // eigenes Blau für „läuft woanders" (21.09.2026).
            Image(systemName: symbol)
                .font(Stil.kachel)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                titel
                    .font(Stil.kachelTitel)
                    .lineLimit(1)
                Text(verbatim: unter)
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if anzahl > 1 {
                // Wie am Fernseher: Akzent, Ziffern gleich breit.
                Text(verbatim: "\(anzahl)")
                    .font(Stil.plakette.monospacedDigit())
                    .foregroundStyle(Stil.aufAkzent)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Stil.akzent, in: Capsule())
            }
        }
        .foregroundStyle(Stil.akzent)
        .padding(.leading, 14)
        .padding(.trailing, anzahl > 1 ? 10 : 14)
        .frame(height: Stil.abzeichenHoehe)
        .background {
            ZStack {
                Capsule().fill(Stil.grund)
                Capsule().fill(Stil.akzent.opacity(0.18))
                if schwebt { Capsule().fill(Stil.schwebeflaeche) }
            }
        }
        .contentShape(Capsule())
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(titel)
        .accessibilityValue(Text(verbatim: unter))
    }

    private var symbol: String {
        if let erste = weiterschauen.first { return erste.geraetezeichen }
        return "person.2.fill"
    }

    /// Dieselben Namen wie das Abzeichen auf dem iPhone.
    private var titel: Text {
        if anzahl > 1 { return Text("Läuft gerade") }
        return weiterschauen.isEmpty ? Text("Gemeinsam schauen") : Text("Hier weiterschauen")
    }

    /// Was läuft — bei einem Eintrag sein Titel, sonst alle hintereinander.
    private var unter: String {
        (weiterschauen.map(\.titelzeile) + gruppen.map(\.name)).joined(separator: ", ")
    }
}

// MARK: - Die Tafeln

/// Die Tafeln „Gemeinsam schauen", „Beitreten" und die Auswahl. Hängt in
/// ``HauptView`` über allem außer dem Player, weil jede Seite sie öffnen
/// kann.
struct Gemeinsamtafeln: View {
    let uebernahme: [Fremdsitzung]
    let weiterschauen: (Fremdsitzung) -> Void

    @State private var gemeinsam = Gemeinsammodell.geteilt
    @State private var name = ""
    @FocusState private var tippt: Bool

    /// Welche Tafel steht. Anlegen hat Vorrang — sie kommt von einem Klick
    /// auf dieser Maschine, Beitreten und Auswahl aus der Seitenleiste.
    private enum Tafel: Equatable { case anlegen, beitreten, auswahl }
    private var tafel: Tafel? {
        if gemeinsam.anlegenFuer != nil { return .anlegen }
        switch gemeinsam.blatt {
        case .beitreten?: return .beitreten
        case .auswahl?: return .auswahl
        case nil: return nil
        }
    }

    var body: some View {
        ZStack {
            if let tafel {
                // Fängt den Klick ab, damit dahinter nichts reagiert — und
                // schließt, wie bei der Geräteauswahl der Übernahme.
                Stil.grund.opacity(0.62)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: abbrechen)
                    .transition(.opacity)

                VStack(spacing: 0) {
                    switch tafel {
                    case .anlegen: anlegen
                    case .beitreten: beitreten
                    case .auswahl: auswahl
                    }
                    Blattlinie()
                    Button(action: abbrechen) {
                        Text("Abbrechen")
                            .font(Stil.koerper)
                            .foregroundStyle(Stil.schriftLeise)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(Stil.Druckzeile())
                    .keyboardShortcut(.cancelAction)
                }
                .foregroundStyle(Stil.schrift)
                .background(Stil.flaeche, in: RoundedRectangle(cornerRadius: Stil.eckeFlaeche, style: .continuous))
                .frame(width: Stil.formularbreite)
                .accessibilityAction(.escape, abbrechen)
                // **Die Auswahl wächst aus dem Abzeichen** in der Seitenleiste
                // (wie am iPhone und wie „Wo weiterschauen?"); Anlegen und
                // Beitreten kommen von woanders und blenden wie bisher.
                .transition(tafel == .auswahl ? .ausDemPunkt(Abzeichenursprung.punkt)
                                              : .opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(tafel == .auswahl || tafel == nil ? Stil.feder : Stil.sprung, value: tafel)
        .onChange(of: gemeinsam.anlegenFuer?.id, initial: true) { _, neu in
            guard neu != nil else { tippt = false; return }
            name = String(localized: "Filmabend")
            // Erst wenn das Feld steht — im selben Durchgang gibt es es noch nicht.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                if gemeinsam.anlegenFuer != nil { tippt = true }
            }
        }
    }

    private func abbrechen() {
        tippt = false
        gemeinsam.anlegenFuer = nil
        gemeinsam.blatt = nil
    }

    // MARK: Anlegen

    @ViewBuilder private var anlegen: some View {
        Tafelrubrik(text: Text("Gemeinsam schauen"))
        if let titel = gemeinsam.anlegenFuer {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: Self.titelzeile(titel))
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .lineLimit(2)
                    .padding(.bottom, 16)
                Text("Name der Gruppe")
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .padding(.bottom, 6)
                TextField(text: $name) { Text("Filmabend") }
                    .textFieldStyle(.plain)
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schrift)
                    .focused($tippt)
                    // Die Eingabetaste im Feld öffnet die Gruppe. Kein
                    // `.defaultAction` am Knopf dazu: sonst ginge sie zweimal.
                    .onSubmit { oeffnen(titel) }
                    .padding(.horizontal, 12)
                    .frame(height: Stil.knopfFeld)
                    .background(Stil.erhoeht, in: RoundedRectangle(cornerRadius: Stil.eckeFeld, style: .continuous))
                Text("Alle auf deinem Server sehen die Gruppe und können mit einsteigen. Pause und Springen gelten dann für alle.")
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .padding(.bottom, 18)
                Hauptknopf(beschriftung: "Gruppe öffnen", symbol: "person.2.fill") { oeffnen(titel) }
                    .disabled(gemeinsam.arbeitet)
                    .opacity(gemeinsam.arbeitet ? 0.5 : 1)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private func oeffnen(_ titel: Item) {
        guard !gemeinsam.arbeitet else { return }
        tippt = false
        Task { await gemeinsam.anlegen(name: name, titel: titel) }
    }

    // MARK: Beitreten

    @ViewBuilder private var beitreten: some View {
        if case let .beitreten(g)? = gemeinsam.blatt {
            Tafelrubrik(text: Text(verbatim: g.name))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: Self.wer(g))
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                if let zustand = Self.zustandText(g.zustand) {
                    Text(zustand)
                        .font(Stil.klein)
                        .foregroundStyle(Stil.akzent)
                        .padding(.top, 6)
                }
                Text("Pause und Springen gelten für alle.")
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .padding(.top, 10)
                    .padding(.bottom, 18)
                Hauptknopf(beschriftung: "Beitreten", symbol: "person.2.fill") {
                    guard !gemeinsam.arbeitet else { return }
                    Task { await gemeinsam.beitreten(g) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(gemeinsam.arbeitet)
                .opacity(gemeinsam.arbeitet ? 0.5 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    // MARK: Auswahl

    @ViewBuilder private var auswahl: some View {
        Tafelrubrik(text: Text("Läuft gerade"))
        ForEach(uebernahme) { s in
            Blattlinie()
            Auswahlzeile(symbol: s.geraetezeichen,
                         titel: s.geraetename ?? String(localized: "Gerät"),
                         unter: s.titelzeile,
                         handlung: Text("Hier weiterschauen")) {
                gemeinsam.blatt = nil
                weiterschauen(s)
            }
        }
        ForEach(gemeinsam.gruppe == nil ? gemeinsam.angebote : []) { g in
            Blattlinie()
            Auswahlzeile(symbol: "person.2.fill", titel: g.name, unter: Self.wer(g),
                         handlung: Text("Beitreten")) {
                Task { await gemeinsam.beitreten(g) }
            }
        }
    }

    /// Bei einer Folge die Serie mit Staffel und Folge — sonst weiß man in
    /// der Tafel nicht, welche Folge die Gruppe schauen wird.
    static func titelzeile(_ titel: Item) -> String {
        guard titel.type == "Episode", let serie = titel.seriesName, !serie.isEmpty else {
            return titel.name
        }
        if let staffel = titel.parentIndexNumber, let folge = titel.indexNumber {
            return "\(serie) · " + String(localized: "Staffel \(staffel) · Folge \(folge)")
        }
        return "\(serie) · \(titel.name)"
    }

    /// „Paul und Tom schauen gerade".
    static func wer(_ g: SyncPlayGruppe) -> String {
        var gesehen = Set<String>()
        let namen = g.teilnehmer.filter { gesehen.insert($0).inserted }
        guard !namen.isEmpty else { return String(localized: "Noch niemand dabei") }
        let liste = ListFormatter.localizedString(byJoining: namen)
        return namen.count == 1 ? String(localized: "\(liste) schaut gerade")
                                : String(localized: "\(liste) schauen gerade")
    }

    static func zustandText(_ z: SyncPlayGruppe.Zustand?) -> LocalizedStringKey? {
        switch z {
        case .laeuft: "Läuft gerade"
        case .angehalten: "Angehalten"
        case .wartet: "Wartet auf alle"
        case .leer, nil: nil
        }
    }
}

/// Die Überschrift einer Tafel — die Stufe der Blattrubrik (17 Semifett).
private struct Tafelrubrik: View {
    let text: Text

    var body: some View {
        text
            .font(Stil.rubrikGross)
            .tracking(Stil.sperrungRubrik)
            .foregroundStyle(Stil.schrift)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Eine Zeile der Auswahl: Zeichen, was und wo, rechts die Handlung.
private struct Auswahlzeile: View {
    let symbol: String
    let titel: String
    let unter: String
    let handlung: Text
    let tun: () -> Void

    @State private var schwebt = false

    var body: some View {
        Button(action: tun) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(Stil.rubrikGross)
                    .foregroundStyle(Stil.akzent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: titel)
                        .font(Stil.listentitel)
                        .foregroundStyle(Stil.schrift)
                        .lineLimit(1)
                    Text(verbatim: unter)
                        .font(Stil.klein)
                        .foregroundStyle(Stil.schriftLeise)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                handlung
                    .font(Stil.listentitel)
                    .foregroundStyle(Stil.akzent)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 58)
            .background(schwebt ? Stil.schwebeflaeche : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckzeile())
        .onHover { schwebt = $0 }
        .animation(Stil.zeitSchweben, value: schwebt)
    }
}

// MARK: - Fehler

/// Was bei der Gruppe schiefging — im `Hinweisstreifen`, wie jede kurze
/// Meldung am Mac. Ein Klick oder vier Sekunden nehmen ihn weg.
struct Gemeinsamfehler: View {
    @State private var gemeinsam = Gemeinsammodell.geteilt

    var body: some View {
        ZStack {
            if let text = gemeinsam.fehler {
                Hinweisstreifen(text: text)
                    .contentShape(Capsule())
                    .onTapGesture { gemeinsam.fehler = nil }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { gemeinsam.fehler = nil }
                    .transition(.opacity)
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled, gemeinsam.fehler == text else { return }
                        gemeinsam.fehler = nil
                    }
            }
        }
        .animation(Stil.einblenden, value: gemeinsam.fehler)
    }
}

// MARK: - Nach dem Verlassen

/// „Filmabend verlassen · Wieder beitreten" — Rückgängig statt Nachfrage.
///
/// In der Form des `Hinweisstreifen`, unten mittig im Inhalt — dort, wo
/// auch auf dem iPhone jeder Hinweis steht. Wie lange er steht, sagt das
/// Paket (`SyncPlayLage.zuletztVerlassen`).
struct Rueckwegstreifen: View {
    let name: String
    let beitreten: () -> Void

    @State private var schwebt = false

    var body: some View {
        HStack(spacing: 12) {
            Text("\(name) verlassen")
                .font(Stil.koerper)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
            Button(action: beitreten) {
                Text("Wieder beitreten")
                    .font(Stil.listentitel)
                    .foregroundStyle(schwebt ? Stil.akzentHell : Stil.akzent)
                    .frame(height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(Stil.Druckknopf())
            .onHover { schwebt = $0 }
            .animation(Stil.zeitSchweben, value: schwebt)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .background(Stil.erhoeht, in: Capsule())
        .overlay(Capsule().strokeBorder(Stil.rand, lineWidth: 1))
    }
}
