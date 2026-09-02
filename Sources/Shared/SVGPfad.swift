import SwiftUI

/// Liest die Pfadsprache aus SVG und baut daraus einen `Path`.
///
/// Bewusst ein Leser statt erzeugten Codes: die Vorlagen liegen als
/// Zeichenkette vor, also lässt sich eine neue Fassung austauschen, ohne
/// tausend Zeilen Punktlisten zu ersetzen.
///
/// Unterstützt M, L, H, V, C, S, Q, T, A und Z in Groß- und Kleinschreibung.
enum SVGPfad {

    /// Passt den Pfad gleichmäßig in den Rahmen ein und setzt ihn mittig.
    ///
    /// `box` ist die viewBox **einschließlich Ursprung** — der liegt nicht
    /// immer bei null. Die Wortmarke etwa beginnt bei `23 -778`; ohne das
    /// Verschieben läge sie weit außerhalb des Rahmens.
    ///
    /// **Der Rohpfad wird gemerkt.** `Shape.path(in:)` ruft das Rahmenwerk
    /// bei *jedem* Auslegen auf — bei einer laufenden Bewegung also einmal je
    /// Einzelbild. Ohne Speicher wurde die Wortmarke dabei jedes Mal neu
    /// abgetastet und zusammengesetzt.
    ///
    /// Gemessen mit `sample` während des Öffnens einer Serienseite auf dem
    /// Mac: **75 von 439 Stichproben des Hauptlaufs — 17 % — steckten in
    /// `SVGPfad`**, davon 56 im Abtaster. Die Wortmarke steht dort dauerhaft
    /// in der Seitenleiste, wird also bei jeder Bewegung im Fenster
    /// mitgerechnet.
    ///
    /// Gemerkt wird der **unverwandelte** Pfad: die Vorlagen sind eine
    /// Handvoll fester Zeichenketten, die Verwandlung dagegen hängt am
    /// Rahmen und ist billig.
    static func pfad(_ daten: String, box: CGRect, in rahmen: CGRect) -> Path {
        let roh = Pfadspeicher.geteilt.roh(daten)
        let faktor = min(rahmen.width / box.width, rahmen.height / box.height)
        let breite = box.width * faktor
        let hoehe = box.height * faktor
        var t = CGAffineTransform(
            translationX: rahmen.minX + (rahmen.width - breite) / 2,
            y: rahmen.minY + (rahmen.height - hoehe) / 2)
        t = t.scaledBy(x: faktor, y: faktor)
        t = t.translatedBy(x: -box.minX, y: -box.minY)
        return roh.applying(t)
    }

    /// Der abgetastete Pfad ohne jede Verwandlung.
    static func rohpfad(_ daten: String) -> Path { zeichne(marken(daten)) }

    // MARK: Zerlegen

    private enum Marke {
        case befehl(Character)
        case zahl(CGFloat)
    }

    /// SVG erlaubt Zahlen ohne Trennzeichen („1.5-2.3", „.5.5"), deshalb ein
    /// eigener Abtaster statt `split`.
    private static func marken(_ daten: String) -> [Marke] {
        var ergebnis: [Marke] = []
        var puffer = ""

        func abschliessen() {
            if let wert = Double(puffer) { ergebnis.append(.zahl(CGFloat(wert))) }
            puffer = ""
        }

        for zeichen in daten {
            switch zeichen {
            case "-", "+":
                // Trennt eine neue Zahl ab — außer direkt hinter einem Exponenten.
                if !puffer.isEmpty, !puffer.lowercased().hasSuffix("e") { abschliessen() }
                puffer.append(zeichen)
            case ".":
                if puffer.contains(".") { abschliessen() }   // zweiter Punkt: neue Zahl
                puffer.append(zeichen)
            case "e", "E":
                puffer.append(zeichen)
            case let z where z.isNumber:
                puffer.append(z)
            case let z where z.isLetter:
                abschliessen()
                ergebnis.append(.befehl(z))
            default:
                abschliessen()
            }
        }
        abschliessen()
        return ergebnis
    }

    // MARK: Durchlaufen

