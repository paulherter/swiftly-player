import JellyfinKit
import SwiftUI

/// **Die nächste Folge als Karte unten rechts** — Variante C, wie auf dem
/// iPhone (`Sources/iOS/Folgenkartenansicht.swift`). Zeiten, Federn und Maße
/// stehen in ``Folgenkarte`` im Paket, Rahmen, Ring und Verlauf in
/// `Sources/Shared/Folgenkartenteile.swift`; hier nur die Zeichnung fürs
/// Fenster.
///
/// Alles hängt an denselben drei Werten wie dort: `da`, `zoom`, `bild` — jede
/// Feder startet aus dem jetzigen Stand.
///
/// **Drei Abweichungen, alle aus Zeiger und Fenster:**
/// - **Die Karte steht über der Leiste**, dort, wo die Überspringen-Pille
///   steht, nicht am unteren Rand. Am Mac holt jede Zeigerbewegung die
///   Steuerung (`Angebotsebene.Oeffnung.nebenbei`); wer zur Karte fährt, um
///   sie anzuklicken, öffnet dabei die Leiste. Stünde die Karte unten, läge
///   die Leiste über ihren Zeilen — und nähme sie die Karte weg, käme man mit
///   der Maus nie an sie heran. Erst ein Klick ins Bild (bewusst) lässt sie
///   warten, wie der Tipp aufs Bild am iPhone.
/// - **Abbrechen mit dem X an der Karte oder mit Esc** (`fluchttaste`),
///   Starten mit der Eingabetaste. Ziehen mit der Maus nach rechts oder
///   unten wirft sie weg wie das Wischen am iPhone.
/// - **Breite wie auf dem iPad** (`gross`), höchstens 30 % des Fensters.
struct Folgenkartenansicht: View {
    let folge: Item
    let bildAdresse: URL?
    let mass: Playermass
    let da: Bool
    let zoom: Double
    let angabenDa: Bool
    let bild: Double
    let fuellung: Fuellungsuhr
    let rest: Int
    let tippen: () -> Void
    let abbrechen: () -> Void

    @State private var ziehen: CGSize = .zero
    @State private var schwebt = false

    private var masse: Folgenkarte.Masse { Folgenkarte.iPhone }
    /// Höhe der zwei Zeilen unter der Karte, samt Abstand.
    private var zeilen: CGFloat {
        CGFloat(masse.abstand) + ceil(CGFloat(masse.klein) * 1.2) + 3 + ceil(CGFloat(masse.titel) * 1.2)
    }

    /// Wo die Karte steht: rechts am Rand der Steuerung, die Zeilen darunter
    /// enden dort, wo die Überspringen-Pille endet.
    private func karte(_ g: GeometryProxy) -> CGRect {
        let breite = CGFloat(Folgenkarte.breite(masse, sichereBreite: Double(g.size.width), gross: true))
        let hoehe = breite * 9 / 16
        let unten = mass.unten + mass.leiste + mass.ueberLeiste
        return CGRect(x: g.size.width - mass.seite - breite,
                      y: g.size.height - unten - zeilen - hoehe,
                      width: breite, height: hoehe)
    }

