import Foundation

/// **„Hier weiterschauen" als Karte, die aus dem Abzeichen wächst**
/// (Entwurf B, Paul 27.09.2026).
///
/// **Empfänger:** Tipp aufs Abzeichen — die Seite tritt zurück, eine Karte
/// mit dem Folgenbild wächst auf geradem Weg aus dem Abzeichen in die Mitte,
/// Titel und Folge stehen darunter. Solange der Strom noch nicht steht,
/// schwebt sie leicht, bei längerem Warten mit einer Ladelinie. Steht das
/// erste Bild, zoomt sie aufs ganze Bild; das Video blendet darunter auf.
///
/// **Abgeber:** das Spiegelbild — das laufende Bild steht still, schrumpft
/// zur Karte, schwebt kurz und fliegt oben hinaus; dann schließt der Player.
///
/// Drei verworfene Anläufe davor (Lichtpunkt, Welle, Metal) haben gelehrt:
/// **nur Lage, Größe und Deckkraft**, keine Effekte obendrauf, und die
/// Bewegung vorab gerechnet — die Plattform legt sie als Stützpunkte in den
/// Render-Server, damit Player-Aufbau und Netz auf dem Hauptlauf sie nicht
/// stören. Mit reduzierter Bewegung wird nur überblendet.
///
/// Federn wie beim Kontowechsel (``Kontowechselkurve/feder(_:_:_:_:_:_:)``)
/// mit Schwung von Phase zu Phase. Maße in Punkt, Zeiten in
/// Sekunden ab dem Tipp (Empfänger) bzw. ab dem Stopp (Abgeber).
public enum Uebergabekarte {

    // MARK: Maße

    /// Kartenbreite in Ruhe, Ecke, Schriftgrade und Abstand zur Zeile darunter.
    public struct Masse: Sendable, Equatable {
        public let breite: Double
        public let ecke: Double
        public let titel: Double
        public let klein: Double
        public let abstand: Double
        public init(breite: Double, ecke: Double, titel: Double, klein: Double, abstand: Double) {
            self.breite = breite; self.ecke = ecke; self.titel = titel
            self.klein = klein; self.abstand = abstand
        }
    }
    public static let iPhone = Masse(breite: 240, ecke: 12, titel: 17, klein: 13, abstand: 12)
    public static let iPad = Masse(breite: 320, ecke: 14, titel: 20, klein: 15, abstand: 14)
    public static let fernseher = Masse(breite: 600, ecke: 24, titel: 42, klein: 30, abstand: 26)
    public static let mac = Masse(breite: 320, ecke: 12, titel: 17, klein: 13, abstand: 12)

