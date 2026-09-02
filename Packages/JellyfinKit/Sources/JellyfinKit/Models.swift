import Foundation

// MARK: - Server

public struct PublicSystemInfo: Codable, Sendable, Equatable {
    public let serverName: String?
    public let version: String?
    public let id: String?

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case version = "Version"
        case id = "Id"
    }
}

// MARK: - Auth

public struct AuthenticationResult: Codable, Sendable {
    public let accessToken: String
    public let serverId: String?
    public let user: User

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case serverId = "ServerId"
        case user = "User"
    }
}

public struct User: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

// MARK: - Items

public struct ItemsResponse: Codable, Sendable {
    public let items: [Item]
    public let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }

    public init(items: [Item], totalRecordCount: Int) {
        self.items = items
        self.totalRecordCount = totalRecordCount
    }

    /// Liest nachsichtig ein.
    ///
    /// Zwei Härten, die vorher eine ganze Antwort kippen konnten:
    /// ein einzelner Eintrag ohne `Name` liess die **gesamte** Liste
    /// scheitern — der Bildschirm blieb leer, ohne dass etwas gesagt wurde —,
    /// und `TotalRecordCount` fehlt bei einigen Endpunkten ganz.
    public init(from decoder: any Decoder) throws {
        let behaelter = try decoder.container(keyedBy: CodingKeys.self)
        items = try behaelter.decodeIfPresent(Nachsichtig<Item>.self, forKey: .items)?
            .werte ?? []
        totalRecordCount = try behaelter.decodeIfPresent(Int.self, forKey: .totalRecordCount)
            ?? items.count
    }
}

/// Liest ein Feld ein und überspringt, was sich nicht lesen lässt.
///
/// Ein Server, der einen kaputten Eintrag liefert, soll eine Liste nicht
/// unbrauchbar machen. Der Rest kommt durch.
struct Nachsichtig<Wert: Decodable>: Decodable {
    let werte: [Wert]

    init(from decoder: any Decoder) throws {
        var behaelter = try decoder.unkeyedContainer()
        var gesammelt: [Wert] = []
        while !behaelter.isAtEnd {
            if let wert = try? behaelter.decode(Wert.self) {
                gesammelt.append(wert)
            } else {
                // Verbrauchen, sonst steht der Zeiger fest und die Schleife
                // läuft ewig.
                _ = try? behaelter.decode(Uebersprungen.self)
            }
        }
        werte = gesammelt
    }