    private static func zeichne(_ marken: [Marke]) -> Path {
        var pfad = Path()
        var stift = CGPoint.zero
        var anfang = CGPoint.zero
        var letzteKontrolle: CGPoint?      // von C und S
        var letzteQuadrat: CGPoint?        // von Q und T
        var befehl: Character = "M"
        var i = 0

        /// Holt die nächsten Zahlen. Ein Buchstabe davor beendet die Folge.
        func zahlen(_ anzahl: Int) -> [CGFloat]? {
            var werte: [CGFloat] = []
            var j = i
            while werte.count < anzahl, j < marken.count {
                guard case let .zahl(wert) = marken[j] else { return nil }
                werte.append(wert)
                j += 1
            }
            guard werte.count == anzahl else { return nil }
            i = j
            return werte
        }

        while i < marken.count {
            if case let .befehl(zeichen) = marken[i] {
                befehl = zeichen
                i += 1
                if Character(zeichen.lowercased()) == "z" {
                    pfad.closeSubpath()
                    stift = anfang
                    letzteKontrolle = nil
                }
                continue
            }

            let relativ = befehl.isLowercase
            func punkt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relativ ? CGPoint(x: stift.x + x, y: stift.y + y) : CGPoint(x: x, y: y)
            }

            switch Character(befehl.lowercased()) {
            case "m":
                guard let w = zahlen(2) else { return pfad }
                stift = punkt(w[0], w[1])
                anfang = stift
                pfad.move(to: stift)
                letzteKontrolle = nil
                // Weitere Paare hinter einem M gelten als L — so schreibt es SVG vor.
                befehl = relativ ? "l" : "L"

            case "l":
                guard let w = zahlen(2) else { return pfad }
                stift = punkt(w[0], w[1])
                pfad.addLine(to: stift)
                letzteKontrolle = nil

            case "h":
                guard let w = zahlen(1) else { return pfad }
                stift = CGPoint(x: relativ ? stift.x + w[0] : w[0], y: stift.y)
                pfad.addLine(to: stift)
                letzteKontrolle = nil

            case "v":
                guard let w = zahlen(1) else { return pfad }
                stift = CGPoint(x: stift.x, y: relativ ? stift.y + w[0] : w[0])
                pfad.addLine(to: stift)
                letzteKontrolle = nil

            case "c":
                guard let w = zahlen(6) else { return pfad }
                let k1 = punkt(w[0], w[1]), k2 = punkt(w[2], w[3]), ziel = punkt(w[4], w[5])
                pfad.addCurve(to: ziel, control1: k1, control2: k2)
                letzteKontrolle = k2
                stift = ziel

            case "s":
                guard let w = zahlen(4) else { return pfad }
                // Der erste Griff ist die Spiegelung des vorigen am Stift.
                let k1 = letzteKontrolle.map {
                    CGPoint(x: 2 * stift.x - $0.x, y: 2 * stift.y - $0.y)
                } ?? stift
                let k2 = punkt(w[0], w[1]), ziel = punkt(w[2], w[3])
                pfad.addCurve(to: ziel, control1: k1, control2: k2)
                letzteKontrolle = k2
                letzteQuadrat = nil
                stift = ziel

            case "q":
                guard let w = zahlen(4) else { return pfad }
                let griff = punkt(w[0], w[1]), ziel = punkt(w[2], w[3])
                pfad.addQuadCurve(to: ziel, control: griff)
                letzteQuadrat = griff
                letzteKontrolle = nil
                stift = ziel

            case "t":
                guard let w = zahlen(2) else { return pfad }
                let griff = letzteQuadrat.map {
                    CGPoint(x: 2 * stift.x - $0.x, y: 2 * stift.y - $0.y)
                } ?? stift
                let ziel = punkt(w[0], w[1])
                pfad.addQuadCurve(to: ziel, control: griff)
                letzteQuadrat = griff
                letzteKontrolle = nil
                stift = ziel

            case "a":
                guard let w = zahlen(7) else { return pfad }
                let ziel = punkt(w[5], w[6])
                bogen(&pfad, von: stift, nach: ziel, rx: w[0], ry: w[1],
                      drehung: w[2], gross: w[3] != 0, imUhrzeigersinn: w[4] != 0)
                letzteKontrolle = nil
                letzteQuadrat = nil
                stift = ziel

            default:
                return pfad
            }
        }
        return pfad
    }

    // MARK: Bögen

    /// Wandelt einen elliptischen Bogen in kubische Kurven.
    ///
    /// `Path` kennt nur Kurven, kein SVG-Bogensegment. Der Weg dorthin ist der
    /// aus der SVG-Spezifikation: von der Endpunkt- in die Mittelpunktform
    /// rechnen, dann in Stücke von höchstens 90 Grad teilen — bis dahin ist
    /// die Näherung durch eine Kurve genauer als ein Bildpunkt.
    private static func bogen(_ pfad: inout Path, von: CGPoint, nach: CGPoint,
                              rx: CGFloat, ry: CGFloat, drehung: CGFloat,
                              gross: Bool, imUhrzeigersinn: Bool) {
        guard rx != 0, ry != 0 else {
            pfad.addLine(to: nach)
            return
        }
        var rx = abs(rx), ry = abs(ry)
        let phi = drehung * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)

        let dx2 = (von.x - nach.x) / 2, dy2 = (von.y - nach.y) / 2
        let x1 =  cosP * dx2 + sinP * dy2
        let y1 = -sinP * dx2 + cosP * dy2

        // Zu kleine Halbachsen aufblasen, sonst gibt es keine Lösung.
        let ausmass = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if ausmass > 1 {
            rx *= sqrt(ausmass)
            ry *= sqrt(ausmass)
        }

        let zaehler = max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1)
        let nenner = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var faktor = nenner == 0 ? 0 : sqrt(zaehler / nenner)
        if gross == imUhrzeigersinn { faktor = -faktor }

        let cx1 =  faktor * rx * y1 / ry
        let cy1 = -faktor * ry * x1 / rx
        let mitte = CGPoint(x: cosP * cx1 - sinP * cy1 + (von.x + nach.x) / 2,
                            y: sinP * cx1 + cosP * cy1 + (von.y + nach.y) / 2)

        func winkel(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let punktprodukt = ux * vx + uy * vy
            let betrag = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            guard betrag > 0 else { return 0 }
            let w = acos(min(max(punktprodukt / betrag, -1), 1))
            return (ux * vy - uy * vx < 0) ? -w : w
        }

        let start = winkel(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var spanne = winkel((x1 - cx1) / rx, (y1 - cy1) / ry,
                            (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !imUhrzeigersinn, spanne > 0 { spanne -= 2 * .pi }
        if imUhrzeigersinn, spanne < 0 { spanne += 2 * .pi }

        let stuecke = max(1, Int(ceil(abs(spanne) / (.pi / 2))))
        let schritt = spanne / CGFloat(stuecke)
        // Griffweite für die Näherung eines Kreisbogens durch eine Kurve.
        let griff = 4.0 / 3.0 * tan(schritt / 4)

        var winkelJetzt = start
        for _ in 0 ..< stuecke {
            let winkelNext = winkelJetzt + schritt
            let cos1 = cos(winkelJetzt), sin1 = sin(winkelJetzt)
            let cos2 = cos(winkelNext), sin2 = sin(winkelNext)

            func abbilden(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: cosP * rx * x - sinP * ry * y + mitte.x,
                        y: sinP * rx * x + cosP * ry * y + mitte.y)
            }

            let ziel = abbilden(cos2, sin2)
            let k1 = abbilden(cos1 - griff * sin1, sin1 + griff * cos1)
            let k2 = abbilden(cos2 + griff * sin2, sin2 - griff * cos2)
            pfad.addCurve(to: ziel, control1: k1, control2: k2)
            winkelJetzt = winkelNext
        }
    }
}

