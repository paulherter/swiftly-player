import CoreGraphics
import ImageIO
import SwiftUI

/// Ein Bild aus dem Netz — geholt, **abseits des Hauptlaufs entschlüsselt**,
/// gemerkt und eingeblendet.
///
/// **Liegt seit dem 05.09.2026 hier statt in `Sources/macOS`.** Vorher gab es
/// drei Bildlader: diesen, `Bild` in `Sources/Shared/Stil.swift` für iPhone
/// und iPad, und noch einmal dasselbe `Bild` in `Sources/tvOS/Stil.swift` —
/// eine Kopie mit demselben Kommentar. Die beiden anderen tragen einen
/// Anlaufzähler gegen `NSURLErrorCancelled`; das ist ein Verband um eine
/// Eigenschaft von `AsyncImage` und kein Bau, der das Problem nicht hat.
///
/// Vorher stand hier `AsyncImage`. Drei Dinge waren daran falsch:
///
/// 1. **Es entschlüsselt auf dem Hauptlauf.** Ein Raster mit fünfzig Kacheln
///    entschlüsselt fünfzig Bilder dort, wo auch gezeichnet wird. Das ist
///    das „Stück für Stück", und beim Öffnen einer Seite ist es das Zucken.
/// 2. **Es merkt sich nichts.** Jedes Erscheinen lädt neu.
/// 3. **Die Einblendung lief nie.** `.animation(value: bild == nil)` hing an
///    einem Wert, der sich nach dem Anlegen nie wieder änderte — die Kurve
///    stand da, ist aber nie gefeuert. Deshalb sprangen die Bilder trotz
///    Kommentar weiterhin hart ins Bild.
///
/// Jetzt: `URLSession` holt, `CGImageSourceCreateThumbnailAtIndex` mit
/// `ShouldCacheImmediately` entschlüsselt in einer eigenen Aufgabe — dort,
/// wo es niemanden stört —, und erst das fertige Bild kommt zurück.

/// Ein `CGImage` über eine Laufgrenze tragen. `CGImage` ist unveränderlich,
/// nur nicht als `Sendable` erklärt.
private struct Bildkiste: @unchecked Sendable { let bild: CGImage }

@MainActor
final class Bildspeicher {
    static let geteilt = Bildspeicher()

    /// Bild und was es im Speicher kostet — Breite mal Hoehe mal vier Byte.
    private struct Eintrag {
        let bild: Image
        let byte: Int
        /// Wie lange das Holen und das Wandeln gedauert haben — nur fuer die
        /// Messung, sonst unbenutzt.
        var holen: Double = 0
        var wandeln: Double = 0
    }

    private var bekannt: [URL: Eintrag] = [:]
    private var reihenfolge: [URL] = []
    private var belegt = 0
    /// Läufe, die schon unterwegs sind. Ohne das holt ein Raster dasselbe
    /// Bild mehrfach, wenn es in zwei Reihen vorkommt.
    private var laufend: [URL: Task<Eintrag?, Never>] = [:]
    /// Einmal zerlegte Adressen. `schluessel(_:)` baut eine `URLComponents`
    /// auf, filtert und setzt wieder zusammen — billig fuer sich, aber es
    /// laeuft je Kachel und je Durchgang, auf dem Hauptlauf.
    private var schluesselspeicher: [URL: URL] = [:]

    // MARK: Die Schleuse

    /// **Wie viele Bilder gleichzeitig geholt werden duerfen.**
    ///
    /// Am 10.09.2026 am Geraet gemessen, 134 Bilder: das Wandeln kostet im
    /// Mittel 8 ms und macht **2 %** der Zeit aus. Alles andere ist Holen —
    /// und zur Spitze waren **25 Abrufe gleichzeitig unterwegs**.
    ///
    /// Das ist der Grund, aus dem eine Seite sich langsam anfuehlt, obwohl
    /// unterm Strich nichts fehlt: fuenfundzwanzig Abrufe teilen sich
    /// dieselbe Leitung, kommen deshalb alle **gleich spaet** an, und bis
    /// dahin steht die Seite leer. Gemessen kam eine Reihe von elf Bildern
    /// innerhalb von zwanzig Millisekunden an — nach jeweils einer Sekunde.
    ///
    /// Mit einer Schleuse aendert sich die Gesamtzeit kaum; es aendert sich,
    /// **wann das erste Bild dasteht**. Vier Abrufe teilen die Leitung durch
    /// vier statt durch fuenfundzwanzig, die ersten vier sind also rund
    /// sechsmal schneller da, und danach fuellt sich die Seite fortlaufend
    /// statt auf einen Schlag.
    ///
    /// Vier und nicht eins: eine einzelne Verbindung laesst die Leitung
    /// zwischen den Anfragen brachliegen. Vier und nicht zwoelf: dann waere
    /// der Unterschied wieder keiner.
    private static let gleichzeitig = 4
    private var imLauf = 0
    private var wartend: [CheckedContinuation<Void, Never>] = []