    private struct Uebersprungen: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

public struct Item: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let type: String?
    public let collectionType: String?
    public let productionYear: Int?
    public let overview: String?
    public let runTimeTicks: Int64?
    /// Serienkontext — für die Zeile unter dem Titel im Player.
    public let seriesName: String?
    public let indexNumber: Int?          // Folge
    public let parentIndexNumber: Int?    // Staffel
    public let seriesId: String?
    /// Staffel, zu der eine Folge gehört — damit die Serienseite gleich die
    /// richtige Staffel aufschlägt.
    public let seasonId: String?
    public let genres: [String]?
    public let officialRating: String?
    public let communityRating: Double?
    public let childCount: Int?
    /// Trailer, die als Datei auf dem Server liegen.
    public let localTrailerCount: Int?
    public let backdropImageTags: [String]?
    /// Poster der Serie — Folgen tragen als eigenes Bild nur ein
    /// Vorschaubild im 16:9-Format, das in einer Hochkantkachel nichts taugt.
    public let seriesPrimaryImageTag: String?
    public let people: [Person]?
    public let studios: [NameID]?
    public let taglines: [String]?
    public let criticRating: Double?
    public let remoteTrailers: [MediaURL]?
    public let imageTags: [String: String]?
    public let userData: UserItemData?
    public let mediaSources: [MediaSource]?
    /// Der Hintergrund der **Serie**, mitgeliefert an jeder Folge.
    ///
    /// Eine Folge hat nie einen eigenen — `BackdropImageTags` ist bei ihr
    /// immer leer, am Server nachgemessen. Wer den Hintergrund einer Folge
    /// will, muss hierher sehen. Wurde bisher gar nicht gelesen.
    public let parentBackdropImageTags: [String]?
    /// Zu welchem Titel der obige Hintergrund gehört.
    public let parentBackdropItemId: String?
    /// Das quer liegende Vorschaubild eines Titels, falls eines hinterlegt
    /// ist. Bei Serien häufig gepflegt, bei Folgen selten.
    public let parentThumbImageTag: String?
    public let parentThumbItemId: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case collectionType = "CollectionType"
        case productionYear = "ProductionYear"
        case overview = "Overview"
        case runTimeTicks = "RunTimeTicks"
        case seriesName = "SeriesName"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case seriesId = "SeriesId"
        case seasonId = "SeasonId"
        case genres = "Genres"
        case officialRating = "OfficialRating"
        case communityRating = "CommunityRating"
        case childCount = "ChildCount"
        case localTrailerCount = "LocalTrailerCount"
        case backdropImageTags = "BackdropImageTags"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case people = "People"
        case studios = "Studios"
        case taglines = "Taglines"
        case criticRating = "CriticRating"
        case remoteTrailers = "RemoteTrailers"
        case imageTags = "ImageTags"
        case userData = "UserData"
        case mediaSources = "MediaSources"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case parentBackdropItemId = "ParentBackdropItemId"
        case parentThumbImageTag = "ParentThumbImageTag"
        case parentThumbItemId = "ParentThumbItemId"
    }

    /// Namen der Regie, für die Zeile unter der Beschreibung.
    public var regie: [String] {
        (people ?? []).filter { $0.type == "Director" }.map(\.name)
    }

    /// Darsteller in Reihenfolge, ohne Stab.
    public var darsteller: [Person] {
        (people ?? []).filter(\.istDarsteller)
    }

    /// Serie, Staffel oder Sammlung — hat keine eigene Mediendatei.
    public var istBehaelter: Bool {
        ["Series", "Season", "BoxSet", "Folder", "CollectionFolder"].contains(type ?? "")
    }

    /// „S1 • E3" — kurz, für Knopfbeschriftungen.
    public var folgenkuerzel: String? {
        guard let staffel = parentIndexNumber, let folge = indexNumber else { return nil }
        return "S\(staffel) • E\(folge)"
    }

    /// Zweitzeile für „Zuletzt hinzugefügt": *was* dazugekommen ist.
    ///
    /// Jellyfin fasst neue Folgen zusammen — kam eine ganze Staffel dazu,
    /// liefert der Server eine Staffel, bei einzelnen Folgen die Folge. Die
    /// Zeile muss das also unterscheiden, sonst steht überall nur der Titel.
    public var neuzugangszeile: String? {
        switch type {
        case "Episode":
            // Die Staffel, nicht die Folge: In der Reihe steht eine Serie für
            // alles, was zuletzt dazukam. „Staffel 3" beantwortet die Frage
            // „wo geht es weiter", eine einzelne Folgennummer nicht.
            if let staffel = parentIndexNumber { return uebersetzt("Staffel \(staffel)") }
            if let folge = indexNumber { return uebersetzt("Folge \(folge)") }
            return nil
        case "Season":
            // Ohne Nummer trägt der Name die Aussage, etwa „Specials".
            if let nummer = indexNumber { return uebersetzt("Staffel \(nummer)") }
            return name
        case "Series":
            // `ChildCount` ist hier **nicht** die Zahl der Staffeln.
            //
            // `Items/Latest` fasst neue Folgen unter ihrer Serie zusammen, und
            // die Zahl gehört zu dieser Gruppe: so viele Folgen sind neu. Als
            // Staffeln beschriftet stand bei einer Serie mit zwei Staffeln
            // „8 Staffeln“, weil acht Folgen dazugekommen waren.
            //
            // Welche Staffel es war, sagt der Server in dieser Antwort nicht.
            guard let anzahl = childCount, anzahl > 0 else {
                return productionYear.map(String.init)
            }
            return uebersetzt("\(anzahl) neue Folgen")
        default:
            return productionYear.map(String.init)
        }
    }

    /// „S1 • E3 • 21 Jump Street" — leer bei Filmen.
    public var kontextzeile: String? {
        var teile: [String] = []
        if let staffel = parentIndexNumber { teile.append("S\(staffel)") }
        if let folge = indexNumber { teile.append("E\(folge)") }
        if let serie = seriesName { teile.append(serie) }
        return teile.isEmpty ? nil : teile.joined(separator: " • ")
    }

    /// Laufzeit in Sekunden. Jellyfin zählt in 100-Nanosekunden-Ticks.
    public var runtimeSeconds: Double? {
        runTimeTicks.map { Double($0) / 10_000_000 }
    }
}

// Für NavigationLink(value:). Die id genügt — sie ist serverweit eindeutig,
// und die übrigen Felder sind teils nicht hashbar.
extension Item: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct UserItemData: Codable, Sendable, Equatable {
    public let playbackPositionTicks: Int64?
    public let played: Bool?
    public let isFavorite: Bool?
    public let playedPercentage: Double?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case played = "Played"
        case isFavorite = "IsFavorite"
        case playedPercentage = "PlayedPercentage"
    }
}

/// Ein Mitwirkender. `role` ist die Rolle im Film, `type` die Funktion
/// (Actor, Director, Writer …).
public struct Person: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let role: String?
    public let type: String?
    public let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case role = "Role"
        case type = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }

    public var istDarsteller: Bool { type == "Actor" }
}

