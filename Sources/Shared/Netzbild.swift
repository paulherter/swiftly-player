import CoreGraphics
import ImageIO
import JellyfinKit
import OSLog
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
    #if DEBUG
    /// Nur zum Nachmessen; im ausgelieferten Bau gibt es die Zeile nicht.
    static let bildlog = Logger(subsystem: "de.paulherter.swiftly", category: "bild")
    #endif

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

    // MARK: Die zweite Schleuse — fuer das Wandeln
    //
    // **Die erste ordnet die Leitung, diese den Rechner.** Der Einlass wird
    // absichtlich **vor** dem Wandeln zurueckgegeben („die Schleuse soll die
    // Leitung ordnen, nicht den Rechner"), und damit war das Wandeln
    // **unbegrenzt**. Auf einem Treffer in der Ablage wird die erste Schleuse
    // gar nicht betreten — beim Scrollen ueber schon geholte Kacheln liefen
    // also beliebig viele Entschluesselungen gleichzeitig.
    //
    // Am 22.09.2026 in Pauls Protokoll gemessen, waehrend er selbst scrollte:
    //
    //     Bild 27 ms holen, 26 ms wandeln, 600 KB · Primary
    //     … dieselbe Zeile neunmal hintereinander
    //
    // Neun verschiedene Bilder — bei Jellyfin heisst jedes Plakat „Primary" —,
    // alle zur selben Zeit, alle mit **26 ms**. Dasselbe Bild allein braucht
    // gemessen 3 bis 12 ms. Die 26 sind also nicht die Arbeit, sondern das
    // Warten auf einen Kern: neun Aufgaben in `.userInitiated` neben einem
    // Hauptlauf, der bei 120 Hertz **8,33 ms** je Bild hat. Drei Bilder lang
    // belegt, neunmal in Folge — das ist, was Paul „extreme Frame-Drops beim
    // Scrollen" nennt. Und es erklaert, warum ihm die Animationen fluessig
    // vorkommen: dort wird nichts geladen.
    //
    // Zwei und nicht eins: ein einzelner Lauf laesst die uebrigen Kerne
    // brachliegen, und ein Plakat soll nicht auf sein Vorgaenger warten
    // muessen. Zwei und nicht acht: dann waere die Grenze wieder keine.
    private static let gleichzeitigWandeln = 2
    private var imWandeln = 0
    private var wartendAufWandeln: [CheckedContinuation<Void, Never>] = []
    /// Nur fuer die Messung: wie viele gleichzeitig gewandelt haben.
    private var spitzeWandeln = 0

    private func wandelEinlass() async {
        if imWandeln < Self.gleichzeitigWandeln {
            imWandeln += 1
            spitzeWandeln = max(spitzeWandeln, imWandeln)
            return
        }
        await withCheckedContinuation { (fortsetzung: CheckedContinuation<Void, Never>) in
            wartendAufWandeln.append(fortsetzung)
        }
        spitzeWandeln = max(spitzeWandeln, imWandeln)
    }

    private func wandelEinlassZurueck() {
        if wartendAufWandeln.isEmpty {
            imWandeln -= 1
        } else {
            wartendAufWandeln.removeFirst().resume()
        }
    }

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

    /// **Beide Schreibweisen.** Jellyfin 12 hat `api_key` abgeschafft und
    /// nimmt `ApiKey`; alte Server nehmen beides. Wer hier nur die neue
    /// pruefte, liesse in einem Speicher, der einen Kontowechsel ueberlebt,
    /// die alten Adressen mit Merkmal stehen — und dieselben Bilder laegen
    /// zweimal drin, einmal je Konto.
    /// **Die Rechnung liegt im Paket** (`Bildschluessel`) — sie stand hier
    /// und erreichte Linux und Windows damit nicht.
    private func gerechnet(_ url: URL) -> URL {
        URL(string: Bildschluessel.fuer(url)) ?? url
    }

    /// `vorrang` laesst die Schleuse aus.
    ///
    /// **Fuer das eine Bild, auf das jemand wirklich wartet.** Auf einer
    /// Detailseite ist das der Banner oben: er fuellt den halben Schirm, und
    /// solange er fehlt, sieht die Seite unfertig aus — gleichgueltig, wie
    /// viele Plakate darunter schon stehen. Er hinter zwanzig Kacheln
    /// anzustellen waere die Schleuse gegen ihren eigenen Zweck gedreht.
    ///
    /// Es ist genau **eines** je Seite. Waeren es mehr, waere es keine
    /// Vorfahrt mehr, sondern die Aufhebung der Schleuse.
    /// `aufGeraet`: das Bild auch auf dem Gerät ablegen und von dort zeigen
    /// — siehe `Geraeteablage`. Nur für Profilbilder.
    /// **`kante` sagt, wie gross entschluesselt wird.**
    ///
    /// Bis zum 22.09. galt fuer jedes Bild dieselbe Kantenlaenge: 1200. Fuer
    /// das Heldbild ist das richtig, fuer ein Plakat, das 112 Punkt breit
    /// dasteht, ist es das **Zwoelffache** an Speicher — 800 × 1200 × 4 Byte
    /// sind 3,8 MB je Kachel statt 0,3.
    ///
    /// Solange nur die sichtbaren Reihen ueberhaupt entstanden, ging das
    /// gerade noch auf. Seit die Startseite alle Reihen traegt, standen
    /// Dutzende solcher Kacheln zugleich im Speicher — im Protokoll ueber
    /// sechzig Bilder in einer Sekunde —, und das System hat die App
    /// abgeschossen (Signal 9).
    ///
    /// Wer die Groesse kennt, in der ein Bild dasteht, gibt sie mit. Wer sie
    /// nicht kennt, bekommt weiter 1200.
    func laden(_ url: URL, vorrang: Bool = false, aufGeraet: Bool = false,
               kante gewuenscht: Int? = nil) async -> Image? {
        let merkmal = schluessel(url)
        if let da = bekannt[merkmal] { return da.bild }
        if let lauf = laufend[merkmal] { return await lauf.value?.bild }

        // **Vor dem Abzweig gelesen.** `kantenlaenge` gehört dem Hauptlauf;
        // von der abgetrennten Aufgabe aus wäre der Zugriff ein Sprung über
        // die Isolationsgrenze, den Swift 6 zu Recht nicht durchlässt.
        let kante = min(gewuenscht ?? Self.kantenlaenge, Self.kantenlaenge)
        // Poster und Hintergründe auch auf der Platte — nur mit `tag`, siehe
        // `Bildablage`. Profilbilder haben ihre eigene Ablage.
        let platte = aufGeraet ? nil : Bildablage.name(merkmal)
        let lauf = Task<Eintrag?, Never> { [self] in
            let begonnen = Date()
            let daten: Data
            // Die Schleuse ordnet die Leitung; ein Treffer auf der Platte
            // braucht keine und wartet deshalb auch nicht in ihr.
            var eingelassen = false
            if let platte,
               let abgelegt = await Task.detached(priority: .userInitiated, operation: {
                   Bildablage.lesen(platte)
               }).value {
                daten = abgelegt
            } else if aufGeraet, let abgelegt = Geraeteablage.lesen(merkmal) {
                // Vom Gerät, sofort — und im Hintergrund frisch geholt, damit
                // ein neues Profilbild beim nächsten Mal da ist.
                daten = abgelegt
                Task.detached(priority: .utility) { await Geraeteablage.auffrischen(url, merkmal) }
            } else {
                if !vorrang { await einlass(); eingelassen = true }
                guard let (geholt, antwort) = try? await URLSession.shared.data(for: .mitEigenenKoepfen(url)) else {
                    if eingelassen { einlassZurueck() }
                    return nil
                }
                daten = geholt
                let ok = (antwort as? HTTPURLResponse)?.statusCode == 200
                if aufGeraet, ok {
                    Geraeteablage.schreiben(geholt, merkmal)
                }
                if let platte, ok {
                    Task.detached(priority: .utility) { Bildablage.schreiben(geholt, platte) }
                }
            }
            let geholt = Date()
            // **Vor dem Wandeln zurueckgeben, nicht danach.** Die Schleuse
            // soll die Leitung ordnen, nicht den Rechner; das Wandeln laeuft
            // ohnehin abseits und kostet acht Millisekunden.
            if eingelassen { einlassZurueck() }
            // **Und jetzt durch die zweite Schleuse.** Siehe dort: das
            // Wandeln war unbegrenzt, und neun gleichzeitige Laeufe haben den
            // Hauptlauf beim Scrollen um seinen Takt gebracht.
            await wandelEinlass()
            defer { wandelEinlassZurueck() }
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
            // **Ins vereinheitlichte Protokoll**, nicht nur in die Datei im
            // Container: die ist von aussen nicht lesbar, und eine Messung,
            // die niemand lesen kann, ist keine. `%@` traegt den Namen des
            // Bildes — das ist bei Jellyfin fuer **jedes** Plakat „Primary",
            // weshalb neun Zeilen gleich aussehen und doch neun Bilder sind.
            let zeile = String(format: "Bild %.0f ms holen, %.0f ms wandeln, %d KB · gleichzeitig bis %d · %@ · %@",
                               (ergebnis.holen) * 1000, (ergebnis.wandeln) * 1000,
                               ergebnis.byte / 1024, spitzeWandeln,
                               merkmal.lastPathComponent,
                               merkmal.deletingLastPathComponent()
                                   .deletingLastPathComponent().lastPathComponent)
            Protokoll.schreib(zeile)
            Self.bildlog.notice("\(zeile, privacy: .public)")
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
    /// Laesst die Schleuse aus — fuer das eine grosse Bild einer Seite.
    var vorrang = false
    /// **Wie gross das Bild dasteht** — damit nicht groesser entschluesselt
    /// wird als noetig.
    ///
    /// Ohne Angabe gilt `Bildspeicher.kantenlaenge`, auf dem Mac **1600**.
    /// Fuer ein Heldbild ist das richtig, fuer ein Plakat in 150 Punkt Breite
    /// ist es Speicher und Rechenzeit fuer nichts. Dieselbe Rechnung, die
    /// `Bild` auf dem iPhone seit dem 22.09. macht — `Netzbild` hatte sie
    /// nie, und damit hatte der Mac sie nirgends.
    ///
    /// Gemessen hat der Server die Plakate ohnehin schon klein geliefert (600
    /// KB entschluesselt, also rund 300 × 500); die Angabe greift dort also
    /// kaum. Sie greift bei den grossen: in Pauls Protokoll standen ein
    /// `Backdrop` mit 792 KB und ein `Primary` mit 1599 KB.
    var anzeigekante: CGFloat?

    @State private var bild: Image?
    @State private var sichtbar = false
    /// Kein Bild zu erwarten: keine Adresse, oder der Abruf kam ohne Bild
    /// zurück. Erst dann tritt das Zeichen ein — nicht schon währenddessen,
    /// sonst blitzte es vor jeder Kachel kurz auf.
    @State private var ohneBild = false

    /// **Was bekannt ist, steht sofort** — nicht erst im nächsten Durchgang.
    /// Ein nachgereichter Wert kommt zu spät, der leere Durchgang hat dann
    /// schon stattgefunden, und genau der ist das Aufblitzen.
    @MainActor init(url: URL?, art: ContentMode = .fill, zeichen: String? = nil,
                    vorrang: Bool = false, anzeigekante: CGFloat? = nil) {
        self.url = url
        self.art = art
        self.zeichen = zeichen
        self.vorrang = vorrang
        self.anzeigekante = anzeigekante
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
            // Der Bildschirm hat hoechstens drei Bildpunkte je Punkt; etwas
            // dazu, damit nichts ausfranst, und mehr braucht niemand.
            let noetig = anzeigekante.map { Int($0 * 3.2) }
            guard let geladen = await Bildspeicher.geteilt.laden(url, vorrang: vorrang,
                                                                kante: noetig) else {
                ohneBild = true
                return
            }
            bild = geladen
            // **`Stil.einblenden`, und zwar doch.** Hier stand
            // `.smooth(duration: 0.22)` mit dem Vermerk, ein Verweis auf
            // `Stil` braeche tvOS und macOS, weil `Stil.swift` allein im
            // iOS-Ziel liegt. Das trifft auf die *Datei* zu, nicht auf den
            // Token: `einblenden` steht in allen drei Fassungen von `Stil`,
            // nachgesehen am 21.09. Der Vermerk hat die Abweichung laenger
            // geschuetzt, als sie noetig war — und sie war sichtbar: auf einer
            // Detailseite blendete der Banner (0,22) schneller ein als das
            // Poster daneben (0,28).
            //
            // Mit dem Token nimmt jede Plattform ihre eigene Kurve, und
            // „Bewegung reduzieren" gilt hier endlich mit.
            withAnimation(Stil.einblenden) { sichtbar = true }
        }
    }
}