    /// Reihum und der Reihe nach — wer zuerst gefragt hat, kommt zuerst
    /// dran. Die Kacheln fragen von oben nach unten, also laedt auch von
    /// oben nach unten.
    private func einlass() async {
        if imLauf < Self.gleichzeitig {
            imLauf += 1
            return
        }
        await withCheckedContinuation { (fortsetzung: CheckedContinuation<Void, Never>) in
            wartend.append(fortsetzung)
        }
        // Der Platz wurde beim Freigeben auf uns umgebucht, `imLauf` bleibt.
    }

    private func einlassZurueck() {
        if wartend.isEmpty {
            imLauf -= 1
        } else {
            wartend.removeFirst().resume()
        }
    }

    /// **Eine Speichergrenze in Byte, keine Anzahl.**
    ///
    /// Hier standen „240 Bilder" und „1600 Punkt lange Kante", mit dem
    /// Kommentar, das seien Zahlen, die jede Plattform selbst setzen muesse.
    /// Am 10.09.2026 nachgesehen: **keine Plattform setzt sie.** Der Regler
    /// war da, niemand drehte daran, und ueberall galten die Mac-Werte —
    /// genau der Fall, vor dem der Kommentar warnte.
    ///
    /// Aufgefallen ist es erst, als der iPhone-Aufbau von `AsyncImage` auf
    /// diesen Speicher umgestellt wurde. Vorher lief kaum etwas hier durch,
    /// und die Zahl war folgenlos.
    ///
    /// **Eine Anzahl ist ohnehin die falsche Groesse.** 240 Plakate sind
    /// etwas voellig anderes als 240 Querbilder; wer in Bildern rechnet,
    /// rechnet nicht in dem, was knapp wird. Gemessen wird jetzt, was ein
    /// entschluesseltes Bild wirklich belegt — Breite mal Hoehe mal vier
    /// Byte —, und die Grenze ist ein Speicherbetrag. Das ist eine Frage,
    /// die sich je Plattform beantworten laesst, und die Anzahl ergibt sich.
    ///
    /// Die Betraege sind **hergeleitet, nicht gemessen**: sie liegen so weit
    /// unter dem, was die Plattform einer Vordergrund-App zugesteht, dass
    /// Bilder nie der Grund sein koennen, aus dem sie abgeraeumt wird. Was
    /// sie wirklich vertraegt, sagt nur ein Lauf mit dem Speicherwerkzeug am
    /// Geraet.
    static var speichergrenze: Int = {
        #if os(macOS)
        256 * 1024 * 1024   // Ein Fenster kann viele Raster gleichzeitig zeigen.
        #elseif os(tvOS)
        64 * 1024 * 1024    // Grosse Kacheln, knapper Speicher — die engste Lage.
        #else
        96 * 1024 * 1024    // iPhone und iPad.
        #endif
    }()

    /// Die laengste Kante beim Entschluesseln — groesser heisst schaerfer und
    /// teurer. Kein Hochrechnen: was der Server kleiner liefert, bleibt
    /// kleiner.
    static var kantenlaenge: Int = {
        #if os(macOS)
        1600
        #elseif os(tvOS)
        1200            // Die Kacheln sind gross, der Schirm steht weit weg.
        #else
        1200            // Traegt auch das Querbild oben auf einer iPad-Seite.
        #endif
    }()

    func bild(_ url: URL) -> Image? { bekannt[schluessel(url)]?.bild }