public struct NameID: Codable, Sendable, Identifiable, Hashable {
    public let id: String?
    public let name: String?
    enum CodingKeys: String, CodingKey { case id = "Id", name = "Name" }
}

public struct MediaURL: Codable, Sendable, Hashable {
    public let url: String?
    public let name: String?
    enum CodingKeys: String, CodingKey { case url = "Url", name = "Name" }
}

// MARK: - Wiedergabe

public struct PlaybackInfoResponse: Codable, Sendable {
    public let mediaSources: [MediaSource]
    public let playSessionId: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionId = "PlaySessionId"
    }
}

public struct MediaSource: Codable, Sendable, Identifiable, Equatable {
    public let id: String?
    public let name: String?
    public let container: String?
    public let size: Int64?
    public let supportsDirectPlay: Bool?
    public let supportsDirectStream: Bool?
    public let supportsTranscoding: Bool?
    public let transcodingUrl: String?
    public let mediaStreams: [MediaStream]?

    /// Bildhöhe der Videospur — für „2160p".
    public var hoehe: Int? {
        mediaStreams?.first { $0.type == "Video" }?.height
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case container = "Container"
        case size = "Size"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case transcodingUrl = "TranscodingUrl"
        case mediaStreams = "MediaStreams"
    }

    /// Wie der Server diese Quelle ausliefern würde. Das ist die Zahl, auf die
    /// es Swiftly ankommt: alles außer `.transcode` ist ein Erfolg.
    public var deliveryMethod: DeliveryMethod {
        if supportsDirectPlay == true { return .directPlay }
        if supportsDirectStream == true { return .directStream }
        return .transcode
    }
}

public enum DeliveryMethod: String, Sendable, Equatable {
    case directPlay = "Direct Play"
    case directStream = "Direct Stream"
    case transcode = "Transcode"

    public var isLossless: Bool { self != .transcode }

    /// Die Schreibweise, die Jellyfin bei Wiedergabemeldungen erwartet.
    /// Nicht identisch mit `rawValue` — der ist für die Oberfläche.
    public var wireName: String {
        switch self {
        case .directPlay:   "DirectPlay"
        case .directStream: "DirectStream"
        case .transcode:    "Transcode"
        }
    }
}

/// **Eine Zahl, die die Antwort nicht umwerfen kann.**
///
/// Ein `Double?` mit erzeugtem Decoder wirft, sobald an der Stelle etwas
/// anderes steht als eine Zahl — und ein Wurf beim Auspacken nimmt nicht das
/// Feld mit, sondern **die ganze Antwort**. Eine Angabe, die nur zur Zierde
/// gebraucht wird, darf niemals ueber die Wiedergabe entscheiden.
///
/// Genau das steht hier auf dem Spiel: `RealFrameRate` ist im Datenblatt eine
/// Fliesskommazahl, aber Jellyfin schreibt Zahlenfelder je nach Quelle auch
/// als Zeichenkette oder gar nicht. Ein Titel, dessen Angabe abweicht, waere
/// sonst gar nicht abspielbar — und niemand kaeme darauf, dass es an der
/// Bildrate liegt.
public struct Zahlwert: Codable, Sendable, Equatable {
    public let wert: Double?

    public init(_ wert: Double?) { self.wert = wert }

    public init(from decoder: Decoder) throws {
        let raum = try decoder.singleValueContainer()
        if let zahl = try? raum.decode(Double.self) { wert = zahl }
        else if let text = try? raum.decode(String.self) { wert = Double(text) }
        else { wert = nil }
    }

    public func encode(to encoder: Encoder) throws {
        var raum = encoder.singleValueContainer()
        if let wert { try raum.encode(wert) } else { try raum.encodeNil() }
    }
}

public struct MediaStream: Codable, Sendable, Equatable {
    public init(codec: String?, type: String?, language: String?, displayTitle: String?,
                channels: Int?, isDefault: Bool?, index: Int?, height: Int?, width: Int?,
                realFrameRate: Double? = nil, averageFrameRate: Double? = nil) {
        self.codec = codec; self.type = type; self.language = language
        self.displayTitle = displayTitle; self.channels = channels
        self.isDefault = isDefault; self.index = index
        self.height = height; self.width = width
        self.realFrameRateRoh = Zahlwert(realFrameRate)
        self.averageFrameRateRoh = Zahlwert(averageFrameRate)
    }

