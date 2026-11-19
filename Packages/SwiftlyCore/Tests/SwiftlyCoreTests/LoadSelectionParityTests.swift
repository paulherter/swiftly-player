import Foundation
import JellyfinKit
import Testing

@testable import SwiftlyCore

/// The core's download selection against the Swift rules the sheet used (`DownloadQuality.offered`,
/// `DownloadAudio.languageOptions`, `DownloadRules.footSpace`) on the same episodes, which also
/// proves that `Item` encodes into JSON the core reads.
@Suite struct LoadSelectionParityTests {
    private static func episodes(_ ids: [(String, Int, Bool)]) throws -> [Item] {
        let rows = ids.map { id, size, played in
            """
            {"Id":"\(id)","Name":"Ep \(id)","Type":"Episode","IndexNumber":1,"ParentIndexNumber":1,"RunTimeTicks":27000000000,
             "UserData":{"Played":\(played)},
             "MediaSources":[{"Id":"m\(id)","Size":\(size),"MediaStreams":[
               {"Index":0,"Type":"Video","Codec":"h264"},
               {"Index":1,"Type":"Audio","Codec":"ac3","Language":"ger"},
               {"Index":2,"Type":"Audio","Codec":"aac","Language":"eng"}]}]}
            """
        }
        return try JSONDecoder().decode([Item].self, from: Data(("[" + rows.joined(separator: ",") + "]").utf8))
    }

    private func made(_ list: [Item], select: Bool = true) throws -> LoadSelectionModel {
        let json = try #require(encode(list))
        return try LoadSelectionModel(
            seasonIds: ["s1"], preloaded: [LoadSeasonEpisodes(seasonId: "s1", episodesJson: json)],
            locale: "en", audioLanguage: "", selectQuality: select, deviceLanguage: "")
    }

