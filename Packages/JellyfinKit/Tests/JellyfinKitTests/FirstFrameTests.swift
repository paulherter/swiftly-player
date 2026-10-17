import Foundation
import Testing
@testable import JellyfinKit

@Suite("Erstbild")
struct FirstFrameTests {

    private func rat(video: Bool = true, from: Bool = false, shown: UInt64 = 0,
                     run: TimeInterval = 5, untilFrom: FirstFrame.Level = .no) -> FirstFrame.Rat {
        FirstFrame.rat(hasVideoTrack: video, excluded: from, shown: shown,
                     runtime: run, untilFrom: untilFrom)
    }

    @Test("Zwei Rettungen, dann Ruhe")
    func levels() {
        #expect(rat(untilFrom: .no) == .outputNew)
        #expect(rat(untilFrom: .outputNew) == .softwareDecoder)
        #expect(rat(untilFrom: .software) == .giveUp)
        #expect(rat(untilFrom: .givenUp) == .nothing)
        var rung = FirstFrame.Level.no
        var episode: [FirstFrame.Rat] = []
        for _ in 0..<5 {
            let r = rat(untilFrom: rung)
            episode.append(r)
            rung = FirstFrame.next(to: r, untilFrom: rung)
        }
        #expect(episode == [.outputNew, .softwareDecoder, .giveUp, .nothing, .nothing])
    }

    @Test("Erst nach der Frist")
    func deadline() {
        #expect(rat(run: 0) == .wait)
        #expect(rat(run: FirstFrame.deadline - 0.5) == .wait)
        #expect(rat(run: FirstFrame.deadline) == .outputNew)
    }

    @Test("Ein Bild, keine Bildspur oder ausgenommen: nichts")
    func exceptions() {
        #expect(rat(shown: 1, run: 60) == .nothing)
        #expect(rat(video: false, run: 60) == .nothing)
        #expect(rat(from: true, run: 60) == .nothing)
        #expect(rat(shown: 1, untilFrom: .software) == .nothing)
    }

    @Test("Nur laufende Uhr zaehlt")
    func growth() {
        #expect(FirstFrame.growth(before: nil, now: 10) == 0)
        #expect(FirstFrame.growth(before: 10, now: 10) == 0)      // buffering, pause
        #expect(FirstFrame.growth(before: 10, now: 9) == 0)       // backwards
        #expect(FirstFrame.growth(before: 10, now: 11) == 1)
        #expect(FirstFrame.growth(before: 10, now: 610) == 0)     // jump
        // Ten ticks of buffering, then four seconds of film: only then due.
        var run: TimeInterval = 0
        var before: TimeInterval? = nil
        for t in [0.0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3] {
            run += FirstFrame.growth(before: before, now: t); before = t
        }
        #expect(rat(run: run) == .wait)
        run += FirstFrame.growth(before: before, now: 4)
        #expect(rat(run: run) == .outputNew)
    }

    @Test("Hinweis nur nach einem Eingriff")
    func hint() {
        #expect(FirstFrame.hint(.no) == nil)
        #expect(FirstFrame.hint(.software) != nil)
        #expect(FirstFrame.hint(.givenUp) != nil)
    }
}

@Suite("Erstbild · Software von Anfang")
struct FirstFrameSoftwareTests {
    @Test("MPEG-4 Part 2 unverändert → Software, sonst frei")
    func mpeg4() {
        #expect(FirstFrame.softwareFromStart(videoCodec: "mpeg4", method: .directPlay))
        #expect(FirstFrame.softwareFromStart(videoCodec: "MPEG4", method: .directStream))
        #expect(!FirstFrame.softwareFromStart(videoCodec: "mpeg4", method: .transcode))
        #expect(!FirstFrame.softwareFromStart(videoCodec: "h264", method: .directPlay))
        #expect(!FirstFrame.softwareFromStart(videoCodec: "hevc", method: .directPlay))
        #expect(!FirstFrame.softwareFromStart(videoCodec: nil, method: .directPlay))
    }
}

@Suite("Erstbild · Software von Anfang, von der Platte")
struct FirstFrameSlabTests {
    private func entries(_ codec: String?, _ q: DownloadQuality = .original) -> DownloadItem {
        DownloadItem(id: "1", account: "k", art: .film, title: "t", container: "avi",
                       bytes: 1, watchState: nil, videoCodec: codec).inQuality(q)
    }

    @Test("Geladene XviD-Datei öffnet mit Software, H.264 frei")
    func slab() {
        let file = URL(fileURLWithPath: "/x.avi")
        #expect(PlaybackPlan.fromSlab(file, container: "avi", videoCodec: "mpeg4").softwareDecoder)
        #expect(!PlaybackPlan.fromSlab(file, container: "mkv", videoCodec: "h264").softwareDecoder)
        #expect(!PlaybackPlan.fromSlab(file, container: "avi").softwareDecoder)
    }

    @Test("libVLC 3 schaltet auch die Hardware in avcodec ab")
    func desktop() {
        #expect(FirstFrame.softwareOptionsDesktop == [FirstFrame.softwareOption, ":avcodec-hw=none"])
    }

    @Test("Der Posten merkt den Codec nur fürs Original")
    func entries() {
        #expect(entries("mpeg4").videoCodec == "mpeg4")
        #expect(entries("mpeg4", .hd720).videoCodec == nil)
    }

    @Test("Eine Liste ohne Codec liest sich weiter, eine mit behält ihn")
    func list() throws {
        let alt = #"{"id":"1","konto":"k","art":"film","titel":"t","bytes":1,"geladen":0,"stand":"fertig","gesehen":false,"angelegt":0,"nochAufDemServer":true}"#
        #expect(try JSONDecoder().decode(DownloadItem.self, from: Data(alt.utf8)).videoCodec == nil)
        let new = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(entries("mpeg4")))
        #expect(new.videoCodec == "mpeg4")
    }
}

@Suite("MediaSource · Bildcodec")
struct MediaSourceImageCodecTests {
    @Test("Erste Bildspur, nil ohne")
    func codec() throws {
        let q = try JSONDecoder().decode(MediaSource.self, from: Data(#"{"MediaStreams":[{"Type":"Audio","Codec":"mp3"},{"Type":"Video","Codec":"mpeg4"}]}"#.utf8))
        #expect(q.videoCodec == "mpeg4")
        let empty = try JSONDecoder().decode(MediaSource.self, from: Data(#"{"MediaStreams":[]}"#.utf8))
        #expect(empty.videoCodec == nil)
    }
}
