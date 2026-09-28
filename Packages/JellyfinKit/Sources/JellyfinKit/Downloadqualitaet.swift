import Foundation

/// **In welcher Qualität ein Titel aufs Gerät kommt.**
///
/// Die Vorgabe bleibt das Original — dieselbe Datei, die auch gestreamt würde
/// (H2). Wer aber für eine Zugfahrt eine ganze Staffel mitnehmen will, hat
/// mit 35 GB ein Problem, das eine kleinere Fassung löst. Die kann nur der
/// Server herstellen, und nur, wenn der Betreiber diesem Konto das Umwandeln
/// erlaubt; deshalb steht die Wahl nur dann zur Verfügung
/// (``waehlbar(videoUmwandeln:tonUmwandeln:)``).
///
/// **Drei Stufen, benannt nach dem, was man sieht.** „720p" beantwortet die
/// Frage, die sich jemand vor dem Laden stellt; die Bitrate steht als Zweites
/// daneben, weil sie die Größe erklärt. Die Zahlen sind die, die Jellyfins
/// eigene Oberfläche und die anderen Clients für dieselben Stufen nehmen.
///
/// **Umgewandelt wird nach H.264 und AAC in Matroska.** Das spielt jedes Gerät,
/// auf dem Swiftly läuft, und kein Server braucht dafür eine besondere
/// Bibliothek. Untertitel stecken in einer umgewandelten Datei nicht mehr —
/// sie reisen als eigene Dateien daneben mit
/// (``Untertiteldatei/mitladen(stroeme:itemID:quelle:server:schluessel:umgewandelt:)``).
public enum Downloadqualitaet: String, Codable, Sendable, CaseIterable, Identifiable {
    case original
    case hd1080
    case hd720
    case sd480

    public var id: String { rawValue }

    /// Die Stufen, die umwandeln — alles außer dem Original.
    public static let stufen: [Downloadqualitaet] = [.hd1080, .hd720, .sd480]

    /// Der Container einer umgewandelten Datei. Steht im Dateinamen, und an
    /// der Endung erkennt VLC den Demuxer.
    public static let container = "mkv"

    public var istOriginal: Bool { self == .original }

    /// Bildhöhe der Stufe — `nil` beim Original.
    public var hoehe: Int? {
        switch self {
        case .original: nil
        case .hd1080: 1080
        case .hd720: 720
        case .sd480: 480
        }
    }

    /// Breite zur Höhe bei 16:9. Der Server hält das Seitenverhältnis selbst;
    /// die Breite begrenzt nur Breitbildfilme, deren Höhe ohnehin darunter liegt.
    public var breite: Int? {
        switch self {
        case .original: nil
        case .hd1080: 1920
        case .hd720: 1280
        case .sd480: 854
        }
    }

    /// Bit je Sekunde für das Bild.
    public var bildBitrate: Int? {
        switch self {
        case .original: nil
        case .hd1080: 8_000_000
        case .hd720: 4_000_000
        case .sd480: 1_500_000
        }
    }

    /// Bit je Sekunde für den Ton. 5.1 bleibt bei 1080p und 720p erhalten;
    /// bei 480p wird Stereo daraus — wer so klein lädt, hört über Kopfhörer.
    public var tonBitrate: Int? {
        switch self {
        case .original: nil
        case .hd1080: 384_000
        case .hd720: 256_000
        case .sd480: 128_000
        }
    }

    public var tonkanaele: Int? {
        switch self {
        case .original: nil
        case .hd1080, .hd720: 6
        case .sd480: 2
        }
    }

    /// Bild und Ton zusammen, bit/s — daraus die geschätzte Größe.
    public var gesamtBitrate: Int? {
        guard let b = bildBitrate, let t = tonBitrate else { return nil }
        return b + t
    }

    // MARK: Was angeboten wird

    /// **Ob überhaupt gewählt werden darf.** Umwandeln heißt Bild *und* Ton
    /// neu rechnen; fehlt eins der beiden Rechte, lehnt der Server ab. Wie
    /// beim ``Downloadrecht`` sperrt nur ein ausdrückliches `false` — ein
    /// schweigender Server nimmt niemandem etwas.
    public static func waehlbar(videoUmwandeln: Bool?, tonUmwandeln: Bool?) -> Bool {
        (videoUmwandeln ?? true) && (tonUmwandeln ?? true)
    }

