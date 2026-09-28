import Foundation
import JellyfinKit

// MARK: - „Hier weiterschauen" als Karte (Entwurf B) — die Bruecke fuer Kotlin
//
// **Alle Zeiten, Federn und Masse stehen im Paket** (`Uebergabekarte`). Hier
// werden sie nur als Stuetzpunkte ausgegeben, wie `Uebergabebuehne` auf Apple
// sie Core Animation gibt: 120 je Sekunde, dazwischen geradlinig. Kotlin
// (`Uebergabe.kt`) legt sie in `graphicsLayer` — nur Lage, Groesse, Deckkraft.
//
// Einheiten: hinein und hinaus in dp. Auf dem Fernseher rechnet das Paket in
// tvOS-Punkten (1920 breit), Android TV in der Haelfte davon — also wird
// dort verdoppelt, gerechnet und wieder halbiert, damit auch der Hub des
// Schwebens und der Weg hinaus stimmen.

struct Uebergabeantwort: Encodable { let grund: String; let ab: Double }

extension Kern {
    /// **Das Bild der Karte** — `Uebernahmemodell.kartenbildURL`: bei Folgen das Bild der Folge (es zeigt,
    /// *wo* man ist), sonst das Querbild des Titels.
    static func kartenbild(_ titel: Item, adressen a: Bildadresse) -> String? {
        if titel.seriesId != nil, let marke = titel.imageTags?["Primary"] {
            return a.bauen(itemID: titel.id, marke: marke, mass: .hoechstensBreit(1280))?.absoluteString
        }
        return Bildwahl.quer(titel, adressen: a, breite: 1280)?.url.absoluteString
    }
}

enum Uebergabebahn {
    typealias K = Uebergabekarte

    struct Massantwort: Encodable { let breite, ecke, titel, klein, abstand: Double }

    /// Zeiten aus dem Paket, damit Kotlin keine eigenen fuehrt.
    struct Zeiten: Encodable {
        let seiteBis = K.seiteBis
        let kartenStart = K.kartenStart
        let schweben = K.schweben
        let ladelinieAb = K.ladelinieAb
        let ladelinieEinblenden = K.ladelinieEinblenden
        let ladelinieTakt = K.ladelinieTakt
        let zeilenAus = K.zeilenAus
        let schwarzDauer = K.schwarzDauer
        let kartenAusVon = K.kartenAusVon
        let ende = K.ende
        let hoechstensWarten = K.hoechstensWarten
        let blende = K.blende
        let blendeAus = K.blendeAus
        let abgangStart = K.abgangStart
        let abgangReduziertEnde = K.abgangReduziertEnde
        /// Bis hierhin rechnet die Bahn des Wartens — weit ueber die laengste Wartezeit hinaus
        /// (`Uebergabebuehne.bahnLegen`).
        let wartenBis = K.schweben + K.hoechstensWarten + 8
    }

    struct Lagenantwort: Encodable {
        let voll: [Double]
        let ruhe: [Double]
        let masse: Massantwort
        let zeiten = Zeiten()
    }

    static func skala(_ fernseher: Bool) -> Double { fernseher ? 0.5 : 1 }
    static func masse(_ fernseher: Bool) -> K.Masse { fernseher ? K.fernseher : K.iPhone }

    static func lagen(breite: Double, hoehe: Double, fernseher: Bool) -> Lagenantwort {
        let s = skala(fernseher), m = masse(fernseher)
        let b = breite / s, h = hoehe / s
        let v = K.vollbild(breite: b, hoehe: h), r = K.ruhelage(breite: b, hoehe: h, masse: m)
        return Lagenantwort(voll: [v.x * s, v.y * s, v.breite * s], ruhe: [r.x * s, r.y * s, r.breite * s],
                            masse: Massantwort(breite: m.breite * s, ecke: m.ecke * s, titel: m.titel * s,
                                               klein: m.klein * s, abstand: m.abstand * s))
    }

    struct Eingabe: Decodable {
        /// `warten`, `deckung`, `zoom`, `abgang` oder `neu` (Flug nach einer Drehung: die Lage bei `ab`).
        let art: String
        let fernseher: Bool
        var von: [Double]?
        var ruhe: [Double]?
        var voll: [Double]?
        /// Wann der (letzte) Flug begann (`Uebergabebuehne.flugAb`).
        var flugAb: Double?
        var ab: Double?
        var bis: Double?
        /// Abgang: Schirmgroesse und Richtung.
        var schirm: [Double]?
        var nachOben: Bool?
        /// Abgang am Telefon: die Schwerkraft wie `CMDeviceMotion.gravity` und die Lage der Oberflaeche
        /// (`hoch`, `kopfueber`, `querHomeRechts`, `querHomeLinks`) — `Uebergabekarte.abflugrichtung`.
        var schwerkraft: [Double]?
        var oberflaeche: String?
    }

