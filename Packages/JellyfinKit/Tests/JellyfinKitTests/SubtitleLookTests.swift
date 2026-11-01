import Foundation
import Testing
@testable import JellyfinKit

@Suite("Untertitel-Aussehen")
struct SubtitleLookTests {

    private func options(_ look: SubtitleLook = .standard, base: Double = 0.82, height: Int = 1080,
                         engine: SubtitleLook.Engine = .vlc4Apple) -> [String] {
        SubtitleLook.vlcOptions(look: look, baseScale: base, outputHeight: height, engine: engine)
    }

    @Test("Voreinstellung entspricht dem bisherigen festen Stil")
    func standardMatchesFormerStyle() {
        #expect(options() == [
            "--freetype-color=16777215",
            "--freetype-outline-thickness=3",
            "--freetype-outline-opacity=230",
            "--freetype-outline-color=0",
            "--freetype-shadow-opacity=0",
            "--freetype-background-opacity=1",
            "--sub-margin=16",
        ])
        #expect(SubtitleLook.standard.isStandard)
    }

    @Test("Groesse: Prozent je Geraet und Stufe", arguments: [
        (0.82, [66, 82, 98, 119]), (0.78, [62, 78, 94, 113]), (0.88, [70, 88, 106, 128]),
    ])
    func sizePercent(base: Double, expected: [Int]) {
        let got = SubtitleLook.Size.allCases.map {
            SubtitleLook.textScalePercent(look: SubtitleLook(size: $0), baseScale: base)
        }
        #expect(got == expected)
    }

    @Test("VLC 3 bekommt die Groesse als Option, Apple nicht")
    func sizeOptionOnlyOnVlc3() {
        #expect(options(SubtitleLook(size: .large), engine: .vlc3).first == "--sub-text-scale=98")
        #expect(!options(SubtitleLook(size: .large)).contains { $0.hasPrefix("--sub-text-scale") })
    }

    @Test("Farbe", arguments: [
        (SubtitleLook.Colour.white, "16777215"), (.yellow, "16770140"), (.grey, "13421772"),
    ])
    func colour(c: SubtitleLook.Colour, value: String) {
        #expect(options(SubtitleLook(colour: c)).contains("--freetype-color=\(value)"))
    }

    @Test("Rand", arguments: [
        (SubtitleLook.Outline.off, "0"), (.thin, "2"), (.normal, "3"),
    ])
    func outline(o: SubtitleLook.Outline, value: String) {
        let got = options(SubtitleLook(outline: o))
        #expect(got.contains("--freetype-outline-thickness=\(value)"))
        #expect(got.contains("--freetype-outline-opacity=230"))
        #expect(got.contains("--freetype-outline-color=0"))
    }

    @Test("Schatten an: gerade nach unten, hart")
    func shadowOn() {
        let got = options(SubtitleLook(shadow: true))
        #expect(got.contains("--freetype-shadow-opacity=160"))
        #expect(got.contains("--freetype-shadow-angle=-90"))
        #expect(got.contains("--freetype-shadow-distance=0.04"))
        #expect(got.contains("--freetype-shadow-color=0"))
    }

    @Test("Schatten aus: nur Deckkraft 0")
    func shadowOff() {
        let got = options()
        #expect(got.contains("--freetype-shadow-opacity=0"))
        #expect(!got.contains { $0.hasPrefix("--freetype-shadow-angle") })
    }

    @Test("Hintergrund an: 160, schwarz, auf beiden Engines")
    func backgroundOn() {
        for engine in [SubtitleLook.Engine.vlc4Apple, .vlc3] {
            let got = options(SubtitleLook(background: true), engine: engine)
            #expect(got.contains("--freetype-background-opacity=160"))
            #expect(got.contains("--freetype-background-color=0"))
        }
    }

    @Test("Hintergrund aus: Apple 1 gegen den Absturz, sonst 0")
    func backgroundOff() {
        #expect(options().contains("--freetype-background-opacity=1"))
        #expect(options(engine: .vlc3).contains("--freetype-background-opacity=0"))
    }

    @Test("Apple haelt die Deckkraft des Hintergrunds nie unter 1")
    func appleNeverBelowOne() {
        for look in [SubtitleLook.standard, SubtitleLook(shadow: true), SubtitleLook(background: true),
                     SubtitleLook(outline: .off, shadow: false, background: false)] {
            let value = options(look).first { $0.hasPrefix("--freetype-background-opacity=") }
                .flatMap { Int($0.split(separator: "=").last ?? "") }
            #expect((value ?? 0) >= 1)
        }
    }

    @Test("Position: unten 16 auf Apple, 0 sonst")
    func positionBottom() {
        #expect(options().contains("--sub-margin=16"))
        #expect(!options(engine: .vlc3).contains { $0.hasPrefix("--sub-margin") })
    }

    @Test("Position: hoeher addiert 7 Prozent der Ausgabehoehe")
    func positionRaised() {
        let look = SubtitleLook(position: .raised)
        #expect(SubtitleLook.raisedMargin(outputHeight: 1080) == 76)
        #expect(SubtitleLook.raisedMargin(outputHeight: 2160) == 151)
        #expect(options(look, height: 1080).contains("--sub-margin=92"))
        #expect(options(look, height: 2160).contains("--sub-margin=167"))
        #expect(options(look, height: 1080, engine: .vlc3).contains("--sub-margin=76"))
    }

    @Test("Gespeichert als JSON und tolerant gelesen")
    func storage() {
        let look = SubtitleLook(size: .huge, colour: .yellow, outline: .thin, shadow: true,
                                background: true, position: .raised, keepFileStyle: false)
        #expect(SubtitleLook.read(look.encoded()) == look)
        #expect(SubtitleLook.read(nil) == .standard)
        #expect(SubtitleLook.read(Data("kaputt".utf8)) == .standard)
        #expect(SubtitleLook.read(Data(#"{"size":"gigantic","shadow":true}"#.utf8))
                == SubtitleLook(shadow: true))
        #expect(look.encoded() == look.encoded())
    }

    @Test("Eigenes: jede Abweichung, auch der Dateischalter")
    func standardCheck() {
        #expect(!SubtitleLook(keepFileStyle: false).isStandard)
        #expect(!SubtitleLook(position: .raised).isStandard)
    }

    @Test("ASS und SSA kommen als SRT, wenn die Datei nicht bestimmt")
    func assAsSrt() {
        #expect(SubtitleFile.textSuffix("ass") == "ass")
        #expect(SubtitleFile.textSuffix("ssa", keepFileStyle: true) == "ass")
        #expect(SubtitleFile.textSuffix("ass", keepFileStyle: false) == "srt")
        #expect(SubtitleFile.textSuffix("SSA", keepFileStyle: false) == "srt")
        #expect(SubtitleFile.textSuffix("subrip", keepFileStyle: false) == "srt")
        #expect(SubtitleFile.textSuffix("hdmv_pgs_subtitle", keepFileStyle: false) == nil)
    }
}