    /// Die Stufen für eine Auswahl, Original zuerst.
    ///
    /// **Eine Stufe, die nicht kleiner macht, fällt weg.** Eine Serie in
    /// 720p mit 2 Mbit/s „in 1080p mit 8 Mbit/s" zu laden hieße, die Datei
    /// umzuwandeln und größer zu machen. Die Quellbitrate kommt aus Größe
    /// und Laufzeit; ist sie unbekannt, bleiben alle Stufen stehen.
    public static func angeboten(waehlbar: Bool, quellBitrate: Int?) -> [Downloadqualitaet] {
        guard waehlbar else { return [.original] }
        let passend = stufen.filter { stufe in
            guard let q = quellBitrate, q > 0, let g = stufe.gesamtBitrate else { return true }
            return g < q
        }
        return [.original] + passend
    }

    /// Bit je Sekunde einer Datei aus Größe und Laufzeit — `nil`, wenn eins
    /// davon fehlt.
    public static func bitrate(bytes: Int64, laufzeitTicks: Int64?) -> Int? {
        guard bytes > 0, let t = laufzeitTicks, t > 0 else { return nil }
        let sekunden = Double(t) / 10_000_000
        return Int(gekappt: Double(bytes) * 8 / sekunden)
    }

    /// **Die höchste Quellbitrate einer Auswahl** — die Stufen richten sich
    /// nach der besten Datei darin. Sonst verschwände 1080p, sobald eine
    /// einzelne Folge in 720p vorliegt.
    public static func quellBitrate(_ dateien: [(bytes: Int64, laufzeitTicks: Int64?)]) -> Int? {
        dateien.compactMap { bitrate(bytes: $0.bytes, laufzeitTicks: $0.laufzeitTicks) }.max()
    }

    // MARK: Größe

    /// **Was die Datei ungefähr wiegen wird.**
    ///
    /// Der Server kennt die Größe einer umgewandelten Datei erst, wenn sie
    /// fertig ist, und schickt deshalb keine Länge mit. Also rechnen wir:
    /// Bitrate mal Laufzeit, drei Prozent für den Container. Beim Original
    /// steht die echte Größe da.
    ///
    /// **Nie größer als das Original.** Liegt die Quelle unter der Stufe,
    /// liefert der Server höchstens ihre Bitrate — eine Schätzung darüber
    /// hieße, die kleinere Wahl sähe teurer aus.
    public func geschaetzteBytes(original: Int64, laufzeitTicks: Int64?) -> Int64 {
        guard let bitrate = gesamtBitrate else { return original }
        guard let t = laufzeitTicks, t > 0 else { return 0 }
        let sekunden = Double(t) / 10_000_000
        let schaetzung = Int64(sekunden * Double(bitrate) / 8 * 1.03)
        return original > 0 ? min(schaetzung, original) : schaetzung
    }

    /// **Was eine Seriengruppe in der Downloadliste nennt:** die Stufe, wenn
    /// alle Folgen dieselbe kleinere tragen — sonst nichts. Eine Gruppe aus
    /// Original und 720p hätte keine Angabe, die für alle stimmt.
    public static func gemeinsam(_ posten: [Downloadposten]) -> Downloadqualitaet? {
        guard let erste = posten.first?.guete, !erste.istOriginal,
              posten.allSatisfy({ $0.guete == erste }) else { return nil }
        return erste
    }

    // MARK: Worte

    /// „Original", „1080p", „720p", „480p".
    public var name: String {
        switch self {
        case .original: uebersetzt("Original")
        case .hd1080: "1080p"
        case .hd720: "720p"
        case .sd480: "480p"
        }
    }

    /// Die zweite Angabe: „Direct Play" oder die Bitrate, „1,5 Mbit/s".
    public func zusatz(locale: Locale = .current) -> String {
        guard let b = bildBitrate else { return uebersetzt("Direct Play") }
        let mbit = (Double(b) / 1_000_000).formatted(
            .number.precision(.fractionLength(0...1)).locale(locale))
        return mbit + " Mbit/s"
    }

    /// Was auf der Plakette steht: „Direct Play · Originalqualität" oder
    /// „720p · 4 Mbit/s".
    public func plakette(locale: Locale = .current) -> String {
        istOriginal ? uebersetzt("Direct Play · Originalqualität")
                    : name + " · " + zusatz(locale: locale)
    }
}