/// Eine Form aus SVG-Pfaddaten.
/// Merkt sich die abgetasteten Rohpfade. Eine Handvoll Einträge — die
/// Vorlagen stehen als feste Zeichenketten im Programm.
///
/// `Shape.path(in:)` ist nicht auf den Hauptlauf festgelegt, deshalb ein
/// Schloss statt eines Akteurs.
private final class Pfadspeicher: @unchecked Sendable {
    static let geteilt = Pfadspeicher()

    private let schloss = NSLock()
    private var bekannt: [String: Path] = [:]

    func roh(_ daten: String) -> Path {
        schloss.lock()
        if let da = bekannt[daten] {
            schloss.unlock()
            return da
        }
        schloss.unlock()

        let neu = SVGPfad.rohpfad(daten)

        schloss.lock()
        // Mehr als eine Handvoll wäre ein Zeichen, dass hier Pfade
        // hereinkommen, die zur Laufzeit entstehen — dann lieber leeren als
        // unbegrenzt wachsen.
        if bekannt.count > 32 { bekannt.removeAll() }
        bekannt[daten] = neu
        schloss.unlock()
        return neu
    }
}

struct SVGForm: Shape {
    let daten: String
    let box: CGRect
    func path(in rahmen: CGRect) -> Path { SVGPfad.pfad(daten, box: box, in: rahmen) }
}
