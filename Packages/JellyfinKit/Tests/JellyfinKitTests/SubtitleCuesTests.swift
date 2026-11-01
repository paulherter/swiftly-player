import Foundation
import Testing
@testable import JellyfinKit

@Suite("Subtitle cues")
struct SubtitleCuesTests {

    @Test func readsSRT() {
        let file = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:03,500\r\nHello <i>there</i>\r\n\r\n2\r\n00:01:00,000 --> 00:01:02,000\r\n{\\an8}Top\r\nline two\r\n"
        let cues = SubtitleCues.parse(file)
        #expect(cues.cues.count == 2)
        #expect(cues.cues[0].text == "Hello there")
        #expect(cues.cues[0].start == 1 && cues.cues[0].end == 3.5)
        #expect(cues.cues[1].text == "Top\nline two")
        #expect(cues.cues[1].start == 60)
    }

    @Test func readsWebVTTWithSettingsAndShortTimes() {
        let file = """
        WEBVTT

        NOTE a comment

        intro
        00:05.000 --> 00:07.250 line:90% align:center
        Fish &amp; chips
        """
        let cues = SubtitleCues.parse(file)
        #expect(cues.cues.count == 1)
        #expect(cues.cues[0].start == 5 && cues.cues[0].end == 7.25)
        #expect(cues.cues[0].text == "Fish & chips")
    }

    @Test func findsTheCueAtATime() {
        let cues = SubtitleCues(cues: [
            SubtitleCue(start: 1, end: 3, text: "a"),
            SubtitleCue(start: 2, end: 5, text: "b"),
            SubtitleCue(start: 10, end: 12, text: "c"),
        ])
        #expect(cues.text(at: 0.5) == nil)
        #expect(cues.text(at: 1.5) == "a")
        #expect(cues.text(at: 2.5) == "a\nb")
        #expect(cues.text(at: 4) == "b")
        #expect(cues.text(at: 7) == nil)
        #expect(cues.text(at: 11) == "c")
        #expect(cues.text(at: 12) == nil)
    }

    @Test func skipsBrokenBlocks() {
        let cues = SubtitleCues.parse("1\nnot a time\ntext\n\n2\n00:00:05,000 --> 00:00:04,000\nbackwards\n\n3\n00:00:01,000 --> 00:00:02,000\n\n")
        #expect(cues.isEmpty)
    }
}

@Suite("Subtitle files for AVPlayer")
struct SubtitleFilesForAVPlayerTests {

    private func streams() throws -> [MediaStream] {
        let json = """
        [{"Index":2,"Type":"Subtitle","Codec":"subrip","IsExternal":false},
         {"Index":3,"Type":"Subtitle","Codec":"ass","IsExternal":false},
         {"Index":4,"Type":"Subtitle","Codec":"hdmv_pgs_subtitle","IsExternal":false},
         {"Index":5,"Type":"Subtitle","Codec":"srt","IsExternal":true,"DeliveryUrl":"/Videos/x/y/Subtitles/5/0/Stream.srt"}]
        """
        return try JSONDecoder().decode([MediaStream].self, from: Data(json.utf8))
    }

    @Test func serverExtractionListsEveryTextTrackAndNoPicture() throws {
        let files = SubtitleFile.forAVPlayer(streams: try streams(), itemID: "item", source: "src",
                                             server: URL(string: "https://s.example")!, key: "k",
                                             serverExtracts: true)
        #expect(files.map(\.index) == [2, 3, 5])
        #expect(files[1].address.absoluteString == "https://s.example/Videos/item/src/Subtitles/3/0/Stream.srt?ApiKey=k")
    }

    @Test func withoutExtractionOnlyExternalFilesCount() throws {
        let files = SubtitleFile.forAVPlayer(streams: try streams(), itemID: "item", source: "src",
                                             server: URL(string: "https://s.example")!, key: "k",
                                             serverExtracts: false)
        #expect(files.map(\.index) == [5])
    }
}
