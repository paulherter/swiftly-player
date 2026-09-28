import JellyfinKit
import SwiftUI

// MARK: - Das Abzeichen oben

/// **Ein Abzeichen für alles, was gerade woanders läuft** (Entwurf A, wie
/// `Angebotsabzeichen` am iPhone).
///
/// Dieselbe Stelle wie bisher „Hier weiterschauen": links vom Profilbild.
/// Läuft woanders etwas **und** gibt es eine Gruppe, steht ein Zähler daran,
/// und ein Druck öffnet eine Tafel mit beidem — nicht zwei Abzeichen
/// nebeneinander, die das Profilbild verschieben.
///
/// **In Ruhe eine Zeile, im Fokus die zweite** — dieselbe Regel wie vorher
/// beim Übernahmeabzeichen: zwei Zeilen neben Reitern in 31 Punkt gingen
/// über dem Titelbild unter. Was ein Druck tut, sagt schon die erste Zeile;
/// wofür, steht da, bevor man drückt.
struct Angebotsabzeichen: View {
    let weiterschauen: [Fremdsitzung]
    let gruppen: [SyncPlayGruppe]
    var aktion: () -> Void

    /// Wie viele Einträge die Tafel hätte.
    var anzahl: Int { weiterschauen.count + gruppen.count }

    var body: some View {
        Button(action: aktion) {
            Inhalt(symbol: symbol, beschriftung: beschriftung, unter: wert,
                   zaehler: anzahl > 1 ? anzahl : nil)
        }
        .buttonStyle(AbzeichenStil(anderesGeraet: true))
        .accessibilityLabel(beschriftung)
        .accessibilityValue(Text(verbatim: wert))
    }

    private var symbol: String {
        if let erste = weiterschauen.first { return erste.geraetezeichen }
        return "person.2.fill"
    }

    private var beschriftung: Text {
        if anzahl > 1 { return Text("Läuft gerade") }
        return weiterschauen.isEmpty ? Text("Gemeinsam schauen") : Text("Hier weiterschauen")
    }

    private var wert: String {
        (weiterschauen.map(\.titelzeile) + gruppen.map(\.name)).joined(separator: ", ")
    }

    private struct Inhalt: View {
        let symbol: String
        let beschriftung: Text
        let unter: String
        let zaehler: Int?
        @Environment(\.isFocused) private var fokus

        var body: some View {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(Stil.kachel)
                VStack(alignment: .leading, spacing: 1) {
                    beschriftung
                        .font(Stil.knopf)
                    if fokus {
                        // Serverdaten, also `verbatim`.
                        Text(verbatim: unter)
                            .font(Stil.klein)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let zaehler {
                    // Wie der Zähler am iPhone: Akzent, in Ruhe wie im Fokus.
                    Text(verbatim: "\(zaehler)")
                        .font(Stil.plakette.monospacedDigit())
                        .foregroundStyle(Stil.aufAkzent)
                        .frame(minWidth: 34, minHeight: 34)
                        .background(Stil.akzent, in: Capsule())
                }
            }
            .padding(.horizontal, 28)
            .frame(height: fokus ? 76 : 64)
        }
    }
}

// MARK: - Tafeln

/// **Anlegen, Beitreten und die Auswahl — als Fokus-Tafeln über allem.**
///
/// Am iPhone sind es Blätter von unten; auf dem Fernseher gibt es keinen
/// Daumen unten, und die Wahl ist folgenreich wie bei der Übernahme — also
/// dieselbe Form wie `TVUebernahmeauswahl`: abgedunkelt, mittig, Menü
/// schließt. Hängt in ``HauptView``, weil jede Seite sie öffnen kann.
///
/// **Der Name ist vorbelegt, die Tastatur freiwillig.** Der Fokus steht auf
/// „Gruppe öffnen", nicht im Feld: wer „Filmabend" gut findet, drückt einmal.
/// Wer tippen will, geht hoch ins Feld — mit der Fernbedienung zu tippen ist
/// ein Umweg, den niemand für einen Gruppennamen nehmen muss.
struct TVGemeinsamtafeln: View {
    let weiterschauen: [Fremdsitzung]
    let hierWeiterschauen: (Fremdsitzung) -> Void
    var gemeinsam: Gemeinsammodell

    @State private var name = ""
    /// Die Zeile der Auswahl, auf der der Fokus steht — siehe `auswahl`.
    @FocusState private var auswahlFokus: String?