    private func encode(_ list: [Item]) -> String? {
        (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) }
    }

    @Test func selectionBytesQualitiesAndFootMatchTheSwiftRules() throws {
        let list = try Self.episodes([("a", 4_000_000_000, false), ("b", 6_000_000_000, true)])
        let m = try made(list)
        m.toggleAll()
        let st = m.state(free: 100_000_000_000)
        #expect(Set(st.selectedIds) == ["a", "b"])
        #expect(st.bytes == 10_000_000_000)
        let expected = DownloadQuality.offered(
            selectable: true,
            sourceBitrateOf: DownloadQuality.sourceBitrateOf(list.map { (Int64($0.mediaSources?.first?.size ?? 0), $0.runTimeTicks) }))
        #expect(st.qualities == expected.map(\.rawValue))
        for free in [Int64(0), 5_000_000_000, 10_000_000_000, 11_000_000_000, 100_000_000_000] {
            let swift = DownloadRules.footSpace(for: st.bytes, free: free)
            switch (m.state(free: free).foot, swift) {
            case (.free(let a), .free(let b)), (.few(let a), .few(let b)): #expect(a == b, "free \(free)")
            default: Issue.record("verdict differs at free \(free)")
            }
        }
    }

    @Test func onlyUnwatchedAndPresentEpisodesAreNeverTaken() throws {
        let list = try Self.episodes([("a", 1000, false), ("b", 2000, true), ("c", 3000, false)])
        let m = try made(list)
        m.setOnlyUnwatched(on: true)
        m.toggleSeason(seasonId: "s1")
        #expect(Set(m.state(free: 0).selectedIds) == ["a", "c"])
        m.setPresent(ids: ["a"])
        let st = m.state(free: 0)
        #expect(st.selectedIds == ["c"])
        #expect(st.seasons[0].episodes.map(\.id) == ["a", "c"], "watched ones leave the list")
        m.toggleEpisode(episodeId: "a")
        #expect(m.state(free: 0).selectedIds == ["c"], "a present episode ignores taps")
    }

    @Test func audioOptionsAreLanguagesAsInTheSwiftSheet() throws {
        let list = try Self.episodes([("a", 1000, false)])
        let m = try made(list)
        m.toggleAll()
        let st = m.state(free: 0)
        let swift = DownloadAudio.languageOptions(list.map { $0.mediaSources?.first?.mediaStreams ?? [] })
        #expect(st.audioOffered == DownloadAudio.offered(selection: list.map { $0.mediaSources?.first?.mediaStreams ?? [] }))
        #expect(st.audioOptions.count == swift.count)
        #expect(st.audioOptions.first?.choice == .all)
        // An unknown wish falls back to all tracks; a chosen language stays.
        let wish = try #require(st.audioOptions.last?.choice)
        m.setAudio(choice: wish)
        #expect(m.state(free: 0).audio == wish)
    }

    /// A film with an English default track and a German dub, as the film sheet reads it.
    private static let dubbedFilm: [MediaStream] = {
        let json = """
            [{"Index":0,"Type":"Video","Codec":"h264"},
             {"Index":1,"Type":"Audio","Codec":"eac3","Language":"eng","IsDefault":true,"Channels":6},
             {"Index":2,"Type":"Audio","Codec":"eac3","Language":"ger","Channels":6}]
            """
        return (try? JSONDecoder().decode([MediaStream].self, from: Data(json.utf8))) ?? []
    }()

    private static func rows(_ streams: [MediaStream]) -> [PlayerStream] {
        streams.compactMap { s in
            s.index.map {
                PlayerStream(index: Int64($0), kind: s.type ?? "", language: s.language, codec: s.codec,
                             channels: s.channels.map(Int64.init), title: s.title, isDefault: s.isDefault ?? false,
                             isForced: false, isExternal: false, isHearingImpaired: false, isOriginal: false)
            }
        }
    }

    /// The film sheet started on the settings language alone (`DownloadAudio.preselected`), so a German device with
    /// default settings started an English film with a German dub on all tracks while the season sheet started on the
    /// German one. The core's start rule takes the device language after the settings.
    @Test func theFilmSheetStartsOnTheDeviceLanguageAndTheSettingsStillWin() throws {
        let film = Self.dubbedFilm
        #expect(film.count == 3, "the fixture decodes")
        let rows = Self.rows(film)
        let options = DownloadAudio.trackOptions(streams: film)
        // Nothing in the settings: the old picker said "all tracks"; the core takes the device language.
        #expect(DownloadAudio.preselected(options: options, streams: film, preferredLanguage: "") == .all)
        #expect(downloadAudioStart(streams: rows, audioLanguage: "", locale: "en", deviceLanguage: "de-DE") == .track(index: 2))
        #expect(downloadAudioStart(streams: rows, audioLanguage: "", locale: "en", deviceLanguage: "en-US") == .track(index: 1))
        #expect(downloadAudioStart(streams: rows, audioLanguage: "", locale: "en", deviceLanguage: "") == .all)
        #expect(downloadAudioStart(streams: rows, audioLanguage: "", locale: "en", deviceLanguage: "fr-FR") == .all)
        // The settings language is what the old picker used, and it still comes first.
        #expect(DownloadAudio.preselected(options: options, streams: film, preferredLanguage: "English") == .track(1))
        #expect(downloadAudioStart(streams: rows, audioLanguage: "English", locale: "en", deviceLanguage: "de-DE") == .track(index: 1))
    }

    @Test func theFetchPlanIsThreeSeasonsAtATime() throws {
        let m = try LoadSelectionModel(seasonIds: (1...7).map { "s\($0)" }, preloaded: [], locale: "en",
                                       audioLanguage: "", selectQuality: false, deviceLanguage: "")
        #expect(m.beginLoad().map(\.count) == [3, 3, 1])
    }

    @Test func shuffleRunKeepsEverythingAndPutsUnplayedFirst() throws {
        let list = try Self.episodes([("a", 1, true), ("b", 1, false), ("c", 1, false)])
        let json = try #require(encode(list))
        let run = try ShuffleRunModel.mixed(episodesJson: json, seed: 3)
        let ids = run.ids()
        #expect(Set(ids) == ["a", "b", "c"])
        #expect(ids.last == "a")
        #expect(run.nextAfter(id: ids[0])?.id == ids[1])
        #expect(run.nextAfter(id: ids[2]) == nil)
        let ordered = try ShuffleRunModel.ordered(episodesJson: json)
        #expect(ordered.ids() == ["a", "b", "c"])
        #expect(ordered.contains(id: "b"))
    }
}