    struct Antwort: Encodable {
        /// Ab wann (Sekunden) und in welchem Abstand die Punkte stehen.
        var t0: Double = 0
        var dt: Double = 0
        /// Je Punkt x, y, Breite, Ecke und Oberkante der Zeilen darunter (dp).
        var l: [Double] = []
        /// Je Punkt eine oder mehrere Deckungen, `dn` je Punkt.
        var d: [Double] = []
        var dn = 0
        /// Abgang: wann die Karte draussen ist. `neu`: Lage bei `ab`.
        var raus: Double?
        var lage: [Double]?
    }

    static func rechnen(_ e: Eingabe) -> Antwort {
        let s = skala(e.fernseher), m = masse(e.fernseher)
        func lage(_ a: [Double]?) -> K.Lage {
            guard let a, a.count >= 3 else { return K.Lage(x: 0, y: 0, breite: 1) }
            return K.Lage(x: a[0] / s, y: a[1] / s, breite: a[2] / s)
        }
        let von = lage(e.von), ruhe = lage(e.ruhe), voll = lage(e.voll)
        let flugAb = e.flugAb ?? K.kartenStart
        var antwort = Antwort()
        func punkte(von t0: Double, bis t1: Double, lage f: ((Double) -> K.Lage)?, deckung g: ((Double) -> [Double])?) {
            let schritte = max(2, Int(((t1 - t0) * 120).rounded(.up)))
            antwort.t0 = t0
            antwort.dt = (t1 - t0) / Double(schritte)
            for i in 0 ... schritte {
                let t = t0 + (t1 - t0) * Double(i) / Double(schritte)
                if let f {
                    let l = f(t)
                    antwort.l += [l.x * s, l.y * s, l.breite * s, K.ecke(l, masse: m, voll: voll) * s,
                                  K.zeilenOben(l, masse: m) * s]
                }
                if let g { let d = g(t); antwort.dn = d.count; antwort.d += d }
            }
        }
        switch e.art {
        case "warten":
            punkte(von: e.ab ?? 0, bis: e.bis ?? (K.schweben + K.hoechstensWarten + 8),
                   lage: { K.warten($0, von: von, nach: ruhe, ab: flugAb) }, deckung: nil)
        case "deckung":
            // Karte, Grund ueber der Seite, Zeilen — die erste Sekunde (`Uebergabebuehne.flugLegen`).
            punkte(von: 0, bis: 1, lage: nil) {
                [K.kartendeckung($0), K.seitendeckung($0), K.zeilendeckung($0, zoomAb: nil)]
            }
        case "neu":
            let l = K.flug(e.ab ?? 0, von: von, nach: ruhe, ab: flugAb)
            antwort.lage = [l.x * s, l.y * s, l.breite * s]
        case "zoom":
            // Aus Lage **und Schwung** der wartenden Karte (`Uebergabebuehne.zoomen`).
            let z = e.ab ?? K.schweben
            let start = K.warten(z, von: von, nach: ruhe, ab: flugAb)
            let schwung = K.schwung(z, von: von, nach: ruhe, ab: flugAb)
            punkte(von: 0, bis: K.ende, lage: { K.zoom($0, von: start, schwung: schwung, nach: voll) }) {
                [K.buehnendeckung(nachZoom: $0)]
            }
        case "abgang":
            let schirm = e.schirm ?? [voll.x * 2 * s, voll.y * 2 * s]
            let karte = K.ruhelage(breite: schirm[0] / s, hoehe: schirm[1] / s, masse: m)
            let oben = e.nachOben ?? true
            var richtung: K.Richtung = oben ? .oben : .unten
            if let g = e.schwerkraft, g.count >= 2 {
                let o: K.Oberflaeche = switch e.oberflaeche {
                case "kopfueber": .kopfueber
                case "querHomeRechts": .querHomeRechts
                case "querHomeLinks": .querHomeLinks
                default: .hoch
                }
                richtung = K.abflugrichtung(schwerkraftX: g[0], schwerkraftY: g[1], oberflaeche: o, nachOben: oben)
            }
            // Der Schirm fuer `abflugziel` ergibt sich aus dem mittigen `voll` — wie auf Apple.
            let raus = K.abgangRaus(voll: voll, karte: karte, richtung: richtung)
            punkte(von: 0, bis: raus + 0.1, lage: { K.abgang($0, voll: voll, karte: karte, richtung: richtung) }) {
                [K.abgangZeilendeckung($0)]
            }
            antwort.raus = raus
            antwort.lage = [karte.x * s, karte.y * s, karte.breite * s]
        default:
            break
        }
        return antwort
    }
}
