import Foundation
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// **The old `TrackRule.audio` / `TrackRule.subtitle` (as `VLCPlayerView.startEngine` and `avTracksApply`
/// called them) against `StartTracks.choose` (the core's `startTrackChoice`)**, over a grid of inputs: the
/// audio and subtitle language wishes, automatic subtitles on and off, the server's defaults, an order from
/// another device (a good, a bad and an "off" one), and every kind of remembered choice (nothing, a hand
/// chosen audio, subtitles off, a subtitle track, the old name-only entry), with and without the engine's
/// own audio track standing in. `StartTracks.swift` is the app's file, linked into this test target.
@Suite struct StartTracksParityTests {
    static let streamsJSON = """
        {"Id":"s","MediaStreams":[
         {"Index":0,"Type":"Video","Codec":"hevc"},
         {"Index":1,"Type":"Audio","Codec":"ac3","Language":"eng","Channels":6,"IsDefault":true,"DisplayTitle":"English"},
         {"Index":2,"Type":"Audio","Codec":"eac3","Language":"ger","Channels":6},
         {"Index":3,"Type":"Audio","Codec":"aac","Language":"jpn","Channels":2,"Title":"Kommentar"},
         {"Index":4,"Type":"Subtitle","Codec":"subrip","Language":"eng","IsDefault":true},
         {"Index":5,"Type":"Subtitle","Codec":"subrip","Language":"ger"},
         {"Index":6,"Type":"Subtitle","Codec":"subrip","Language":"ger","IsHearingImpaired":true,"Title":"SDH"},
         {"Index":7,"Type":"Subtitle","Codec":"subrip","Language":"ger","IsForced":true,"Title":"Forced"},
         {"Index":8,"Type":"Subtitle","Codec":"subrip","Language":"eng","IsForced":true},
         {"Index":9,"Type":"Subtitle","Codec":"ass","Language":"ger","IsExternal":true}
        ]}
        """

    static func streams() throws -> [MediaStream] {
        try #require(JSONDecoder().decode(MediaSource.self, from: Data(streamsJSON.utf8)).mediaStreams)
    }

    static let title = "acct|series1"

    /// Fills a fresh store the way an older build (or a hand choice in the panel) would have.
    static func memory(_ kind: String, in streams: [MediaStream], _ defaults: UserDefaults) {
        let memory = TrackMemory(store: defaults)
        func stream(_ index: Int) -> MediaStream { streams.first { $0.index == index }! }
        switch kind {
        case "audio-ger": memory.rememberAudio(TrackImprint(feed: stream(2), in: streams, name: "Deutsch"), for: title)
        case "audio-jpn": memory.rememberAudio(TrackImprint(feed: stream(3), in: streams, name: nil), for: title)
        case "sub-off": memory.rememberSubtitle(.off, for: title)
        case "sub-ger-sdh":
            memory.rememberSubtitle(.track(TrackImprint(feed: stream(6), in: streams, name: "Deutsch SDH")), for: title)
        case "sub-eng-forced":
            memory.rememberSubtitle(.track(TrackImprint(feed: stream(8), in: streams, name: nil)), for: title)
        case "sub-name-de": memory.rememberSubtitle(.name("Deutsch"), for: title)
        case "sub-name-forced": memory.rememberSubtitle(.name("Deutsch [Forced]"), for: title)
        default: break
        }
    }

    /// What `VLCPlayerView.startEngine` / `avTracksApply` decided with the old rules.
    static func old(
        _ streams: [MediaStream], defaults: UserDefaults, defaultAudio: Int?, defaultSubtitle: Int?, audio: String,
        subtitle: String, automatic: Bool, ordered: TrackIndices?, fallback: Int?
    ) -> StartTracks.Choice {
        let memory = TrackMemory(store: defaults)
        var audioIndex = TrackRule.audio(
            streams: streams, remembered: memory.audio(for: title), preferredLanguage: audio,
            serverPreGift: defaultAudio, ordered: ordered?.audio)
        audioIndex = audioIndex ?? fallback
        let choice = TrackRule.subtitle(
            streams: streams, remembered: memory.subtitle(for: title), serverPreGift: defaultSubtitle,
            automatic: automatic, audioIndex: audioIndex, tonwunsch: audio, preferredLanguage: subtitle,
            ordered: ordered?.subtitle)
        var shown = -1
        if case .feed(let index) = choice { shown = index }
        return StartTracks.Choice(audio: audioIndex, subtitle: shown)
    }

