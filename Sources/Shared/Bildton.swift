import CoreGraphics
import Foundation
import ImageIO
import JellyfinKit
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
/// **Geteilt, seit das iPhone denselben Ton braucht.** Fernseher und iPhone
/// rechnen dieselben Toene aus demselben Bild; wie daraus ein Grund wird,
/// entscheidet jede Plattform selbst (`TVBildgrund.swift`,
/// `Sources/iOS/Bildstimmung.swift`).
@MainActor
final class Bildton {
    static let geteilt = Bildton()

    /// Einmal gerechnet, dann gemerkt. Ohne das rechnet jede Rueckkehr auf
    /// dieselbe Seite neu, und der Hintergrund blendet jedes Mal auf.
    ///
    /// **Gedeckelt.** Ein Eintrag ist klein, aber wer eine Stunde durch die
    /// Bibliothek faehrt, sammelt tausende; die aeltesten fallen heraus.
    private var bekannt: [URL: [Double]] = [:]
    private var reihenfolge: [URL] = []
    private static let hoechstens = 300
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

        // **Losgeloest, nicht bloss `nonisolated`.** Ein gewoehnliches
        // `Task` erbt den Hauptakteur, und `toeneAus` lief darin trotz
        // `nonisolated` auf ihm: Entschluesseln, Verkleinern und ein
        // Histogramm ueber jeden Punkt, mitten im Fokuswechsel.
        let aufgabe = Task.detached(priority: .userInitiated) { () -> [Double] in
            guard let (daten, _) = try? await URLSession.shared.data(for: .mitEigenenKoepfen(url)) else { return [] }
            return Self.toeneAus(daten)
        }
        laufend[url] = aufgabe
        let ergebnis = await aufgabe.value
        if bekannt[url] == nil { reihenfolge.append(url) }
        bekannt[url] = ergebnis
        laufend[url] = nil
        if reihenfolge.count > Self.hoechstens {
            let weg = reihenfolge.prefix(reihenfolge.count - Self.hoechstens)
            for alt in weg { bekannt[alt] = nil }
            reihenfolge.removeFirst(weg.count)
        }
        return ergebnis
    }

    /// Auf 32 x 32 heruntergerechnet, dann Punkt fuer Punkt in ein Histogramm
    /// der Farbtoene.
    ///
    /// **Ein Mittelwert reicht nicht.** Die erste Fassung mittelte alle Toene
    /// zu einem einzigen — und ein Bild hat selten nur einen. Stimmt: ein
    /// Sonnenuntergang ist orange **und** blau, und der Mittelwert davon ist
    /// keins von beidem.
    ///
    /// Deshalb 36 Faecher zu je zehn Grad, gewichtet mit dem Quadrat der
    /// Saettigung mal der Helligkeit. Danach werden die staerksten Gipfel
    /// gezogen, und zwar mit Mindestabstand: zwei Faecher nebeneinander sind
    /// derselbe Ton, kein zweiter.
    ///
    /// **Fuenf, nicht drei.** Stimmt — drei war meine Sparsamkeit, nicht die
    /// des Bildes. Mehr Toene heissen mehr Bewegung ueber die Flaeche, und das
    /// ist zugleich das Beste gegen Streifen: je mehr die drei Kanaele
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

        // Histogramm und Gipfel stehen im Paket, damit Android dieselben
        // Töne rechnet (`Bildtonrechnung.toene`).
        return Bildtonrechnung.toene(rgba: punkte)
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
    /// wirken, und in der Ecke, wo beide halb greifen, wird es doppelt dunkel.
    /// Genau das — geglaettete Kanten sind immer noch Kanten.
    ///
    /// Ein einziger radialer Abfall hat keine Richtung, in der er wirkt, also
    /// auch keine Gerade, die er nachzeichnen koennte.
    ///
    /// Dieselbe Kurve wie ueberall, damit weder Anfang noch Ende einen Knick
    /// hat, an dem ein Band entstehen koennte.
}

// MARK: - Das Netz

