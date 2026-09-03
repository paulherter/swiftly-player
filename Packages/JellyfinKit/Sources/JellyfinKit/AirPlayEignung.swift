import Foundation

/// Ob eine Datei per **echtem AirPlay** auf einen Fernseher kann — und wenn
/// nicht, woran es liegt.
///
/// **Das Hindernis ist nicht unser Abspieler, sondern das Gerät am anderen
/// Ende.** AirPlay für Video schickt den Strom in seinem Format weiter; was
/// dort ankommt, muss der Empfänger selbst dekodieren. Ein Apple TV nimmt
/// dabei weder DTS noch TrueHD an — in keiner App, auch nicht in Apples
/// eigenen. Nachgeschlagen in Apples Vorgaben für HLS: Video H.264 und HEVC,
/// Ton AAC, AC-3, E-AC-3, ALAC und FLAC.
///
/// Deshalb steht diese Prüfung **vor** dem Knopf, nicht dahinter. Wer sie
/// überspringt, bietet AirPlay an und liefert dann Bild ohne Ton.
///
/// **Sie schaut auf alle Tonspuren, nicht nur auf die erste.** Rips tragen
/// häufig DTS *und* eine AC-3-Spur; dann geht AirPlay sehr wohl, man muss dem
/// Server nur sagen, welche Spur er nehmen soll. Genau dafür ist `tonspur`
/// da — ohne sie wäre die halbe Sammlung fälschlich abgelehnt.
///
/// Gehört ins Paket und nicht in die Ansichten, weil vier Plattformen
/// denselben Knopf zeigen und dieselbe Meldung schulden. Wie `Folgenende`
/// und `Zeitannahme`.
public struct AirPlayEignung: Sendable, Equatable {

    /// Index der Tonspur, die per AirPlay durchkommt — `nil`, wenn keine.
    ///
    /// Es ist der `Index` aus der Serverantwort, nicht die Position in der
    /// Liste: Jellyfin zählt Video, Ton und Untertitel in einer Reihe, und
    /// `AudioStreamIndex` erwartet genau diese Zahl.
    public let tonspur: Int?

    public let hindernisse: [Hindernis]

    public var geeignet: Bool { hindernisse.isEmpty }

    public init(tonspur: Int?, hindernisse: [Hindernis]) {
        self.tonspur = tonspur
        self.hindernisse = hindernisse
    }

    /// Was AirPlay im Weg steht.
    public struct Hindernis: Sendable, Equatable {
        public enum Art: String, Sendable {
            case video
            case ton
            /// Der Server müsste umpacken, kann oder will aber nicht.
            case umpacken
        }

        public let art: Art
        public let codec: String

        public init(art: Art, codec: String) {
            self.art = art
            self.codec = codec
        }

        public var text: String {
            switch art {
            case .video:
                uebersetzt("Das Bild liegt als \(codec.uppercased()) vor. AirPlay überträgt nur H.264 und HEVC.")
            case .ton:
                uebersetzt("Der Ton liegt als \(codec.uppercased()) vor. Apple-Geräte nehmen das über AirPlay nicht an.")
            case .umpacken:
                uebersetzt("Die Datei liegt als \(codec.uppercased()) vor. Für AirPlay müsste der Server sie umpacken — er bietet das nicht an. In den Servereinstellungen unter „Wiedergabe“ muss Transkodierung erlaubt sein.")
            }
        }
    }

    /// Ein Satz für die Meldung in der App.
    ///
    /// **Der zweite Satz ist der wichtigere.** Eine Fehlermeldung, die nur
    /// „geht nicht" sagt, lässt den Zuschauer im Regen stehen — obwohl es
    /// einen Weg gibt, der bei *jedem* Format funktioniert, weil dabei auf
    /// dem Telefon dekodiert wird.
    public var meldung: String? {
        guard !geeignet else { return nil }
        let gruende = hindernisse.map(\.text).joined(separator: " ")
        return gruende + " "
            + uebersetzt("Über Bildschirmsynchronisierung im Kontrollzentrum läuft der Film trotzdem auf dem Fernseher.")
    }

