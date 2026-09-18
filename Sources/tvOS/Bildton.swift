import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// **Der Farbton eines Bildes — nur der Ton, nicht die Farbe.**
///
/// Die Detailseite faerbt ihren Grund nach der Kulisse, wie Plex das macht.
/// Der Kniff steckt darin, was *nicht* uebernommen wird: Saettigung und
/// Helligkeit setzt die App selbst, aus dem Bild kommt allein der Farbton.
///
/// Der Grund dafuer ist nachrechenbar. Ein Durchschnitt ueber ein dunkles
/// Filmplakat ergibt Braungrau, und zwar fast immer — dunkle Bilder mitteln
/// sich zu Matsch, weil sich Gegenfarben aufheben. Nimmt man dagegen nur den
/// Ton und setzt den Rest fest, sieht das Ergebnis **immer** nach Swiftly
/// aus: ein kuehler Film wird blaugruen, ein warmer bernstein, und beide
/// bleiben gleich dunkel und gleich zurueckhaltend.
///
/// **Gemittelt wird auf dem Kreis, nicht auf der Zahl.** Farbtoene sind
/// Winkel: 350 Grad und 10 Grad liegen nebeneinander, ihr Zahlenmittel waere
/// 180 — also genau die Gegenfarbe. Deshalb werden sie als Einheitsvektoren
/// addiert und am Ende zurueckgerechnet.
///
/// Gewichtet wird mit dem Quadrat der Saettigung: der farbigste Fleck traegt
/// den Eindruck, den man vom Bild hat, nicht die graue Flaeche ringsum.
///
/// **Versuchsweise hier und nicht in `Sources/Shared`.** Mac und iPad haetten
/// dieselbe Verwendung; sobald es bleibt, gehoert die Rechnung nach der Regel
/// zuerst nach iOS und dann in den geteilten Code. Gemeldet.
@MainActor
final class Bildton {
    static let geteilt = Bildton()

    /// Einmal gerechnet, dann gemerkt. Ohne das rechnet jede Rueckkehr auf
    /// dieselbe Seite neu, und der Hintergrund blendet jedes Mal auf.
    private var bekannt: [URL: [Double]] = [:]
    private var laufend: [URL: Task<[Double], Never>] = [:]

    /// **Schon bekannt?** Ohne Warten, ohne `await`.
    ///
    /// Damit die Detailseite die Toene **sofort** setzen kann, statt sie
    /// aufzublenden. Beim Wechsel von der Startseite sind sie meist schon da:
    /// dort werden sie beim Bildwechsel mitgerechnet, und beide Seiten holen
    /// dasselbe Bild (`breite: 1600`).
    ///
    /// `nil` heisst "noch nie gerechnet", ein leeres Feld "gerechnet und
    /// nichts gefunden". Das ist nicht dasselbe: bei einem Graustufenbild
    /// soll nicht bei jedem Oeffnen neu gesucht werden.
    func gemerkt(fuer url: URL) -> [Double]? { bekannt[url] }

    // `vorrechnen` gab es, solange nur die Detailseiten sich faerbten und
    // die Startseite den Ton bloss schon einmal ausrechnen sollte. Jetzt
    // faerbt sie sich selbst, also rechnet `Bildgrund` ihn dort ohnehin —
    // und `gemerkt(fuer:)` sorgt dafuer, dass die Detailseite ihn ohne
    // Warten und ohne Ueberblendung uebernimmt.

    /// Bis zu drei Farbtoene in Grad, nach Gewicht — leer, wenn sich keiner
    /// ableiten laesst.
    func toene(fuer url: URL) async -> [Double] {
        if let fertig = bekannt[url] { return fertig }
        if let laeuft = laufend[url] { return await laeuft.value }

        let aufgabe = Task<[Double], Never> {
            guard let (daten, _) = try? await URLSession.shared.data(from: url) else { return [] }
            return Self.toeneAus(daten)
        }
        laufend[url] = aufgabe
        let ergebnis = await aufgabe.value
        bekannt[url] = ergebnis
        laufend[url] = nil
        return ergebnis
    }