    @Test func theGridGivesTheSameTracks() throws {
        let streams = try Self.streams()
        let name = "StartTracksParity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var checked = 0
        var different: [String] = []
        for kind in ["none", "audio-ger", "audio-jpn", "sub-off", "sub-ger-sdh", "sub-eng-forced", "sub-name-de",
                     "sub-name-forced"] {
            defaults.removePersistentDomain(forName: name)
            Self.memory(kind, in: streams, defaults)
            for audio in ["", "ger", "eng", "jpn", "fra", "Deutsch", "English"] {
                for subtitle in ["", "ger", "eng", "Deutsch", "English"] {
                    for automatic in [false, true] {
                        for server in [(nil, nil), (1, -1), (2, 5), (1, 4), (2, 7), (9, 99)] as [(Int?, Int?)] {
                            for ordered in [
                                nil, TrackIndices(audio: 3, subtitle: nil), TrackIndices(audio: 42, subtitle: nil),
                                TrackIndices(audio: nil, subtitle: -1), TrackIndices(audio: 2, subtitle: 7),
                                TrackIndices(audio: nil, subtitle: 99),
                            ] {
                                for fallback in [nil, 1, 3] as [Int?] {
                                    let expected = Self.old(
                                        streams, defaults: defaults, defaultAudio: server.0, defaultSubtitle: server.1,
                                        audio: audio, subtitle: subtitle, automatic: automatic, ordered: ordered,
                                        fallback: fallback)
                                    let got = StartTracks.choose(
                                        streams: streams, defaultAudio: server.0, defaultSubtitle: server.1,
                                        audioLanguage: audio, subtitleLanguage: subtitle, automatic: automatic,
                                        title: Self.title, ordered: ordered, audioFallback: fallback,
                                        defaults: defaults)
                                    checked += 1
                                    if got != expected, different.count < 12 {
                                        different.append(
                                            "memory \(kind) audio '\(audio)' sub '\(subtitle)' auto \(automatic) server \(server) "
                                                + "ordered \(String(describing: ordered)) fallback \(String(describing: fallback)): "
                                                + "old \(expected) core \(got)")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(checked > 10_000)
        #expect(different.isEmpty, "\(different.joined(separator: "\n"))")
    }

    /// **The settings hold display names ("Deutsch", "English"), not codes**, and the rule compares the audio's language with
    /// the audio *wish*: with audio wish "English" and an English track, German subtitles are not needed (only the forced English one, as
    /// before: `tonwunsch` equals the audio). Without an audio wish the subtitle language counts, so English audio gets
    /// the full German track. A probe once read the first case as a bug.
    @Test func displayNamesStartLikeTheOldRule() throws {
        let streams = try Self.streams()
        let name = "StartTracksParity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for (audio, expected) in [("English", 8), ("", 5), ("Deutsch", 7), ("Japanese", 5)] {
            let old = Self.old(streams, defaults: defaults, defaultAudio: 1, defaultSubtitle: nil, audio: audio,
                               subtitle: "Deutsch", automatic: true, ordered: nil, fallback: 1)
            let got = StartTracks.choose(
                streams: streams, defaultAudio: 1, defaultSubtitle: nil, audioLanguage: audio,
                subtitleLanguage: "Deutsch", automatic: true, title: Self.title, ordered: nil, audioFallback: 1,
                defaults: defaults)
            #expect(got == old, "audio wish '\(audio)': old \(old) core \(got)")
            #expect(got.subtitle == expected, "audio wish '\(audio)': subtitle \(got.subtitle), expected \(expected)")
        }
    }

    /// A hand choice in the panel: the old `TrackMemory.remember…` against `StartTracks.remember` (the core), on
    /// two stores that held the same other entries. What lands in the dictionary must decode to the same thing,
    /// and the start must read it back the same way.
    @Test func aHandChoiceIsStoredLikeBefore() throws {
        let streams = try Self.streams()
        func store() throws -> (UserDefaults, () -> Void) {
            let name = "StartTracksParity-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defaults.set(["acct|other": "Deutsch", "bare": ""], forKey: "utJeTitel")
            defaults.set(["acct|other": #"{"sprache":"eng","erzwungen":false,"extern":false}"#], forKey: "tonJeTitel")
            return (defaults, { defaults.removePersistentDomain(forName: name) })
        }
        func entries(_ defaults: UserDefaults, _ key: String) -> [String: String] {
            defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        }
        func decoded(_ raw: String?) -> TrackImprint? {
            raw.flatMap { try? JSONDecoder().decode(TrackImprint.self, from: Data($0.utf8)) }
        }
        for index in streams.compactMap(\.index) {
            let stream = streams.first { $0.index == index }!
            let kind: StartTracks.Kind? = stream.type == "Audio" ? .audio : stream.type == "Subtitle" ? .subtitle : nil
            guard let kind else { continue }
            for name in [nil, "Deutsch", "English [Forced]"] as [String?] {
                let (old, closeOld) = try store(), (new, closeNew) = try store()
                defer { closeOld(); closeNew() }
                let imprint = TrackImprint(feed: stream, in: streams, name: name)
                if kind == .audio {
                    TrackMemory(store: old).rememberAudio(imprint, for: Self.title)
                } else {
                    TrackMemory(store: old).rememberSubtitle(.track(imprint), for: Self.title)
                }
                StartTracks.remember(kind, streams: streams, index: index, name: name, title: Self.title, defaults: new)
                let key = kind == .audio ? "tonJeTitel" : "utJeTitel"
                let a = entries(old, key), b = entries(new, key)
                #expect(Set(a.keys) == Set(b.keys), "keys differ for \(index)")
                #expect(decoded(a[Self.title]) != nil && decoded(a[Self.title]) == decoded(b[Self.title]), "stream \(index) name \(name ?? "-"): \(a[Self.title] ?? "-") vs \(b[Self.title] ?? "-")")
                for (k, v) in a where k != Self.title { #expect(b[k] == v) }
                // The other kind is untouched.
                let other = kind == .audio ? "utJeTitel" : "tonJeTitel"
                #expect(entries(old, other) == entries(new, other))
            }
        }
        // Subtitles switched off.
        let (old, closeOld) = try store(), (new, closeNew) = try store()
        defer { closeOld(); closeNew() }
        TrackMemory(store: old).rememberSubtitle(.off, for: Self.title)
        StartTracks.remember(.subtitle, streams: streams, index: nil, name: nil, title: Self.title, defaults: new)
        #expect(entries(old, "utJeTitel") == entries(new, "utJeTitel"))
        #expect(entries(new, "utJeTitel")[Self.title] == "")
    }

    @Test func withoutATitleNothingIsRemembered() throws {
        let streams = try Self.streams()
        let name = "StartTracksParity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        Self.memory("sub-off", in: streams, defaults)
        // The old call site passed no remembered choice when the request had no title.
        var shown = -1
        let choice = TrackRule.subtitle(
            streams: streams, remembered: nil, serverPreGift: nil, automatic: true, audioIndex: 1,
            tonwunsch: "eng", preferredLanguage: "ger")
        if case .feed(let index) = choice { shown = index }
        let got = StartTracks.choose(
            streams: streams, defaultAudio: nil, defaultSubtitle: nil, audioLanguage: "eng", subtitleLanguage: "ger",
            automatic: true, title: nil, ordered: nil, audioFallback: 1, defaults: defaults)
        #expect(got.subtitle == shown)
    }

    /// The memory key: the old `TrackMemory.title` against the core's `trackMemoryKey`.
    @Test func theMemoryKeyIsTheOldOne() throws {
        for json in [#"{"Id":"e1","Name":"E","SeriesId":"s1"}"#, #"{"Id":"f1","Name":"F"}"#] {
            let item = try JSONDecoder().decode(Item.self, from: Data(json.utf8))
            for account in [nil, "", "acct", "plex-9"] as [String?] {
                #expect(StartTracks.key(for: item, account: account) == TrackMemory.title(for: item, account: account))
            }
        }
    }
}