/// **Profilbilder auf dem Gerät.**
///
/// Seit es mehrere Server gibt, stehen im Profil Konten von Servern, mit
/// denen die App gerade nicht verbunden ist — und die sollen ihr Bild
/// behalten, auch nach einem Neustart und auch, wenn der andere Server gerade
/// nicht antwortet. Einmal geladen, liegt es hier und steht sofort da.
///
/// **Nur Profilbilder.** Poster und Hintergründe füllten das Gerät; die holt
/// `Bildspeicher` weiter nur in den Arbeitsspeicher. Abgelegt wird im
/// Cache-Ordner — räumt das System dort auf, kommt das Bild beim nächsten
/// Mal eben wieder vom Server.
enum Geraeteablage {
    private static var ordner: URL? {
        guard let basis = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let ordner = basis.appendingPathComponent("Profilbilder", isDirectory: true)
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        return ordner
    }

    /// Ein stabiler Dateiname aus der Adresse ohne Zugangsschlüssel (FNV-1a,
    /// 64 Bit). `hashValue` taugt nicht: der wechselt mit jedem Programmstart.
    private static func datei(_ merkmal: URL) -> URL? {
        ordner?.appendingPathComponent(dateiname(merkmal.absoluteString))
    }

    static func lesen(_ merkmal: URL) -> Data? {
        datei(merkmal).flatMap { try? Data(contentsOf: $0) }
    }