@Suite("Untertitel als SRT")
struct SubtitleAsTextTests {

    private func stream(_ index: Int, _ codec: String, external: Bool = false, path: String? = nil) -> MediaStream {
        MediaStream(codec: codec, type: "Subtitle", language: "eng", displayTitle: nil, channels: nil,
                    isDefault: nil, index: index, height: nil, width: nil,
                    isExternal: external, deliveryUrl: path)
    }

    private let server = URL(string: "https://s.example")!

    @Test("ASS wird zur SRT-Adresse mit demselben Index, anderes bleibt")
    func replacesAss() {
        let streams = [stream(2, "ass"), stream(3, "subrip"), stream(4, "ssa", external: true, path: "/x/4.ssa"),
                       stream(5, "srt", external: true, path: "/x/5.srt")]
        let files = SubtitleFile.asPlainText(streams: streams, itemID: "I", source: "S",
                                             server: server, key: "K")
        #expect(files.map(\.index) == [2, 4, 5])
        #expect(files[0].address.absoluteString == "https://s.example/Videos/I/S/Subtitles/2/0/Stream.srt?ApiKey=K")
        #expect(files[1].address.absoluteString == "https://s.example/Videos/I/S/Subtitles/4/0/Stream.srt?ApiKey=K")
        #expect(files[2].address.absoluteString.contains("/x/5.srt"))
    }

