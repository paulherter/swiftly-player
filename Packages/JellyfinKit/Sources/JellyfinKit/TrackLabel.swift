import Foundation

/// **How an audio or subtitle track is named in a list: one rule for every platform.**
///
/// The player's track list mixed three styles in one column: audio built here
/// ("русский · AC-3 · Stereo", the language in lower case because that is how Russian
/// writes it inside a sentence), subtitles with VLC's raw name ("Forced - [Russian]") and
/// side-loaded files built a third way. On Linux and Windows the languages were not even
/// translated, because `Locale.current` there is not the language of the interface.
///
/// The order is always the same: language, then what tells two tracks of that language
/// apart, then the format. Audio: "Russian · AC-3 · 5.1". Subtitles: "English · Forced ·
/// SRT · File".
public enum TrackLabel {

    /// The words between the parts.
    static let separator = " · "

    // MARK: Locale

    /// **The locale of the interface, not of the system.**
    ///
    /// On Apple the system already hands each app the language it runs in. On Linux and
    /// Windows `Locale.current` comes from the environment: Windows reports `en-001`
    /// regardless of its display language, so a Russian interface showed "Russian" and
    /// "0.00 s". There the language the catalog picked (``TextCatalog``) is the truth.
    ///
    /// If the system's language is the interface's, the system locale is kept: it also
    /// carries the region, and with it the user's own decimal separator.
    public static let displayLocale: Locale = {
        #if canImport(Darwin)
        let language = Bundle.module.preferredLocalizations.first ?? "en"
        #else
        let language = packageCatalog.language
        #endif
        let system = Locale.current.identifier
            .split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init)
        return system == language ? .current : Locale(identifier: language)
    }()

    // MARK: Language

    /// Codes a file carries when nobody set a language: `und` is "undetermined", `mis`
    /// "miscellaneous", `zxx` "no linguistic content". None of them is a language.
    static let undetermined: Set<String> = ["und", "unknown", "unbekannt", "mis", "zxx"]

    /// **A track's language as a list entry: in the interface's language, capitalised.**
    ///
    /// Files and players report "rus", "ru", "Russian" or "русский"; all of them become
    /// "Русский" in Russian and "Russian" in English. An ISO code is looked up directly; a
    /// written-out name goes through ``Language/detected(in:)`` to its code first, because
    /// `Locale` knows codes only.
    ///
    /// **Capitalised because it starts the entry.** Russian writes language names in
    /// lower case inside a sentence, and `Locale` returns that form; at the start of a row
    /// it reads like a typo next to "English" and "Deutsch". Only the first letter changes,
    /// so "Norwegian Bokmål" keeps its spelling.
    ///
    /// Something unknown is shown rather than dropped, an unknown code in capitals ("QAA")
    /// so it reads as a code: it may still mean something to the person who made the file.
    public static func language(_ raw: String?, locale: Locale = displayLocale) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        if undetermined.contains(raw.lowercased()) { return capitalised(translated("unbekannt")) }
        let name = looksLikeCode(raw)
            ? locale.localizedString(forLanguageCode: raw.lowercased())
            : Language.detected(in: raw).flatMap(code(of:))
                .flatMap { locale.localizedString(forLanguageCode: $0) }
        if let name { return capitalised(name) }
        return looksLikeCode(raw) ? raw.uppercased() : capitalised(raw)
    }

    /// "ru", "rus", "pt-BR": a code, not a word. A word goes through the language table.
    static func looksLikeCode(_ text: String) -> Bool {
        let parts = text.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard let first = parts.first, (2...3).contains(first.count) else { return false }
        return text.allSatisfy { ($0.isASCII && $0.isLetter) || $0 == "-" || $0 == "_" }
            && parts.dropFirst().allSatisfy { $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
    }

    /// The ISO code behind a name from ``Language/all``: the first short form `Locale`
    /// resolves. The table lists spellings, not codes, and asking `Locale` keeps it that
    /// way instead of maintaining a second column.
    static func code(of name: String) -> String? {
        guard let entry = Language.all.first(where: { $0.name == name }) else { return nil }
        let probe = Locale(identifier: "en")
        return entry.shape.first { form in
            (2...3).contains(form.count) && looksLikeCode(form)
                && probe.localizedString(forLanguageCode: form) != nil
        }
    }

    static func capitalised(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    // MARK: Audio

    /// "Russian · AC-3 · 5.1": language, codec, channel layout, as far as known.
    ///
    /// `codec` is already in the spelling of ``TechDetails/codecNameValue(_:)``; the caller
    /// knows whether it came from the server or from libVLC.
    public static func audio(language raw: String?, codec: String?, channels: Int?,
                             locale: Locale = displayLocale) -> String? {
        let parts = [language(raw, locale: locale), codec, TechDetails.channelWord(channels)]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    // MARK: Subtitles

    /// A subtitle the server knows: "English · Forced · SRT · File".
    ///
    /// **Built from the structured fields, never from `DisplayTitle`.** The server's
    /// display title repeats language and flags in the server's language and its own
    /// order ("English [Forced] - [English]", "Forced - [Russian]"), so the same list
    /// showed some tracks in its style and others in ours. The file's own `Title` is
    /// kept where it says something those fields cannot, such as "Commentary" or
    /// "Signs & Songs" (``extraTitle(_:)``).
    ///
    /// `nil` if the server knows neither a language nor a title; the caller then shows
    /// the player's own name, which is all there is.
    public static func subtitle(_ feed: MediaStream, locale: Locale = displayLocale) -> String? {
        subtitle(language: feed.language, title: feed.title,
                 codec: TechDetails.codecNameValue(feed.codec),
                 forced: feed.isForced == true,
                 hearingImpaired: feed.isHearingImpaired == true,
                 external: feed.isExternal == true, locale: locale)
    }

    /// A subtitle only the player knows (no matching `MediaStream`): language and format
    /// from libVLC, "Forced" guessed from the name as ``TrackRule`` does.
    ///
    /// `nil` without a language: "SRT" alone says less than the player's "Track 1".
    public static func subtitle(_ track: PlayerTrack, locale: Locale = displayLocale) -> String? {
        guard language(track.language, locale: locale) != nil else { return nil }
        return subtitle(language: track.language, title: nil, codec: track.codec,
                        forced: Language.soundsForced(track.name), hearingImpaired: false,
                        external: track.additionId != nil, locale: locale)
    }

    static func subtitle(language raw: String?, title: String?, codec: String?,
                         forced: Bool, hearingImpaired: Bool, external: Bool,
                         locale: Locale) -> String? {
        let languageWord = language(raw, locale: locale)
        let extra = extraTitle(title)
        guard languageWord != nil || extra != nil else { return nil }
        let parts: [String?] = [
            languageWord,
            extra,
            forced ? translated("Erzwungen") : nil,
            hearingImpaired ? translated("Hörgeschädigt") : nil,
            codec,
            external ? translated("Datei") : nil,
        ]
        return parts.compactMap { $0 }.joined(separator: separator)
    }

    /// **Equal names get a running number**: "English · SRT · 1", "English · SRT · 2".
    ///
    /// Two tracks the fields cannot tell apart (same language, same format, no title)
    /// would otherwise be two identical rows. VLC's names used to differ by "Track 1" and
    /// "Track 2"; the number keeps that distinction without bringing its style back.
    /// Names that are unique stay untouched.
    public static func distinct(_ labels: [String]) -> [String] {
        var seen: [String: Int] = [:]
        let counts = Dictionary(labels.map { ($0, 1) }, uniquingKeysWith: +)
        return labels.map { label in
            guard let count = counts[label], count > 1 else { return label }
            let number = (seen[label] ?? 0) + 1
            seen[label] = number
            return label + separator + "\(number)"
        }
    }

    /// Words a track title repeats from the structured fields: flags, formats and the
    /// generic word for subtitles, in the languages of the interface.
    static let repeatedWords: Set<String> = [
        "forced", "erzwungen", "форсированные", "принудительные",
        "sdh", "cc", "hi", "hörgeschädigt", "default", "standard", "full", "полные",
        "subtitle", "subtitles", "sub", "subs", "untertitel", "субтитры",
        "srt", "subrip", "ass", "ssa", "pgs", "vobsub", "webvtt", "vtt",
    ]

    /// **The track title, only if it adds something.**
    ///
    /// Most titles only repeat what the row already says ("Forced", "English", "Русский
    /// [SDH]"), and repeating it is what made rows long enough to truncate. A title is
    /// kept if, after dropping language names and the ``repeatedWords``, a word remains:
    /// "Commentary", "Signs & Songs". It is then shown as written, since it is the file
    /// author's wording.
    static func extraTitle(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        let words = title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let remaining = words.filter { word in
            !repeatedWords.contains(word) && Language.detected(in: word) == nil
                && !looksLikeLanguageCode(word)
        }
        return remaining.isEmpty ? nil : title
    }

    /// "en", "ru": a bare code in a title such as "en.forced".
    private static func looksLikeLanguageCode(_ word: String) -> Bool {
        (2...3).contains(word.count) && looksLikeCode(word)
            && Locale(identifier: "en").localizedString(forLanguageCode: word) != nil
    }
}
