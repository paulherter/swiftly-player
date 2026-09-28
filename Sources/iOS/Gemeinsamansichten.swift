import JellyfinKit
import SwiftUI

// MARK: - Im Player

/// „Filmabend · mit Paul und Tom" unter dem Titel — wo sonst Jahr und
/// Laufzeit stehen. Der Name trägt den Akzent: in einer Gruppe zu sein ist
/// ein Zustand.
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
struct Gruppenereignis: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Stil.akzent)
            Text(verbatim: text)
                .font(Stil.koerper)
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .background(Stil.flaeche, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Das Abzeichen oben

/// **Ein Abzeichen für alles, was gerade woanders läuft** (Entwurf A).
///
/// Dieselbe Stelle wie „Hier weiterschauen": links von Merkliste und
/// Profil. Läuft woanders etwas **und** gibt es eine Gruppe, steht ein
/// Zähler daran, und ein Tipp öffnet ein Blatt mit beidem — nicht zwei
/// Zeichen nebeneinander, die Merkliste und Profil verschieben.
struct Angebotsabzeichen: View {
    let uebernahme: Uebernahmemodell?
    /// Abstand darunter — nur, wenn es das Abzeichen gibt.
    var unten: CGFloat = 0
    @State private var gemeinsam = Gemeinsammodell.geteilt
    /// Wo das Zeichen auf dem Schirm steht — die Auswahl wächst von dort.
    @State private var rahmen: CGRect = .zero

    private var gruppen: [SyncPlayGruppe] {
        gemeinsam.gruppe == nil && gemeinsam.darfBeitreten ? gemeinsam.angebote : []
    }
    private var weiterschauen: [Fremdsitzung] { uebernahme?.angebote ?? [] }

    /// Wie viele Einträge das Blatt hätte.
    var anzahl: Int { weiterschauen.count + gruppen.count }

    var body: some View {
        if anzahl > 0 {
            Button(action: antippen) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(Stil.akzent)
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) {
                        if anzahl > 1 {
                            Text(verbatim: "\(anzahl)")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Stil.aufAkzent)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Stil.akzent, in: Capsule())
                                .offset(x: -2, y: 4)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(Stil.Druckknopf())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rahmen = $0 }
            .accessibilityLabel(beschriftung)
            .accessibilityValue(Text(verbatim: wert))
            .padding(.bottom, unten)
            .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
        }
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

    private func antippen() {
        Abzeichenursprung.punkt = CGPoint(x: rahmen.midX, y: rahmen.midY)
        if gruppen.isEmpty {
            uebernahme?.angetippt = true
        } else if weiterschauen.isEmpty, gruppen.count == 1, let g = gruppen.first {
            gemeinsam.blatt = .beitreten(g)
        } else {
            gemeinsam.blatt = .auswahl
        }
    }
}

// MARK: - Blätter

/// Die Blätter „Gemeinsam schauen", „Beitreten" und die Auswahl, und der
/// Streifen nach dem Verlassen. Hängt in ``HauptView`` über allem, weil jede
/// Wurzelseite und jede Detailseite sie öffnen kann.
struct Gemeinsamblaetter: View {
    let uebernahme: [Fremdsitzung]
    let weiterschauen: (Fremdsitzung) -> Void

    @State private var gemeinsam = Gemeinsammodell.geteilt
    @State private var name = ""
    @FocusState private var tippt: Bool

    /// **Was das Blatt zeigt, bleibt im Baum — auch zu, und schon bevor es
    /// aufgeht.** Hing der Inhalt direkt an `anlegenFuer`, entstand er im
    /// selben Augenblick, in dem das Blatt aufging: neu eingefügte Ansichten
    /// stehen sofort an ihrer Endstelle und fahren den animierten Versatz des
    /// Blatts nicht mit — Text und Knopf waren da, das Blatt kam darunter
    /// nach. Jetzt steht der Inhalt zuerst, und das Blatt geht einen Takt
    /// später auf.
    @State private var anlegenTitel: Item?
    @State private var anlegenAuf = false
    @State private var beitretenGruppe: SyncPlayGruppe?
    @State private var beitretenAuf = false

