import JellyfinKit
import SwiftUI

/// **Die nächste Folge als Karte unten rechts — auf dem Fernseher** (Variante
/// C). Wie am iPhone, mit Fokus: steht die Karte, hat sie ihn und hebt sich
/// um 6 %; ein Klick drückt sie kurz ein und startet, Menü schiebt sie
/// hinaus und der Abspann läuft weiter. Zeiten, Federn und Maße aus
/// ``Folgenkarte``, gemeinsame Teile aus `Folgenkartenteile.swift`.
struct TVFolgenkarte: View {
    let folge: Item
    let bildAdresse: URL?
    let da: Bool
    let zoom: Double
    let angabenDa: Bool
    let bild: Double
    let fuellung: Fuellungsuhr
    let rest: Int
    let fokus: FocusState<PlayerScreen.Fokusziel?>.Binding
    let tippen: () -> Void

    private let masse = Folgenkarte.fernseher
    private var breite: CGFloat { CGFloat(masse.breite) }
    private var hoehe: CGFloat { breite * 9 / 16 }
    private var zeilen: CGFloat {
        CGFloat(masse.abstand) + CGFloat(masse.klein) * 1.3 + 6 + CGFloat(masse.titel) * 1.25
    }

    var body: some View {
        GeometryReader { g in
            let karte = CGRect(x: g.size.width - Stil.randSeite - breite,
                               y: g.size.height - Stil.randOben - zeilen - hoehe,
                               width: breite, height: hoehe)
            ZStack(alignment: .topLeading) {
                Kartenschleier()
                    .opacity(angabenDa && da ? 1 : 0)
                    .animation(angabenKurve, value: angabenDa)
                    .allowsHitTesting(false)

                Button(action: tippen) {
                    ZStack {
                        Color.black
                        Bild(url: bildAdresse, ecke: 0)
                            .opacity(bild)
                        Countdownring(fuellung: fuellung, durchmesser: CGFloat(masse.ring))
                            .opacity(angabenDa ? 1 : 0)
                            .animation(angabenKurve, value: angabenDa)
                    }
                    .modifier(Kartenform(zoom: zoom, karte: karte, ganz: g.size,
                                         ecke: CGFloat(masse.ecke)))
                }
                .buttonStyle(Kartenstil(gezoomt: zoom > 0))
                .focused(fokus, equals: .angebot)
                .disabled(!da || zoom > 0)
                .modifier(Kartenlage(zoom: zoom, karte: karte, ganz: g.size))
                .accessibilityLabel(Text("Nächste Folge abspielen: \(kuerzel)"))
                .accessibilityValue(Text("Startet in \(rest) Sekunden"))

                angaben
                    .frame(width: breite, alignment: .leading)
                    .offset(x: karte.minX, y: karte.maxY + CGFloat(masse.abstand))
                    .opacity(angabenDa ? 1 : 0)
                    .offset(y: angabenDa || Stil.bewegungReduziert ? 0 : 12)
                    .animation(angabenKurve, value: angabenDa)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .opacity(da ? 1 : 0)
            .scaleEffect(zoom > 0 ? 1 : (da ? 1 : Folgenkarte.startmass),
                         anchor: UnitPoint(x: karte.midX / max(g.size.width, 1),
                                           y: karte.midY / max(g.size.height, 1)))
            .offset(x: da || Stil.bewegungReduziert ? 0 : Folgenkarte.versatz * 2)
        }
        .ignoresSafeArea()
    }

    private var angabenKurve: Animation {
        Stil.bewegung(.easeOut(duration: Folgenkarte.angabenAus))
    }

    // Aus dem Paket (`folgenkuerzel`), nicht mehr von Hand: stand hier fest
    // als „F", auch auf Englisch — dort ist es „E" (gemeldet 27.09.2026).
    private var kuerzel: String {
        folge.folgenkuerzel ?? folge.name
    }

    private var angaben: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 24) {
                Text(verbatim: kuerzel)
                Spacer(minLength: 0)
                Text("in \(rest) s")
                    .monospacedDigit()
            }
            .font(.system(size: CGFloat(masse.klein), weight: .semibold))
            .foregroundStyle(Stil.schriftSehrLeise)
            Text(verbatim: folge.name)
                .font(.system(size: CGFloat(masse.titel), weight: .semibold))
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
        }
    }
}

/// Fokus hebt die Karte (``Folgenkarte/fokusmass``), ein Klick drückt sie
/// ein — per Feder, aus dem jetzigen Stand. Beim Zoom nichts davon.
private struct Kartenstil: ButtonStyle {
    let gezoomt: Bool

    func makeBody(configuration: Configuration) -> some View {
        Innen(configuration: configuration, gezoomt: gezoomt)
    }

    private struct Innen: View {
        let configuration: ButtonStyleConfiguration
        let gezoomt: Bool
        @Environment(\.isFocused) private var fokussiert

        var body: some View {
            let heben = fokussiert && !gezoomt ? Folgenkarte.fokusmass : 1
            let druck = configuration.isPressed ? 1 - Folgenkarte.klickDruck : 1
            configuration.label
                .scaleEffect(Stil.bewegungReduziert ? 1 : heben * druck)
                .animation(Stil.bewegung(.interpolatingSpring(
                    mass: 1, stiffness: Folgenkarte.feder(Folgenkarte.erscheinenOmega).steifigkeit,
                    damping: Folgenkarte.feder(Folgenkarte.erscheinenOmega).daempfung)),
                           value: heben * druck)
        }
    }
}
