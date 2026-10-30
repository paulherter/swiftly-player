import Foundation

/// **Which audio a download carries.**
///
/// Until now a download was the original file with every audio track in it, which is
/// what ``DownloadItem/audioIndex`` being `nil` still means. A file with six
/// languages is mostly sound nobody listens to, so whoever wants one language can ask
/// for exactly that: the server then builds the file with the picture copied and only
/// the chosen track in it (`JellyfinClient.downloadURL(itemID:mediaSourceID:quality:audioStreamIndex:)`).
public enum DownloadAudioChoice: Hashable, Sendable {
    /// The original file, every track.
    case all
    /// Exactly this stream index. For a single title (a film).
    case track(Int)
    /// The track in this language (``TrackImprint/languageKey(_:)``). For a selection
    /// of episodes, where the same language has a different index in every file.
    case language(String)
}

public struct DownloadAudioOption: Identifiable, Hashable, Sendable {
    public let choice: DownloadAudioChoice
    public let label: String
    public var id: DownloadAudioChoice { choice }
}

public enum DownloadAudio {

    static func tracks(_ streams: [MediaStream]) -> [MediaStream] {
        streams.filter { $0.type == "Audio" && $0.index != nil }
    }

    /// **Whether to ask at all.** One track has nothing to choose from.
    public static func offered(streams: [MediaStream]) -> Bool {
        tracks(streams).count > 1
    }

    /// **Whether a selection of files offers a choice**: at least one of them holds
    /// two languages.
    public static func offered(selection: [[MediaStream]]) -> Bool {
        languageOptions(selection).count > 2
    }

    /// "Alle Tonspuren", then every track of one file, labelled as the player labels
    /// them: "German · AC-3 · 5.1".
    public static func trackOptions(streams: [MediaStream]) -> [DownloadAudioOption] {
        let list = tracks(streams)
        let labels = TrackLabel.distinct(list.enumerated().map { label(for: $1, position: $0 + 1) })
        return [all] + zip(list, labels).compactMap { stream, label in
            stream.index.map { DownloadAudioOption(choice: .track($0), label: label) }
        }
    }

    /// "Alle Tonspuren", then every language that occurs in any of the files, in the
    /// order they first appear.
    public static func languageOptions(_ selection: [[MediaStream]]) -> [DownloadAudioOption] {
        var seen: [String] = []
        for streams in selection {
            for stream in tracks(streams) {
                guard let key = TrackImprint.languageKey(stream.language), !seen.contains(key)
                else { continue }
                seen.append(key)
            }
        }
        return [all] + seen.map {
            DownloadAudioOption(choice: .language($0), label: TrackLabel.language($0) ?? $0)
        }
    }

    static var all: DownloadAudioOption {
        DownloadAudioOption(choice: .all, label: translated("Alle Tonspuren"))
    }

    private static func label(for stream: MediaStream, position: Int) -> String {
        TrackLabel.audio(language: stream.language,
                         codec: TechDetails.codecNameValue(stream.codec),
                         channels: stream.channels)
            ?? stream.displayTitle
            ?? translated("Tonspur") + " \(position)"
    }

    /// **What the choice starts on.** The track of the audio language from the
    /// settings if there is one, otherwise all tracks: without a stated wish nothing
    /// is cut away.
    public static func preselected(options: [DownloadAudioOption], streams: [MediaStream],
                                   preferredLanguage: String) -> DownloadAudioChoice {
        guard !preferredLanguage.isEmpty else { return .all }
        if let index = TrackRule.audio(streams: streams, remembered: nil,
                                       preferredLanguage: preferredLanguage, serverPreGift: nil),
           options.contains(where: { $0.choice == .track(index) }) {
            return .track(index)
        }
        let language = DownloadAudioChoice.language(preferredLanguage)
        return options.contains(where: { $0.choice == language }) ? language : .all
    }

    /// The stream index a choice means in this file; `nil` for "all tracks", and for a
    /// language or track the file does not have (then the whole file is loaded, rather
    /// than none).
    public static func index(for choice: DownloadAudioChoice, streams: [MediaStream]) -> Int? {
        let list = tracks(streams)
        guard list.count > 1 else { return nil }
        switch choice {
        case .all:
            return nil
        case let .track(index):
            return list.contains { $0.index == index } ? index : nil
        case let .language(key):
            let fitting = list.filter { TrackImprint.languageKey($0.language) == key }
            return (fitting.first { $0.isDefault == true } ?? fitting.first)?.index
        }
    }

    /// The language key of a track, to hand to the next episode.
    public static func languageKey(of index: Int, streams: [MediaStream]) -> String? {
        tracks(streams).first { $0.index == index }.flatMap { TrackImprint.languageKey($0.language) }
    }
}

extension DownloadItem {
    /// **The same item with a chosen audio choice**, resolved against this file's
    /// streams. A choice that leaves all tracks in returns the item unchanged.
    ///
    /// The file becomes Matroska, like a converted one: the server builds it. Call it on
    /// the item as the catalog describes it, after ``inQuality(_:)``.
    public func withAudio(_ choice: DownloadAudioChoice, streams: [MediaStream]) -> DownloadItem {
        guard let index = DownloadAudio.index(for: choice, streams: streams) else { return self }
        let language: String? = switch choice {
        case let .language(key): key
        default: DownloadAudio.languageKey(of: index, streams: streams)
        }
        return withAudio(index: index, language: language)
    }

    /// The same item, cut down to one audio track.
    public func withAudio(index: Int, language: String?) -> DownloadItem {
        DownloadItem(
            id: id, account: account, art: art, title: title, series: series,
            seriesIdentifier: seriesIdentifier, season: season, episode: episode,
            runtimeTicks: runtimeTicks, container: converted ? container : DownloadQuality.container,
            source: source, bytes: bytes, quality: quality, loaded: loaded, state: state,
            reason: reason, watched: watched, created: created, stillOnTheServer: stillOnTheServer,
            sections: sections, pointTicks: pointTicks, recent: recent, videoCodec: videoCodec,
            audioIndex: index, audioLanguage: language, replaces: replaces,
            nextPending: nextPending)
    }
}
