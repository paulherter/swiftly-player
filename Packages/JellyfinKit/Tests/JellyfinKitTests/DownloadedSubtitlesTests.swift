import Foundation
import Testing
@testable import JellyfinKit

/// What a download remembers about its subtitles (`<file>.untertitel/info.json`, the same shape the Rust UIs write), and the
/// track list a stored title is opened with.
@Suite("Untertitel im Download")
struct DownloadedSubtitlesTests {

    private func stream(_ index: Int, _ type: String, codec: String, language: String? = nil, title: String? = nil,
                        external: Bool = false, forced: Bool = false, address: String? = nil) -> MediaStream {
        MediaStream(codec: codec, type: type, language: language, displayTitle: nil, channels: nil, isDefault: nil,
                    index: index, height: nil, width: nil, isForced: forced, isExternal: external, title: title,
                    deliveryUrl: address)
    }

    private var served: [MediaStream] {
        [
            stream(0, "Video", codec: "h264"),
            stream(1, "Audio", codec: "aac", language: "eng"),
            stream(2, "Subtitle", codec: "subrip", language: "eng", title: "English (SRT)", external: true,
                   address: "/Videos/x/q/Subtitles/2/0/Stream.srt?ApiKey=secret"),
            stream(3, "Subtitle", codec: "ass", language: "deu", external: true,
                   address: "/Videos/x/q/Subtitles/3/0/Stream.ass"),
            stream(4, "Subtitle", codec: "subrip", language: "eng"),
            stream(5, "Subtitle", codec: "hdmv_pgs_subtitle", language: "deu", forced: true),
        ]
    }

    private func folder(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dlsubs-\(tag)-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Gespeichert werden die geladenen Dateien und die Spuren, die in der Datei bleiben, nie eine Adresse")
    func factsOfADownload() throws {
        let kept = DownloadedSubtitles.facts(streams: served, fetched: [2, 3], embeddedStay: true)
        #expect(kept.map(\.index) == [2, 3, 4, 5])
        #expect(kept.map { $0.embedded == true } == [false, false, true, true])
        #expect(kept[1].language == "deu" && kept[3].forced)
        let built = DownloadedSubtitles.facts(streams: served, fetched: [2, 3, 4], embeddedStay: false)
        #expect(built.map(\.index) == [2, 3, 4], "a built file holds no text track: only the fetched files")
        let missed = DownloadedSubtitles.facts(streams: served, fetched: [3], embeddedStay: true)
        #expect(missed.map(\.index) == [3, 4, 5], "a file that was not fetched is not listed")
        let text = String(data: try JSONEncoder().encode(kept), encoding: .utf8) ?? ""
        #expect(!text.contains("http") && !text.contains("secret") && !text.contains("Subtitles/"))
    }

    @Test("Die Spurliste eines gespeicherten Titels: Dateien und eingebettete Spuren, je einmal, mit den Namen wie online")
    func listOfAStoredTitle() throws {
        let dir = folder("list")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("2.srt"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("3.ass"))
        DownloadedSubtitles.write(DownloadedSubtitles.facts(streams: served, fetched: [2, 3], embeddedStay: true), to: dir)
        let list = DownloadedSubtitles.streams(in: dir)
        #expect(list.compactMap(\.index) == [2, 3, 4, 5])
        #expect(list.allSatisfy { $0.type == "Subtitle" })
        #expect(list.map { $0.isExternal == true } == [true, true, false, false], "only the files are loaded by the player")
        #expect(list[0].language == "eng" && list[0].title == "English (SRT)" && list[0].codec == "subrip")
        #expect(list[3].isForced == true)
        let english = Locale(identifier: "en")
        let names = list.map { TrackLabel.subtitle($0, locale: english) ?? "—" }
        #expect(names[0].hasPrefix("English") && names[0].contains("SRT"))
        #expect(names[1].hasPrefix("German") && names[1].contains("ASS"))
        #expect(Set(names).count == names.count)
    }

    @Test("Ein alter Download ohne info.json: die Dateien im Ordner, das Format aus der Endung")
    func oldDownloadWithoutSidecar() throws {
        let dir = folder("old")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("2.srt"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("7.vtt"))
        let list = DownloadedSubtitles.streams(in: dir)
        #expect(list.compactMap(\.index) == [2, 7])
        #expect(list.map(\.codec) == ["subrip", "webvtt"])
        #expect(list.allSatisfy { $0.isExternal == true })
        #expect(list.allSatisfy { !($0.displayTitle ?? "").isEmpty }, "a row without language still has a name")
        #expect(DownloadedSubtitles.streams(in: dir.appendingPathComponent("missing")).isEmpty)
    }

    @Test("info.json der Rust-Oberflaechen (snake_case, ohne eingebettet) wird gelesen")
    func rustShape() throws {
        let dir = folder("rust")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("3.srt"))
        let json = #"[{"index":3,"language":"deu","title":"Signs","codec":"subrip","forced":true,"hearing_impaired":true}]"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("info.json"))
        let only = try #require(DownloadedSubtitles.streams(in: dir).first)
        #expect((only.language, only.title, only.isForced, only.isHearingImpaired) == ("deu", "Signs", true, true))
        // And what this side writes keeps the same keys.
        DownloadedSubtitles.write([SubtitleSidecar(index: 3, language: "deu", hearingImpaired: true)], to: dir)
        let written = try String(contentsOf: dir.appendingPathComponent("info.json"), encoding: .utf8)
        #expect(written.contains("\"hearing_impaired\":true") && written.contains("\"index\":3"))
    }

    @Test("Die Beschreibung der Datei: Laufzeit und Untertitel, sonst leer")
    func sourceOfAFile() throws {
        let dir = folder("source")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(DownloadedSubtitles.source(runtimeTicks: nil, folder: dir) == nil)
        try Data("x".utf8).write(to: dir.appendingPathComponent("2.srt"))
        DownloadedSubtitles.write(DownloadedSubtitles.facts(streams: served, fetched: [2], embeddedStay: true), to: dir)
        let source = try #require(DownloadedSubtitles.source(runtimeTicks: 600_000_000, folder: dir))
        #expect(source.runTimeTicks == 600_000_000)
        #expect((source.mediaStreams ?? []).compactMap(\.index) == [2, 4, 5])
        #expect(DownloadedSubtitles.source(runtimeTicks: 600_000_000, folder: folder("none"))?.mediaStreams?.isEmpty != false)
    }
}
