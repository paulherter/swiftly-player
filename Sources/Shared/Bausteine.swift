import JellyfinKit
//  Bausteine.swift
//  Swiftly
//
//  **Bausteine, die auf jeder Plattform dieselben sind.**
//
//  Sie standen dreimal da — einmal hier, einmal in `Sources/tvOS`, einmal in
//  `Sources/macOS` —, weil `Stil.swift` iPhone-Masse und neutrale Bausteine in
//  einer Datei mischte und die anderen Ziele sie deshalb nicht einbinden
//  konnten. Kopien laufen auseinander: bei `nachladen()`, `trefferauskunft`
//  und `Spielzeit` ist es passiert.
//
//  **Die Naht ist `Stil`.** Farben kommen aus `Farben.swift` und sind ohnehin
//  geteilt; Groessen kommen aus dem `Stil` des jeweiligen Ziels. Ein Baustein
//  hier darf deshalb nur benutzen, was **alle** Ziele haben:
//
//      Farben      akzent, rand, schrift, schriftLeise, flaeche
//      Stil        plakette, reihe
//
//  `Stil.randAbstand` gehoert nicht dazu — tvOS hat es nicht. Abstaende setzt
//  darum der Aufrufer, nicht der Baustein.

import SwiftUI

/// Überschrift über einer Reihe.
struct Reihentitel: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(Stil.reihe)
            .tracking(-0.3)
            .foregroundStyle(Stil.schrift)
    }
}

/// Kleine Angabe wie „FSK 16" oder „4K".
struct Plakette: View {
    let text: String
    /// **Die Farbe ist ein Parameter, kein fester Wert.** Der Dateiauszug
    /// faerbt die Warnung orange, wenn der Server doch transkodiert — das ist
    /// die eine Stelle, an der eine Plakette nicht nur beschriftet, sondern
    /// alarmiert. Waere sie fest, haette tvOS beim Uebernehmen der geteilten
    /// Fassung genau diese Auskunft verloren.
    var farbe: Color = Stil.schriftLeise
    /// Getrennt von `farbe`: sonst haette das Einfaerben der Schrift den Rand
    /// mitgezogen und die Plakette auf dem iPhone sichtbar heller gemacht.
    var randfarbe: Color = Stil.rand
    /// Masse als Parameter: auf dem Fernseher sind die iPhone-Werte zu klein.
    /// So kommt jede Plattform ohne eigene Kopie aus.
    var innenWaagerecht: CGFloat = 5
    var innenSenkrecht: CGFloat = 2
    var rundung: CGFloat = 3
    var strichstaerke: CGFloat = 1

    var body: some View {
        Text(text)
            .font(Stil.plakette)
            .foregroundStyle(farbe)
            .padding(.horizontal, innenWaagerecht)
            .padding(.vertical, innenSenkrecht)
            .overlay(RoundedRectangle(cornerRadius: rundung)
                .strokeBorder(randfarbe, lineWidth: strichstaerke))
    }
}

struct Lader: View {
    var groesse: CGFloat = 34
    var staerke: CGFloat = 3

    @State private var dreht = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.22)
            .stroke(Stil.akzent, style: StrokeStyle(lineWidth: staerke, lineCap: .round))
            .frame(width: groesse, height: groesse)
            .rotationEffect(.degrees(dreht ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: dreht)
            .background {
                Circle()
                    .stroke(Stil.akzent.opacity(0.18), lineWidth: staerke)
                    .frame(width: groesse, height: groesse)
            }
            .onAppear { dreht = true }
    }
}


/// Rundes Profilzeichen mit dem Anfangsbuchstaben.
struct Profilzeichen: View {
    let name: String
    var bild: URL?
    var groesse: CGFloat = 34
    var hervorgehoben = false

    /// **Was schon geholt wurde, steht im ersten Durchgang da.**
    ///
    /// Hier lag ein `AsyncImage`, und das faengt in jeder neuen Ansicht von
    /// vorn an — auch wenn dasselbe Bild seit dem Start im Speicher liegt.
    /// Waehrend es laeuft, steht nur der gruene Verlauf; das ist das, was am
    /// 07.09.2026 gemeldet wurde: „klicke ich auf mein Profilbild, ist es auf
    /// der Seite kurz nicht da, stattdessen ein gruener Hintergrund." Beim
    /// ersten Wechsel auf Filme oder Serien dasselbe, aus demselben Grund.
    ///
    /// Zwei Anlaeufe hatten den **Buchstaben** aus dem Weg geraeumt, ohne die
    /// Ursache anzufassen: dass die Ansicht das Bild neu holt, obwohl es
    /// dasteht. `Bildspeicher` beantwortet genau diese Frage, und er
    /// antwortet **synchron** — deshalb wird hier im `init` nachgesehen und
    /// nicht in `task`. Ein nachgereichter Wert kommt einen Durchgang zu
    /// spaet, und der eine Durchgang ist das Aufblitzen.
    @State private var geladen: Image?