    /// Auf 32 x 32 heruntergerechnet, dann Punkt fuer Punkt in ein
    /// Histogramm der Farbtoene.
    ///
    /// **Ein Mittelwert reicht nicht.** Die erste Fassung mittelte alle Toene
    /// zu einem einzigen — und ein Bild hat selten nur einen. Paul, an
    /// Plex-Bildern: "zu wenig Farbe aus dem Bild genommen, es ist irgendwie
    /// immer nur eine." Stimmt: ein Sonnenuntergang ist orange **und** blau,
    /// und der Mittelwert davon ist keins von beidem.
    ///
    /// Deshalb 36 Faecher zu je zehn Grad, gewichtet mit dem Quadrat der
    /// Saettigung mal der Helligkeit. Danach werden die staerksten Gipfel
    /// gezogen, und zwar mit Mindestabstand: zwei Faecher nebeneinander sind
    /// derselbe Ton, kein zweiter.
    ///
    /// **Fuenf, nicht drei.** Paul: „man kann aus so einem Bild ja meist
    /// viele Farben kriegen." Stimmt — drei war meine Sparsamkeit, nicht die
    /// des Bildes. Mehr Toene heissen mehr Bewegung ueber die Flaeche, und
    /// das ist zugleich das Beste gegen Streifen: je mehr die drei Kanaele
    /// unterschiedlich schnell laufen, desto weniger fallen ihre
    /// Quantisierungsgrenzen zusammen.
    nonisolated static func toeneAus(_ daten: Data) -> [Double] {
        guard let quelle = CGImageSourceCreateWithData(daten as CFData, nil),
              let bild = CGImageSourceCreateThumbnailAtIndex(quelle, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 48,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return [] }

        let breite = bild.width, hoehe = bild.height
        guard breite > 0, hoehe > 0 else { return [] }

        var punkte = [UInt8](repeating: 0, count: breite * hoehe * 4)
        guard let raum = CGColorSpace(name: CGColorSpace.sRGB),
              let flaeche = CGContext(data: &punkte, width: breite, height: hoehe,
                                      bitsPerComponent: 8, bytesPerRow: breite * 4,
                                      space: raum,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        flaeche.draw(bild, in: CGRect(x: 0, y: 0, width: breite, height: hoehe))

        let faecher = 36
        var korb = [Double](repeating: 0, count: faecher)
        var gesamt = 0.0

        for i in stride(from: 0, to: punkte.count, by: 4) {
            let r = Double(punkte[i]) / 255
            let g = Double(punkte[i + 1]) / 255
            let b = Double(punkte[i + 2]) / 255

            let hoch = max(r, g, b), tief = min(r, g, b)
            let spanne = hoch - tief
            guard spanne > 0.04, hoch > 0.08 else { continue }

            let saettigung = spanne / hoch
            var ton: Double
            switch hoch {
            case r: ton = (g - b) / spanne
            case g: ton = 2 + (b - r) / spanne
            default: ton = 4 + (r - g) / spanne
            }
            ton *= 60
            if ton < 0 { ton += 360 }

            let gewicht = saettigung * saettigung * hoch
            korb[min(faecher - 1, Int(ton / 10))] += gewicht
            gesamt += gewicht
        }

        guard gesamt > 0.5 else { return [] }

        // Gipfel ziehen: staerkstes Fach, dann das staerkste mit mindestens
        // drei Faechern (30 Grad) Abstand, und so weiter.
        var gewaehlt: [Double] = []
        var uebrig = korb
        for _ in 0 ..< 5 {
            guard let (fach, wert) = uebrig.enumerated().max(by: { $0.element < $1.element }),
                  wert > gesamt * 0.035 else { break }

            // Der genaue Ton kommt aus dem Fach und seinen Nachbarn, damit er
            // nicht auf Zehnergrad einrastet.
            var x = 0.0, y = 0.0
            for versatz in -1 ... 1 {
                let f = (fach + versatz + faecher) % faecher
                let bogen = (Double(f) * 10 + 5) * .pi / 180
                x += cos(bogen) * korb[f]
                y += sin(bogen) * korb[f]
            }
            var grad = atan2(y, x) * 180 / .pi
            if grad < 0 { grad += 360 }
            gewaehlt.append(grad)

            for versatz in -1 ... 1 { uebrig[(fach + versatz + faecher) % faecher] = 0 }
        }
        return gewaehlt
    }

}

extension Bildton {
    /// Saettigung und Helligkeit stehen jetzt in `Bildgrund.farbe(bei:)`,
    /// wo sie von der Stelle im Netz abhaengen. Die frueheren `farbe` und
    /// `grundfarbe` gab es nur, solange der Grund aus einer Flaeche und
    /// gestapelten Wolken bestand — sie sind mit dem Netz weggefallen.