    static func schreiben(_ daten: Data, _ merkmal: URL) {
        guard let ziel = datei(merkmal) else { return }
        try? daten.write(to: ziel, options: .atomic)
    }

    /// Frisch vom Server, nur bei einer echten Antwort — eine Fehlerseite soll
    /// kein Profilbild überschreiben.
    static func auffrischen(_ url: URL, _ merkmal: URL) async {
        guard let (daten, antwort) = try? await URLSession.shared.data(for: .mitEigenenKoepfen(url)),
              (antwort as? HTTPURLResponse)?.statusCode == 200 else { return }
        schreiben(daten, merkmal)
    }
}

/// FNV-1a, 64 Bit, als Dateiname. Stabil über Programmstarts hinweg.
private func dateiname(_ text: String) -> String {
    var wert: UInt64 = 0xcbf29ce484222325
    for byte in text.utf8 {
        wert ^= UInt64(byte)
        wert &*= 0x100000001b3
    }
    return String(wert, radix: 16)
}

/// **Poster und Hintergründe auf der Platte** (Audit Teil 3, #11).
///
/// `Bildspeicher` hielt sie nur im Arbeitsspeicher; nach jedem Kaltstart kam
/// jede Kachel neu vom Server. Swiftfin legt bis 1 GB ab. Welche Adressen
/// auf die Platte dürfen und unter welchem Schlüssel — ohne Host, ohne
/// Zugang, nur mit `tag` —, steht in `Bildablageschluessel` im Paket.
///
/// Abgelegt wird im Cache-Ordner, den das System bei Platzmangel leert;
/// darüber hinaus räumt `aufraeumen` einmal je Start die ältesten Dateien
/// weg, bis die Grenze wieder passt.
enum Bildablage {
    /// Hergeleitet, nicht gemessen: ein Querbild in 1200 Punkt liegt als
    /// JPEG bei 100–300 KB, ein Plakat darunter.
    static let grenze: Int = {
        #if os(tvOS)
        256 * 1024 * 1024
        #else
        512 * 1024 * 1024
        #endif
    }()

