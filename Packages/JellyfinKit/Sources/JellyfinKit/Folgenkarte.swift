import Foundation

/// **Die nächste Folge als Karte unten rechts — und wie sie ins Bild zoomt.**
///
/// Paul hat am 26.09.2026 **Variante C** gewählt: das laufende Bild bleibt
/// groß. Ab dem Abspann (sonst in den letzten ``restfenster`` Sekunden)
/// schiebt sich unten rechts die nächste Folge als Karte herein — Vorschaubild,
/// „S6 · F11", Titel, ein Ring als Countdown. Tippen oder Ablauf: die Karte
/// zoomt aufs ganze Bild und übernimmt es; ihr Vorschaubild wird zum ersten
/// Bild der neuen Folge, ohne Schwarz dazwischen. Tippen aufs Bild (iPhone)
/// oder Menü (Fernseher) schiebt die Karte wieder hinaus, der Abspann läuft
/// weiter.
///
/// Ersetzt die Countdown-Pille „Nächste Folge" (`Angebotsebene.Anzeige.karte`)
/// und den Titel-Übergang A. Der Knopf in der offenen Steuerung bleibt.
///
/// **Alles Federn aus dem jetzigen Stand**, kritisch gedämpft, mit den
/// Eigenfrequenzen des Entwurfs: `1 − e^(−ωt)·(1 + ωt)`. Auf Apple heißt das
/// `interpolatingSpring(stiffness: ω², damping: 2ω)` — unterbrechbar von
/// selbst. Maße in Punkt, je Plattform.
public enum Folgenkarte {

    /// Ohne Abspann-Abschnitt: so viele Sekunden vor Schluss.
    public static let restfenster: Double = 30

    // MARK: Federn (Eigenfrequenz ω, kritisch gedämpft)

    /// Hereinschieben, 0,12 s nach Beginn des Abspanns.
    public static let erscheinenOmega: Double = 9
    public static let erscheinenVerzug: Double = 0.12
    /// Hinausschieben (abgesagt).
    public static let wegOmega: Double = 12
    /// Aufzoomen aufs ganze Bild.
    public static let zoomOmega: Double = 10

    /// Steifigkeit und Dämpfung einer kritisch gedämpften Feder mit Masse 1.
    public static func feder(_ omega: Double) -> (steifigkeit: Double, daempfung: Double) {
        (omega * omega, 2 * omega)
    }

    /// Wie weit eine solche Feder nach `t` Sekunden ist, 0 bis 1.
    public static func federweg(_ t: Double, omega: Double) -> Double {
        t <= 0 ? 0 : 1 - exp(-omega * t) * (1 + omega * t)
    }

    // MARK: Ablauf nach dem Start

    /// Ring und Angaben unter der Karte blenden in so vielen Sekunden aus.
    public static let angabenAus: Double = 0.15
    /// **Erst hier wird die neue Folge gestartet** — die Karte deckt dann
    /// das Bild (Zoom zu 98 %). Vorher bliebe um sie herum Schwarz sichtbar.
    public static let tausch: Double = 0.6
    /// Ab dem ersten Bild der neuen Folge (frühestens ``tausch``) blendet das
    /// Vorschaubild in so vielen Sekunden aus, das Video steht darunter.
    public static let bildBlende: Double = 0.4

    /// Wann das Vorschaubild auszublenden beginnt, ab dem Start gemessen.
    public static func blendeAb(bildSeit: Double) -> Double { max(bildSeit, tausch) }

    // MARK: Aussehen (aus dem Entwurf)

    /// Beim Hereinschieben: von rechts um so viel Punkt, und von 94 % Größe.
    public static let versatz: Double = 40
    public static let startmass: Double = 0.94
    /// Fernseher: die Karte mit Fokus hebt sich um 6 %, ein Klick drückt sie
    /// 0,3 s lang um 3,5 % ein.
    public static let fokusmass: Double = 1.06
    public static let klickDruck: Double = 0.035
    public static let klickDauer: Double = 0.3

    /// Maße je Plattform: Kartenbreite, Ecke, Ring, Abstand zur Zeile darunter,
    /// Schriftgrade der beiden Zeilen.
    public struct Masse: Sendable, Equatable {
        public let breite: Double
        public let ecke: Double
        public let ring: Double
        public let abstand: Double
        public let klein: Double
        public let titel: Double
    }
    public static let iPhone = Masse(breite: 240, ecke: 12, ring: 52, abstand: 12, klein: 12, titel: 17)
    public static let fernseher = Masse(breite: 600, ecke: 24, ring: 130, abstand: 32, klein: 30, titel: 42)

    // MARK: Lage und Abbrechen (iPhone, 26.09.2026 abends)

    /// Höchstens dieser Anteil der sicheren Breite — auf dem iPhone SE quer
    /// (667 pt) wird die Karte so schmaler, statt in die Mitte zu ragen.
    public static let hoechstensAnteil: Double = 0.3
    /// Abstand der Zeilen unter der Karte zum unteren sicheren Rand.
    public static let untenAbstand: Double = 12
    /// So weit (Punkt) nach rechts oder unten gewischt, ist die Karte weg —
    /// oder wenn der Schwung sie doppelt so weit trüge.
    public static let wegwischen: Double = 70
    /// Nach links und oben folgt sie dem Finger nur zu einem Fünftel.
    public static let widerstand: Double = 0.2

    /// Die Kartenbreite für eine sichere Breite.
    public static func breite(_ m: Masse, sichereBreite: Double, gross: Bool) -> Double {
        min(m.breite * (gross ? 1.25 : 1), sichereBreite * hoechstensAnteil)
    }

    /// Der Versatz beim Ziehen: rechts und unten frei, links und oben zäh.
    public static func gezogen(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        (x > 0 ? x : x * widerstand, y > 0 ? y : y * widerstand)
    }

    /// Ob ein Wisch die Karte wegschiebt.
    public static func weggewischt(x: Double, y: Double, schwungX: Double, schwungY: Double) -> Bool {
        x > wegwischen || y > wegwischen || schwungX > 2 * wegwischen || schwungY > 2 * wegwischen
    }

    /// Der Rahmen zwischen Karte (`zoom` 0) und ganzem Bild (1).
    public static func rahmen(karte: (x: Double, y: Double, b: Double, h: Double),
                              ganz: (b: Double, h: Double), zoom: Double)
        -> (x: Double, y: Double, b: Double, h: Double) {
        func l(_ a: Double, _ b: Double) -> Double { a + (b - a) * zoom }
        return (l(karte.x, 0), l(karte.y, 0), l(karte.b, ganz.b), l(karte.h, ganz.h))
    }
}
