import Foundation
import Testing
@testable import JellyfinKit

/// **Data written before the identifier rename still reads, and is written back the same way.**
///
/// Every JSON below uses the key names of the last version before the rename (tag
/// `pre-english-umstellung`), taken from that source. Each test decodes it with today's types,
/// encodes it again and requires the same set of key paths, nested objects included. A
/// property renamed without a matching `CodingKeys` raw value fails here: the old key is
/// dropped on decode, the new one appears on encode.
///
/// `Werkzeuge/codable-keys-check.py` guards the same thing statically for every Codable type
/// on all platforms; these tests prove it at runtime for the types the package persists or
/// exchanges.
@Suite struct LegacyKeysTests {

    /// All key paths of a JSON value: `a`, `a.b`, `list[].c`. Array elements are merged.
    private static func paths(_ value: Any, _ prefix: String = "") -> Set<String> {
        var out = Set<String>()
        if let object = value as? [String: Any] {
            for (key, inner) in object {
                let path = prefix.isEmpty ? key : prefix + "." + key
                out.insert(path)
                out.formUnion(paths(inner, path))
            }
        } else if let array = value as? [Any] {
            for inner in array { out.formUnion(paths(inner, prefix + "[]")) }
        }
        return out
    }

    private static func paths(of data: Data) throws -> Set<String> {
        paths(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// Decodes the old JSON and encodes it again; both must carry the same key paths.
    @discardableResult
    private func roundTrip<T: Codable>(_ type: T.Type, _ json: String,
                                       sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
        let old = Data(json.utf8)
        let value = try JSONDecoder().decode(type, from: old)
        let again = try JSONEncoder().encode(value)
        let expected = try Self.paths(of: old)
        let actual = try Self.paths(of: again)
        #expect(actual == expected,
                "missing: \(expected.subtracting(actual).sorted()), new: \(actual.subtracting(expected).sorted())",
                sourceLocation: sourceLocation)
        return value
    }

    /// Every old raw value still resolves, and resolves back to itself.
    private func raw<T: RawRepresentable>(_ type: T.Type, _ old: [String],
                                          sourceLocation: SourceLocation = #_sourceLocation) where T.RawValue == String {
        for value in old {
            #expect(T(rawValue: value)?.rawValue == value, "\(T.self): \(value)", sourceLocation: sourceLocation)
        }
    }

    private func allRaw<T: RawRepresentable & CaseIterable>(_ type: T.Type, _ old: [String],
                                                           sourceLocation: SourceLocation = #_sourceLocation) where T.RawValue == String {
        raw(type, old, sourceLocation: sourceLocation)
        #expect(Set(T.allCases.map(\.rawValue)) == Set(old), "\(T.self)", sourceLocation: sourceLocation)
    }

    // MARK: - Fixtures

    static let mediaStream = #"""
    {"Codec":"hevc","Type":"Video","Language":"ger","DisplayTitle":"4K","Channels":6,"IsDefault":true,
     "IsForced":false,"IsExternal":false,"IsHearingImpaired":false,"AspectRatio":"16:9","Title":"Main",
     "DeliveryUrl":"/x","Index":0,"Height":2160,"Width":3840,"VideoRangeType":"DOVIWithHDR10",
     "ColorTransfer":"smpte2084","ColorPrimaries":"bt2020","DvProfile":8,"DvBlSignalCompatibilityId":1,
     "RealFrameRate":23.976,"AverageFrameRate":23.976}
    """#

    static let mediaSource = #"""
    {"Id":"m1","Name":"Film","Container":"mkv","Size":1000,"SupportsDirectPlay":true,
     "SupportsDirectStream":true,"SupportsTranscoding":false,"TranscodingUrl":"/t",
     "MediaStreams":[\#(mediaStream)],"DefaultAudioStreamIndex":1,"DefaultSubtitleStreamIndex":2,
     "RunTimeTicks":72000000000}
    """#

    static let item = #"""
    {"Id":"i1","Name":"Episode","Type":"Episode","CollectionType":"tvshows","ProductionYear":2020,
     "Overview":"Text","RunTimeTicks":100,"SeriesName":"Series","IndexNumber":2,"ParentIndexNumber":1,
     "SeriesId":"s1","SeasonId":"st1","Genres":["Drama"],"OfficialRating":"16","CommunityRating":7.5,
     "ChildCount":3,"LocalTrailerCount":1,"BackdropImageTags":["b"],"SeriesPrimaryImageTag":"p",
     "People":[{"Id":"p1","Name":"A","Role":"R","Type":"Actor","PrimaryImageTag":"t"}],
     "Studios":[{"Id":"n1","Name":"S"}],"Taglines":["T"],"CriticRating":80,
     "RemoteTrailers":[{"Name":"Trailer","Url":"https://x.test"}],"ImageTags":{"Primary":"x"},
     "UserData":{"PlaybackPositionTicks":5,"Played":false,"IsFavorite":true,"PlayedPercentage":12.5,
                 "UnplayedItemCount":0,"LastPlayedDate":"2026-01-01T00:00:00Z"},
     "MediaSources":[\#(mediaSource)],"ParentBackdropImageTags":["pb"],"ParentBackdropItemId":"pbi",
     "ParentThumbImageTag":"pt","ParentLogoImageTag":"pl","ParentThumbItemId":"pti",
     "PremiereDate":"2020-01-01T00:00:00Z","ProductionLocations":["DE"],"ProviderIds":{"Tmdb":"1"},
     "ExtraType":"Trailer"}
    """#

    // MARK: - Stored on the device

    @Test("A download index entry keeps all of its keys")
    func downloadItem() throws {
        let item = try roundTrip(DownloadItem.self, #"""
        {"id":"d1","konto":"u1","art":"folge","titel":"T","serie":"S","serienId":"s1","staffel":1,
         "folge":2,"laufzeitTicks":100,"container":"mkv","quelle":"src","bytes":10,"qualitaet":"hd720",
         "geladen":5,"stand":"laedt","grund":"r","gesehen":false,"angelegt":700000000,
         "nochAufDemServer":true,"abschnitte":[{"StartTicks":0,"EndTicks":10,"Type":"Intro"}],
         "stelleTicks":3,"zuletzt":700000001,"bildcodec":"hevc"}
        """#)
        #expect(item.account == "u1" && item.state == .loads && item.art == .episode)
        #expect(item.quality == .hd720 && item.sections?.first?.art == .introSegment)
    }

    @Test("The stored home page keeps its keys, items included")
    func homeStore() throws {
        let store = try roundTrip(HomeStore.self, #"""
        {"fassung":1,"bibliotheken":[\#(Self.item)],"weiterschauen":[\#(Self.item)],
         "naechsteFolge":[\#(Self.item)],"zuletzt":[\#(Self.item)],"neueFilme":[\#(Self.item)],
         "neueSerien":[\#(Self.item)],"gattungsreihen":[{"name":"Drama","items":[\#(Self.item)]}]}
        """#)
        #expect(store.version == 1 && store.genreRails.first?.items.first?.id == "i1")
    }

    @Test("An item, its media sources and streams keep the server's keys")
    func item() throws {
        let item = try roundTrip(Item.self, Self.item)
        #expect(item.mediaSources?.first?.mediaStreams?.first?.codec == "hevc")
        try roundTrip(PlaybackInfoResponse.self,
                      #"{"MediaSources":[\#(Self.mediaSource)],"PlaySessionId":"p","ErrorCode":"e"}"#)
    }

    @Test("The account bundle keeps `konten` and `aktiveKennung`")
    func accountBundle() throws {
        let bundle = try roundTrip(AccountBundle.self, #"""
        {"konten":[{"accessToken":"t","userID":"u","userName":"n","serverURL":"https://x.test"}],
         "aktiveKennung":"u"}
        """#)
        #expect(bundle.activeId == "u" && bundle.accounts.first?.userName == "n")
    }

    @Test("A session keeps its four keys")
    func session() throws {
        try roundTrip(Session.self, #"{"accessToken":"t","userID":"u","userName":"n","serverURL":"https://x.test"}"#)
    }

    @Test("A pending report keeps `konto` and `wann`")
    func pendingReport() throws {
        let report = try roundTrip(PendingReport.self, #"{"itemID":"i1","konto":"u1","ticks":42,"wann":700000000}"#)
        #expect(report.account == "u1")
    }

    @Test("A remembered track keeps its German keys")
    func trackImprint() throws {
        let imprint = try roundTrip(TrackImprint.self, #"""
        {"sprache":"ger","codec":"ac3","titel":"T","erzwungen":true,"kanaele":6,"position":1,
         "extern":false,"name":"N","hoergeschaedigt":false}
        """#)
        #expect(imprint.language == "ger" && imprint.forced && imprint.channels == 6)
    }

    @Test("A Trakt token keeps `zugriff`, `erneuerung`, `ablauf`, `benutzer`")
    func traktToken() throws {
        let token = try roundTrip(TraktToken.self, #"{"zugriff":"a","erneuerung":"r","ablauf":700000000,"benutzer":"u"}"#)
        #expect(token.access == "a" && token.user == "u")
    }

    @Test("Own headers and the Seerr access keep their keys")
    func seerrAccess() throws {
        let access = try roundTrip(SeerrAccess.self, #"""
        {"adresse":"https://seerr.test","keks":"c","koepfe":[{"name":"X-A","wert":"1"}]}
        """#)
        #expect(access.cookie == "c" && access.headers.first?.value == "1")
        try roundTrip(OwnHeader.self, #"{"name":"X-Test","wert":"1"}"#)
    }

    @Test("Seerr hits, people, seasons and details keep their keys")
    func seerr() throws {
        let hit = #"{"id":1,"art":"tv","titel":"T","jahr":2020,"plakatPfad":"/p","kulissePfad":"/k","stand":5}"#
        try roundTrip(SeerrHit.self, hit)
        try roundTrip(SeerrPerson.self, #"{"id":2,"name":"N","rolle":"R","bildPfad":"/b"}"#)
        try roundTrip(SeerrSeason.self, #"{"nummer":1,"folgen":10,"stand":5}"#)
        let detail = try roundTrip(SeerrDetail.self, #"""
        {"beschreibung":"D","genres":["G"],"laufzeit":90,"bewertung":7.5,
         "staffeln":[{"nummer":1,"folgen":10,"stand":5}],
         "besetzung":[{"id":2,"name":"N","rolle":"R","bildPfad":"/b"}],
         "aehnliches":[\#(hit)],"stand":5}
        """#)
        #expect(detail.seasons.first?.number == 1 && detail.similarOne.first?.title == "T")
    }

    @Test("Start libraries keep `sammlung`, through the store helpers as well")
    func startLibraries() throws {
        try roundTrip(StartLibrary.self, #"{"id":"a","name":"Filme","sammlung":true}"#)
        let read = StartLibraries.read(Data(#"[{"id":"a","name":"Filme","sammlung":true}]"#.utf8))
        #expect(read.first?.collection == true)
        let written = try #require(StartLibraries.data(read))
        #expect(try Self.paths(of: written) == ["[].id", "[].name", "[].sammlung"])
    }

    @Test("The device profile sent to the server keeps its keys")
    func deviceProfile() throws {
        let data = try JSONEncoder().encode(DeviceProfile.vlc())
        let keys = try Self.paths(of: data)
        for key in ["Name", "MaxStreamingBitrate", "MaxStaticBitrate", "DirectPlayProfiles",
                    "TranscodingProfiles", "SubtitleProfiles", "CodecProfiles",
                    "DirectPlayProfiles[].Container", "DirectPlayProfiles[].Type",
                    "SubtitleProfiles[].Format", "SubtitleProfiles[].Method"] {
            #expect(keys.contains(key), "\(key)")
        }
        #expect(keys.allSatisfy { $0.split(separator: ".").allSatisfy { $0.first?.isUppercase == true } })
    }

    // MARK: - Raw values that are stored or sent

    @Test("Stored enum raw values are the old ones")
    func rawValues() {
        allRaw(DownloadState.self, ["wartet", "laedt", "angehalten", "fertig", "fehler"])
        raw(DownloadItem.Art.self, ["film", "folge"])
        allRaw(DownloadQuality.self, ["original", "hd1080", "hd720", "sd480"])
        allRaw(BufferLevel.self, ["normal", "schlecht", "sehrSchlecht"])
        allRaw(StartRail.self, ["weiterschauen", "naechsteFolge", "neuzugaenge", "neueFilme", "neueSerien"])
        allRaw(Sorting.self, ["name", "neueste", "erscheinung", "bewertung"])
        allRaw(LibraryFilter.self, ["alle", "ungesehen", "angefangen", "merkliste"])
        allRaw(RememberGenre.self, ["alle", "filme", "serien"])
        allRaw(DownloadPermission.self, ["erlaubt", "verboten", "unbekannt"])
        allRaw(CertificateReason.self, ["abgelaufen", "giltNochNicht", "andereAdresse", "nichtVertraut", "sonst"])
        raw(QuickConnectState.self, ["offen", "freigegeben", "abgelaufen", "gescheitert"])
        raw(Community.Trigger.self, ["bewertung", "discord"])
        raw(AirPlaySuitability.Obstacle.Art.self, ["video", "ton", "umpacken"])
        raw(Segment.Art.self, ["Unknown", "Commercial", "Preview", "Recap", "Outro", "Intro"])
    }
}