    /// **Feines Rauschen gegen Streifenbildung.**
    ///
    /// Der eigentliche Grund fuer Streifen ist nicht der Verlauf, sondern die
    /// Zahlendarstellung: acht Bit je Kanal geben 256 Stufen, und ein
    /// Farbverlauf, der ueber tausend Punkte nur ein paar Stufen durchlaeuft,
    /// hat zwangslaeufig breite Baender gleicher Farbe. Auf einem grossen
    /// dunklen Schirm sieht man jede Grenze.
    ///
    /// Dagegen hilft kein weicherer Verlauf — die Stufen liegen dann nur
    /// woanders. Es hilft nur, die Grenze **aufzubrechen**: ein Hauch
    /// Zufallsrauschen laesst benachbarte Punkte mal auf die eine, mal auf
    /// die andere Stufe fallen. Das Auge mittelt darueber und sieht den
    /// Uebergang, den die Zahlen nicht hergeben. Genau dafuer gibt es
    /// Dithering, seit es Bildschirme gibt.
    ///
    /// **Die Staerke ist der ganze Trick, und sie ist winzig.** Gebraucht
    /// wird eine Amplitude von etwa **einer** Helligkeitsstufe: gerade genug,
    /// damit ein Punkt mal auf die eine, mal auf die andere Stufe faellt.
    ///
    /// Ein Zwischenstand stand auf 3,5 Prozent — bei Schwarz/Weiss mit voller
    /// Zufallsdeckkraft sind das rund neun Stufen Ausschlag. Das ist kein
    /// Dither mehr, sondern sichtbares Korn, und genau so sah es aus.
    ///
    ///     255 × 0,008 × 0,5 (mittlere Deckkraft) ≈ 1 Stufe
    ///
    /// 96 x 96 gekachelt. Sichtbar ist davon nichts, ausser dass die Baender
    /// weg sind.
    static let rauschen: Image = {
        let kante = 96
        var punkte = [UInt8](repeating: 0, count: kante * kante * 4)
        var zustand: UInt64 = 0x2545F4914F6CDD1D
        for i in stride(from: 0, to: punkte.count, by: 4) {
            // Xorshift: schnell, gleichverteilt genug, und ohne Abhaengigkeit
            // von einer Zufallsquelle, die je Lauf anders aussieht.
            zustand ^= zustand << 13
            zustand ^= zustand >> 7
            zustand ^= zustand << 17
            // **In beide Richtungen.** Die erste Fassung war weiss mit
            // zufaelliger Deckkraft — die konnte nur aufhellen, nie
            // abdunkeln. Ein einseitiger Stoss verschiebt den Verlauf, statt
            // die Stufengrenze aufzubrechen. Hier ist jeder Punkt zufaellig
            // schwarz oder weiss, das Mittel bleibt neutral.
            let hell = (zustand & 1) == 1
            let deckung = UInt8(truncatingIfNeeded: zustand >> 8)
            // Vormultipliziert: bei Schwarz sind die Farbkanaele null, bei
            // Weiss gleich der Deckkraft.
            let kanal: UInt8 = hell ? deckung : 0
            punkte[i] = kanal; punkte[i + 1] = kanal; punkte[i + 2] = kanal
            punkte[i + 3] = deckung
        }
        let raum = CGColorSpace(name: CGColorSpace.sRGB)!
        let flaeche = CGContext(data: &punkte, width: kante, height: kante,
                                bitsPerComponent: 8, bytesPerRow: kante * 4,
                                space: raum,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return Image(decorative: flaeche.makeImage()!, scale: 1)
    }()

    /// **Eine runde Blende — ein Abfall statt zweier.**
    ///
    /// Zwei Masken uebereinander, eine waagerecht und eine senkrecht, ergeben
    /// zusammen einen **rechteckigen** Abfall. Jede fuer sich kann noch so
    /// weich sein: ihr Produkt zeichnet die zwei Geraden nach, an denen sie
    /// wirken, und in der Ecke, wo beide halb greifen, wird es doppelt
    /// dunkel. Paul: „man sieht zwei harte Kanten, die geglaettet wurden."
    /// Genau das — geglaettete Kanten sind immer noch Kanten.
    ///
    /// Ein einziger radialer Abfall hat keine Richtung, in der er wirkt, also
    /// auch keine Gerade, die er nachzeichnen koennte.
    ///
    /// Dieselbe Kurve wie ueberall, damit weder Anfang noch Ende einen Knick
    /// hat, an dem ein Band entstehen koennte.
}

/// Faerbt den Grund einer ganzen Seite nach ihrem Kulissenbild.
///
/// **An der Seite, nicht am Kopf.** Erst sass das im `Detailkopf`, und damit
/// endete die Faerbung an dessen Unterkante — darunter stand wieder reines
/// `#0B0B0D` und quer ueber dem Schirm eine Naht. Der Grund gehoert unter
/// alles, was die Seite zeigt, die Reihen eingeschlossen.
struct Bildgrund: ViewModifier {
    let url: URL?
    @State private var toene: [Double]