    var body: some View {
        ZStack {
            if let titel = gemeinsam.anlegenFuer {
                tafel(schliessen: { gemeinsam.anlegenFuer = nil }) { anlegen(titel) }
                    .onAppear { name = String(localized: "Filmabend") }
            } else if case let .beitreten(g)? = gemeinsam.blatt {
                tafel(schliessen: { gemeinsam.blatt = nil }) { beitreten(g) }
            } else if gemeinsam.blatt == .auswahl {
                tafel(schliessen: { gemeinsam.blatt = nil }) { auswahl }
                    .defaultFocus($auswahlFokus, ersteZeile)
                    .task { auswahlFokus = ersteZeile }
            }
        }
    }

    /// Der Rahmen um jede Tafel — derselbe wie bei `TVUebernahmeauswahl`.
    /// Den Schleier legt `HauptView` darunter, als eigene Ebene: er blendet
    /// nur, die Tafel kommt aus dem Abzeichen, wenn sie von dort kam.
    private func tafel<Inhalt: View>(schliessen: @escaping () -> Void,
                                     @ViewBuilder inhalt: () -> Inhalt) -> some View {
        ZStack {
            VStack(spacing: 34) { inhalt() }
                .padding(48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Menü schließt, wie überall auf dem Fernseher.
        .onExitCommand(perform: schliessen)
    }

    private func kopf(_ titel: Text, _ unter: String) -> some View {
        VStack(spacing: 10) {
            titel
                .font(Stil.unterseitentitel)
                .tracking(Stil.sperrungUnterseite)
            // Titel und Namen vom Server — wörtlich.
            Text(verbatim: unter)
                .font(Stil.klein)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Anlegen

    @ViewBuilder
    private func anlegen(_ titel: Item) -> some View {
        kopf(Text("Gemeinsam schauen"), Gemeinsammodell.titelzeile(titel))
        VStack(alignment: .leading, spacing: 12) {
            Text("Name der Gruppe")
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
            Eingabefeld(platzhalter: "Filmabend", text: $name)
            Text("Alle auf deinem Server sehen die Gruppe und können mit einsteigen. Pause und Springen gelten dann für alle.")
                .font(Stil.klein)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .frame(width: 760)
        .focusSection()
        Knopfpaar(haupt: Text("Gruppe öffnen"), gesperrt: gemeinsam.arbeitet,
                  tun: { Task { await gemeinsam.anlegen(name: name, titel: titel) } },
                  abbrechen: { gemeinsam.anlegenFuer = nil })
    }

    // MARK: Beitreten

    @ViewBuilder
    private func beitreten(_ g: SyncPlayGruppe) -> some View {
        kopf(Text(verbatim: g.name), Gemeinsammodell.wer(g))
        VStack(spacing: 8) {
            if let zustand = Gemeinsammodell.zustandText(g.zustand) {
                Text(zustand)
                    .font(Stil.klein)
                    .foregroundStyle(Stil.akzent)
            }
            Text("Pause und Springen gelten für alle.")
                .font(Stil.klein)
                .foregroundStyle(Stil.schriftSehrLeise)
        }
        Knopfpaar(haupt: Text("Beitreten"), gesperrt: gemeinsam.arbeitet,
                  tun: { Task { await gemeinsam.beitreten(g) } },
                  abbrechen: { gemeinsam.blatt = nil })
    }

    // MARK: Auswahl

    /// Geräte und Gruppen in einer Liste, wie am iPhone: jede Zeile sagt
    /// rechts, was ein Druck tut.
    ///
    /// **Der Fokus wird hineingesetzt, nicht gesucht.** Das Abzeichen, das
    /// die Tafel öffnet, wird mit ihr gesperrt — tvOS zieht den Fokus davon
    /// aber nicht ab. Ohne das hier blieb er auf dem gesperrten Abzeichen
    /// stehen, und die Tafel nahm keinen Druck an, bis die App einmal im
    /// Hintergrund war und der Fokus neu gesucht wurde. Beitreten und
    /// Anlegen setzen ihn in ``Knopfpaar`` genauso.
    @ViewBuilder
    private var auswahl: some View {
        Text("Läuft gerade")
            .font(Stil.unterseitentitel)
            .tracking(Stil.sperrungUnterseite)
        VStack(spacing: 14) {
            ForEach(weiterschauen) { s in
                zeile(schluessel: "s" + s.id, symbol: s.geraetezeichen,
                      titel: s.geraetename ?? String(localized: "Gerät"),
                      unter: s.titelzeile,
                      handlung: Text("Hier weiterschauen")) {
                    gemeinsam.blatt = nil
                    hierWeiterschauen(s)
                }
            }
            ForEach(gemeinsam.gruppe == nil ? gemeinsam.angebote : []) { g in
                zeile(schluessel: "g" + g.id, symbol: "person.2.fill", titel: g.name, unter: Gemeinsammodell.wer(g),
                      handlung: Text("Beitreten")) {
                    Task { await gemeinsam.beitreten(g) }
                }
            }
        }
        .focusSection()
        Button("Abbrechen") { gemeinsam.blatt = nil }
            .buttonStyle(AbzeichenStil())
    }

    /// Die oberste Zeile der Auswahl — dort beginnt der Fokus.
    private var ersteZeile: String? {
        if let s = weiterschauen.first { return "s" + s.id }
        return (gemeinsam.gruppe == nil ? gemeinsam.angebote.first : nil).map { "g" + $0.id }
    }

    private func zeile(schluessel: String, symbol: String, titel: String, unter: String, handlung: Text,
                       tun: @escaping () -> Void) -> some View {
        Button(action: tun) {
            HStack(spacing: 20) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .medium))
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: titel)
                        .font(Stil.listentitel)
                    Text(verbatim: unter)
                        .font(Stil.klein)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                handlung
                    .font(Stil.klein.weight(.semibold))
            }
            .padding(.horizontal, 28)
            .frame(height: 88)
            .frame(maxWidth: 760)
        }
        // Wie in der Übernahmeauswahl: kühl, weil es woanders läuft.
        .buttonStyle(AbzeichenStil(anderesGeraet: true))
        .focused($auswahlFokus, equals: schluessel)
    }
}

/// Die Haupthandlung und „Abbrechen" nebeneinander. Der Fokus beginnt auf
/// der Haupthandlung — siehe ``TVGemeinsamtafeln``.
private struct Knopfpaar: View {
    let haupt: Text
    let gesperrt: Bool
    let tun: () -> Void
    let abbrechen: () -> Void
    @FocusState private var amHaupt: Bool

