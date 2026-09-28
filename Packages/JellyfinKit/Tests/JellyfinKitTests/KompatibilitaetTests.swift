import Foundation
import Testing
@testable import JellyfinKit

/// Befunde aus den Testdateien der Kompatibilitätsrunde 2 (25.09.2026).
@Suite("Kompatibilität: Anamorph, Laufzeit, Ablehnung, Container")
struct KompatibilitaetTests {

    // MARK: Anamorph

    @Test("Verdrehtes Pixelverhältnis von VLC 4 wird erkannt (PAL 16:9, gemessen 45:64)")
    func verdreht() {
        #expect(Seitenverhaeltnis.korrektur(sar: (45, 64), breite: 720, hoehe: 576, anzeige: "16:9") == "16:9")
    }

    @Test("Richtig gelesenes Bild bleibt unangetastet — VLC 3 und MP4 melden 64:45")
    func richtig() {
        #expect(Seitenverhaeltnis.korrektur(sar: (64, 45), breite: 720, hoehe: 576, anzeige: "16:9") == nil)
        // VLC 3 kürzt nicht: 9216:6480 ist dasselbe.
        #expect(Seitenverhaeltnis.korrektur(sar: (9216, 6480), breite: 720, hoehe: 576, anzeige: "16:9") == nil)
    }

    @Test("Quadratische Pixel, fehlende oder unlesbare Angaben: nichts tun")
    func nichtsZuTun() {
        #expect(Seitenverhaeltnis.korrektur(sar: (1, 1), breite: 1920, hoehe: 1080, anzeige: "16:9") == nil)
        #expect(Seitenverhaeltnis.korrektur(sar: (45, 64), breite: 720, hoehe: 576, anzeige: nil) == nil)
        #expect(Seitenverhaeltnis.korrektur(sar: (45, 64), breite: 720, hoehe: 576, anzeige: "breit") == nil)
        #expect(Seitenverhaeltnis.korrektur(sar: (0, 0), breite: 720, hoehe: 576, anzeige: "16:9") == nil)
        // Ein anderes, aber nicht verdrehtes Verhältnis ist nicht dieser Fehler.
        #expect(Seitenverhaeltnis.korrektur(sar: (16, 15), breite: 720, hoehe: 576, anzeige: "16:9") == nil)
    }

    // MARK: Laufzeit

    @Test("RunTimeTicks der Quelle wird gelesen — Ersatz, wenn VLC bei TS keine Länge nennt")
    func laufzeit() throws {
        let json = #"{"Id":"a","Container":"ts","RunTimeTicks":606580000,"SupportsDirectPlay":true}"#
        let quelle = try JSONDecoder().decode(MediaSource.self, from: Data(json.utf8))
        #expect(quelle.laufzeitSekunden == 60.658)
        let ohne = try JSONDecoder().decode(MediaSource.self, from: Data(#"{"Id":"a"}"#.utf8))
        #expect(ohne.laufzeitSekunden == nil)
    }

    // MARK: Ablehnung

    private func plan(_ json: String) throws -> PlaybackPlan? {
        let antwort = try JSONDecoder().decode(PlaybackInfoResponse.self, from: Data(json.utf8))
        return try PlaybackPlan.make(from: antwort, itemID: "x", profile: .vlc(),
                                     streamURL: { _, _, _ in URL(string: "http://s/x")! },
                                     serverBase: URL(string: "http://s")!)
    }

    @Test("Lehnt der Server mit Grund ab, kommt der Grund an — kein leerer Plan")
    func abgelehnt() throws {
        #expect(throws: JellyfinError.self) { try plan(#"{"MediaSources":[],"ErrorCode":"NoCompatibleStream"}"#) }
        // Auch ohne Quellenliste: vorher „Antwort unverständlich".
        #expect(throws: JellyfinError.self) { try plan(#"{"ErrorCode":"NotAllowed"}"#) }
        // Ohne Grund bleibt es beim leeren Plan wie bisher.
        #expect(try plan(#"{"MediaSources":[]}"#) == nil)
        for grund in ["NotAllowed", "NoCompatibleStream", "RateLimitExceeded", "Neu"] {
            #expect(!lesbarerFehler(JellyfinError.wiedergabeAbgelehnt(grund)).isEmpty)
        }
    }

    /// Umwandeln fürs Konto verboten, Datei nicht direkt abspielbar: der
    /// Server nennt die Quelle, aber keine `TranscodingUrl`
    /// (`MediaInfoHelper`: `SupportsTranscoding = false`). Für libVLC ist die
    /// Originaldatei der richtige Weg — sie läuft, statt Schwarzbild.
    @Test("Umwandeln verboten: die Originaldatei wird gespielt")
    func umwandelnVerboten() throws {
        let p = try #require(try plan(#"{"MediaSources":[{"Id":"q","Container":"ogg","SupportsDirectPlay":false,"SupportsDirectStream":false,"SupportsTranscoding":false}],"PlaySessionId":"s"}"#))
        #expect(p.method == .directPlay)
        #expect(p.url.absoluteString == "http://s/x")
    }

    @Test("Mit TranscodingUrl spielt die Umwandlung — der Rückfall aus „Immer Direct Play“ heraus")
    func umwandlung() throws {
        let p = try #require(try plan(#"{"MediaSources":[{"Id":"q","Container":"mkv","SupportsDirectPlay":false,"SupportsTranscoding":true,"TranscodingUrl":"/videos/x/master.m3u8?MediaSourceId=q"}],"PlaySessionId":"s"}"#))
        #expect(p.method == .transcode)
        #expect(p.url.absoluteString == "http://s/videos/x/master.m3u8?MediaSourceId=q")
    }

    // MARK: Container

    @Test("Ogg-Video (Jellyfin: „ogg“) ist Direct Play")
    func ogg() {
        #expect(DeviceProfile.vlc().directPlayProfiles.contains { $0.container == "ogg" && $0.type == "Video" })
    }
}
