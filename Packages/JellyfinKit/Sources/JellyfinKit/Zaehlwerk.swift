import Foundation

/// **VLCs Zaehlwerk, gerechnet — ohne VLC.**
///
/// Die Zahlen im Technikschild entstehen nicht aus einem Messwert, sondern
/// aus der Differenz zweier Messungen und der Zeit dazwischen. Genau diese
/// Rechnung stand bisher in `Sources/Shared/Spielwerte.swift` und damit nur
/// auf den Apple-Fassungen; Linux und Windows haetten sie ein zweites Mal
/// gebraucht. Eine kopierte Funktion ist ein Fehler (CLAUDE.md), und die
/// Faustregel aus `ABLAUF.md` gilt hier woertlich: **wenn zwei Plattformen
/// dieselbe Frage stellen, ist die Antwort Paketcode.**
///
/// Was hier liegt, ist die Rechnung. Wo die Rohwerte herkommen — `VLCMedia`
/// auf Apple, `libvlc_media_get_stats` auf Linux — bleibt Sache der
/// Plattform; beide Wege liefern dieselben Felder.
public struct Zaehlwerk: Sendable, Equatable {

    /// Die Rohwerte einer Messung, so wie VLC sie fuehrt: Summen seit dem
    /// Beginn der Wiedergabe, nicht pro Sekunde.
    public struct Rohwerte: Sendable, Equatable {
        public var gelesen: UInt64
        public var entpackt: UInt64
        public var gezeigt: UInt64
        public var verworfen: UInt64
        public var zuSpaet: UInt64
        public var videoBloecke: UInt64
        public var tonBloecke: UInt64
        public var tonGespielt: UInt64
        public var tonVerloren: UInt64
        public var beschaedigt: UInt64
        public var spruenge: UInt64

        public init(gelesen: UInt64 = 0, entpackt: UInt64 = 0, gezeigt: UInt64 = 0,
                    verworfen: UInt64 = 0, zuSpaet: UInt64 = 0, videoBloecke: UInt64 = 0,
                    tonBloecke: UInt64 = 0, tonGespielt: UInt64 = 0, tonVerloren: UInt64 = 0,
                    beschaedigt: UInt64 = 0, spruenge: UInt64 = 0) {
            self.gelesen = gelesen; self.entpackt = entpackt; self.gezeigt = gezeigt
            self.verworfen = verworfen; self.zuSpaet = zuSpaet
            self.videoBloecke = videoBloecke; self.tonBloecke = tonBloecke
            self.tonGespielt = tonGespielt; self.tonVerloren = tonVerloren
            self.beschaedigt = beschaedigt; self.spruenge = spruenge
        }
    }

    // MARK: Durchgereicht

    public let roh: Rohwerte
    /// Wann diese Messung entstanden ist — die naechste rechnet daraus die
    /// Dauer. **Gemessen, nicht angenommen:** ein Warten haelt *mindestens*
    /// die gewuenschte Zeit ein, nicht genau sie. Mit einer angenommenen
    /// Dauer stand am 08.09.2026 „Zeigt 30,0 fps" bei einer Datei mit
    /// 23,976 — der Abstand war in Wahrheit zweieinhalb Sekunden.
    public let gemessenAm: Date
    /// Die Stelle im Film, in Sekunden.
    public let stelle: Double

    // MARK: Gerechnet

    /// Bit je Sekunde am Eingang, oder `nil` beim ersten Mal — dann gibt es
    /// kein Vorher, und eine Null waere eine Aussage, die wir nicht haben.
    public let eingang: Double?
    public let demuxer: Double?
    /// Gezeigte Bilder je Sekunde ueber das lange Fenster.
    public let zeigtProSekunde: Double?
    /// Dekodierte Bilder je Sekunde — trennt Dekoder und Ausgabe.
    public let dekodiertProSekunde: Double?
    /// Wie weit die Stelle gegenueber der echten Uhr vorankommt. 1 ist
    /// Echtzeit; darunter ist verlorene Zeit, und genau die sieht man als
    /// Stocken.
    public let laufAnteil: Double?
    /// Wie viel gelesen, aber noch nicht entpackt ist — der Vorrat in Bytes.
    public var vorratBytes: UInt64 { roh.gelesen >= roh.entpackt ? roh.gelesen - roh.entpackt : 0 }

    // MARK: Fenster

    let basisGezeigt: UInt64
    let basisDekodiert: UInt64
    let basisStelle: Double
    let basisZeit: Date