    /// Mitte und Breite der Karte; die Höhe ist immer 16:9.
    public struct Lage: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var breite: Double
        public init(x: Double, y: Double, breite: Double) {
            self.x = x; self.y = y; self.breite = breite
        }
        public var hoehe: Double { breite * 9 / 16 }
    }

    /// **Das ganze Bild** — 16:9 in den Schirm eingepasst, mittig. Hochkant
    /// also schirmbreit; genau dort steht das Video im Player auch.
    public static func vollbild(breite: Double, hoehe: Double) -> Lage {
        Lage(x: breite / 2, y: hoehe / 2, breite: min(breite, hoehe * 16 / 9))
    }

    /// **Wo die Karte ruht** — waagerecht mittig, so weit über der Mitte,
    /// dass Karte und die zwei Zeilen darunter zusammen mittig stehen.
    public static func ruhelage(breite: Double, hoehe: Double, masse: Masse) -> Lage {
        let b = min(masse.breite, breite * 0.7)
        let zeilen = masse.abstand + masse.titel * 1.2 + masse.klein * 1.2 + 6
        return Lage(x: breite / 2, y: hoehe / 2 - zeilen / 2, breite: b)
    }

    /// Oberkante der Zeilen unter einer Karte in dieser Lage.
    public static func zeilenOben(_ l: Lage, masse: Masse) -> Double {
        l.y + l.hoehe / 2 + masse.abstand * 0.6
    }

    /// **Die sichtbare Ecke**: in Ruhe ``Masse/ecke``, zum ganzen Bild hin
    /// auf null — und nie mehr als 5,5 % der Breite, damit die kleine Karte
    /// am Abzeichen keine Pille wird.
    public static func ecke(_ l: Lage, masse: Masse, voll: Lage) -> Double {
        let spanne = max(voll.breite - masse.breite, 1)
        let anteil = min(max((voll.breite - l.breite) / spanne, 0), 1)
        return min(masse.ecke * anteil, l.breite * 0.055)
    }

    // MARK: Federn

    static func linear(_ t: Double, _ a: Double, _ b: Double) -> Double {
        min(max((t - a) / (b - a), 0), 1)
    }

    static func glatt(_ u: Double) -> Double { u * u * (3 - 2 * u) }

    // MARK: Empfänger

    /// Die Seite tritt zurück (Deckkraft des Grunds darüber, linear).
    public static let seiteVon = 0.08
    public static let seiteBis = 0.28
    /// Ab hier ist die Karte da — sie blendet in ``kartenEinblenden`` auf.
    public static let kartenStart = 0.1
    public static let kartenEinblenden = 0.05
    /// Der gerade Weg aus dem Abzeichen: Antwort 0,55 s, Dämpfung 0,8 für
    /// Lage und Größe — ein kleiner Überschwinger wie beim Kontowechsel.
    /// Stand bis 27.09. mittags auf 0,86/0,9: am Gerät „fehlte das Easing".
    public static let flugAntwort = 0.55
    public static let flugDaempfung = 0.8
    public static let groessenDaempfung = 0.8
    /// Titel und Folge unter der Karte.
    public static let zeilenVon = 0.45
    public static let zeilenBis = 0.7
    /// **Frühester Zoom.** Ist das Bild vorher da, wartet die Karte bis hier;
    /// ist es später da, schwebt sie.
    public static let schweben = 0.7
    /// Schweben: so viel Punkt auf und ab, eine Schwingung in so vielen
    /// Sekunden, eingeblendet über 0,4 s ab 0,15 s vor ``schweben``.
    public static let schwebHub = 1.8
    public static let schwebPeriode = 1.8
    /// Die Ladelinie kommt nur, wenn das Bild zu diesem Zeitpunkt noch fehlt.
    public static let ladelinieAb = schweben + 0.05
    public static let ladelinieEinblenden = 0.2
    /// Eine Fahrt der Ladelinie über die Kartenbreite.
    public static let ladelinieTakt = 1.0 / 0.9
    /// **Zoom aufs ganze Bild**: Feder Antwort 0,5 s, Dämpfung 0,85, und
    /// **mit dem Schwung, den die Karte gerade hat** — aus Flug oder
    /// Schweben ohne Halt. Bis 27.09. mittags kritisch gedämpft aus dem
    /// Stand (ω 10): kam das Bild früh, stoppte die Karte mitten im Flug
    /// und fuhr neu an; das las sich am Gerät mechanisch.
    public static let zoomAntwort = 0.5
    public static let zoomDaempfung = 0.85
    /// Nach dem Zoombeginn: Zeilen weg, Schwarz dahinter, Karte aus — die
    /// Blende beginnt, wenn die Feder fast am Ziel ist.
    public static let zeilenAus = 0.15
    public static let schwarzDauer = 0.3
    public static let kartenAusVon = 0.42
    public static let kartenAusBis = 0.72
    /// Danach ist die Bühne abgeräumt.
    public static let ende = kartenAusBis + 0.05
    /// **So lange wartet die Karte höchstens aufs erste Bild**, ab dem
    /// Moment, in dem der Player steht. Danach zoomt sie trotzdem, und der
    /// Player zeigt seinen eigenen Lader.
    public static let hoechstensWarten = 6.0
    /// Mit reduzierter Bewegung: jede Blende so lang.
    public static let blende = 0.2
    public static let blendeAus = 0.3

    /// Wann gezoomt wird, wenn das erste Bild zu `bereit` (ab Tipp) kam.
    public static func zoomBeginn(bereit: Double) -> Double { max(schweben, bereit) }

    /// **Die Karte im Flug** — Mitte und Breite nach `t` Sekunden, ohne
    /// Schweben. Vor ``kartenStart`` steht sie am Abzeichen.
    ///
    /// `ab`: wann der Flug beginnt — sonst bei ``kartenStart``. Dreht sich
    /// der Schirm unterwegs ins Querformat, fliegt die Karte von dort, wo sie
    /// gerade ist, neu in die Ruhelage des Querformats.
    public static func flug(_ t: Double, von: Lage, nach: Lage, ab: Double = kartenStart) -> Lage {
        let u = t - ab
        guard u > 0 else { return von }
        let f = Kontowechselkurve.feder
        return Lage(x: f(von.x, nach.x, 0, flugAntwort, flugDaempfung, u),
                    y: f(von.y, nach.y, 0, flugAntwort, flugDaempfung, u),
                    breite: f(von.breite, nach.breite, 0, flugAntwort, groessenDaempfung, u))
    }

    /// Senkrechter Versatz beim Schweben.
    public static func schwebeversatz(_ t: Double) -> Double {
        let ab = schweben - 0.15
        guard t > ab else { return 0 }
        // Weich eingeblendet: das Atmen setzt ohne Knick ein.
        return sin((t - ab) * 2 * .pi / schwebPeriode) * schwebHub * glatt(linear(t, ab, schweben + 0.4))
    }

    /// Flug samt Schweben — so steht die Karte, solange das Bild fehlt.
    public static func warten(_ t: Double, von: Lage, nach: Lage, ab: Double = kartenStart) -> Lage {
        var l = flug(t, von: von, nach: nach, ab: ab)
        l.y += schwebeversatz(t)
        return l
    }

    /// **Wie schnell die Karte beim Warten gerade ist** (je Sekunde, je
    /// Achse) — der Schwung, den der Zoom übernimmt.
    public static func schwung(_ t: Double, von: Lage, nach: Lage, ab: Double = kartenStart) -> Lage {
        let h = 1.0 / 240
        let a = warten(max(0, t - h), von: von, nach: nach, ab: ab)
        let b = warten(t + h, von: von, nach: nach, ab: ab)
        let d = t + h - max(0, t - h)
        return Lage(x: (b.x - a.x) / d, y: (b.y - a.y) / d, breite: (b.breite - a.breite) / d)
    }

    /// **Der Zoom** `z` Sekunden nach seinem Beginn, aus Lage und Schwung,
    /// die die Karte da gerade hatte.
    public static func zoom(_ z: Double, von: Lage, schwung v: Lage, nach voll: Lage) -> Lage {
        let f = Kontowechselkurve.feder
        return Lage(x: f(von.x, voll.x, v.x, zoomAntwort, zoomDaempfung, z),
                    y: f(von.y, voll.y, v.y, zoomAntwort, zoomDaempfung, z),
                    breite: f(von.breite, voll.breite, v.breite, zoomAntwort, zoomDaempfung, z))
    }

    /// Deckkraft der Karte bis zum Zoom.
    public static func kartendeckung(_ t: Double) -> Double {
        linear(t, kartenStart, kartenStart + kartenEinblenden)
    }

    /// Deckkraft des Grunds über der Seite.
    public static func seitendeckung(_ t: Double) -> Double { glatt(linear(t, seiteVon, seiteBis)) }

    /// Deckkraft der Zeilen; `zoomAb` ist der Zoombeginn, falls schon bekannt.
    public static func zeilendeckung(_ t: Double, zoomAb: Double?) -> Double {
        let an = linear(t, zeilenVon, zeilenBis)
        guard let zoomAb else { return an }
        return an * (1 - linear(t, zoomAb, zoomAb + zeilenAus))
    }

    /// Deckkraft der ganzen Bühne nach dem Zoombeginn `z` — erst ganz, dann
    /// weich hinaus, das Video steht darunter.
    public static func buehnendeckung(nachZoom z: Double) -> Double {
        1 - glatt(linear(z, kartenAusVon, kartenAusBis))
    }

    /// Ob die Ladelinie kommt: nur, wenn das Bild bei ``ladelinieAb`` fehlt.
    public static func ladelinie(bereit: Double?) -> Bool {
        guard let bereit else { return true }
        return bereit > ladelinieAb
    }

    // MARK: Abgeber

    // **Das Spiegelbild des Empfängers** (Paul 27.09. nachmittags): dieselben
    // Federn, der Weg umgekehrt. Das ganze Bild schrumpft mit der Feder des
    // Zooms zur Karte, schwebt kurz und fliegt mit der Feder des Wachsens
    // über den oberen Rand hinaus; dann schließt der Player, und man steht
    // wieder auf der Seite. Bis dahin: schnelleres Schrumpfen, seitliches
    // Gleiten und „Läuft jetzt auf dem …" — am Gerät zu schnell und anders
    // als das Hereinkommen.

    /// Das Bild steht still, dann beginnt es zu schrumpfen.
    public static let abgangStart = 0.12
    /// Titel und Folge kommen, wenn die Karte fast klein ist — gespiegelt
    /// zum Zoom, bei dem sie gehen.
    public static let abgangZeilenVon = abgangStart + 0.35
    public static let abgangZeilenBis = abgangStart + 0.6
    /// Kurzes Schweben ab hier (weich eingeblendet wie beim Empfänger).
    public static let abgangSchwebenAb = abgangStart + 0.55
    /// **Abflug** — mit Lage und Schwung aus dem Schweben.
    public static let abflug = abgangStart + 1.1
    /// Beim Abflug schrumpft die Karte noch auf diesen Anteil — zurück ins
    /// Kleine, aus dem sie beim Empfänger kam.
    public static let abflugMass = 0.6
    /// Mit reduzierter Bewegung: Bild aus, dann zu.
    public static let abgangReduziertEnde = blendeAus + 0.1

    /// **Wohin die Karte fliegt — dorthin, wo das andere Gerät meist steht.**
    /// Nach Größe geordnet (Apple TV/Android TV > Mac > iPad > iPhone/Android;
    /// Linux und Windows zählen als Schreibtisch wie der Mac): ist das Ziel
    /// größer, nach oben (das Telefon liegt unter dem Fernseher), ist es
    /// kleiner, nach unten. Gleich groß oder unbekannt: nach oben.
    /// - Parameters: `von`, `nach`: Gerätenamen wie im Übernahme-Hinweis.
    public static func abflugNachOben(von: String, nach: String) -> Bool {
        guard let a = groessenrang(von), let b = groessenrang(nach) else { return true }
        return b >= a
    }

    static func groessenrang(_ name: String) -> Int? {
        switch name {
        // Die Android-Fassung meldet sich als „Android TV" bzw. „Android" (Handy).
        case "Apple TV", "Android TV": 3
        case "Mac", "Linux", "Windows": 2
        case "iPad": 1
        case "iPhone", "Android": 0
        default: nil
        }
    }

    /// Eine Richtung auf dem Schirm, Einheitsvektor, y nach unten.
    public struct Richtung: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
        public static let oben = Richtung(x: 0, y: -1)
        public static let unten = Richtung(x: 0, y: 1)
    }

    /// Wie die Oberfläche steht (`UIInterfaceOrientation`): hochkant, kopfüber,
    /// quer mit dem Home-Knopf rechts oder links.
    public enum Oberflaeche: Sendable {
        case hoch, kopfueber, querHomeRechts, querHomeLinks
    }

    /// **Wo „physisch oben" auf dem Schirm liegt** — aus der Schwerkraft
    /// (`CMDeviceMotion.gravity`, Gerätekoordinaten: x rechts, y zur Oberkante,
    /// z aus dem Glas) und der Lage der Oberfläche. Hält man das iPhone schon
    /// wieder hochkant, während der Player noch quer steht, ist oben die linke
    /// oder rechte Bildschirmseite; schräg gehalten auch schräg. Liegt es flach
    /// (Schwerkraft fast nur auf z), gilt das Oben der Oberfläche.
    /// `nachOben` false: die Gegenrichtung (zum kleineren Gerät).
    public static func abflugrichtung(schwerkraftX gx: Double, schwerkraftY gy: Double,
                                      oberflaeche: Oberflaeche, nachOben: Bool) -> Richtung {
        let laenge = (gx * gx + gy * gy).squareRoot()
        guard laenge >= flachGrenze else { return nachOben ? .oben : .unten }
        // „Oben" ist gegen die Schwerkraft; auf dem Schirm hochkant zeigt y nach unten.
        let px = -gx / laenge, py = gy / laenge
        var r: Richtung
        switch oberflaeche {
        case .hoch:           r = Richtung(x: px, y: py)
        case .kopfueber:      r = Richtung(x: -px, y: -py)
        case .querHomeRechts: r = Richtung(x: py, y: -px)
        case .querHomeLinks:  r = Richtung(x: -py, y: px)
        }
        if !nachOben { r = Richtung(x: -r.x, y: -r.y) }
        return r
    }

    /// Darunter (Anteil der Erdschwere in der Glasebene) liegt das Gerät flach.
    public static let flachGrenze = 0.35

    /// **Wohin die Karte fliegt**: entlang `richtung`, bis sie ganz aus dem
    /// Schirm ist, dazu eine halbe Kartenhöhe. Der Schirm ergibt sich aus dem
    /// mittigen `voll`.
    public static func abflugziel(karte: Lage, voll: Lage, richtung: Richtung = .oben) -> Lage {
        let b = karte.breite * abflugMass
        let halb = (b / 2, b * 9 / 32)
        let schirm = (voll.x * 2, voll.y * 2)
        var weg = Double.infinity
        if abs(richtung.x) > 1e-6 {
            let rand = richtung.x > 0 ? schirm.0 - karte.x : karte.x
            weg = min(weg, (rand + halb.0) / abs(richtung.x))
        }
        if abs(richtung.y) > 1e-6 {
            let rand = richtung.y > 0 ? schirm.1 - karte.y : karte.y
            weg = min(weg, (rand + halb.1) / abs(richtung.y))
        }
        weg += karte.hoehe / 2
        return Lage(x: karte.x + richtung.x * weg, y: karte.y + richtung.y * weg, breite: b)
    }

    /// Senkrechter Versatz beim kurzen Schweben des Abgebers.
    static func abgangSchweben(_ t: Double) -> Double {
        schwebeversatz(t - abgangSchwebenAb + schweben - 0.15)
    }

    /// Schrumpfen und Schweben — ohne Abflug.
    static func abgangVorAbflug(_ t: Double, voll: Lage, karte: Lage) -> Lage {
        let u = t - abgangStart
        guard u > 0 else { return voll }
        let f = Kontowechselkurve.feder
        return Lage(x: f(voll.x, karte.x, 0, zoomAntwort, zoomDaempfung, u),
                    y: f(voll.y, karte.y, 0, zoomAntwort, zoomDaempfung, u) + abgangSchweben(t),
                    breite: f(voll.breite, karte.breite, 0, zoomAntwort, zoomDaempfung, u))
    }

    /// **Das abgehende Bild** nach `t` Sekunden ab dem Stopp.
    public static func abgang(_ t: Double, voll: Lage, karte: Lage, richtung: Richtung = .oben) -> Lage {
        guard t > abflug else { return abgangVorAbflug(t, voll: voll, karte: karte) }
        let start = abgangVorAbflug(abflug, voll: voll, karte: karte)
        let h = 1.0 / 240
        let davor = abgangVorAbflug(abflug - h, voll: voll, karte: karte)
        let v = Lage(x: (start.x - davor.x) / h, y: (start.y - davor.y) / h,
                     breite: (start.breite - davor.breite) / h)
        let ziel = abflugziel(karte: karte, voll: voll, richtung: richtung)
        let f = Kontowechselkurve.feder, u = t - abflug
        return Lage(x: f(start.x, ziel.x, v.x, flugAntwort, flugDaempfung, u),
                    y: f(start.y, ziel.y, v.y, flugAntwort, flugDaempfung, u),
                    breite: f(start.breite, ziel.breite, v.breite, flugAntwort, groessenDaempfung, u))
    }

    /// Deckkraft der Zeilen unter der abgehenden Karte: kommen, wenn sie
    /// klein ist, gehen beim Abflug.
    public static func abgangZeilendeckung(_ t: Double) -> Double {
        linear(t, abgangZeilenVon, abgangZeilenBis) * (1 - linear(t, abflug, abflug + zeilenAus))
    }

    /// **Wann die Karte ganz aus dem Bild ist** — dann schließt der Player.
    public static func abgangRaus(voll: Lage, karte: Lage, richtung: Richtung = .oben) -> Double {
        var t = abflug
        while t < abflug + 3 {
            let l = abgang(t, voll: voll, karte: karte, richtung: richtung)
            let draussen = l.y + l.hoehe / 2 < 0 || l.y - l.hoehe / 2 > voll.y * 2
                || l.x + l.breite / 2 < 0 || l.x - l.breite / 2 > voll.x * 2
            if draussen { return t }
            t += 1.0 / 240
        }
        return t
    }

    // MARK: Stützpunkte

    /// Stützpunkte für eine Keyframe-Animation: `schritte + 1` gleich
    /// verteilte Werte von `von` bis `bis`.
    public static func stuetzpunkte<T>(von: Double, bis: Double, jeSekunde: Double = 120,
                                       _ wert: (Double) -> T) -> [T] {
        let schritte = max(2, Int(((bis - von) * jeSekunde).rounded(.up)))
        return (0 ... schritte).map { wert(von + (bis - von) * Double($0) / Double(schritte)) }
    }
}
