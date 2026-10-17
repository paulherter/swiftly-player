import Foundation

/// Which audio and subtitle track is on when playback starts.
///
/// The decision is made from Jellyfin's `MediaStream`s, not from the names in
/// the player; where the track sits in the player is told by ``Spurzuordnung``.
///
/// **Audio, top to bottom:**
/// 1. Chosen by hand, for this series or this movie.
/// 2. The audio language from the app settings, if one is set.
/// 3. The server's default (`DefaultAudioStreamIndex`), which holds what is set
///    as audio language in the Jellyfin profile.
/// 4. Otherwise the file decides.
///
/// **Subtitles, top to bottom:**
/// 1. Chosen by hand, for this series or this movie, including "off". Someone
///    who switches within an episode means the whole series.
/// 2. "Automatic subtitles" on, and the audio is not in the preferred language:
///    the full track in the subtitle language, the ordinary one before the one
///    for the hearing impaired (SDH).
/// 3. The server's default (`DefaultSubtitleStreamIndex`): with "automatic
///    subtitles" any, without it only a forced one. Without a manual choice
///    subtitles are otherwise off, and that stays so.
/// 4. Forced subtitles (`IsForced`), first those in the audio language. They are
///    on without any setting: without them the scene cannot be understood.
/// 5. Otherwise off. **Not** the first track, and not what the file marks as
///    default: VLC used to adopt that silently.
///
/// External subtitle files count everywhere.
public enum TrackRule {

    public enum Subtitle: Equatable, Sendable {
        case off
        /// Jellyfin's `Index`.
        case feed(Int)
    }

    public static func audio(streams: [MediaStream], remembered: TrackImprint?,
                           preferredLanguage: String, serverPreGift: Int?) -> Int? {
        let tracks = streams.filter { $0.type == "Audio" }
        if let remembered, let hit = remembered.bester(under: streams, art: "Audio") {
            return hit.index
        }
        if !preferredLanguage.isEmpty,
           let hit = tracks.first(where: { TrackImprint.languageKey($0.language) == preferredLanguage }) {
            return hit.index
        }
        if let serverPreGift, tracks.contains(where: { $0.index == serverPreGift }) {
            return serverPreGift
        }
        return nil
    }

    /// - Parameters:
    ///   - tonindex: the audio track that is playing; its language decides whether
    ///     automatic subtitles are needed and which forced ones fit.
    ///   - tonwunsch: audio language from the settings, empty means none.
    ///   - wunschsprache: subtitle language from the settings.
    public static func subtitle(streams: [MediaStream], remembered: TrackMemory.Choice?,
                                  serverPreGift: Int?, automatic: Bool,
                                  audioIndex: Int?, tonwunsch: String,
                                  preferredLanguage: String) -> Subtitle {
        let tracks = streams.filter { $0.type == "Subtitle" }
        let forced = tracks.filter { $0.isForced == true }

        switch remembered {
        case .off?:
            return .off
        case .track(let imprint)?:
            if let hit = imprint.bester(under: streams, art: "Subtitle"), let index = hit.index {
                return .feed(index)
            }
            // If it does not exist, the normal case applies instead of "off": the choice
            // was "this language", not "none".
        case .name(let alt)?:
            // Remembered before: only the track name from VLC.
            if let language = Language.detected(in: alt) {
                let matching = tracks.filter { TrackImprint.languageKey($0.language) == language }
                let willForced = Language.soundsForced(alt)
                if let hit = matching.first(where: { ($0.isForced == true) == willForced }) ?? matching.first,
                   let index = hit.index {
                    return .feed(index)
                }
            }
        case nil:
            break
        }

        let audioLong = streams.first { $0.type == "Audio" && $0.index == audioIndex }
            .flatMap { TrackImprint.languageKey($0.language) }

        if automatic, !preferredLanguage.isEmpty {
            // Without an audio preference the subtitle language counts: anyone who wants
            // German subtitles needs them with English audio. If the audio language is
            // unknown, nothing is guessed.
            let should = tonwunsch.isEmpty ? preferredLanguage : tonwunsch
            if let audioLong, audioLong != should {
                let matching = tracks.filter { TrackImprint.languageKey($0.language) == preferredLanguage }
                // The full one before the forced one of the same language: anyone who wants
                // subtitles because they do not understand the audio needs everything. And the
                // ordinary one before the one for the hearing impaired: sound descriptions are
                // only wanted by someone who chooses them explicitly.
                if let full = matching.first(where: { $0.isForced != true && $0.isHearingImpaired != true })
                    ?? matching.first(where: { $0.isForced != true }) ?? matching.first,
                   let index = full.index {
                    return .feed(index)
                }
            }
        }

        if let serverPreGift, serverPreGift >= 0,
           let guideline = tracks.first(where: { $0.index == serverPreGift }),
           automatic || guideline.isForced == true {
            return .feed(serverPreGift)
        }

        if let audioLong,
           let matching = forced.first(where: { TrackImprint.languageKey($0.language) == audioLong }),
           let index = matching.index {
            return .feed(index)
        }
        if let index = forced.first?.index { return .feed(index) }
        return .off
    }
}

/// The track choice made by hand, per series or movie, permanent.
///
/// The key is the series, not the episode: switched off in episode 3 means
/// switched off in episode 4. Jellyfin itself remembers the choice per episode
public struct TrackMemory {
    public enum Choice: Equatable, Sendable {
        case off
        case track(TrackImprint)
        /// Old entry: only the track name.
        case name(String)
    }

    /// The same key as before: there it held track names, empty meant "off". They
    /// stay readable.
    static let subtitleKey = "utJeTitel"
    static let audioKey = "tonJeTitel"
    private let store: UserDefaults

    public init(store: UserDefaults = .standard) { self.store = store }

    public static func title(for item: Item) -> String { item.seriesId ?? item.id }

    public func subtitle(for title: String) -> Choice? { read(Self.subtitleKey, title) }

    public func audio(for title: String) -> TrackImprint? {
        if case .track(let imprint)? = read(Self.audioKey, title) { return imprint }
        return nil
    }

    public func rememberSubtitle(_ choice: Choice, for title: String) {
        write(Self.subtitleKey, title, choice)
    }

    public func rememberAudio(_ imprint: TrackImprint, for title: String) {
        write(Self.audioKey, title, .track(imprint))
    }

    private func read(_ key: String, _ title: String) -> Choice? {
        guard let raw = (store.dictionary(forKey: key) as? [String: String])?[title] else { return nil }
        if raw.isEmpty { return .off }
        if raw.hasPrefix("{"),
           let imprint = try? JSONDecoder().decode(TrackImprint.self, from: Data(raw.utf8)) {
            return .track(imprint)
        }
        return .name(raw)
    }

    private func write(_ key: String, _ title: String, _ choice: Choice) {
        var all = (store.dictionary(forKey: key) as? [String: String]) ?? [:]
        switch choice {
        case .off: all[title] = ""
        case .name(let name): all[title] = name
        case .track(let imprint):
            let data = (try? JSONEncoder().encode(imprint)) ?? Data()
            all[title] = String(decoding: data, as: UTF8.self)
        }
        store.set(all, forKey: key)
    }
}

/// The running tracks as Jellyfin indices, for the start and progress report.
/// Subtitle `-1` means "off".
public struct TrackIndices: Sendable, Equatable {
    public var audio: Int?
    public var subtitle: Int?

    public init(audio: Int? = nil, subtitle: Int? = nil) {
        self.audio = audio; self.subtitle = subtitle
    }
}