    /// **Der Zugang gehört nicht zum Bild.** Jede Bildadresse trägt
    /// `api_key` — nach einem Kontowechsel hiesse dasselbe Plakat plötzlich
    /// anders, und der ganze Speicher wäre auf einen Schlag kalt: jede Kachel
    /// neu geholt, und die alten Einträge bleiben liegen, bis sie hinten
    /// herausfallen. Bei 240 Plätzen für zwei Konten ist das die Hälfte.
    ///
    /// Ein Plakat ist aber für beide Konten dasselbe Bild — der Server gibt
    /// es unter derselben Kennung heraus, und `tag` (Jellyfins Fingerabdruck)
    /// bleibt im Schlüssel, eine geänderte Fassung fällt also weiterhin auf.
    /// Geholt wird mit dem vollen Weg, gemerkt ohne das Merkmal.
    ///
    /// Das ist G3 an einer Stelle, an der die Frage noch niemand gestellt
    /// hatte — mit dem Unterschied, dass hier nichts zu verwerfen ist: ein
    /// Bild trägt keinen Sehstand.
    private func schluessel(_ url: URL) -> URL {
        if let da = schluesselspeicher[url] { return da }
        let neu = gerechnet(url)
        // Mitwachsen darf er nicht: nach zwei Kontowechseln liegen dieselben
        // Bilder unter drei Adressen. Dieselbe Grenze wie die Bilder selbst,
        // nur in Eintraegen — ein Adresspaar kostet nichts Nennenswertes.
        if schluesselspeicher.count > 2_000 { schluesselspeicher.removeAll() }
        schluesselspeicher[url] = neu
        return neu
    }

    private func gerechnet(_ url: URL) -> URL {
        guard var teile = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let werte = teile.queryItems, werte.contains(where: { $0.name == "api_key" })
        else { return url }
        teile.queryItems = werte.filter { $0.name != "api_key" }
        return teile.url ?? url
    }

    func laden(_ url: URL) async -> Image? {
        let merkmal = schluessel(url)
        if let da = bekannt[merkmal] { return da.bild }
        if let lauf = laufend[merkmal] { return await lauf.value?.bild }

        // **Vor dem Abzweig gelesen.** `kantenlaenge` gehört dem Hauptlauf;
        // von der abgetrennten Aufgabe aus wäre der Zugriff ein Sprung über
        // die Isolationsgrenze, den Swift 6 zu Recht nicht durchlässt.
        let kante = Self.kantenlaenge
        let lauf = Task<Eintrag?, Never> { [self] in
            await einlass()
            let begonnen = Date()
            guard let (daten, _) = try? await URLSession.shared.data(from: url) else {
                einlassZurueck()
                return nil
            }
            let geholt = Date()
            // **Vor dem Wandeln zurueckgeben, nicht danach.** Die Schleuse
            // soll die Leitung ordnen, nicht den Rechner; das Wandeln laeuft
            // ohnehin abseits und kostet acht Millisekunden.
            einlassZurueck()
            let kiste = await Task.detached(priority: .userInitiated) { () -> Bildkiste? in
                guard let quelle = CGImageSourceCreateWithData(daten as CFData, nil) else { return nil }
                let regeln: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    // **Der entscheidende Schalter.** Ohne ihn schiebt
                    // CoreGraphics das Entschlüsseln bis zum ersten Zeichnen
                    // auf — und das ist wieder der Hauptlauf.
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: kante
                ]
                guard let roh = CGImageSourceCreateThumbnailAtIndex(
                    quelle, 0, regeln as CFDictionary) else { return nil }
                return Bildkiste(bild: roh)
            }.value
            guard let kiste else { return nil }
            // Vier Byte je Bildpunkt. Das entschluesselte Bild liegt so im
            // Speicher, unabhaengig davon, wie klein die Datei war — genau
            // deshalb sagt die Dateigroesse hier nichts.
            let byte = kiste.bild.width * kiste.bild.height * 4
            return Eintrag(bild: Image(decorative: kiste.bild, scale: 1), byte: byte,
                           holen: geholt.timeIntervalSince(begonnen),
                           wandeln: Date().timeIntervalSince(geholt))
        }

