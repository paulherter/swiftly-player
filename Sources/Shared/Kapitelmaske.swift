import JellyfinKit
import SwiftUI

/// **Die Form der Zeitleiste: ein Stück je Kapitel.**
///
/// Liegt als Maske über Spur, Balken und Kerben — gezeichnet wird darunter
/// wie bisher, die Maske schneidet nur die Lücken heraus und gibt jedem Stück
/// seine Höhe. So bleiben die drei Leisten (iPhone, Mac, Fernseher) bei ihrem
/// eigenen Aufbau, und keine muss ihre Füllung je Kapitel neu stückeln.
///
/// **Ohne Kapitel ist es eine einzige Kapsel über die volle Breite** — genau
/// die Form, die die Spur vorher selbst hatte. Wer keine Kapitel hat, sieht
/// keinen Unterschied.
///
/// Wo geschnitten wird und welche Schnitte zu eng sind, rechnet
/// ``Kapitelleiste`` im Paket; hier steht nur das Zeichnen.
struct Kapitelmaske: View {
    let stuecke: [Kapitelleiste.Stueck]
    let breite: CGFloat
    /// Die Lücke zwischen zwei Stücken — so breit wie eine Kerbe, damit
    /// Kapitelgrenze und Abschnittsgrenze dasselbe Gewicht haben.
    let luecke: CGFloat
    let dicke: CGFloat
    /// **Das Stück, das sich hebt** — beim Spulen das unter dem Griff, sonst
    /// keins. Ohne Kapitel ist das die ganze Leiste, und sie wird beim
    /// Anfassen dicker wie bisher.
    let gehoben: Int?
    let dickeGehoben: CGFloat
    /// Wie das Heben läuft — jede Plattform mit ihrer eigenen Kurve, und
    /// jede hält sich darin an „Bewegung reduzieren". `nil`: es springt.
    let bewegung: Animation?

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(stuecke.indices, id: \.self) { i in
                let rahmen = stuecke[i].rahmen(breite: Double(breite), luecke: Double(luecke))
                Capsule()
                    .frame(width: CGFloat(rahmen.breite),
                           height: i == gehoben ? dickeGehoben : dicke)
                    .offset(x: CGFloat(rahmen.x))
            }
        }
        .frame(width: breite, alignment: .leading)
        // **Nur die Höhen wechseln mit Bewegung, nicht der Balken darunter.**
        // Stünde die Animation an der ganzen Leiste, liefe die Füllung bei
        // jedem Kapitelwechsel unter dem Finger einen Takt hinterher.
        .animation(bewegung, value: gehoben)
    }
}