    @Test("Ohne Quelle bleibt alles, wie es ist")
    func withoutSource() {
        let streams = [stream(2, "ass")]
        #expect(SubtitleFile.asPlainText(streams: streams, itemID: "I", source: nil,
                                         server: server, key: nil).isEmpty)
    }

    @Test("Die eingebettete ASS-Spur wird durch die Datei ersetzt")
    func hidesEmbedded() {
        let streams = [stream(2, "ass"), stream(3, "subrip")]
        let files = SubtitleFile.asPlainText(streams: streams, itemID: "I", source: "S",
                                             server: server, key: "K",
                                             attribute: { _ in "0123456789abcdef0123456789abcdef" })
        let tracks = [
            PlayerTrack(identifier: "spu/0", name: "A", language: "eng", codec: nil, channels: nil),
            PlayerTrack(identifier: "spu/1", name: "B", language: "eng", codec: nil, channels: nil),
            PlayerTrack(identifier: "0123456789abcdef0123456789abcdef/spu/0", name: "S", language: nil,
                        codec: "subrip", channels: nil),
        ]
        let map = TrackMapping.compose(audio: [], subtitle: tracks, streams: streams, files: files)
        #expect(map.subtitle == [nil, 3, 2])
        #expect(map.subtitlePosition(index: 2) == 2)
        #expect(TrackMapping.replacedPositions(subtitle: tracks, streams: streams, files: files) == [0])
    }

    @Test("Beim Oeffnen wird eine ersetzte Spur nicht gesetzt")
    func startSkipsReplaced() {
        let streams = [stream(2, "ass"), stream(3, "subrip")]
        let files = [SubtitleFile(index: 2, address: URL(string: "https://s.example/a.srt")!, attribute: nil)]
        #expect(TrackMapping.startPositions(streams: streams, audio: nil, subtitle: .feed(2), files: files).subtitle == nil)
        #expect(TrackMapping.startPositions(streams: streams, audio: nil, subtitle: .feed(3), files: files).subtitle == 1)
        #expect(TrackMapping.startPositions(streams: streams, audio: nil, subtitle: .feed(2)).subtitle == 0)
    }

    @Test("Der Schlüsselname folgt der Serverart, auch ohne Query in der Adresse", arguments: [
        (ServerKind.jellyfin, "ApiKey"), (ServerKind.emby, "api_key"), (ServerKind.plex, "X-Plex-Token"),
    ])
    func tokenNamePerKind(kind: ServerKind, name: String) {
        let streams = [stream(2, "ass"), stream(4, "srt", external: true, path: "/x/4.srt")]
        let keyName = EmbyPaths.tokenName(for: kind)
        #expect(keyName == name)
        let plain = SubtitleFile.from(streams: streams, server: server, key: "K", keyName: keyName)
        #expect(plain.map(\.address.absoluteString) == ["https://s.example/x/4.srt?\(name)=K"])
        let text = SubtitleFile.asPlainText(streams: streams, itemID: "I", source: "S",
                                            server: server, key: "K", keyName: keyName)
        #expect(text.map(\.address.absoluteString) == [
            "https://s.example/Videos/I/S/Subtitles/2/0/Stream.srt?\(name)=K",
            "https://s.example/x/4.srt?\(name)=K",
        ])
    }
}