    // MARK: - Was durchkommt

    /// Videocodecs, die AirPlay überträgt.
    ///
    /// Die Vier-Zeichen-Kennungen stehen mit drin, weil Jellyfin je nach
    /// Container mal `hevc` und mal `hvc1` meldet. Dolby Vision (`dvh1`,
    /// `dvhe`) ist HEVC mit Zusatzschicht und geht auf einem Apple TV 4K.
    public static let videoCodecs: Set<String> = [
        "h264", "avc1", "avc",
        "hevc", "h265", "hvc1", "hev1",
        "dvh1", "dvhe",
    ]

    /// Toncodecs, die AirPlay überträgt.
    ///
    /// **Nicht dabei und auch nicht nachtragbar:** DTS in allen Spielarten,
    /// TrueHD, MLP. Der Empfänger lehnt sie ab. PCM, Opus und Vorbis fehlen
    /// ebenfalls in Apples Vorgaben.
    public static let tonCodecs: Set<String> = [
        "aac", "aac_latm", "he-aac",
        "ac3", "eac3", "ec-3",
        "alac", "flac", "mp3",
    ]

    // MARK: - Prüfen

    public static func pruefen(quelle: MediaSource) -> AirPlayEignung {
        let stroeme = quelle.mediaStreams ?? []
        var hindernisse: [Hindernis] = []

        // Video. Gibt es keine Videospur, ist es eine Tondatei — dann steht
        // dem Ton nichts im Weg und AirPlay ist ohnehin nicht die Frage.
        if let video = stroeme.first(where: { $0.type == "Video" }) {
            let codec = video.codec?.lowercased() ?? ""
            if !videoCodecs.contains(codec) {
                hindernisse.append(Hindernis(art: .video, codec: codec.isEmpty ? "?" : codec))
            }
        }

        // Ton. Von allen tauglichen Spuren die beste, nicht die erste.
        let tonstroeme = stroeme.filter { $0.type == "Audio" }
        let tauglich = tonstroeme.filter { tonCodecs.contains($0.codec?.lowercased() ?? "") }
        let gewaehlt = besteTonspur(tauglich)

        if gewaehlt == nil, !tonstroeme.isEmpty {
            // Für die Meldung zählt, was der Zuschauer sonst gehört hätte:
            // die Standardspur, sonst die erste.
            let genannt = tonstroeme.first { $0.isDefault == true } ?? tonstroeme[0]
            hindernisse.append(Hindernis(art: .ton,
                                         codec: genannt.codec?.lowercased() ?? "?"))
        }

        return AirPlayEignung(tonspur: hindernisse.isEmpty ? gewaehlt?.index : nil,
                              hindernisse: hindernisse)
    }

    /// Die Standardspur, wenn sie taugt — sonst die mit den meisten Kanälen.
    ///
    /// Die Standardspur zuerst, weil der Zuschauer sie gewohnt ist; erst wenn
    /// sie ausfällt, ist mehr Ton besser als weniger. Bei Gleichstand bleibt
    /// die Reihenfolge des Servers.
    private static func besteTonspur(_ spuren: [MediaStream]) -> MediaStream? {
        if let standard = spuren.first(where: { $0.isDefault == true }) { return standard }
        // Nicht `max(by:)`: das liefert bei Gleichstand die *letzte* Spur und
        // würde die Reihenfolge des Servers umdrehen.
        var beste: MediaStream?
        for spur in spuren where (spur.channels ?? 0) > (beste?.channels ?? -1) {
            beste = spur
        }
        return beste
    }
}

/// Was AirPlay für einen Titel hergibt.
public enum AirPlayAuskunft: Sendable {
    /// Geht — mit diesem Plan, den `AVPlayer` öffnen kann.
    case geht(PlaybackPlan)
    /// Geht nicht, und hier steht warum.
    case gehtNicht(AirPlayEignung)
}
