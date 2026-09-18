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
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Überschrift über einer Reihe.
struct Reihentitel: View {
    var text: LocalizedStringKey = ""
    /// **Wenn die Überschrift vom Server kommt** — ein Genre heißt, wie es
    /// heißt, und darf nicht durch die Übersetzungstabelle laufen.
    var name: String? = nil
    var body: some View {
        Group {
            if let name { Text(verbatim: name) } else { Text(text) }
        }
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
            // **Schneller dreht sich schneller an.** Bei gleicher Ladezeit
            // wirkt ein flotter Ring kuerzer als ein gemaechlicher — das ist
            // gefuehlte Leistung, nicht gemessene. 0,9 s je Umdrehung war
            // traege; 0,7 s traegt dieselbe Aussage zuegiger. Linear bleibt
            // es, eine Kurve wuerde bei einer Dauerdrehung stocken.
            .animation(.linear(duration: 0.7).repeatForever(autoreverses: false), value: dreht)
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
    /// Der Abruf ist gescheitert — meist, weil das Konto gar kein Bild hat.
    /// Dann gehört der Buchstabe hin, nicht der leere Verlauf.
    @State private var ohneBild = false

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
            } else if bild == nil || ohneBild {
                // Auch, wenn der Abruf scheitert: die Adresse steht für jedes
                // Konto da, ob es ein Bild hat oder nicht.
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
            ohneBild = false
            guard let bild else { geladen = nil; return }
            if let da = Bildspeicher.geteilt.bild(bild) { geladen = da; return }
            geladen = await Bildspeicher.geteilt.laden(bild, aufGeraet: true)
            ohneBild = geladen == nil
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

// MARK: - Zwischenablage

/// **Ein Klick, und der Code liegt in der Zwischenablage.**
///
/// Wer Quick Connect öffnet, hat den Code gleich danach woanders einzugeben —
/// meist in einem Browserfenster auf demselben Gerät. Ihn abzuschreiben,
/// während er daneben steht, ist die Art von Arbeit, die eine App abnehmen
/// soll.
///
/// **Auf dem Fernseher gibt es keine.** tvOS hat keine Zwischenablage, und
/// der Code steht dort ohnehin, um an einem *anderen* Gerät eingegeben zu
/// werden. Dort bleibt die Anzeige, wie sie ist.
enum Zwischenablage {

    /// Ob dieses Gerät eine hat.
    static var gibtEs: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    static func kopiere(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}

extension View {
    /// Macht die Ansicht anklickbar: der Text wandert in die Zwischenablage,
    /// und darunter steht kurz „Kopiert".
    func kopierbar(_ text: String) -> some View { modifier(Kopierbar(text: text)) }
}

private struct Kopierbar: ViewModifier {
    let text: String
    @State private var kopiert = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if Zwischenablage.gibtEs {
            Button {
                Zwischenablage.kopiere(text)
                withAnimation(.easeOut(duration: 0.15)) { kopiert = true }
            } label: {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .help(Text("Zum Kopieren klicken"))
            #endif
            .accessibilityLabel(Text("\(text), zum Kopieren"))
            // **Die Rückmeldung liegt über der Anzeige, nicht darunter.** Ein
            // Hinweis, der unter dem Code auftaucht, schiebt alles, was
            // darunter steht, um seine Höhe nach unten und wieder zurück.
            .overlay(alignment: .bottom) {
                if kopiert {
                    // **Kein Akzent.** Der Ton trägt Fortschritt, Auswahl
                    // und den Direct-Play-Beleg — eine Rückmeldung, die nach
                    // anderthalb Sekunden wieder weg ist, gehört nicht dazu
                    // (GESTALTUNG E2). Eine erhöhte Fläche mit Rand sagt
                    // dasselbe, ohne den Ton zu verbrauchen.
                    Text("Kopiert")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Stil.schrift)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Stil.erhoeht, in: Capsule())
                        .overlay { Capsule().strokeBorder(Stil.rand) }
                        .offset(y: 16)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .task(id: kopiert) {
                guard kopiert else { return }
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.25)) { kopiert = false }
            }
        } else {
            content
        }
    }
}

// MARK: - Fortschritt auf Kacheln

extension EnvironmentValues {
    /// **Ob Kacheln ihren Fortschrittsbalken zeigen** — Profil → Darstellung.
    ///
    /// Er lag als Einstellung vor, wurde gespeichert und gelesen hat ihn
    /// **niemand**: die Kacheln zeichneten den Balken immer. Ein Schalter, der
    /// nichts tut, auf vier Fassungen — genau das Muster, das CLAUDE.md
    /// „gebaut, aber nicht angeschlossen" nennt. Gefunden am 12.09.2026 beim
    /// Durchsehen vor der Beta.
    ///
    /// **Ueber die Umgebung, nicht ueber 33 Aufrufstellen.** So viele geben
    /// `fortschritt:` weiter; sie alle anzufassen hiesse, dieselbe Abfrage
    /// dreiunddreissigmal zu schreiben, und beim vierunddreissigsten Aufruf
    /// stuende sie nicht da. Gelesen wird sie an der einen Stelle je
    /// Plattform, an der der Balken wirklich entsteht.
    @Entry var fortschrittAufKacheln: Bool = true
}
