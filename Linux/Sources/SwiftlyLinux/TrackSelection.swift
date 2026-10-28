import CGtk
import Foundation
import JellyfinKit

/// **Which audio and subtitle track plays, decided by Jellyfin's index, not
/// by VLC's track name.**
///
/// The rules live in the package: ``Spurregel`` (manual choice per show → app
/// settings → server defaults → forced subtitles → off), ``Spurzuordnung``
/// (VLC track ↔ `MediaStream`) and ``Spurgedaechtnis``. This file only covers
/// how libVLC 3 exposes the tracks. Modeled on `Sources/Shared/VLCPlayer.swift`,
/// `wendeLanguagesAn`.
///
/// **The one difference from Apple: libVLC 3 only has numbers as track IDs.**
/// VLCKit 4 prefixes the track of an externally added file with the MD5 of its
/// URL (`<md5>/spu/0`), which is how ``Spurzuordnung`` recognizes it. libVLC 3
/// does not. So the files are attached **one at a time** here, and the track
/// that newly appears in the list gets the prefix from this code: same ID,
/// same mapping in the package.
final class TrackStatus {
    /// The show or movie for which a manual choice is remembered.
    var title: String?
    var source: MediaSource?
    var files: [SubtitleFile] = []
    /// VLC track number → MD5 of the file it came from.
    var fileTracks: [Int32: String] = [:]
    /// Still to attach, in this order.
    var queue: [SubtitleFile] = []
    /// The file that was just attached, and what was already there.
    var onTheGo: (file: SubtitleFile, before: Set<Int32>, since: Date)?
    /// A chosen subtitle file whose track is not there yet.
    var currentSubtitle: Int?
    /// What was last reported as playing; goes out with start and progress.
    var reported = TrackIndices()

    /// A new title or episode.
    func new(title: String?, source: MediaSource?, files: [SubtitleFile]) {
        self.title = title
        self.source = source
        self.files = files
        reported = TrackIndices()
        newOpened()
    }

    /// The stream was rebuilt: libVLC forgot the attached files.
    func newOpened() {
        fileTracks = [:]
        queue = []
        onTheGo = nil
        currentSubtitle = nil
    }
}

extension App {

    /// **A store of its own, written after every change.** Foundation only writes
    /// `UserDefaults` to `~/.config/<name>.plist` on an orderly exit here; a killed
    /// process lost the manual choice (after `pkill` there was no file).
    nonisolated(unsafe) static let trackStore = UserDefaults(suiteName: "de.paulherter.swiftly") ?? .standard

    func trackMemory() -> TrackMemory { TrackMemory(store: Self.trackStore) }

    private func trackStoreSafe() { _ = Self.trackStore.synchronize() }

    private func trackLog(_ text: String) {
        AppLog.writeOut("[Spuren] \(text)")
        fflush(nil)
    }

    /// Before every opening of a title or episode.
    func trackStatusNew(_ item: Item, plan: PlaybackPlan?) {
        var files: [SubtitleFile] = []
        if let plan, !plan.url.isFileURL, let addresses {
            files = SubtitleFile.from(streams: plan.source?.mediaStreams ?? [],
                                          server: addresses.base, key: addresses.token,
                                          attribute: Self.subtitleRememberTimes)
        }
        trackStatus.new(title: TrackMemory.title(for: item), source: plan?.source, files: files)
    }