    var body: some View {
        ZStack {
            Color.clear
                .allowsHitTesting(false)
                .blatt(offen: anlegenOffen) { anlegen }
            Color.clear
                .allowsHitTesting(false)
                .blatt(offen: beitretenOffen) { beitreten }
            // **Die Auswahl ist eine Karte aus dem Abzeichen**, kein Blatt
            // von unten (Versuch `experiment-glas`) — wie „Wo
            // weiterschauen?" in `HauptView`.
            if auswahlOffen {
                Uebernahmeauswahl.schleier { gemeinsam.blatt = nil }
                    .transition(.opacity)
                VStack(spacing: 0) { auswahl }
                    .padding(.top, 15)
                    .background(Stil.flaeche,
                                in: RoundedRectangle(cornerRadius: Stil.eckeFlaeche, style: .continuous))
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 24)
                    .accessibilityAction(.escape) { gemeinsam.blatt = nil }
                    .transition(.ausDemPunkt(Abzeichenursprung.punkt))
            }

            if let alt = gemeinsam.zuletztVerlassen {
                Rueckwegstreifen(name: alt.name) { gemeinsam.wiederBeitreten() }
                    .transition(.opacity)
            } else if let fehler = gemeinsam.fehler, !gemeinsam.imPlayer {
                // Im Player zeigt er selbst den Streifen.
                Hinweisstreifen(text: fehler) { gemeinsam.fehler = nil }
            }
        }
        .animation(Stil.feder, value: auswahlOffen)
        .animation(Stil.einblenden, value: gemeinsam.zuletztVerlassen?.id)
        .animation(Stil.einblenden, value: gemeinsam.fehler)
        .onChange(of: gemeinsam.anlegenFuer?.id) { _, neu in
            guard neu != nil, let titel = gemeinsam.anlegenFuer else {
                anlegenAuf = false
                return
            }
            anlegenTitel = titel
            name = String(localized: "Filmabend")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                anlegenAuf = gemeinsam.anlegenFuer != nil
            }
        }
        .onChange(of: gemeinsam.blatt) { _, neu in
            guard case let .beitreten(g)? = neu else {
                beitretenAuf = false
                return
            }
            beitretenGruppe = g
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                if case .beitreten? = gemeinsam.blatt { beitretenAuf = true }
            }
        }
    }

    // MARK: Anlegen

    private var anlegenOffen: Binding<Bool> {
        Binding(get: { anlegenAuf },
                set: { if !$0 { anlegenAuf = false; gemeinsam.anlegenFuer = nil; tippt = false } })
    }

    @ViewBuilder private var anlegen: some View {
        Blattrubrik(text: Text("Gemeinsam schauen"))
        if let titel = anlegenTitel {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: Gemeinsammodell.titelzeile(titel))
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .padding(.top, -10)
                    .padding(.bottom, 16)
                Text("Name der Gruppe")
                    .font(Stil.klein)
                    .foregroundStyle(Stil.schriftSehrLeise)
                    .padding(.bottom, 6)
                TextField(text: $name) { Text("Filmabend") }
                    .font(.system(size: 17))
                    .foregroundStyle(Stil.schrift)
                    .focused($tippt)
                    .submitLabel(.done)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Stil.erhoeht, in: RoundedRectangle(cornerRadius: Stil.eckeFeld, style: .continuous))
                Text("Alle auf deinem Server sehen die Gruppe und können mit einsteigen. Pause und Springen gelten dann für alle.")
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .padding(.bottom, 18)
                Button {
                    tippt = false
                    Task { await gemeinsam.anlegen(name: name, titel: titel) }
                } label: {
                    Text("Gruppe öffnen")
                }
                .buttonStyle(HauptknopfStil(gesperrtFlaeche: Stil.erhoeht))
                .disabled(gemeinsam.arbeitet)
            }
            .padding(.horizontal, Stil.randAbstand)
            .padding(.bottom, 12)
        }
        Blattlinie()
        Blattabbruch { gemeinsam.anlegenFuer = nil; tippt = false }
    }

    // MARK: Beitreten

    private var beitretenOffen: Binding<Bool> {
        Binding(get: { beitretenAuf },
                set: { if !$0 { beitretenAuf = false; gemeinsam.blatt = nil } })
    }

    @ViewBuilder private var beitreten: some View {
        if let g = beitretenGruppe {
            Blattrubrik(text: Text(verbatim: g.name))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: Gemeinsammodell.wer(g))
                    .font(Stil.koerper)
                    .foregroundStyle(Stil.schriftLeise)
                    .padding(.top, -10)
                if let zustand = Gemeinsammodell.zustandText(g.zustand) {
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
                Button {
                    Task { await gemeinsam.beitreten(g) }
                } label: {
                    Text("Beitreten")
                }
                .buttonStyle(HauptknopfStil(gesperrtFlaeche: Stil.erhoeht))
                .disabled(gemeinsam.arbeitet)
            }
            .padding(.horizontal, Stil.randAbstand)
            .padding(.bottom, 12)
        }
        Blattlinie()
        Blattabbruch { gemeinsam.blatt = nil }
    }

    // MARK: Auswahl

    private var auswahlOffen: Bool { gemeinsam.blatt == .auswahl }

    @ViewBuilder private var auswahl: some View {
        Blattrubrik(text: Text("Läuft gerade"))
        ForEach(uebernahme) { s in
            Blattlinie()
            zeile(symbol: s.geraetezeichen,
                  titel: s.geraetename ?? String(localized: "Gerät"),
                  unter: s.titelzeile,
                  handlung: Text("Hier weiterschauen")) {
                gemeinsam.blatt = nil
                weiterschauen(s)
            }
        }
        ForEach(gemeinsam.gruppe == nil ? gemeinsam.angebote : []) { g in
            Blattlinie()
            zeile(symbol: "person.2.fill", titel: g.name, unter: Gemeinsammodell.wer(g),
                  handlung: Text("Beitreten")) {
                Task { await gemeinsam.beitreten(g) }
            }
        }
        Blattlinie()
        Blattabbruch { gemeinsam.blatt = nil }
    }

    private func zeile(symbol: String, titel: String, unter: String, handlung: Text,
                       tun: @escaping () -> Void) -> some View {
        Button(action: tun) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Stil.akzent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: titel)
                        .font(Stil.listentitel)
                        .foregroundStyle(Stil.schrift)
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
            .padding(.horizontal, Stil.randAbstand)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckzeile())
    }
}

/// „Filmabend verlassen · Wieder beitreten" — Rückgängig statt Nachfrage.
struct Rueckwegstreifen: View {
    let name: String
    let beitreten: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Text("\(name) verlassen")
                    .font(.system(size: 13))
                    .foregroundStyle(Stil.schrift)
                    .lineLimit(1)
                Button(action: beitreten) {
                    Text("Wieder beitreten")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Stil.akzent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(Stil.Druckknopf())
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .background(Stil.flaeche, in: Capsule())
            // **Dieselbe Stelle wie jeder Hinweis** (`Hinweisstreifen`):
            // 34 über dem unteren Rand, 24 zur Seite. Hier standen 96 — der
            // Streifen hing im unteren Drittel.
            .padding(.bottom, 34)
            .padding(.horizontal, 24)
        }
    }
}
