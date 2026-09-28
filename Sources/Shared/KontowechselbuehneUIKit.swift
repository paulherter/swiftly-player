import OSLog
import QuartzCore
import SwiftUI
import UIKit

// MARK: - Die Bühne des Kontowechsels in UIKit — iPhone, iPad, Fernseher
//
// Ablauf und Kurve des Kontowechsels stehen geteilt in
// `Sources/Shared/Kontowechselflug.swift`; hier nur, was UIKit braucht. Am
// Mac steht die Bühne in `Sources/macOS/Kontowechselbuehne.swift`.

/// **Die Bühne des Kontowechsels in UIKit**: Standbild und fliegendes Bild
/// als Ebenen im Fenster, mit Core-Animation-Stützpunkten — siehe
/// ``Kontowechselflug``.
@MainActor
enum Kontowechselbuehne {
    /// Breite des Fensters — für ``Kontowechselflug/zielMelden(_:)``.
    static var fensterbreite: CGFloat? { fenster?.bounds.width }

    private static var fenster: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    /// Was auf der Bühne steht — damit ein früher Abschluss es abräumen kann.
    final class Teile {
        var standbild: UIView?
        var ebene: CALayer?
        var ring: CALayer?

        /// Das Standbild blendet kurz aus, Bild und Ring gehen sofort — das
        /// echte Bild steht an ihrer Stelle.
        func abbrechen() {
            if let standbild {
                UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState],
                               animations: { standbild.alpha = 0 },
                               completion: { _ in standbild.removeFromSuperview() })
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ebene?.removeFromSuperlayer()
            ring?.removeFromSuperlayer()
            CATransaction.commit()
            standbild = nil; ebene = nil; ring = nil
        }
    }

    /// `nil` ohne Fenster — dann gibt es keine Bewegung.
    static func spielen(kurve: Kontowechselflug.Kurve?, bild: some View, von: CGRect,
                        flaeche: Color, inhaltAb: CGFloat, ruhig: Bool,
                        start: CFTimeInterval) -> Teile? {
        guard let fenster else { return nil }
        let flaeche = UIColor(flaeche)
        let teile = Teile()
        // 1. Das Standbild der Profilseite. Das angetippte Bild ist darauf
        //    zugedeckt — es fliegt ja schon.
        //
        //    **Mit Seitenleiste (iPad breit) nur der Inhalt rechts davon** —
        //    die Leiste bleibt stehen, und in ihr landet das Bild.
        let ausschnitt = CGRect(x: inhaltAb, y: 0, width: fenster.bounds.width - inhaltAb,
                                height: fenster.bounds.height)
        let standbild = inhaltAb > 0
            ? fenster.resizableSnapshotView(from: ausschnitt, afterScreenUpdates: false,
                                            withCapInsets: .zero)
            : fenster.snapshotView(afterScreenUpdates: false)
        if let standbild {
            standbild.frame = ausschnitt
            if kurve != nil {
                // Auf dem Fernseher liegt um das fokussierte Bild der Ring
                // und die Lupe — der Deckel nimmt beides mit.
                #if os(tvOS)
                let deckelrand: CGFloat = -8
                #else
                let deckelrand: CGFloat = -3
                #endif
                let deckel = UIView(frame: von.insetBy(dx: deckelrand, dy: deckelrand)
                    .offsetBy(dx: -inhaltAb, dy: 0))
                deckel.backgroundColor = flaeche
                deckel.layer.cornerRadius = deckel.bounds.width / 2
                standbild.addSubview(deckel)
            }
            // **Kein Schatten** (Paul, 26.09.): er stand riesig unter der
            // wegfahrenden Seite und verschwand am Ende schlagartig.
            // Tipps gehen hindurch: das Profil oben ist sofort wieder
            // antippbar, auch solange die Seite noch wegfährt.
            standbild.isUserInteractionEnabled = false
            fenster.addSubview(standbild)
            teile.standbild = standbild
            #if os(tvOS)
            // **Der Fernseher blendet aus** — tvOS schiebt keine Seiten, und
            // die Bereiche der App überblenden auch (`Stil.seitenwechsel`).
            let ausblenden = true
            #else
            let ausblenden = ruhig
            #endif
            if ausblenden {
                UIView.animate(withDuration: ruhig ? 0.2 : 0.3, delay: ruhig ? 0 : 0.08,
                               options: [.curveEaseOut], animations: { standbild.alpha = 0 },
                               completion: { _ in standbild.removeFromSuperview(); teile.standbild = nil })
            } else {
                // Wie ein gewöhnliches Zurück: Feder 0,42, keine Überschwinger,
                // 80 ms nach dem Tipp.
                UIView.animate(springDuration: 0.42, bounce: 0, initialSpringVelocity: 0, delay: 0.08,
                               options: [], animations: {
                    standbild.transform = CGAffineTransform(translationX: ausschnitt.width, y: 0)
                }, completion: { _ in standbild.removeFromSuperview(); teile.standbild = nil })
            }
        }
        guard let kurve else { return teile }

        // 2. Das fliegende Bild: einmal gezeichnet, dann nur bewegt.
        let basis = kurve.groesse * 1.06
        let zeichner = ImageRenderer(content: bild.frame(width: basis, height: basis))
        zeichner.scale = fenster.screen.scale
        let ebene = CALayer()
        ebene.contents = zeichner.cgImage
        ebene.contentsScale = fenster.screen.scale
        ebene.bounds = CGRect(x: 0, y: 0, width: basis, height: basis)
        ebene.position = kurve.nach
        ebene.transform = CATransform3DMakeScale(kurve.zielgroesse / basis,
                                                 kurve.zielgroesse / basis, 1)
        var orte: [NSValue] = [], masse: [NSNumber] = [], zeiten: [NSNumber] = []
        let schritte = max(2, Int(kurve.tausch * 120))
        for i in 0 ... schritte {
            let t = kurve.tausch * Double(i) / Double(schritte)
            let b = kurve.lage(t)
            orte.append(NSValue(cgPoint: CGPoint(x: b.x, y: b.y)))
            masse.append(NSNumber(value: Double(b.s / basis)))
            zeiten.append(NSNumber(value: Double(i) / Double(schritte)))
        }
        let ort = CAKeyframeAnimation(keyPath: "position")
        ort.values = orte
        let mass = CAKeyframeAnimation(keyPath: "transform.scale")
        mass.values = masse
        for a in [ort, mass] {
            a.keyTimes = zeiten
            a.duration = kurve.tausch
            a.beginTime = start
            a.fillMode = .backwards
            a.calculationMode = .linear
            ebene.add(a, forKey: a.keyPath)
        }
        fenster.layer.addSublayer(ebene)
        teile.ebene = ebene

        // 3. Der Ring, nur angedeutet: ab der Landung, Feder 0,35/0,75,
        //    0,45 s voll, dann 0,35 s aus — höchstens 55 %.
        let ring = CAShapeLayer()
        // Auf dem Fernseher so groß wie der Fokusring der Kopfleiste
        // (`ProfilStil`: 4 Punkt, 8 außen, mit Lupe) — der Pop landet in ihm.
        #if os(tvOS)
        let ringmass: CGFloat = (60 + 16) * Stil.fokusLupeKlein, strich: CGFloat = 4
        #else
        let ringmass: CGFloat = 52, strich: CGFloat = 2
        #endif
        ring.path = UIBezierPath(ovalIn: CGRect(x: strich / 2, y: strich / 2,
                                                width: ringmass - strich, height: ringmass - strich)).cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor(Stil.akzent).cgColor
        ring.lineWidth = strich
        ring.bounds = CGRect(x: 0, y: 0, width: ringmass, height: ringmass)
        ring.position = kurve.nach
        ring.opacity = 0
        var ringmasse: [NSNumber] = [], ringdeckung: [NSNumber] = [], ringzeiten: [NSNumber] = []
        for i in 0 ... 96 {
            let r = 0.8 * Double(i) / 96
            ringmasse.append(NSNumber(value: Double(Kontowechselflug.Kurve.feder(0.6, 1, 0, 0.35, 0.75, r))))
            let d = r < 0.45 ? min(1, r / 0.05) : 1 - min(1, (r - 0.45) / 0.35)
            ringdeckung.append(NSNumber(value: d * 0.55))
            ringzeiten.append(NSNumber(value: Double(i) / 96))
        }
        let rm = CAKeyframeAnimation(keyPath: "transform.scale")
        rm.values = ringmasse
        let rd = CAKeyframeAnimation(keyPath: "opacity")
        rd.values = ringdeckung
        for a in [rm, rd] {
            a.keyTimes = ringzeiten
            a.duration = 0.8
            a.beginTime = start + kurve.landung
            ring.add(a, forKey: a.keyPath)
        }
        fenster.layer.addSublayer(ring)
        teile.ring = ring

        // Aufräumen: das Bild einen Durchgang nach dem Tausch (dann steht
        // das echte schon), der Ring nach seinem Ende.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, kurve.tausch + 0.05 - (CACurrentMediaTime() - start))))
            teile.ebene?.removeFromSuperlayer()
            teile.ebene = nil
            try? await Task.sleep(for: .seconds(max(0, kurve.ringEnde + 0.05 - (CACurrentMediaTime() - start))))
            teile.ring?.removeFromSuperlayer()
            teile.ring = nil
        }
        return teile
    }
}

