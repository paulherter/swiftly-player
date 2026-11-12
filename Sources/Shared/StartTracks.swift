import Foundation
import JellyfinKit
import struct SwiftlyCore.PlayOrderedTracks
import struct SwiftlyCore.PlayerStream
import struct SwiftlyCore.PlayerSubtitleFile
import func SwiftlyCore.rememberTrackChoice
import func SwiftlyCore.startTrackChoice
import func SwiftlyCore.trackMemoryKey

/// **The tracks a title starts with, decided by the core** (`startTrackChoice`, the Rust port of
/// `TrackRule.audio` / `TrackRule.subtitle` with the remembered choices of `TrackMemory`).
///
/// The remembered choices are the old UserDefaults dictionaries (`tonJeTitel`, `utJeTitel`), which the core
/// reads in the same format, so a choice made by an older build still counts. A hand choice is still
/// written by ``TrackMemory`` (the panel); this decides only the start.
enum StartTracks {
    struct Choice: Equatable {
        /// The Jellyfin `Index` of the audio track, `nil` = the file's own.
        var audio: Int?
        /// The Jellyfin `Index` of the subtitle track, `-1` = off.
        var subtitle: Int
    }

    /// - Parameters:
    ///   - audioFallback: the audio track the engine already plays; it stands in when no rule names
    ///     one, and then also feeds the subtitle rule (what `avTracksApply` always did).
    ///   - title: the memory key (`account|series`); `nil` = nothing remembered.
    static func choose(
        streams: [MediaStream], defaultAudio: Int?, defaultSubtitle: Int?, audioLanguage: String,
        subtitleLanguage: String, automatic: Bool, title: String?, ordered: TrackIndices?,
        audioFallback: Int? = nil, defaults: UserDefaults = .standard
    ) -> Choice {
        let rows = Self.rows(streams)
        // Nothing remembered without a title: the key is empty and matches no entry.
        let key = title ?? ""
        let answer = startTrackChoice(
            streams: rows, defaultAudio: defaultAudio.map(Int64.init), defaultSubtitle: defaultSubtitle.map(Int64.init),
            audioLanguage: audioLanguage, subtitleLanguage: subtitleLanguage, automaticSubtitles: automatic,
            audioMemory: title == nil ? [:] : dictionary("tonJeTitel", defaults),
            subtitleMemory: title == nil ? [:] : dictionary("utJeTitel", defaults),
            title: key,
            ordered: ordered.map {
                PlayOrderedTracks(audio: $0.audio.map(Int64.init), subtitle: $0.subtitle.map(Int64.init))
            },
            audioFallback: audioFallback.map(Int64.init))
        return Choice(audio: answer.audio.map(Int.init), subtitle: Int(answer.subtitle))
    }

    /// The memory key of a title (`account|series`, the core's `trackMemoryKey`).
    static func key(for item: Item, account: String?) -> String {
        trackMemoryKey(seriesId: item.seriesId, itemId: item.id, account: account)
    }

    /// `transcoded`: the server delivers the text tracks of a transcode (HLS) as files, `IsExternal` stays false for them;
    /// they count as files here so the core hands them to the engine.
    static func rows(_ streams: [MediaStream], transcoded: Bool = false) -> [PlayerStream] {
        streams.compactMap { stream in
            guard let index = stream.index else { return nil }
            return PlayerStream(
                index: Int64(index), kind: stream.type ?? "", language: stream.language, codec: stream.codec,
                channels: stream.channels.map(Int64.init), title: stream.title,
                isDefault: stream.isDefault ?? false, isForced: stream.isForced ?? false,
                isExternal: transcoded ? stream.isDeliveredFile : (stream.isExternal ?? false), isHearingImpaired: stream.isHearingImpaired ?? false)
        }
    }

    /// **The external subtitle files the core hands to the engine and selects by number** (`CoreTrackIDs`): the core
    /// numbers a file `externalBase + position in this list` only for a file it was given here. Without them the engine
    /// lists the file as 1000+n while the core waits for the server's index, and no external subtitle ever shows.
    static func files(_ files: [SubtitleFile]) -> [PlayerSubtitleFile] {
        files.map { PlayerSubtitleFile(index: Int64($0.index), address: $0.address.absoluteString, attribute: $0.attribute) }
    }

    enum Kind: String {
        case audio, subtitle
        fileprivate var key: String { self == .audio ? "tonJeTitel" : "utJeTitel" }
    }

    /// **A track picked by hand in the panel, remembered for the series or film** (`TrackMemory.rememberAudio` /
    /// `rememberSubtitle`, now the core's `rememberTrackChoice`): the entry goes into the same UserDefaults
    /// dictionary the start reads. `index == nil` for a subtitle means "off".
    static func remember(
        _ kind: Kind, streams: [MediaStream], index: Int?, name: String?, title: String,
        defaults: UserDefaults = .standard
    ) {
        let written = rememberTrackChoice(
            kind: kind.rawValue, streams: rows(streams), index: index.map(Int64.init), name: name, title: title,
            memory: dictionary(kind.key, defaults))
        defaults.set(written, forKey: kind.key)
    }

    private static func dictionary(_ key: String, _ defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