    public let codec: String?
    public let type: String?          // Video | Audio | Subtitle
    public let language: String?
    public let displayTitle: String?
    public let channels: Int?
    public let isDefault: Bool?
    public let index: Int?
    public let height: Int?
    public let width: Int?
    /// Die Bildrate der Spur.
    ///
    /// **Wofuer.** Der Apple TV kann seinen Ausgang auf die Bildrate des
    /// Films stellen; ohne das wird 23,976 in 60 Hz ungleichmaessig verteilt
    /// und die Bewegung ruckelt, obwohl kein Bild fehlt. Gemessen: butterweich
    /// mit Anpassung, ruckelig ohne — bei 4 zu spaeten Bildern auf 4888.
    ///
    /// **Warum sie hier steht und nicht beim Abspieler.** VLC kennt sie erst,
    /// wenn der Strom offen ist. Der Umschaltvorgang kostet den Fernseher
    /// aber ein paar Sekunden Schwarzbild, und die soll hinter dem Ladeschirm
    /// liegen, nicht dahinter herausragen. Der Server weiss es vorher.
    ///
    /// `RealFrameRate` ist der genaue Wert, `AverageFrameRate` der gemittelte
    /// — bei variabler Bildrate weichen sie voneinander ab.
    private let realFrameRateRoh: Zahlwert?
    private let averageFrameRateRoh: Zahlwert?

    public var realFrameRate: Double? { realFrameRateRoh?.wert }
    public var averageFrameRate: Double? { averageFrameRateRoh?.wert }

    /// Die verlaesslichere der beiden — oder `nil`, wenn ihr nicht zu trauen
    /// ist.
    ///
    /// **Weichen die beiden deutlich voneinander ab, ist die Bildrate
    /// schwankend.** Dann gibt es keine Rate, auf die sich ein Ausgang stellen
    /// liesse: welche man auch nimmt, es passt nur zeitweise. Umzuschalten
    /// waere dann ein Schwarzbild fuer nichts, und deshalb sagt diese
    /// Auskunft in dem Fall lieber gar nichts.
    public var bildrate: Double? {
        let plausibel = { (wert: Double?) -> Double? in
            guard let wert, wert > 1, wert < 250 else { return nil }
            return wert
        }
        guard let echt = plausibel(realFrameRate) else { return plausibel(averageFrameRate) }
        if let mittel = plausibel(averageFrameRate), abs(echt - mittel) > 0.5 { return nil }
        return echt
    }

    enum CodingKeys: String, CodingKey {
        case height = "Height"
        case width = "Width"
        case codec = "Codec"
        case type = "Type"
        case language = "Language"
        case displayTitle = "DisplayTitle"
        case channels = "Channels"
        case isDefault = "IsDefault"
        case index = "Index"
        case realFrameRateRoh = "RealFrameRate"
        case averageFrameRateRoh = "AverageFrameRate"
    }

    /// Kurze, lesbare Bezeichnung — „Deutsch · DTS-HD MA 5.1".
    ///
    /// Jellyfins `DisplayTitle` ist für eine Zeile unbrauchbar; dort steht
    /// etwa „German Forced - Hörgeschädigt - Standard - Erzwungen - ASS".
    /// Hier wird aus Sprache, Codec und Kanälen selbst zusammengesetzt.
    public var kurz: String {
        var teile: [String] = []
        if let sprache = sprachname { teile.append(sprache) }
        if let codec { teile.append(codecName(codec)) }
        // Unter einem Kanal ist die Angabe kaputt und wird weggelassen —
        // vorher stand bei null Kanälen „-1.1" in der Zeile.
        if let kanaele = channels, kanaele > 0, type == "Audio" {
            teile.append(kanaele == 2 ? uebersetzt("Stereo")
                       : kanaele == 1 ? uebersetzt("Mono")
                                      : "\(kanaele - 1).1")
        }
        return teile.isEmpty ? (displayTitle ?? "—") : teile.joined(separator: " · ")
    }

    /// Sprache in der Sprache des Geräts, aus dem Dreibuchstaben-Kürzel.
    public var sprachname: String? {
        guard let language, !language.isEmpty else { return nil }
        let locale = Locale.current
        return locale.localizedString(forLanguageCode: language)?.capitalized
            ?? language.uppercased()
    }

    /// Auch von außen nutzbar.
    public static func lesbar(_ codec: String) -> String {
        MediaStream(codec: nil, type: nil, language: nil, displayTitle: nil,
                    channels: nil, isDefault: nil, index: nil, height: nil, width: nil)
            .codecName(codec)
    }

    private func codecName(_ codec: String) -> String {
        switch codec.lowercased() {
        case "dca", "dts":        "DTS"
        case "dtshd", "dts-hd":   "DTS-HD"
        case "truehd":            "TrueHD"
        case "eac3":              "Dolby Digital+"
        case "ac3":               "Dolby Digital"
        case "aac":               "AAC"
        case "flac":              "FLAC"
        case "opus":              "Opus"
        case "pgssub", "pgs":     "PGS"
        case "subrip", "srt":     "SRT"
        case "ass", "ssa":        "ASS"
        case "dvdsub", "vobsub":  "VOBSUB"
        case "hevc", "h265":      "HEVC"
        case "h264", "avc":       "H.264"
        case "av1":               "AV1"
        default:                  codec.uppercased()
        }
    }
}