        laufend[merkmal] = lauf
        let ergebnis = await lauf.value
        laufend[merkmal] = nil
        #if DEBUG
        // **Vorlaeufig, zum Nachmessen einer gemeldeten Verschlechterung.**
        // `Protokoll.schreib` schreibt nur im Entwicklerbau; in der
        // ausgelieferten Fassung steht die Zeile da und tut nichts.
        if let ergebnis {
            Protokoll.schreib(String(format: "Bild %.0f ms holen, %.0f ms wandeln, %d KB · %@",
                                     (ergebnis.holen) * 1000, (ergebnis.wandeln) * 1000,
                                     ergebnis.byte / 1024,
                                     merkmal.lastPathComponent))
        }
        #endif
        if let ergebnis { merken(ergebnis, fuer: merkmal) }
        return ergebnis?.bild
    }

    private func merken(_ eintrag: Eintrag, fuer url: URL) {
        if let alt = bekannt[url] {
            belegt -= alt.byte
        } else {
            reihenfolge.append(url)
        }
        bekannt[url] = eintrag
        belegt += eintrag.byte

        // **Aeltestes zuerst, bis der Betrag wieder passt.** `removeFirst`
        // verschiebt das Feld, ist hier aber ein Verschieben von Zeigern
        // gegen ein entschluesseltes JPEG — bewusst so gelassen und nicht
        // gegen einen Ring getauscht, der mehr Bau als Nutzen waere.
        while belegt > Self.speichergrenze, !reihenfolge.isEmpty {
            let raus = reihenfolge.removeFirst()
            belegt -= bekannt.removeValue(forKey: raus)?.byte ?? 0
        }
    }
}

struct Netzbild: View {
    let url: URL?
    /// Wie das Bild seine Fläche füllt.
    var art: ContentMode = .fill
    /// Was stehen soll, wenn kein Bild kommt — als Systemzeichen.
    ///
    /// **Eine leere Fläche sieht aus wie ein Fehler in der App**, und genau so
    /// wurde sie gemeldet. Ein Zeichen sagt: hier gehört ein Bild hin, der
    /// Server hat keins. Steht seit je in der iPhone-Fassung; der Mac hatte
    /// es nie.
    var zeichen: String?

    @State private var bild: Image?
    @State private var sichtbar = false
    /// Kein Bild zu erwarten: keine Adresse, oder der Abruf kam ohne Bild
    /// zurück. Erst dann tritt das Zeichen ein — nicht schon währenddessen,
    /// sonst blitzte es vor jeder Kachel kurz auf.
    @State private var ohneBild = false

    /// **Was bekannt ist, steht sofort** — nicht erst im nächsten Durchgang.
    /// Ein nachgereichter Wert kommt zu spät, der leere Durchgang hat dann
    /// schon stattgefunden, und genau der ist das Aufblitzen.
    @MainActor init(url: URL?, art: ContentMode = .fill, zeichen: String? = nil) {
        self.url = url
        self.art = art
        self.zeichen = zeichen
        let sofort = url.flatMap { Bildspeicher.geteilt.bild($0) }
        _bild = State(initialValue: sofort)
        _sichtbar = State(initialValue: sofort != nil)
        _ohneBild = State(initialValue: url == nil)
    }

    var body: some View {
        ZStack {
            if let bild {
                bild.resizable().aspectRatio(contentMode: art)
                    .opacity(sichtbar ? 1 : 0)
            } else if ohneBild, let zeichen {
                Image(systemName: zeichen)
                    .font(.system(size: 22))
                    .foregroundStyle(Stil.schriftSehrLeise)
            }
        }
        .task(id: url) {
            guard let url else { ohneBild = true; return }
            guard bild == nil else { return }
            ohneBild = false
            guard let geladen = await Bildspeicher.geteilt.laden(url) else {
                ohneBild = true
                return
            }
            bild = geladen
            // 220 ms, dieselbe Zeit wie ein Sprung im Player — lang genug,
            // dass fünfzig Kacheln wie eine Bewegung wirken statt wie fünfzig.
            // **Feder statt Kurve, und bewusst ohne `Stil`.** Eine feste
            // Dauer ist nicht unterbrechbar; beim Scrollen durch ein Raster
            // ist das die am haeufigsten laufende Bewegung der ganzen App.
            // `Stil.einblenden` waere die richtige Adresse — nur liegt
            // `Stil.swift` allein im iOS-Ziel, `Netzbild` dagegen in allen
            // dreien. Ein Verweis dorthin braeche tvOS und macOS. Deshalb
            // hier dieselbe Federfamilie mit derselben Dauer.
            withAnimation(.smooth(duration: 0.22)) { sichtbar = true }
        }
    }
}
