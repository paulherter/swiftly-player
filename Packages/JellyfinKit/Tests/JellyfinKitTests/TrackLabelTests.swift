import Foundation
import Testing
@testable import JellyfinKit

@Suite("Spurnamen")
struct TrackLabelTests {
    let de = Locale(identifier: "de_DE")
    let en = Locale(identifier: "en_US")
    let ru = Locale(identifier: "ru_RU")

    private func subtitle(_ language: String?, title: String? = nil, codec: String? = "subrip",
                          forced: Bool = false, hearingImpaired: Bool = false,
                          external: Bool = false) -> MediaStream {
        MediaStream(codec: codec, type: "Subtitle", language: language,
                    displayTitle: "server words - [\(language ?? "")]",
                    channels: nil, isDefault: false, index: 3, height: nil, width: nil,
                    isForced: forced, isExternal: external, title: title,
                    isHearingImpaired: hearingImpaired)
    }

    @Test("Sprache in der Sprache der Oberfläche, am Anfang groß")
    func languageInInterfaceLanguage() {
        #expect(TrackLabel.language("rus", locale: ru) == "Русский")
        #expect(TrackLabel.language("eng", locale: ru) == "Английский")
        #expect(TrackLabel.language("ger", locale: en) == "German")
        #expect(TrackLabel.language("deu", locale: de) == "Deutsch")
        #expect(TrackLabel.language("ru", locale: de) == "Russisch")
    }

    @Test("Ausgeschriebene Namen werden übersetzt, nicht durchgereicht")
    func writtenOutNames() {
        // libVLC 3 on Windows reports the name, not the code; it showed "Russian" in a
        // Russian interface.
        #expect(TrackLabel.language("Russian", locale: ru) == "Русский")
        #expect(TrackLabel.language("German", locale: en) == "German")
        #expect(TrackLabel.language("русский", locale: de) == "Russisch")
        #expect(TrackLabel.language("English", locale: de) == "Englisch")
    }

    @Test("Unbekanntes bleibt sichtbar, ohne Sprache gibt es nichts")
    func unknownLanguage() {
        #expect(TrackLabel.language("und", locale: en) == translated("unbekannt"))
        #expect(TrackLabel.language("qaa", locale: en) == "QAA")
        #expect(TrackLabel.language("", locale: en) == nil)
        #expect(TrackLabel.language(nil, locale: en) == nil)
    }

    @Test("Tonspur: Sprache, Codec, Kanäle")
    func audio() {
        #expect(TrackLabel.audio(language: "rus", codec: "AC-3", channels: 2, locale: ru)
                == "Русский · AC-3 · Stereo")
        #expect(TrackLabel.audio(language: "Russian", codec: "E-AC-3", channels: 6, locale: en)
                == "Russian · E-AC-3 · 5.1")
        #expect(TrackLabel.audio(language: nil, codec: "AAC", channels: 2, locale: de) == "AAC · Stereo")
        #expect(TrackLabel.audio(language: nil, codec: nil, channels: 0, locale: de) == nil)
    }

    @Test("Untertitel im selben Aufbau wie der Ton, nie mit DisplayTitle")
    func subtitleStructure() {
        let forced = translated("Erzwungen"), file = translated("Datei")
        #expect(TrackLabel.subtitle(subtitle("rus", codec: "ass"), locale: ru) == "Русский · ASS")
        #expect(TrackLabel.subtitle(subtitle("eng", title: "English [Forced]", forced: true), locale: en)
                == "English · \(forced) · SRT")
        #expect(TrackLabel.subtitle(subtitle("eng", external: true), locale: de)
                == "Englisch · SRT · \(file)")
        let sdh = TrackLabel.subtitle(subtitle("ger", title: "SDH", hearingImpaired: true), locale: de)
        #expect(sdh == "Deutsch · \(translated("Hörgeschädigt")) · SRT")
        #expect(TrackLabel.subtitle(subtitle("rus"), locale: ru)?.contains("server") == false)
    }

    @Test("Ein Spurtitel bleibt nur, wenn er etwas hinzufügt")
    func extraTitle() {
        #expect(TrackLabel.extraTitle("Forced - [Russian]") == nil)
        #expect(TrackLabel.extraTitle("Русский") == nil)
        #expect(TrackLabel.extraTitle("English [Forced]") == nil)
        #expect(TrackLabel.extraTitle("Deutsch SDH") == nil)
        #expect(TrackLabel.extraTitle("en.forced") == nil)
        #expect(TrackLabel.extraTitle("Commentary") == "Commentary")
        #expect(TrackLabel.extraTitle("Signs & Songs") == "Signs & Songs")
        #expect(TrackLabel.extraTitle("Надписи") == "Надписи")
        #expect(TrackLabel.extraTitle("  ") == nil)
        #expect(TrackLabel.subtitle(subtitle("eng", title: "Commentary"), locale: en)
                == "English · Commentary · SRT")
    }

    @Test("Gleiche Namen werden durchnummeriert, eindeutige bleiben")
    func distinct() {
        #expect(TrackLabel.distinct(["English · SRT", "Русский · ASS", "English · SRT"])
                == ["English · SRT · 1", "Русский · ASS", "English · SRT · 2"])
        #expect(TrackLabel.distinct(["Deutsch · PGS"]) == ["Deutsch · PGS"])
        #expect(TrackLabel.distinct([]) == [])
    }

    @Test("Ohne Sprache und Titel entscheidet der Player")
    func subtitleWithoutLanguage() {
        #expect(TrackLabel.subtitle(subtitle(nil), locale: en) == nil)
        #expect(TrackLabel.subtitle(subtitle(nil, title: "Signs"), locale: en) == "Signs · SRT")
        let bare = PlayerTrack(identifier: "spu/2", name: "Track 1", language: nil, codec: "SRT", channels: nil)
        #expect(TrackLabel.subtitle(bare, locale: en) == nil)
        let known = PlayerTrack(identifier: "spu/3", name: "Forced - [Russian]", language: "rus",
                                codec: "ASS", channels: nil)
        #expect(TrackLabel.subtitle(known, locale: ru) == "Русский · \(translated("Erzwungen")) · ASS")
    }
}