#if DEBUG
/// **Bildzeiten während des Kontowechsels, am Gerät** (nur Debug): ein
/// `CADisplayLink` auf 120 Hz misst jede Bilddauer; was länger als 1,5 Soll
/// braucht (12,5 ms bei 120 Hz), steht mit Zeit, Dauer und Stufe im
/// Protokoll. Die Ebenen
/// laufen im Render-Server und sind davon unberührt — was hier auftaucht,
/// ist der Hauptlauf (Startseite, Kopf, Reihen).
@MainActor
final class Bildzeitmesser: NSObject {
    static let geteilt = Bildzeitmesser()
    private var takt: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var letzte: CFTimeInterval = 0
    private var ausreisser: [String] = []
    private var bilder = 0
    var kurve: Kontowechselflug.Kurve?

    func starten() {
        takt?.invalidate()
        start = CACurrentMediaTime()
        letzte = 0
        ausreisser = []
        bilder = 0
        let t = CADisplayLink(target: self, selector: #selector(bild(_:)))
        t.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        t.add(to: .main, forMode: .common)
        takt = t
    }

    func anhalten() {
        takt?.invalidate()
        takt = nil
        Kontowechselflug.notiz("bildzeit: \(self.bilder) bilder, \(self.ausreisser.count) zu lang: \(self.ausreisser.joined(separator: " "))")
    }

    @objc private func bild(_ t: CADisplayLink) {
        bilder += 1
        defer { letzte = t.timestamp }
        guard letzte > 0 else { return }
        let dauer = t.timestamp - letzte
        // Das Soll aus dem Takt selbst: 8,3 ms bei 120 Hz, 16,7 ms bei 60 Hz
        // (Simulator, Stromsparen).
        let soll = max(t.targetTimestamp - t.timestamp, 1.0 / 120)
        guard dauer > soll * 1.5 else { return }
        let seit = t.timestamp - start
        ausreisser.append("\(Int(seit * 1000))ms/\(Int(dauer * 1000))ms/\(stufe(seit))")
    }

    private func stufe(_ t: Double) -> String {
        guard let k = kurve else { return "ohne-flug" }
        if t < 0.08 { return "tipp" }
        if t < Kontowechselflug.Kurve.wachsen { return "abheben" }
        if t < 0.55 { return "seite+flug" }
        if t < k.landung { return "flug" }
        if t < k.tausch - Kontowechselflug.wechselVorRuhe { return "landung" }
        if t < k.tausch { return "wechsel" }
        if t < k.tausch + 0.05 { return "tausch" }
        return "reihen"
    }
}
#endif

#if DEBUG
/// **Selbsttest Kontowechsel**, ohne Bedienung und ohne echten Server:
///
///     xcrun simctl launch <geraet> de.paulherter.swiftly \
///         -testsitzung http://127.0.0.1:8899 -testsitzung2 -kontowechsellauf
///
/// Öffnet nach dem Start das Profil und wechselt dort aufs andere Konto —
/// über denselben Weg wie ein Tipp. Der Ablauf steht mit Zeitstempeln im
/// Protokoll, Kategorie `kontowechsel`.
enum Kontowechsellauf {
    static var an: Bool { ProcessInfo.processInfo.arguments.contains("-kontowechsellauf") }
    /// `-profiltipp <ms>`: so lange nach dem Wechsel-Tipp das Profil oben
    /// antippen (öffnen) — mitten im Flug oder im Einblenden.
    static var profiltipp: Int? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-profiltipp"), i + 1 < a.count else { return nil }
        return Int(a[i + 1])
    }
    /// Der Selbsttest wechselt einmal, nicht bei jedem Öffnen des Profils.
    @MainActor static var getippt = false
}
#endif