    /// **Der Anfangswert kommt aus dem Gedaechtnis, nicht aus dem Nichts.**
    ///
    /// Jede Seite legt ihren eigenen `Bildgrund` an — die Detailseite also
    /// einen neuen, wenn sie aufgeht. Stand der auf `[]`, zeichnete er
    /// zuerst den nackten Grund und fuellte sich erst im naechsten Durchgang.
    /// Genau das sah Paul: „es ist ja dasselbe Bild, wozu aus- und
    /// einblenden?"
    ///
    /// Das nachtraegliche Setzen ohne Animation kam dafuer zu spaet — der
    /// leere Durchgang hatte da schon stattgefunden. Ein Ton, der bekannt
    /// ist, muss deshalb **schon im ersten** Durchgang stehen.
    @MainActor init(url: URL?) {
        self.url = url
        _toene = State(initialValue: url.flatMap { Bildton.geteilt.gemerkt(fuer: $0) } ?? [])
    }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    netz.ignoresSafeArea()

                    // Der letzte Rest gegen Baender — siehe `Bildton.rauschen`.
                    if !toene.isEmpty {
                        Bildton.rauschen
                            .resizable(resizingMode: .tile)
                            .opacity(0.008)
                            .ignoresSafeArea()
                    }
                }
                .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.4), value: toene)
            .task(id: url) {
                guard let url else { toene = []; return }

                // Schon bekannt? Dann steht es seit dem ersten Durchgang da
                // (siehe `init`) und hier ist nichts mehr zu tun. Ohne diese
                // Rueckkehr wuerde dieselbe Zuweisung eine Animation
                // ausloesen, obwohl sich der Wert gar nicht aendert.
                if let schonDa = Bildton.geteilt.gemerkt(fuer: url) {
                    if schonDa != toene {
                        var ohne = Transaction()
                        ohne.disablesAnimations = true
                        withTransaction(ohne) { toene = schonDa }
                    }
                    return
                }

                // Nur wirklich Neues wird uebergeblendet — etwa ein Titel,
                // den man ueber die Suche direkt oeffnet.
                toene = await Bildton.geteilt.toene(fuer: url)
            }
    }

    /// **Ein Netz statt gestapelter Verlaeufe.**
    ///
    /// Davor lagen hier ein linearer Grundverlauf und bis zu fuenf radiale
    /// Wolken uebereinander. Jede davon hat Stuetzstellen, an jeder
    /// Stuetzstelle springt die Steigung, und jeder Sprung liest sich als
    /// Band — dazu addieren sich fuenf halbdurchsichtige Ebenen zu genau den
    /// fleckigen Uebergaengen, die Paul gesehen hat. Kein Feinschliff an den
    /// Zahlen konnte das beheben, weil der Aufbau selbst die Kanten erzeugte.
    ///
    /// `MeshGradient` interpoliert stattdessen auf der GPU ueber eine
    /// **Flaeche**: neun Stuetzpunkte, dazwischen eine glatte Lage. Es gibt
    /// darin keine Stopps, an denen etwas knicken koennte, und keine
    /// gestapelten Ebenen, die sich addieren. Seit tvOS 18 da, unser Ziel
    /// steht auf 18.0.
    ///
    /// Die Farben verteilen sich so, wie das Bild steht: oben rechts, wo die
    /// Kulisse sitzt, der staerkste Ton am hellsten; nach links unten wird es
    /// dunkler, bis es in den Grund uebergeht. Die uebrigen Toene fuellen die
    /// Mitte, damit ueber die Flaeche wirklich Farbe wechselt.
    private var netz: some View {
        // **Fuenf mal fuenf, nicht drei mal drei.**
        //
        // Neun Stuetzpunkte auf 1920 x 1080 sind neun Farbinseln, und was
        // dazwischen interpoliert wird, sieht man als Beule — Paul: „etwas
        // fleckig." Das laesst sich nicht wegdaempfen; solange die Punkte so
        // weit auseinanderliegen, traegt jeder eine eigene Wolke.
        //
        // 25 Punkte tasten dasselbe Farbfeld dicht genug ab, dass die
        // Flecken zu einer Flaeche verschmelzen. `farbe(bei:)` ist eine
        // stetige Funktion des Ortes — je feiner man sie abtastet, desto
        // glatter das Ergebnis.
        let seite = 5
        var punkte: [SIMD2<Float>] = []
        for zeile in 0 ..< seite {
            for spalte in 0 ..< seite {
                punkte.append([Float(spalte) / Float(seite - 1),
                               Float(zeile) / Float(seite - 1)])
            }
        }
        return MeshGradient(width: seite, height: seite,
                            points: punkte,
                            colors: punkte.map { farbe(bei: $0) })
    }

    /// Welche Farbe an welcher Stelle des Netzes steht.
    ///
    /// **Stetig, nicht je Feld.** Vorher waehlte ein ganzzahliger Index den
    /// Ton, also sprang die Farbe von Punkt zu Punkt — bei fuenf Toenen sass
    /// neben Blau schnell Orange. Jetzt laeuft ein Wert von 0 bis 1 schraeg
    /// ueber die Flaeche und blendet zwischen benachbarten Toenen ueber:
    /// zwei Nachbarn im Netz unterscheiden sich dadurch nur noch um einen
    /// Bruchteil eines Tonabstands.
    ///
    /// Zwei Dinge entscheiden: die Naehe zur Kulisse oben rechts bestimmt,
    /// **wie hell** es wird, die Stelle im Netz, **welcher** Ton es ist.
    private func farbe(bei punkt: SIMD2<Float>) -> Color {
        guard !toene.isEmpty else { return Stil.grund }

        // Abstand zur Kulisse (oben rechts), auf 0…1 gebracht.
        let dx = Double(1 - punkt.x), dy = Double(punkt.y)
        let naehe = 1 - min(1, (dx * dx + dy * dy).squareRoot() / 1.414)

        // Schraeg ueber die Flaeche, damit die Farbe wandert.
        let lauf = (Double(punkt.x) + Double(punkt.y)) / 2
        let ton = tonBei(lauf)

        // Nah an der Kulisse farbig, weit weg fast der Grundton.
        //
        //     Saettigung  0,38…0,58
        //     Helligkeit  0,075…0,215
        //     Abfall      naehe^1,6
        //
        // Der Abfall traegt das meiste: quadratisch faellt die Helligkeit so
        // schnell, dass ausserhalb des Bildes fast alles auf dem Grundton
        // liegt und die Farbe nur dort steht, wo ohnehin das Bild ist.
        //
        // Der Akzent bleibt aussen vor (E2): das ist Grund, kein
        // Bedienelement, und dunkel genug fuer weisse Schrift darauf.
        return Color(hue: ton / 360,
                     saturation: 0.38 + 0.20 * naehe,
                     brightness: 0.075 + 0.140 * pow(naehe, 1.6))
    }

    /// Der Farbton an der Stelle `lauf` (0…1) — zwischen den gefundenen
    /// Toenen uebergeblendet, ueber den kuerzesten Weg auf dem Farbkreis.
    ///
    /// Jeder Ton rueckt dabei zur Hauptfarbe hin: die Bewegung ueber die
    /// Flaeche bleibt, ihre Spannweite schrumpft auf ein Drittel. Sonst
    /// stuende neben Blau ein volles Orange, und das sieht man als Fleck,
    /// wie fein das Netz auch ist.
    private func tonBei(_ lauf: Double) -> Double {
        let leit = toene[0]
        func gedaempft(_ ton: Double) -> Double {
            var weg = ton - leit
            if weg > 180 { weg -= 360 }
            if weg < -180 { weg += 360 }
            return leit + weg * 0.34
        }
        guard toene.count > 1 else { return leit }

        let stelle = lauf * Double(toene.count - 1)
        let a = min(Int(stelle), toene.count - 2)
        let t = stelle - Double(a)

        let von = gedaempft(toene[a]), bis = gedaempft(toene[a + 1])
        var weg = bis - von
        if weg > 180 { weg -= 360 }
        if weg < -180 { weg += 360 }
        var ton = von + weg * (t * t * (3 - 2 * t))
        if ton < 0 { ton += 360 }
        if ton >= 360 { ton -= 360 }
        return ton
    }
}

extension View {
    func bildgrund(url: URL?) -> some View { modifier(Bildgrund(url: url)) }
}