    init(name: String, bild: URL? = nil, groesse: CGFloat = 34,
         hervorgehoben: Bool = false) {
        self.name = name
        self.bild = bild
        self.groesse = groesse
        self.hervorgehoben = hervorgehoben
        _geladen = State(initialValue: bild.flatMap { Bildspeicher.geteilt.bild($0) })
    }

    var body: some View {
        ZStack {
            // Der Verlauf traegt immer: er steht hinter dem Bild und faellt
            // nicht auf, wenn eines da ist.
            grund

            // **Der Buchstabe ist Rueckfall, nicht Untergrund.** Frueher lag
            // er immer darunter und das Bild darueber — waehrend dessen
            // Aufblende schien er hindurch, und wer ein Profilbild hatte, sah
            // fuer einen Moment ein grosses „P" darin. Er gehoert deshalb in
            // den Zweig, in dem kein Bild ankommt. **Und `.empty` heisst
            // „laeuft noch", nicht „kein Bild".**
            //
            // Der Absatz darueber hat den Buchstaben aus dem Untergrund in den
            // Rueckfallzweig geholt — aber der Zweig fing weiterhin *jede*
            // Lage ausser Erfolg ab, auch die des laufenden Abrufs. Deshalb
            // blitzte er weiter: nicht mehr unter dem Bild, sondern davor. Am
            // staerksten beim **ersten** Wechsel von der Startseite auf Filme
            // oder Serien, weil dort eine neue Ansicht entsteht und deren
            // `AsyncImage` von vorn anfaengt, obwohl das Bild laengst im
            // Speicher liegt. Danach war es weg, und genau so hat
            //
            // Waehrend des Abrufs steht deshalb nur der Verlauf. Dieselbe
            // Unterscheidung wie in `Bild`, dieselbe Ursache, dieselbe
            // Behebung.
            if let geladen {
                geladen.resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if bild == nil {
                // **Der Buchstabe ist Rueckfall, nicht Untergrund.** Er
                // gehoert in den Zweig, in dem es gar kein Bild gibt — lag er
                // darunter, schien er waehrend der Aufblende hindurch.
                buchstabe
            }
        }
        .animation(Stil.einblenden, value: geladen == nil)
        // Eine neue Adresse heisst ein neuer Anlauf; was schon dalag, bleibt
        // solange stehen, statt gegen den Verlauf zu tauschen.
        .task(id: bild) {
            guard let bild else { geladen = nil; return }
            if let da = Bildspeicher.geteilt.bild(bild) { geladen = da; return }
            geladen = await Bildspeicher.geteilt.laden(bild)
        }
        .frame(width: groesse, height: groesse)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(hervorgehoben ? Stil.akzent : Stil.rand,
                                  lineWidth: hervorgehoben ? 1.5 : 1)
        }
        .accessibilityElement()
        .accessibilityLabel("Profil von \(name)")
    }

    private var grund: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(red: 0.173, green: 0.424, blue: 0.400),
                                          Color(red: 0.090, green: 0.251, blue: 0.239)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var buchstabe: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: groesse * 0.38, weight: .semibold))
            .foregroundStyle(Stil.schrift)
    }
}

// MARK: - Übernahme: welches Gerät?

/// Läuft auf mehreren eigenen Geräten etwas, wird gefragt statt geraten.
///
/// **Der Schleier ist der Grund, warum das kein `confirmationDialog` ist.**
/// Der Systemdialog bringt seinen eigenen, sehr hellen mit; über einer dunklen
/// Startseite voller Plakate hebt er sich kaum ab. Hier gehört er uns.
///
/// Und die Wahl ist folgenreich: was hier gewählt wird, **schließt auf dem
/// anderen Gerät den Player**. Das gehört vor Augen, nicht in eine Zeile.
struct Uebernahmeauswahl: View {
    let sitzungen: [Fremdsitzung]
    var waehlen: (Fremdsitzung) -> Void
    var abbrechen: () -> Void

    var body: some View {
        ZStack {
            // Fängt auch den Druck ab, damit dahinter nichts reagiert.
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture(perform: abbrechen)

            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text("Wo weiterschauen?")
                        .font(.headline)
                    Text("Auf dem gewählten Gerät wird geschlossen, hier läuft es an derselben Stelle weiter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

                ForEach(sitzungen) { s in
                    Divider().overlay(Stil.schrift.opacity(0.12))
                    Button { waehlen(s) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: s.geraetezeichen)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Stil.akzent)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.geraetename ?? String(localized: "Gerät"))
                                    .font(.system(size: 16, weight: .semibold))
                                Text(s.titelzeile)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(Spielzeit.text(s.stand?.stelle ?? 0))
                                .font(.system(size: 13).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 20)
                        .frame(height: 58)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Divider().overlay(Stil.schrift.opacity(0.12))
                Button("Abbrechen", action: abbrechen)
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
            }
            .foregroundStyle(Stil.schrift)
            .background(Stil.erhoeht, in: RoundedRectangle(cornerRadius: Stil.ecke))
            .overlay(RoundedRectangle(cornerRadius: Stil.ecke)
                .strokeBorder(Stil.schrift.opacity(0.12)))
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
    }
}