    var body: some View {
        GeometryReader { g in
            let karte = karte(g)
            let versatz = zoom > 0 ? .zero : ziehen
            ZStack(alignment: .topLeading) {
                // Der Verlauf blendet nur — er zieht nicht mit der Karte.
                Kartenschleier()
                    .opacity(angabenDa && da ? 1 : 0)
                    .animation(angabenKurve, value: angabenDa)
                    .allowsHitTesting(false)

                Group {
                    Button(action: tippen) {
                        kartenbild
                            .modifier(Kartenform(zoom: zoom, karte: karte, ganz: g.size,
                                                 ecke: CGFloat(masse.ecke)))
                    }
                    .buttonStyle(Stil.Druckknopf())
                    .disabled(zoom > 0)
                    .onHover { schwebt = $0 && zoom == 0 }
                    .animation(Stil.zeitSchweben, value: schwebt)
                    .modifier(Kartenlage(zoom: zoom, karte: karte, ganz: g.size))
                    .accessibilityLabel(Text("Nächste Folge abspielen: \(kuerzel)"))
                    .accessibilityValue(Text("Startet in \(rest) Sekunden"))
                    .accessibilityAction(named: Text("Karte schließen"), abbrechen)

                    angaben
                        .frame(width: karte.width, alignment: .leading)
                        .offset(x: karte.minX, y: karte.maxY + CGFloat(masse.abstand))
                        .opacity(angabenDa ? 1 : 0)
                        .offset(y: angabenDa || Stil.bewegungReduziert ? 0 : 6)
                        .animation(angabenKurve, value: angabenDa)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    // Das runde X an der Kartenecke: Karte weg, Countdown aus,
                    // Abspann läuft.
                    schliessknopf
                        .position(x: karte.maxX - 16, y: karte.minY + 16)
                        .opacity(angabenDa ? 1 : 0)
                        .animation(angabenKurve, value: angabenDa)
                        .allowsHitTesting(angabenDa)
                }
                .offset(versatz)
                .gesture(ziehenGeste, including: zoom > 0 ? .none : .all)
                .opacity(da ? 1 : 0)
                .scaleEffect(zoom > 0 ? 1 : (da ? 1 : Folgenkarte.startmass),
                             anchor: UnitPoint(x: karte.midX / max(g.size.width, 1),
                                               y: karte.midY / max(g.size.height, 1)))
                .offset(x: da || Stil.bewegungReduziert ? 0 : Folgenkarte.versatz)
            }
        }
        .ignoresSafeArea()
        // Weg ist weg: den Zug vergessen, wenn die Karte gegangen ist.
        .onChange(of: da) { _, jetzt in
            guard !jetzt else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { ziehen = .zero }
            }
        }
    }

    /// Folgt dem Zeiger nach rechts und unten; weit genug oder mit Schwung
    /// ist die Karte weg, sonst federt sie zurück. Dieselbe Regel wie das
    /// Wischen am iPhone (``Folgenkarte/weggewischt(x:y:schwungX:schwungY:)``).
    private var ziehenGeste: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { w in
                let z = Folgenkarte.gezogen(Double(w.translation.width), Double(w.translation.height))
                ziehen = CGSize(width: z.x, height: z.y)
            }
            .onEnded { w in
                let t = w.translation, p = w.predictedEndTranslation
                if Folgenkarte.weggewischt(x: Double(t.width), y: Double(t.height),
                                           schwungX: Double(p.width), schwungY: Double(p.height)) {
                    Protokoll.schreib("[Karte] weggezogen")
                    abbrechen()
                } else {
                    let f = Folgenkarte.feder(Folgenkarte.wegOmega)
                    withAnimation(Stil.bewegungReduziert ? Stil.blendeReduziert
                                  : .interpolatingSpring(mass: 1, stiffness: f.steifigkeit,
                                                         damping: f.daempfung)) {
                        ziehen = .zero
                    }
                }
            }
    }

    /// Klein und rund an der Ecke der Karte — am Mac mit 32 Punkt
    /// Trefferfläche, ein Zeiger trifft genauer als ein Daumen.
    private var schliessknopf: some View {
        Button {
            Protokoll.schreib("[Karte] × geklickt")
            abbrechen()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Stil.schrift)
                .frame(width: 24, height: 24)
                .background(Stil.flaeche.opacity(0.85), in: Circle())
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
        .help(Text("Karte schließen"))
        .accessibilityLabel(Text("Karte schließen"))
    }

    /// Ring und Zeilen gehen beim Start in ``Folgenkarte/angabenAus``.
    private var angabenKurve: Animation {
        Stil.bewegungReduziert ? Stil.blendeReduziert : .easeOut(duration: Folgenkarte.angabenAus)
    }

    // Aus dem Paket (`folgenkuerzel`), nicht mehr von Hand: stand hier fest
    // als „F", auch auf Englisch — dort ist es „E" (gemeldet 27.09.2026).
    private var kuerzel: String {
        folge.folgenkuerzel ?? folge.name
    }

    private var kartenbild: some View {
        ZStack {
            Color.black
            Netzbild(url: bildAdresse, vorrang: true)
                .opacity(bild)
            Countdownring(fuellung: fuellung, durchmesser: CGFloat(masse.ring))
                .opacity(angabenDa ? 1 : 0)
                .scaleEffect(schwebt && !Stil.bewegungReduziert ? 1.06 : 1)
                .animation(angabenKurve, value: angabenDa)
                .animation(Stil.zeitSchweben, value: schwebt)
        }
    }

    private var angaben: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Text(verbatim: kuerzel)
                Spacer(minLength: 0)
                Text("in \(rest) s")
                    .monospacedDigit()
            }
            .font(.system(size: CGFloat(masse.klein), weight: .semibold))
            .foregroundStyle(Stil.schriftSehrLeise)
            .lineLimit(1)
            Text(verbatim: folge.name)
                .font(.system(size: CGFloat(masse.titel), weight: .semibold))
                .foregroundStyle(Stil.schrift)
                .lineLimit(1)
        }
    }
}
