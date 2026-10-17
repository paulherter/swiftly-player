import Foundation

/// The languages offered for preselection, with the spellings under which they
/// appear in track names.
///
/// A plain table, hence outside the model: bound to the main actor, it could not
/// be read from a view without a detour.
public enum Language {
    /// The languages to choose from, with the spellings under which they appear in
    /// track names. Depending on the file, VLC reports "German", "Deutsch" or
    /// "ger"; comparing against a single name would fall short.
    public static let all: [(name: String, shape: [String])] = [
        // The six most used here first; the rest alphabetically. Before, only these
        // six were offered, and anyone speaking Polish or Portuguese could not set the
        // subtitle language.
        ("Deutsch", ["deutsch", "german", "ger", "deu"]),
        ("English", ["english", "eng", "en"]),
        ("Français", ["français", "french", "fre", "fra"]),
        ("Español", ["español", "spanish", "spa", "esp"]),
        ("Italiano", ["italiano", "italian", "ita"]),
        ("日本語", ["japanese", "jpn", "japanisch"]),
        // **Short forms only where they are not an ordinary word.** "no" for
        // Norwegian or "is" for Icelandic would appear in every other track name
        // ("No subtitles", "This is forced") and match wrongly; there it stays with
        // the three-letter form.
        ("العربية", ["arabic", "ara", "arabisch"]),
        ("Български", ["bulgarian", "bul", "bulgarisch"]),
        ("Català", ["català", "catalan", "cat", "katalanisch"]),
        ("Čeština", ["čeština", "cestina", "czech", "cze", "ces", "tschechisch"]),
        ("Dansk", ["dansk", "danish", "dan", "dänisch", "daenisch"]),
        ("Ελληνικά", ["ελληνικά", "greek", "gre", "ell", "griechisch"]),
        ("עברית", ["hebrew", "heb", "hebräisch", "hebraeisch"]),
        ("हिन्दी", ["hindi", "hin"]),
        ("Hrvatski", ["hrvatski", "croatian", "hrv", "kroatisch"]),
        ("Indonesia", ["indonesia", "indonesian", "ind", "indonesisch"]),
        ("Magyar", ["magyar", "hungarian", "hun", "ungarisch"]),
        ("Nederlands", ["nederlands", "dutch", "dut", "nld", "niederländisch",
                        "niederlaendisch"]),
        ("Norsk", ["norsk", "norwegian", "nor", "nob", "norwegisch"]),
        ("Polski", ["polski", "polish", "pol", "polnisch"]),
        ("Português", ["português", "portugues", "portuguese", "por",
                       "portugiesisch"]),
        ("Română", ["română", "romana", "romanian", "rum", "ron", "rumänisch",
                    "rumaenisch"]),
        ("Русский", ["русский", "russian", "rus", "russisch"]),
        ("Slovenčina", ["slovenčina", "slovencina", "slovak", "slo", "slk",
                        "slowakisch"]),
        ("Slovenščina", ["slovenščina", "slovenscina", "slovenian", "slv",
                         "slowenisch"]),
        ("Suomi", ["suomi", "finnish", "fin", "finnisch"]),
        ("Svenska", ["svenska", "swedish", "swe", "schwedisch"]),
        ("ไทย", ["thai", "tha"]),
        ("Türkçe", ["türkçe", "turkce", "turkish", "tur", "türkisch",
                    "tuerkisch"]),
        ("Українська", ["українська", "ukrainian", "ukr", "ukrainisch"]),
        ("Tiếng Việt", ["tiếng việt", "vietnamese", "vie", "vietnamesisch"]),
        ("中文", ["chinese", "chi", "zho", "zh", "chinesisch",
                 "mandarin", "cantonese"]),
        ("한국어", ["korean", "kor", "koreanisch"]),
    ]

    /// Does the track name match the wanted language?
    public static func fits(_ trackName: String, toward language: String) -> Bool {
        !language.isEmpty && detected(in: trackName) == language
    }

    /// The recognized display name ("Deutsch") if one of the stored languages
    /// appears in the text, otherwise `nil` rather than a guess.
    ///
    /// Word by word, not as a substring. With `contains`, "Slovenian" counted as
    /// English because it contains "en", and "Armenian" too. Short forms like "en"
    /// or "ger" are language codes and stand alone in a track name; long forms
    /// like "deutsch" may also sit inside a compound name ("Deutsch (Kommentar)").
    public static func detected(in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let small = text.lowercased()
        let words = Set(small.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return all.first { entryRecord in
            entryRecord.shape.contains { form in
                words.contains(form) || (form.count > 3 && small.contains(form))
            }
        }?.name
    }

    /// Does the track name say that only the foreign-language parts are subtitled?
    /// Only for tracks the server knows nothing about.
    public static func soundsForced(_ name: String) -> Bool {
        let small = name.lowercased()
        return ["forced", "erzwungen"].contains { small.contains($0) }
    }
}