/// **Wie aus den Toenen ein Grund wird — auf Fernseher und iPhone gleich.**
/// Stand zuerst im tvOS-`Bildgrund`; das iPhone malt seine Detailseiten jetzt
/// aus derselben Rechnung, deshalb hier. Die Zahlen sind Stil-Tokens
/// (`Farben.swift`, „Farbe aus dem Bild").
extension Bildton {
    /// **Ein Netz statt gestapelter Verlaeufe.**
    ///
    /// Davor lagen hier ein linearer Grundverlauf und bis zu fuenf radiale
    /// Wolken uebereinander. Jede davon hat Stuetzstellen, an jeder
    /// Stuetzstelle springt die Steigung, und jeder Sprung liest sich als Band
    /// — dazu addieren sich fuenf halbdurchsichtige Ebenen zu genau den
    /// fleckigen Uebergaengen, die Kein Feinschliff an den Zahlen konnte das
    /// beheben, weil der Aufbau selbst die Kanten erzeugte.
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
    static func netz(_ toene: [Double]) -> MeshGradient {
        // **Fuenf mal fuenf, nicht drei mal drei.**
        //
        // Neun Stuetzpunkte auf 1920 x 1080 sind neun Farbinseln, und was
        // dazwischen interpoliert wird, sieht man als Beule Das laesst sich
        // nicht wegdaempfen; solange die Punkte so weit auseinanderliegen,
        // traegt jeder eine eigene Wolke.
        //
        // 25 Punkte tasten dasselbe Farbfeld dicht genug ab, dass die Flecken
        // zu einer Flaeche verschmelzen. `farbe(bei:)` ist eine stetige
        // Funktion des Ortes — je feiner man sie abtastet, desto glatter das
        // Ergebnis.
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
                            colors: punkte.map { farbe(toene, bei: $0) })
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
    static func farbe(_ toene: [Double], bei punkt: SIMD2<Float>) -> Color {
        guard !toene.isEmpty else { return Stil.grund }

        // Die Rechnung steht im Paket (`Bildtonrechnung.hsb`), die Zahlen
        // sind die Stil-Tokens in `Farben.swift`:
        //
        //     Saettigung  0,38…0,58
        //     Helligkeit  0,075…0,215
        //     Abfall      naehe^1,6
        //
        // Der Abfall traegt das meiste: ausserhalb des Bildes liegt fast
        // alles auf dem Grundton, die Farbe steht nur dort, wo ohnehin das
        // Bild ist. Der Akzent bleibt aussen vor (E2): das ist Grund, kein
        // Bedienelement, und dunkel genug fuer weisse Schrift darauf.
        let t = Bildtonrechnung.hsb(toene, x: Double(punkt.x), y: Double(punkt.y))
        return Color(hue: t.ton / 360, saturation: t.saettigung, brightness: t.helligkeit)
    }

    /// Dieselbe Farbe wie ``farbe(_:bei:)``, aber `abklingen` (1 … 0) führt
    /// sie auf `grund` zurück — **in OKLab**: Helligkeit und Buntheit
    /// gemeinsam, bis bei 0 genau `grund` steht. Eine Deckkraft über `grund`
    /// mischte in sRGB, und wo die Farbe dunkler war als der Grund, stand beim
    /// Scrollen eine Kante (Paul, 27.09.). Gerechnet im Paket
    /// (`Bildtonrechnung.farbe`), damit Android denselben Auslauf hat.
    static func farbe(_ toene: [Double], x: Double, y: Double, abklingen f: Double) -> Color {
        guard !toene.isEmpty else { return Stil.grund }
        let aus = Bildtonrechnung.farbe(toene, x: x, y: y, abklingen: f)
        return Color(.sRGB, red: aus.r, green: aus.g, blue: aus.b)
    }

    /// **Das Netz für eine Detailseite, die in `grund` ausläuft** (iPhone).
    /// Oben genau das Bild des Fernsehers über `farbhoehe` (wie bisher), ab
    /// `ab` über `auslauf` auf einer Glättkurve (smootherstep) exakt bis
    /// `grund` — Stützzeilen dicht über den Auslauf, gemischt in der
    /// wahrnehmungsgleichen Farbwelt.
    static func netz(_ toene: [Double], hoehe: Double, farbhoehe: Double, ab: Double,
                     auslauf: Double) -> MeshGradient {
        let spalten = 5
        var zeilen: [Double] = [0, ab * 0.5, ab]
        for i in 1 ... 10 { zeilen.append(ab + auslauf * Double(i) / 10) }
        zeilen.append(hoehe)
        var punkte: [SIMD2<Float>] = [], farben: [Color] = []
        for y in zeilen {
            let f = Bildtonrechnung.abklingen(y: y, ab: ab, auslauf: auslauf)
            for s in 0 ..< spalten {
                let x = Double(s) / Double(spalten - 1)
                punkte.append([Float(x), Float(min(1, y / hoehe))])
                farben.append(farbe(toene, x: x, y: min(1, y / farbhoehe), abklingen: f))
            }
        }
        return MeshGradient(width: spalten, height: zeilen.count, points: punkte, colors: farben,
                            background: Stil.grund, smoothsColors: true, colorSpace: .perceptual)
    }

    /// Der Farbton an der Stelle `lauf` (0…1) — zwischen den gefundenen
    /// Toenen uebergeblendet, ueber den kuerzesten Weg auf dem Farbkreis.
    ///
    /// Jeder Ton rueckt dabei zur Hauptfarbe hin: die Bewegung ueber die
    /// Flaeche bleibt, ihre Spannweite schrumpft auf ein Drittel. Sonst
    /// stuende neben Blau ein volles Orange, und das sieht man als Fleck,
    /// wie fein das Netz auch ist.
    static func tonBei(_ toene: [Double], _ lauf: Double) -> Double {
        Bildtonrechnung.tonBei(toene, lauf)
    }
}