    private static let ordner: URL? = {
        guard let basis = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let ordner = basis.appendingPathComponent("Bilder", isDirectory: true)
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        return ordner
    }()

    /// Der Dateiname zu einem Bildschlüssel, `nil` ohne `tag` — die Regel
    /// liegt im Paket (`Bildablageschluessel`).
    static func name(_ merkmal: URL) -> String? {
        Bildablageschluessel.fuer(merkmal).map(dateiname)
    }

    /// Liest und frischt das Datum auf, damit `aufraeumen` das zuletzt
    /// Gezeigte behält. Nicht auf dem Hauptlauf aufrufen.
    nonisolated static func lesen(_ name: String) -> Data? {
        guard let datei = ordner?.appendingPathComponent(name),
              let daten = try? Data(contentsOf: datei) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: datei.path)
        return daten
    }

    nonisolated static func schreiben(_ daten: Data, _ name: String) {
        guard let ziel = ordner?.appendingPathComponent(name) else { return }
        try? daten.write(to: ziel, options: .atomic)
        _ = aufgeraeumt
    }

    /// Einmal je Start, beim ersten Schreiben.
    private static let aufgeraeumt: Void = aufraeumen()

    private static func aufraeumen() {
        guard let ordner else { return }
        let felder: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let dateien = try? FileManager.default.contentsOfDirectory(
            at: ordner, includingPropertiesForKeys: felder) else { return }
        var liste = dateien.compactMap { datei -> (URL, Int, Date)? in
            guard let werte = try? datei.resourceValues(forKeys: Set(felder)) else { return nil }
            return (datei, werte.fileSize ?? 0, werte.contentModificationDate ?? .distantPast)
        }
        var summe = liste.reduce(0) { $0 + $1.1 }
        guard summe > grenze else { return }
        // Bis auf drei Viertel, damit nicht jeder Start wieder räumt.
        liste.sort { $0.2 < $1.2 }
        for (datei, groesse, _) in liste where summe > grenze * 3 / 4 {
            try? FileManager.default.removeItem(at: datei)
            summe -= groesse
        }
    }
}