    var body: some View {
        HStack(spacing: 24) {
            Button(action: tun) { haupt }
                .buttonStyle(KnopfStil())
                .disabled(gesperrt)
                .focused($amHaupt)
            Button("Abbrechen", action: abbrechen)
                .buttonStyle(KnopfStil())
        }
        .focusSection()
        .defaultFocus($amHaupt, true)
        .task { amHaupt = true }
    }
}

// MARK: - Rückweg

/// „Filmabend verlassen · Wieder beitreten" — Rückgängig statt Nachfrage.
///
/// **Unten, wo sonst nichts Fokussierbares steht**, als eigener
/// Fokusabschnitt über die ganze Breite: ein Druck nach unten landet im
/// Knopf, von jeder Stelle aus. Den Fokus holt er sich nicht selbst — er
/// gehört nach dem Schließen des Players dem Auslöser (VERHALTEN E5).
struct TVRueckwegstreifen: View {
    let name: String
    let beitreten: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 24) {
                Text("\(name) verlassen")
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(1)
                Button(action: beitreten) {
                    Text("Wieder beitreten")
                        .padding(.horizontal, 28)
                        .frame(height: 64)
                }
                .buttonStyle(AbzeichenStil(anderesGeraet: true))
            }
            .padding(.leading, 36)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
            .background(Stil.erhoeht, in: Capsule())
            .frame(maxWidth: .infinity)
            .focusSection()
            .padding(.bottom, Stil.randOben)
        }
    }
}

// MARK: - Im Player

/// „Filmabend · mit Paul und Tom" unter dem Titel — wo sonst Staffel und
/// Folge stehen. Der Name trägt den Akzent: in einer Gruppe zu sein ist ein
/// Zustand.
struct TVGruppenzeile: View {
    let name: String
    let mitWem: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .foregroundStyle(Stil.akzent)
            // Name und Teilnehmer kommen vom Server — wörtlich.
            Text(verbatim: name)
                .fontWeight(.semibold)
                .foregroundStyle(Stil.akzent)
            Text(verbatim: "· \(mitWem)")
        }
        .accessibilityElement(children: .combine)
    }
}

/// Kurz oben im Bild: wer kam, wer ging, warum der Film steht.
struct TVGruppenereignis: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Stil.akzent)
            Text(verbatim: text)
                .font(Stil.koerper)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
        }
        .padding(.horizontal, 30)
        .frame(minHeight: 76)
        .background(Stil.flaeche, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
