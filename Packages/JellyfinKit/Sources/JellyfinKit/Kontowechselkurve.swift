import Foundation

/// **Der Flug des Profilbilds beim Kontowechsel** (Entwurf D, Paul 26.09.2026).
///
/// Drei Federn, je Achse eine: waagerecht kritisch gedämpft mit Schwung nach
/// links, senkrecht leicht federnd mit einem kleinen Schwung nach unten, die
/// Größe für sich. **Gerechnet statt animiert**: nur so lassen sich
/// Anfangsschwung, Landung und Ruhe vorab bestimmen — der Tausch gegen das
/// echte Bild hängt an der Ruhe, der Kontowechsel läuft kurz davor, der Ring
/// ploppt bei der Landung.
///
/// Stand bis 27.09.2026 als `Kontowechselflug.Kurve` in
/// `Sources/iOS/Uebergaenge.swift`; hier, damit Apple, Android, Linux und
/// Windows dieselbe Bahn fliegen. Der Schwung wächst mit dem Weg, damit der
/// Bogen auf anderen Schirmmaßen dieselbe Form hat wie im Entwurf
/// (297 × −171 Punkt).
/// Maße in Punkt (iOS) bzw. dp (Android), Zeiten in Sekunden ab dem Tipp.
public struct Kontowechselkurve: Sendable, Equatable {
    public let vonX, vonY, groesse, nachX, nachY: Double
    /// So groß ist das Bild am Ziel — oben rechts am iPhone ``zielgroesse`` (34), am Fernseher kleiner.
    public let ziel: Double
    /// Wann das Bild ruht (auf 0,3 Punkt).
    public let tausch: Double
    /// Wann es zum ersten Mal auf Zielhöhe zurückfällt: da ploppt der Ring.
    public let landung: Double
    public var ringEnde: Double { landung + 0.8 }

    /// So lange wächst das Bild am Ort um 6 %, bevor es abhebt.
    public static let wachsen = 0.1
    /// So groß ist das Profilbild oben rechts.
    public static let zielgroesse = 34.0
    /// **Wann das Konto wirklich wechselt**: 0,3 s bevor das Bild ruht — der
    /// Wechsel kostet den Hauptlauf Zeit, und kurz vor der Ruhe bewegt sich das
    /// Bild nur noch um Bruchteile eines Punkts.
    public static let wechselVorRuhe = 0.3
    /// Frühestens so lange nach dem Tipp wechselt das Konto.
    public static let wechselFruehestens = 0.6

    public init(vonX: Double, vonY: Double, groesse: Double, nachX: Double, nachY: Double,
                zielgroesse: Double = Kontowechselkurve.zielgroesse) {
        self.vonX = vonX; self.vonY = vonY; self.groesse = groesse
        self.nachX = nachX; self.nachY = nachY; self.ziel = zielgroesse
        var ruhe = 0.0, ueber = -1.0, land = -1.0
        var t = Self.wachsen
        let dt = 1.0 / 240
        while t < 5 {
            let b = Self.lage(vonX, vonY, groesse, nachX, nachY, zielgroesse, t)
            if max(abs(b.x - nachX), abs(b.y - nachY), abs(b.s - zielgroesse)) > 0.3 { ruhe = t }
            if ueber < 0, b.y < nachY - 0.5 { ueber = t }
            if ueber >= 0, land < 0, b.y >= nachY { land = t }
            t += dt
        }
        tausch = ruhe + dt
        landung = land >= 0 ? land : (ueber >= 0 ? ueber : tausch - 0.3)
    }

    /// Dasselbe mit Punkten als Paaren (Linux, Windows).
    public init(von: (x: Double, y: Double), groesse: Double, nach: (x: Double, y: Double),
                zielgroesse: Double) {
        self.init(vonX: von.x, vonY: von.y, groesse: groesse, nachX: nach.x, nachY: nach.y,
                  zielgroesse: zielgroesse)
    }

    /// Wann das Konto wechselt: ``wechselVorRuhe`` vor der Ruhe, frühestens
    /// nach ``wechselFruehestens``.
    public var wechsel: Double { max(Self.wechselFruehestens, tausch - Self.wechselVorRuhe) }

    /// Mitte und Größe des Bildes nach `t` Sekunden.
    public func lage(_ t: Double) -> (x: Double, y: Double, s: Double) {
        Self.lage(vonX, vonY, groesse, nachX, nachY, ziel, t)
    }

    private static func lage(_ vx0: Double, _ vy0: Double, _ groesse: Double, _ nx: Double, _ ny: Double,
                             _ zs: Double, _ t: Double) -> (x: Double, y: Double, s: Double) {
        if t < wachsen {
            let k = max(0, min(1, t / wachsen))
            return (vx0, vy0, groesse * (1 + 0.06 * k))
        }
        let u = t - wachsen
        // Der Schwung wächst mit dem Weg, damit der Bogen bei anderen
        // Schirmmaßen dieselbe Form hat wie im Entwurf. **Ruhiger als der
        // Entwurf** (Paul am Gerät, 26.09.): halber Anfangsschwung, längere
        // Antworten und fast kritische Dämpfung.
        let vx = -900 * (nx - vx0) / 297
        let vy = 80 * (ny - vy0) / -171
        return (feder(vx0, nx, vx, 0.8, 1, u),
                feder(vy0, ny, vy, 0.9, 0.88, u),
                feder(groesse * 1.06, zs, 0, 0.8, 0.95, u))
    }

    /// Eine gedämpfte Feder, geschlossen gelöst: Antwort `r` (s), Dämpfung
    /// `z`, Anfangsgeschwindigkeit `v0` (pro Sekunde).
    public static func feder(_ von: Double, _ nach: Double, _ v0: Double,
                             _ r: Double, _ z: Double, _ t: Double) -> Double {
        guard t > 0 else { return von }
        let w = 2 * Double.pi / r, x0 = von - nach
        let x: Double
        if z < 1 {
            let wd = w * (1 - z * z).squareRoot()
            x = exp(-z * w * t) * (x0 * cos(wd * t) + (v0 + z * w * x0) / wd * sin(wd * t))
        } else {
            x = (x0 + (v0 + w * x0) * t) * exp(-w * t)
        }
        return nach + x
    }

    /// **Der Ring bei der Landung**, nur angedeutet: `r` Sekunden nach der
    /// Landung (0 … 0,8) sein Maß (Feder 0,35/0,75 aus 0,6) und seine Deckung
    /// (0,05 s herein, bis 0,45 voll, dann 0,35 s hinaus — höchstens 55 %).
    public static func ring(_ r: Double) -> (mass: Double, deckung: Double) {
        let d = r < 0.45 ? min(1, r / 0.05) : 1 - min(1, (r - 0.45) / 0.35)
        return (feder(0.6, 1, 0, 0.35, 0.75, r), max(0, d) * 0.55)
    }

    // MARK: Reihen nach dem Wechsel

    /// **Die Reihen der Startseite ploppen gestaffelt ein**: 80 ms je Reihe,
    /// Deckkraft linear in 0,22 s, von 14 Punkt tiefer und 96 % Größe
    /// (`Reihenauftritt`).
    public static let reihenStaffel = 0.08
    public static let reihenBlende = 0.22
    public static let reihenVersatz = 14.0
    public static let reihenMass = 0.96
    /// So lange nach dem Tausch dürfen die Reihen kommen.
    public static let reihenNachTausch = 0.03
}
