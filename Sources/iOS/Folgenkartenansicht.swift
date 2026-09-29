import JellyfinKit
import SwiftUI

/// **Die nächste Folge als Karte unten rechts** — Variante C aus Pauls
/// Entwurf. Zeiten, Federn und Maße stehen in ``Folgenkarte`` im Paket;
/// hier nur die Zeichnung fürs iPhone und iPad.
///
/// Alles hängt an drei Werten, die der Player mit Federn bewegt: `da`
/// (hereinschieben/hinausschieben), `zoom` (Karte → ganzes Bild) und
/// `bild` (Deckkraft des Vorschaubilds, wenn darunter die neue Folge
/// läuft). Jede Feder startet aus dem jetzigen Stand — wer mitten
/// hineintippt, bekommt keinen Sprung.
///
/// **Ganz im sicheren Bereich** (26.09.2026, Pauls Bildschirmfoto: der Titel
/// lief unten aus dem Bild): gerechnet wird ab den Rändern des sicheren
/// Bereichs, nicht des Schirms, und die Karte wird auf schmalen Geräten
/// schmaler (``Folgenkarte/breite(_:sichereBreite:gross:)``).
///
/// **Abbrechen ist eindeutig** (Muster Max, 26.09.2026): das runde X an der
/// Kartenecke oder Wegwischen nach rechts oder unten. Tippen aufs Bild holt
/// die Steuerung — die Karte geht dann weg, der Countdown wartet, und mit
/// der Steuerung kommt sie zurück (`Angebotsebene.karteWartetBeiSteuerung`).
struct Folgenkartenansicht: View {
    let folge: Item
    let bildAdresse: URL?
    let pad: Bool
    /// Rand rechts, wie die Steuerung.
    let seite: CGFloat
    let da: Bool
    let zoom: Double
    let angabenDa: Bool
    let bild: Double
    let fuellung: Fuellungsuhr
    let rest: Int
    let tippen: () -> Void
    let abbrechen: () -> Void

    @State private var ziehen: CGSize = .zero

    private var masse: Folgenkarte.Masse { Folgenkarte.iPhone }
    /// Höhe der zwei Zeilen unter der Karte, samt Abstand.
    private var zeilen: CGFloat {
        CGFloat(masse.abstand) + ceil(CGFloat(masse.klein) * 1.2) + 3 + ceil(CGFloat(masse.titel) * 1.2)
    }

    /// **Die sicheren Ränder des Fensters.** Der Leser selbst ragt über den
    /// sicheren Bereich hinaus und meldet dann null (gemessen im Simulator,
    /// iPhone 17 Pro Max quer: 0 statt 62 links und rechts) — also vom
    /// Fenster, und das Größere von beiden.
    private func sicher(_ g: GeometryProxy) -> EdgeInsets {
        let f = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets ?? .zero
        let e = g.safeAreaInsets
        return EdgeInsets(top: max(e.top, f.top), leading: max(e.leading, f.left),
                          bottom: max(e.bottom, f.bottom), trailing: max(e.trailing, f.right))
    }

    /// Wo die Karte steht — innerhalb des sicheren Bereichs.
    private func karte(_ g: GeometryProxy) -> CGRect {
        let sicher = sicher(g)
        let sichereBreite = g.size.width - sicher.leading - sicher.trailing
        let breite = CGFloat(Folgenkarte.breite(masse, sichereBreite: Double(sichereBreite), gross: pad))
        let hoehe = breite * 9 / 16
        let unten = sicher.bottom + CGFloat(Folgenkarte.untenAbstand)
        return CGRect(x: g.size.width - sicher.trailing - seite - breite,
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

                    // Das runde X an der Kartenecke (wie bei Max): Karte weg,
                    // Countdown aus, Abspann läuft.
                    schliessknopf
                        .position(x: karte.maxX - 18, y: karte.minY + 18)
                        .opacity(angabenDa ? 1 : 0)
                        .animation(angabenKurve, value: angabenDa)
                        .allowsHitTesting(angabenDa)
                }
                .offset(versatz)
                .gesture(wischen, including: zoom > 0 ? .none : .all)
                // **Herein und hinaus bewegt sich nur die Karte** — von
                // rechts, aus 94 % Größe, mit Deckkraft.
                .opacity(da ? 1 : 0)
                .scaleEffect(zoom > 0 ? 1 : (da ? 1 : Folgenkarte.startmass),
                             anchor: UnitPoint(x: karte.midX / max(g.size.width, 1),
                                               y: karte.midY / max(g.size.height, 1)))
                .offset(x: da || Stil.bewegungReduziert ? 0 : Folgenkarte.versatz)
            }
            #if DEBUG
            .onChange(of: karte, initial: true) { _, k in
                let s = sicher(g)
                Protokoll.schreib("[Karte] Rahmen \(Int(k.minX)),\(Int(k.minY)) \(Int(k.width))×\(Int(k.height))"
                    + " · Zeilen bis \(Int(k.maxY + zeilen)) · Schirm \(Int(g.size.width))×\(Int(g.size.height))"
                    + " · sicher o\(Int(s.top)) l\(Int(s.leading)) u\(Int(s.bottom)) r\(Int(s.trailing))"
                    + " · unten frei \(Int(g.size.height - s.bottom - k.maxY - zeilen))"
                    + " · rechts frei \(Int(g.size.width - s.trailing - k.maxX))")
            }
            #endif
        }
        .ignoresSafeArea()
        // Weg ist weg: den Wisch vergessen, wenn die Karte gegangen ist.
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

    /// Folgt dem Finger nach rechts und unten; weit genug oder mit Schwung
    /// ist die Karte weg, sonst federt sie zurück.
    private var wischen: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { w in
                let z = Folgenkarte.gezogen(Double(w.translation.width), Double(w.translation.height))
                ziehen = CGSize(width: z.x, height: z.y)
            }
            .onEnded { w in
                let t = w.translation, p = w.predictedEndTranslation
                if Folgenkarte.weggewischt(x: Double(t.width), y: Double(t.height),
                                           schwungX: Double(p.width), schwungY: Double(p.height)) {
                    Protokoll.schreib("[Karte] weggewischt")
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

    /// Nacktes Zeichen an der Ecke der Karte wie die anderen Player-Symbole
    /// (kein Kreis: ein Kreis ist ein Bild, kein Knopf), 44 Punkt Trefferfläche.
    private var schliessknopf: some View {
        Button {
            Protokoll.schreib("[Karte] × gedrückt")
            abbrechen()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Stil.schrift)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Stil.Druckknopf())
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
            Bild(url: bildAdresse, ecke: 0)
                .opacity(bild)
            Countdownring(fuellung: fuellung, durchmesser: CGFloat(masse.ring))
                .opacity(angabenDa ? 1 : 0)
                .animation(angabenKurve, value: angabenDa)
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
