import Foundation

/// **"(Original)" on audio tracks**: the one place that decides whether a track is
/// the original language of the title and how that is written.
///
/// Every screen that lists audio tracks (player menus, the download picker) calls
/// ``label(_:language:stream:originalLanguage:)`` or ``label(for:originalLanguage:)``
/// instead of deciding for itself.
///
/// Two sources, in this order (Jellyfin 12 and later; older servers send neither, and
/// then nothing is shown, never a guess):
/// 1. The track itself says so: `MediaStream.IsOriginal`.
/// 2. The title's `OriginalLanguage` equals the track's language. Both sides may be
///    written as two-letter (`en`), three-letter (`eng`, `ger`/`deu`) code or as a name;
///    they are compared as languages, not as text.
public enum OriginalAudio {

    /// Is this track the title's original language?
    ///
    /// - `language`: the track's language as the player or the server reports it.
    /// - `stream`: the matching server stream, `nil` if there is none.
    /// - `originalLanguage`: `Item.originalLanguage`.
    public static func isOriginal(language: String?, stream: MediaStream?,
                                  originalLanguage: String?) -> Bool {
        if stream?.isOriginal == true { return true }
        guard let wanted = canonical(originalLanguage),
              let own = canonical(language ?? stream?.language) else { return false }
        return wanted == own
    }

    /// `base` with the suffix when the track is the original, otherwise unchanged.
    public static func label(_ base: String, language: String?, stream: MediaStream?,
                             originalLanguage: String?) -> String {
        isOriginal(language: language, stream: stream, originalLanguage: originalLanguage)
            ? base + " " + suffix : base
    }

    /// The server's own short label ("Deutsch · DTS-HD MA 5.1") with the suffix.
    public static func label(for stream: MediaStream, originalLanguage: String?) -> String {
        label(stream.short, language: stream.language, stream: stream,
              originalLanguage: originalLanguage)
    }

    /// "(Original)" in the interface language.
    public static var suffix: String { translated("(Original)") }

    // MARK: Comparing languages

    /// Two-letter code, three-letter codes (bibliographic and terminologic) and
    /// English names of the languages films are commonly made in.
    private static let table: [(two: String, others: [String])] = [
        ("ar", ["ara", "arabic"]), ("bg", ["bul", "bulgarian"]), ("ca", ["cat", "catalan"]),
        ("cs", ["ces", "cze", "czech"]), ("da", ["dan", "danish"]),
        ("de", ["deu", "ger", "german", "deutsch"]), ("el", ["ell", "gre", "greek"]),
        ("en", ["eng", "english"]), ("es", ["spa", "spanish", "español"]),
        ("et", ["est", "estonian"]), ("fa", ["fas", "per", "persian"]),
        ("fi", ["fin", "finnish"]), ("fr", ["fra", "fre", "french", "français"]),
        ("he", ["heb", "hebrew"]), ("hi", ["hin", "hindi"]), ("hr", ["hrv", "croatian"]),
        ("hu", ["hun", "hungarian"]), ("id", ["ind", "indonesian"]),
        ("is", ["isl", "ice", "icelandic"]), ("it", ["ita", "italian", "italiano"]),
        ("ja", ["jpn", "japanese"]), ("ko", ["kor", "korean"]), ("lt", ["lit", "lithuanian"]),
        ("lv", ["lav", "latvian"]), ("ms", ["msa", "may", "malay"]),
        ("nb", ["nob"]), ("nl", ["nld", "dut", "dutch"]), ("no", ["nor", "norwegian", "nob", "nb"]),
        ("pl", ["pol", "polish"]), ("pt", ["por", "portuguese", "português"]),
        ("ro", ["ron", "rum", "romanian"]), ("ru", ["rus", "russian"]),
        ("sk", ["slk", "slo", "slovak"]), ("sl", ["slv", "slovenian"]),
        ("sr", ["srp", "serbian"]), ("sv", ["swe", "swedish"]), ("ta", ["tam", "tamil"]),
        ("te", ["tel", "telugu"]), ("th", ["tha", "thai"]), ("tr", ["tur", "turkish"]),
        ("uk", ["ukr", "ukrainian"]), ("vi", ["vie", "vietnamese"]),
        ("zh", ["zho", "chi", "cmn", "yue", "chinese", "mandarin", "cantonese"]),
    ]

    private static let lookup: [String: String] = {
        var result: [String: String] = [:]
        for row in table {
            result[row.two] = row.two
            for other in row.others where result[other] == nil { result[other] = row.two }
        }
        // Norwegian Bokmål counts as Norwegian.
        result["nb"] = "no"; result["nob"] = "no"
        return result
    }()

    /// The two-letter code for any spelling of a language, the lowercase text itself
    /// for a language not in the table, `nil` for "no language" (empty, `und`, `zxx`,
    /// `mul`).
    static func canonical(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty
        else { return nil }
        // "pt-BR", "zh_CN": the language part only.
        if let cut = text.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            text = String(text[..<cut])
        }
        if ["und", "unk", "zxx", "mul", "mis", "unknown", "undetermined"].contains(text) { return nil }
        return lookup[text] ?? text
    }
}
