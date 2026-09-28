import AppKit
import Observation
import QuartzCore
import SwiftUI

/// **Die Bühne des Kontowechsels am Mac** — das Gegenstück zur UIKit-Bühne
/// des iPhones (`Sources/iOS/Uebergaenge.swift`). Ablauf, Zeiten und Kurve
/// stehen geteilt in ``Kontowechselflug``; hier nur, wie der Mac sie zeigt.
///
/// **Zwei Abweichungen, beide aus dem Fenster:**
/// - **Kein Standbild.** Das iPhone legt ein Bild des Schirms über alles und
///   lässt es als Seite wegfahren. Am Mac fährt die Profilseite selbst hinaus
///   — `Navigator.allesLeeren()`, dieselbe Bewegung wie ein Zurück —, und die
///   Seitenleiste bleibt stehen, in der das Bild landet.
/// - **Das Bild fliegt in einer SwiftUI-Auflage**, nicht als Ebene im
///   Render-Server. Auf dem iPhone hing es am Hauptlauf und ruckelte, weil
///   dort beim Wechsel die Startseite gebaut wird; der Wechsel selbst liegt
///   aber 0,3 s vor der Ruhe (``Kontowechselflug/wechselVorRuhe``), und dann
///   bewegt sich das Bild nur noch um Bruchteile eines Punkts.
@MainActor
enum Kontowechselbuehne {
    /// Breite des Fensters — für ``Kontowechselflug/zielMelden(_:)``.
    static var fensterbreite: CGFloat? { NSApp.keyWindow?.contentView?.bounds.width }

    /// Was auf der Bühne steht — damit ein früher Abschluss es abräumen kann.
    @MainActor
    final class Teile {
        let nummer: Int
        init(nummer: Int) { self.nummer = nummer }
        func abbrechen() { Kontowechselauftritt.geteilt.weg(nummer) }
    }

    /// `nil` ohne Fenster — dann gibt es keine Bewegung. `flaeche` und
    /// `inhaltAb` braucht nur das Standbild des iPhones.
    static func spielen(kurve: Kontowechselflug.Kurve?, bild: some View, von: CGRect,
                        flaeche: Color, inhaltAb: CGFloat, ruhig: Bool,
                        start: CFTimeInterval) -> Teile? {
        guard NSApp.keyWindow ?? NSApp.mainWindow != nil else { return nil }
        guard let kurve else { return Teile(nummer: 0) }
        return Teile(nummer: Kontowechselauftritt.geteilt.zeigen(kurve: kurve, bild: AnyView(bild),
                                                                 start: start))
    }
}

/// Was gerade fliegt — einer für das Fenster, gezeigt von
/// ``Kontowechselbild`` über der ganzen `HauptView`.
@MainActor
@Observable
final class Kontowechselauftritt {
    static let geteilt = Kontowechselauftritt()

    struct Auftritt {
        let nummer: Int
        let kurve: Kontowechselflug.Kurve
        let bild: AnyView
        let start: CFTimeInterval
    }

    private(set) var auftritt: Auftritt?
    @ObservationIgnored private var zaehler = 0

    func zeigen(kurve: Kontowechselflug.Kurve, bild: AnyView, start: CFTimeInterval) -> Int {
        zaehler += 1
        let nummer = zaehler
        auftritt = Auftritt(nummer: nummer, kurve: kurve, bild: bild, start: start)
        // Aufräumen nach dem Ring — vorher steht das Bild schon nicht mehr
        // (``Kontowechselbild`` zeichnet es nur bis zum Tausch).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, kurve.ringEnde + 0.05
                                                    - (CACurrentMediaTime() - start))))
            self.weg(nummer)
        }
        return nummer
    }

    func weg(_ nummer: Int) {
        guard auftritt?.nummer == nummer else { return }
        auftritt = nil
    }
}

/// **Das fliegende Profilbild und der Ring**, nach ``Kontowechselflug/Kurve``
/// — dieselben drei Federn, dieselbe Landung, derselbe Ring wie am iPhone
/// (Entwurf D). Nimmt keine Klicks.
struct Kontowechselbild: View {
    @State private var buehne = Kontowechselauftritt.geteilt

    var body: some View {
        GeometryReader { g in
            if let a = buehne.auftritt {
                let o = g.frame(in: .global).origin
                TimelineView(.animation) { _ in
                    let t = CACurrentMediaTime() - a.start
                    let basis = a.kurve.groesse * 1.06
                    ZStack(alignment: .topLeading) {
                        // Bis zum Tausch — dann steht dort das echte Bild.
                        if t < a.kurve.tausch {
                            let b = a.kurve.lage(max(0, t))
                            a.bild
                                .frame(width: basis, height: basis)
                                .scaleEffect(b.s / basis)
                                .position(x: b.x - o.x, y: b.y - o.y)
                        }
                        // Der Ring, nur angedeutet: ab der Landung, Feder
                        // 0,35/0,75, 0,45 s voll, dann 0,35 s aus — höchstens
                        // 55 %. Am Mac im Verhältnis zum kleineren Ziel.
                        let r = t - a.kurve.landung
                        if r >= 0, r < 0.8 {
                            let mass = Kontowechselflug.Kurve.feder(0.6, 1, 0, 0.35, 0.75, r)
                            let d = r < 0.45 ? min(1, r / 0.05) : 1 - min(1, (r - 0.45) / 0.35)
                            let kante = 52 * a.kurve.zielgroesse / Kontowechselflug.Kurve.zielgroesse
                            Circle()
                                .stroke(Stil.akzent, lineWidth: 2)
                                .frame(width: kante - 2, height: kante - 2)
                                .scaleEffect(mass)
                                .opacity(d * 0.55)
                                .position(x: a.kurve.nach.x - o.x, y: a.kurve.nach.y - o.y)
                        }
                    }
                    .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