    /// **Zwanzig Sekunden.**
    ///
    /// Ein kurzes Fenster rauscht: VLC fuehrt `gezeigt` nicht Bild fuer Bild,
    /// sondern schreibt es in Schueben fort. Ein Zwei-Sekunden-Fenster faengt
    /// mal zwei Schuebe und mal keinen — die Zahl war damit kein Messwert,
    /// sondern ein Zufallsgenerator mit einer Nachkommastelle. Zwanzig
    /// Sekunden sind rund fuenfhundert Bilder; ein Schub mehr oder weniger
    /// faellt darin nicht auf.
    public static let fenster: TimeInterval = 20
    /// Vorher wird nichts gemeldet — siehe `fenster`.
    public static let mindestens: TimeInterval = 4

    /// **Hat VLC die Struktur gar nicht gefuellt, kommt Speicherschrott.**
    /// Eine Milliarde Bilder waeren bei 60 Hz ueber ein halbes Jahr am
    /// Stueck; was darueber liegt, ist keine Messung.
    static let grenze: UInt64 = 1_000_000_000

    public init?(_ roh: Rohwerte, stelle: Double, laeuft: Bool,
                 vorher: Zaehlwerk? = nil, jetzt: Date = Date()) {
        guard roh.gezeigt < Self.grenze, roh.verworfen < Self.grenze,
              roh.zuSpaet < Self.grenze, roh.videoBloecke < Self.grenze,
              roh.tonBloecke < Self.grenze, roh.tonVerloren < Self.grenze,
              roh.beschaedigt < Self.grenze, roh.spruenge < Self.grenze,
              roh.tonGespielt < Self.grenze
        else { return nil }

        self.roh = roh
        self.stelle = stelle
        self.gemessenAm = jetzt
        let sekunden = vorher.map { jetzt.timeIntervalSince($0.gemessenAm) } ?? 0

        // **Ein Sprung macht das Fenster ungueltig**, und der Anlauf gehoert
        // nicht dazu. Die Zaehler laufen beim Springen weiter, die Stelle
        // aber springt; und solange nicht gespielt wird, floesse die Wartezeit
        // als Stillstand in `laufAnteil` ein.
        let laeuftFort = laeuft && (vorher.map {
            stelle >= $0.stelle && stelle - $0.stelle <= sekunden * 2 + 1
        } ?? false)

        if let v = vorher, laeuftFort, roh.gezeigt >= v.basisGezeigt,
           jetzt.timeIntervalSince(v.basisZeit) < Self.fenster {
            basisGezeigt = v.basisGezeigt; basisDekodiert = v.basisDekodiert
            basisStelle = v.basisStelle;   basisZeit = v.basisZeit
        } else if let v = vorher, laeuftFort, roh.gezeigt >= v.roh.gezeigt {
            basisGezeigt = v.roh.gezeigt;  basisDekodiert = v.roh.videoBloecke
            basisStelle = v.stelle;        basisZeit = v.gemessenAm
        } else {
            basisGezeigt = roh.gezeigt;    basisDekodiert = roh.videoBloecke
            basisStelle = stelle;          basisZeit = jetzt
        }

        let spanne = jetzt.timeIntervalSince(basisZeit)
        let reif = spanne >= Self.mindestens
        zeigtProSekunde = reif && roh.gezeigt >= basisGezeigt
            ? Double(roh.gezeigt - basisGezeigt) / spanne : nil
        dekodiertProSekunde = reif && roh.videoBloecke >= basisDekodiert
            ? Double(roh.videoBloecke - basisDekodiert) / spanne : nil
        laufAnteil = reif && stelle >= basisStelle
            ? (stelle - basisStelle) / spanne : nil

        eingang = Self.rate(roh.gelesen, vorher?.roh.gelesen, sekunden)
        demuxer = Self.rate(roh.entpackt, vorher?.roh.entpackt, sekunden)
    }

    /// **Die Rate wird selbst gerechnet, nicht abgelesen.** VLCs eigene
    /// Fliesskommafelder standen auf dem Apple TV bei laufendem Film beide
    /// auf **0**, am Geraet nachgesehen. Was verlaesslich steigt, sind die
    /// Summen.
    static func rate(_ jetzt: UInt64, _ vorher: UInt64?, _ sekunden: Double) -> Double? {
        guard let vorher, sekunden > 0, jetzt >= vorher else { return nil }
        let bit = Double(jetzt - vorher) * 8 / sekunden
        return bit > 0 ? bit : nil
    }

    /// Der Vorrat in Sekunden, wenn der Bedarf der Datei bekannt ist.
    /// **Gelesen minus entpackt** ist der Fuellstand — genau die Zahl, die
    /// andere Clients als „Buffer" zeigen.
    public func vorratSekunden(bytesJeSekunde: Double) -> Double? {
        guard bytesJeSekunde > 0 else { return nil }
        return Double(vorratBytes) / bytesJeSekunde
    }
}
