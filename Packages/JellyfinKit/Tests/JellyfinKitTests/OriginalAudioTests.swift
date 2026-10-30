import Foundation
import Testing
@testable import JellyfinKit

@Suite("Original audio label")
struct OriginalAudioTests {

    private func stream(_ language: String?, original: Bool? = nil) -> MediaStream {
        MediaStream(codec: "eac3", type: "Audio", language: language, displayTitle: nil,
                    channels: 6, isDefault: nil, index: 1, height: nil, width: nil,
                    isOriginal: original)
    }

    @Test("the stream's own flag wins, whatever the languages say")
    func streamFlag() {
        #expect(OriginalAudio.isOriginal(language: "ger", stream: stream("ger", original: true),
                                         originalLanguage: "en"))
    }

    @Test("two-letter and three-letter codes are the same language")
    func codesCompare() {
        for (track, original) in [("eng", "en"), ("ger", "de"), ("deu", "de"), ("fre", "fr"),
                                  ("fra", "fr"), ("jpn", "ja"), ("zho", "zh"), ("chi", "zh"),
                                  ("English", "en"), ("pt-BR", "por"), ("nob", "no")] {
            #expect(OriginalAudio.isOriginal(language: track, stream: nil, originalLanguage: original),
                    "\(track) vs \(original)")
        }
    }

    @Test("another language, no source and no language are no original")
    func noLabel() {
        #expect(!OriginalAudio.isOriginal(language: "ger", stream: stream("ger", original: false),
                                          originalLanguage: "en"))
        #expect(!OriginalAudio.isOriginal(language: "ger", stream: nil, originalLanguage: nil))
        #expect(!OriginalAudio.isOriginal(language: nil, stream: nil, originalLanguage: "en"))
        #expect(!OriginalAudio.isOriginal(language: "und", stream: nil, originalLanguage: "und"))
        #expect(!OriginalAudio.isOriginal(language: "eng", stream: nil, originalLanguage: ""))
    }

    @Test("a language outside the table compares by its own code")
    func unknownLanguage() {
        #expect(OriginalAudio.isOriginal(language: "ben", stream: nil, originalLanguage: "ben"))
        #expect(!OriginalAudio.isOriginal(language: "ben", stream: nil, originalLanguage: "en"))
    }

    @Test("the suffix is appended once, only for the original")
    func labelText() {
        let original = OriginalAudio.label("English · AAC", language: "eng", stream: nil,
                                           originalLanguage: "en")
        #expect(original.hasPrefix("English · AAC "))
        #expect(original.contains("Original"))
        #expect(OriginalAudio.label("Deutsch · AAC", language: "ger", stream: nil,
                                    originalLanguage: "en") == "Deutsch · AAC")
        #expect(OriginalAudio.label(for: stream("jpn"), originalLanguage: "ja").contains("Original"))
    }

    @Test("both fields decode when present and stay nil on older servers")
    func decoding() throws {
        let new = Data(#"{"Id":"1","Name":"x","Type":"Movie","OriginalLanguage":"ja"}"#.utf8)
        #expect(try JSONDecoder().decode(Item.self, from: new).originalLanguage == "ja")
        let old = Data(#"{"Id":"1","Name":"x","Type":"Movie"}"#.utf8)
        #expect(try JSONDecoder().decode(Item.self, from: old).originalLanguage == nil)
        let s = Data(#"{"Type":"Audio","Index":1,"IsOriginal":true}"#.utf8)
        #expect(try JSONDecoder().decode(MediaStream.self, from: s).isOriginal == true)
        let s2 = Data(#"{"Type":"Audio","Index":1}"#.utf8)
        #expect(try JSONDecoder().decode(MediaStream.self, from: s2).isOriginal == nil)
    }
}