    /// MD5 of the URL as libVLC 4 forms it, via GLib, which exists on Linux and
    /// Windows anyway.
    static func subtitleRememberTimes(_ address: URL) -> String? {
        guard let raw = g_compute_checksum_for_string(G_CHECKSUM_MD5, address.absoluteString, -1)
        else { return nil }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    // MARK: Tracks as the package sees them

    private func identifier(_ number: Int32, art: String) -> String {
        if art == "spu", let attribute = trackStatus.fileTracks[number] { return "\(attribute)/spu/\(number)" }
        return "\(art)/\(number)"
    }

    private func playerTracks(_ tracks: [Player.TrackSupport], art: String,
                                 details: [Int32: Player.TrackDetail]) -> [PlayerTrack] {
        tracks.map { track in
            let detail = details[track.identifier]
            return PlayerTrack(identifier: identifier(track.identifier, art: art), name: track.name,
                                 language: detail?.language,
                                 codec: detail.flatMap { TechDetails.codecNameValue(vlcId: $0.codec) },
                                 channels: detail?.channels)
        }
    }

    /// The tracks of both kinds without VLC's "Disable", with their mapping.
    private func trackState() -> (audio: [Player.TrackSupport], subtitle: [Player.TrackSupport],
                                 mapping: TrackMapping, details: [Int32: Player.TrackDetail]) {
        let audio = mediaPlayer.audioTracks.filter { $0.identifier >= 0 }
        let ut = mediaPlayer.subtitleTracks.filter { $0.identifier >= 0 }
        let details = mediaPlayer.trackDetails()
        let z = TrackMapping.compose(audio: playerTracks(audio, art: "audio", details: details),
                                     subtitle: playerTracks(ut, art: "spu", details: details),
                                     streams: trackStatus.source?.mediaStreams ?? [],
                                     files: trackStatus.files)
        return (audio, ut, z, details)
    }

    // MARK: On start

    /// **Once per title, as soon as VLC knows the tracks.**
    func tracksPreSelect() {
        let status = trackStatus
        let streams = status.source?.mediaStreams ?? []
        let (audio, ut, z, _) = trackState()
        let memory = trackMemory()
        // Sent along with this title from another device; never for the next one.
        let ordered = playOrderedTracks.flatMap { $0.itemID == runningTitle?.id ? $0.tracks : nil }
        playOrderedTracks = nil

        var audioIndex = TrackRule.audio(streams: streams,
                                     remembered: status.title.flatMap { memory.audio(for: $0) },
                                     preferredLanguage: selection.audioLanguage,
                                     serverPreGift: status.source?.defaultAudioStreamIndex,
                                     ordered: ordered?.audio)
        if let searched = audioIndex, let position = z.audioPositionValue(index: searched) {
            mediaPlayer.setAudioTrack(audio[position].identifier)
        } else {
            // Nothing to map: as before by name, otherwise by file.
            if !selection.audioLanguage.isEmpty,
               let hit = audio.first(where: { Language.fits($0.name, toward: selection.audioLanguage) }) {
                mediaPlayer.setAudioTrack(hit.identifier)
            }
            let now = mediaPlayer.audioTrack
            audioIndex = audio.firstIndex { $0.identifier == now }.flatMap { z.audio[$0] }
        }

        let choice = TrackRule.subtitle(streams: streams,
                                        remembered: status.title.flatMap { memory.subtitle(for: $0) },
                                        serverPreGift: status.source?.defaultSubtitleStreamIndex,
                                        automatic: selection.subtitleAutomatic, audioIndex: audioIndex,
                                        tonwunsch: selection.audioLanguage, preferredLanguage: selection.subtitleLanguage,
                                        ordered: ordered?.subtitle)
        trackLog("Ton \(audioIndex.map(String.init) ?? "Datei") · Untertitel \(choice)"
            + " · Vorgaben \(status.source?.defaultAudioStreamIndex.map(String.init) ?? "—")/"
            + "\(status.source?.defaultSubtitleStreamIndex.map(String.init) ?? "—")"
            + " · Zuordnung Ton \(z.audio) Untertitel \(z.subtitle)"
            + " · Dateien \(status.files.map(\.index))")
        subtitleSet(choice, tracks: ut, mapping: z)
        trackIndicesReport(TrackIndices(audio: audioIndex, subtitle: subtitleIndex(choice)))
        // Only now: the embedded tracks are present, so every new one is a file.
        status.queue = status.files
        trackFilesUpdate()
    }

    private func subtitleIndex(_ choice: TrackRule.Subtitle) -> Int {
        if case .feed(let index) = choice { return index }
        return -1
    }

    private func subtitleSet(_ choice: TrackRule.Subtitle, tracks: [Player.TrackSupport],
                                  mapping z: TrackMapping) {
        trackStatus.currentSubtitle = nil
        guard case .feed(let index) = choice else {
            // Switch off actively: the file often brings its own preselection.
            mediaPlayer.setSubtitle(-1)
            return
        }
        if let position = z.subtitlePosition(index: index) {
            mediaPlayer.setSubtitle(tracks[position].identifier)
        } else {
            mediaPlayer.setSubtitle(-1)
            if trackStatus.files.contains(where: { $0.index == index }) {
                trackStatus.currentSubtitle = index
                trackLog("Untertiteldatei \(index) noch nicht da, wartet")
            } else {
                trackLog("Untertitel \(index) nicht zuzuordnen, bleibt aus")
            }
        }
    }

    private func trackIndicesReport(_ new: TrackIndices) {
        guard new != trackStatus.reported else { return }
        trackStatus.reported = new
        trackLog("gemeldet \(new.audio.map(String.init) ?? "—")/\(new.subtitle.map(String.init) ?? "—")")
    }

    // MARK: External subtitles

    /// **Per tick: find the attached file again, then attach the next one.**
    ///
    /// One at a time because libVLC 3 does not say which file a track comes
    /// from, only that it is new. Reading the list only costs while a file is
    /// in flight.
    func trackFilesUpdate() {
        let status = trackStatus
        if let onTheGo = status.onTheGo {
            let newOne = mediaPlayer.subtitleTracks.filter { $0.identifier >= 0 && !onTheGo.before.contains($0.identifier) }
            if let track = newOne.first, let attribute = onTheGo.file.attribute {
                status.fileTracks[track.identifier] = attribute
                status.onTheGo = nil
                trackLog("Datei \(onTheGo.file.index) ist Spur \(track.identifier), Merkmal \(attribute)")
                holdSelectionAfterFile()
            } else if Date().timeIntervalSince(onTheGo.since) > 15 {
                status.onTheGo = nil
                trackLog("Datei \(onTheGo.file.index) nach 15 s ohne Spur, uebersprungen")
            } else {
                return
            }
        }
        guard status.onTheGo == nil, !status.queue.isEmpty else { return }
        let file = status.queue.removeFirst()
        let before = Set(mediaPlayer.subtitleTracks.map(\.identifier))
        let attached = mediaPlayer.subtitleFileAppend(file.address)
        trackLog("Datei \(file.index) angehängt \(attached), Merkmal \(file.attribute ?? "—")")
        if attached { status.onTheGo = (file, before, Date()) }
    }

    /// After a new file: enable the chosen open file, otherwise keep what was
    /// chosen; a new track must not shift the choice.
    private func holdSelectionAfterFile() {
        let (_, ut, z, _) = trackState()
        if let index = trackStatus.currentSubtitle, let position = z.subtitlePosition(index: index) {
            trackStatus.currentSubtitle = nil
            mediaPlayer.setSubtitle(ut[position].identifier)
            trackLog("Untertiteldatei \(index) nachgereicht")
            trackIndicesReport(TrackIndices(audio: trackStatus.reported.audio, subtitle: index))
            return
        }
        guard let should = trackStatus.reported.subtitle else { return }
        let identifier = should < 0 ? -1 : z.subtitlePosition(index: should).map { ut[$0].identifier }
        if let identifier, mediaPlayer.subtitleTrack != identifier { mediaPlayer.setSubtitle(identifier) }
    }

    // MARK: Manual choice

    /// An audio track from the sheet; applies to the whole show.
    func audioTrackSelected(_ identifier: Int32) {
        mediaPlayer.setAudioTrack(identifier)
        let (audio, _, z, details) = trackState()
        guard let position = audio.firstIndex(where: { $0.identifier == identifier }) else { return }
        let index = z.audio[position]
        if let title = trackStatus.title {
            let streams = trackStatus.source?.mediaStreams ?? []
            let track = playerTracks([audio[position]], art: "audio", details: details)[0]
            let imprint = index.flatMap { i in streams.first { $0.type == "Audio" && $0.index == i } }
                .map { TrackImprint(feed: $0, in: streams, name: track.name) }
                ?? TrackImprint(track: track)
            trackMemory().rememberAudio(imprint, for: title)
            trackStoreSafe()
            trackLog("Ton von Hand: \(index.map(String.init) ?? "?") \(imprint)")
        }
        trackIndicesReport(TrackIndices(audio: index, subtitle: trackStatus.reported.subtitle))
    }

    /// A subtitle from the sheet, `nil` means off; this also applies to the show.
    func subtitleSelected(_ identifier: Int32?) {
        trackStatus.currentSubtitle = nil
        guard let identifier else {
            if let title = trackStatus.title {
                trackMemory().rememberSubtitle(.off, for: title)
                trackStoreSafe()
            }
            mediaPlayer.setSubtitle(-1)
            trackLog("Untertitel von Hand: aus")
            trackIndicesReport(TrackIndices(audio: trackStatus.reported.audio, subtitle: -1))
            return
        }
        mediaPlayer.setSubtitle(identifier)
        let (_, ut, z, details) = trackState()
        guard let position = ut.firstIndex(where: { $0.identifier == identifier }) else { return }
        let index = z.subtitle[position]
        if let title = trackStatus.title {
            let streams = trackStatus.source?.mediaStreams ?? []
            let track = playerTracks([ut[position]], art: "spu", details: details)[0]
            let imprint = index.flatMap { i in streams.first { $0.type == "Subtitle" && $0.index == i } }
                .map { TrackImprint(feed: $0, in: streams, name: track.name) }
                ?? TrackImprint(track: track)
            trackMemory().rememberSubtitle(.track(imprint), for: title)
            trackStoreSafe()
            trackLog("Untertitel von Hand: \(index.map(String.init) ?? "?") \(imprint)")
        }
        trackIndicesReport(TrackIndices(audio: trackStatus.reported.audio, subtitle: index))
    }

    // MARK: Names in the sheet

    /// **"Deutsch · AAC · 5.1" instead of VLC's "Track 2 - [German]"**: the
    /// same format as the tech badge (`prettyName`).
    func audioTrackNames() -> [(identifier: Int32, name: String)] {
        let audio = mediaPlayer.audioTracks.filter { $0.identifier >= 0 }
        let details = mediaPlayer.trackDetails()
        return audio.map { track in
            let a = details[track.identifier]
            let name = TechDetails.audioTrackName(
                language: a?.language,
                codec: a.flatMap { TechDetails.codecNameValue(vlcId: $0.codec) },
                channels: a?.channels) ?? track.name
            return (track.identifier, name)
        }
    }

    /// Subtitles with identical names and added files get language, format,
    /// "Erzwungen", "Hörgeschädigt" and "Datei"; otherwise they cannot be told
    /// apart in the list (Apple: `subtitleNames()`).
    func subtitleNames() -> [(identifier: Int32, name: String)] {
        let (_, ut, z, _) = trackState()
        let streams = trackStatus.source?.mediaStreams ?? []
        return ut.enumerated().map { position, track in
            let double = ut.filter { $0.name == track.name }.count > 1
            guard let index = z.subtitle[position],
                  let feed = streams.first(where: { $0.type == "Subtitle" && $0.index == index }),
                  double || feed.isExternal == true || feed.isHearingImpaired == true else {
                return (track.identifier, track.name)
            }
            let parts: [String?] = [
                TechDetails.language(feed.language) ?? track.name,
                TechDetails.codecNameValue(feed.codec),
                feed.isForced == true ? translated("Erzwungen") : nil,
                feed.isHearingImpaired == true ? translated("Hörgeschädigt") : nil,
                feed.isExternal == true ? translated("Datei") : nil,
            ]
            return (track.identifier, parts.compactMap { $0 }.joined(separator: " · "))
        }
    }
}
