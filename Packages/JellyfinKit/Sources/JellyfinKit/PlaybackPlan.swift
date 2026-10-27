import Foundation

/// What the player should do, and why.
///
/// The second part is the real value: when Jellyfin does want to transcode,
/// Swiftly says which stream is to blame. Other clients only show *that*
/// transcoding happens, not *why*.
public struct PlaybackPlan: Sendable, Equatable {

    public let url: URL
    public let method: DeliveryMethod
    public let mediaSourceID: String?
    public let playSessionID: String?
    public let container: String?
    public let reasons: [TranscodeReason]
    /// The chosen source, for the file excerpt on the detail page.
    public let source: MediaSource?
    /// Video codec of a file on the device, as remembered at download time
    /// (``Downloadposten/bildcodec``); there is no ``source`` for it.
    var plattenImageCodec: String? = nil

    public var isLossless: Bool { method.isLossless }

    /// Whether the player should open with the software decoder right away, see
    /// ``Erstbild/softwareFromStart(bildcodec:methode:)``.
    public var softwareDecoder: Bool {
        FirstFrame.softwareFromStart(videoCodec: source?.videoCodec ?? plattenImageCodec,
                                   method: method)
    }


    /// Short sentence for the UI.
    public var summary: String {
        switch method {
        case .directPlay:
            return translated("Direct Play — die Datei läuft unverändert.")
        case .directStream:
            return translated("Direct Stream — nur der Container wird umgepackt, das Bild bleibt unangetastet.")
        case .transcode:
            guard let first = reasons.first else {
                return translated("Der Server transkodiert. Grund unbekannt.")
            }
            return translated("Der Server transkodiert: \(first.text)")
        }
    }
}

public extension PlaybackPlan {

    /// A plan for a file that is already on the device.
    ///
    /// **Without the server.** That is the point: if the file is here, playback
    /// must not depend on a `PlaybackInfo` request that does not exist on a plane.
    /// That is what the download was for.
    ///
    /// The method is `directPlay`, and that is no euphemism: it *is* the unchanged
    /// original file, the same one the server would have delivered, bit for bit.
    /// There is no reason that could name a conversion, so `reasons` is empty.
    ///
    /// `playSessionID` is `nil`: without a server there is no session. What was
    /// watched is reported once the network is back.
    ///
    /// `videoCodec` is ``Downloadposten/bildcodec``; without a source it is the only
    /// information ``softwareDecoder`` depends on (XviD, also offline).
    public static func fromSlab(_ file: URL, container: String?,
                             mediaSourceID: String? = nil,
                             videoCodec: String? = nil) -> PlaybackPlan {
        PlaybackPlan(url: file, method: .directPlay,
                     mediaSourceID: mediaSourceID, playSessionID: nil,
                     container: container, reasons: [], source: nil,
                     plattenImageCodec: videoCodec)
    }
}

/// The stream that stops direct playback.
public struct TranscodeReason: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case video    = "Video"
        case audio    = "Audio"
        case subtitle = "Untertitel"
        case container = "Container"

        /// `rawValue` stays the identifier, this is the label.
        var label: String {
            switch self {
            case .video:     translated("Video")
            case .audio:     translated("Audio")
            case .subtitle:  translated("Untertitel")
            case .container: translated("Container")
            }
        }
    }

    public let kind: Kind
    public let codec: String
    public let detail: String?

    public var text: String {
        if let detail {
            return translated("\(kind.label) „\(codec)“ wird nicht direkt unterstützt (\(detail)).")
        }
        return translated("\(kind.label) „\(codec)“ steht nicht im Geräteprofil.")
    }
}

public extension PlaybackPlan {

    /// Builds the plan for the player from the server response.
    ///
    /// For Direct Play and Direct Stream the URL points to the original file.
    /// Only for Transcode is the server's `TranscodingUrl` used.
    static func make(
        from response: PlaybackInfoResponse,
        itemID: String,
        profile: DeviceProfile,
        streamURL: (String, String?, String?) throws -> URL,
        serverBase: URL,
        preferredSourceID: String? = nil
    ) throws -> PlaybackPlan? {

        // **The version the user picked beats the cheapest one.** Only when it is
        // named and the server still has it; otherwise the rule below applies.
        let picked = preferredSourceID.flatMap { id in
            response.mediaSources.first { $0.id == id }
        }
        guard let source = picked ?? bestSource(response.mediaSources) else {
            // With a reason it is a rejection, not "nothing there", and the user should
            // be able to read it.
            if let reason = response.errorCode, !reason.isEmpty {
                throw JellyfinError.playbackRejected(reason)
            }
            return nil
        }
        // **Without an address to convert, the original file plays, and it is called
        // that.** If a bitrate limit demands conversion but the server has transcoding
        // off, it names no `TranscodingUrl`; the raw file is played below. If it still
        // said `.transcode`, the app would show "transcoding" while Jellyfin correctly
        // saw "Direct Play".
        let method: DeliveryMethod = source.transcodingUrl == nil ? .directPlay : source.deliveryMethod

        // **The server's address applies as soon as there is one.**
        //
        // Not only for Transcode: when remuxing, Jellyfin also delivers a
        // `TranscodingUrl`, and only that one carries the start position. Taking the
        // raw file instead starts from the beginning again.
        //
        let url: URL
        if method != .directPlay, let path = source.transcodingUrl {
            // TranscodingUrl comes back as a server-relative path, and must keep the
            // subpath of a reverse proxy, see there.
            guard let composed = AppModelURLNormalizer.serverRelative(path, base: serverBase) else {
                throw JellyfinError.invalidServerURL
            }
            url = composed
        } else {
            url = try streamURL(itemID, source.id, response.playSessionId)
        }

        return PlaybackPlan(
            url: url,
            method: method,
            mediaSourceID: source.id,
            playSessionID: response.playSessionId,
            container: source.container,
            reasons: method == .transcode ? diagnose(source: source, profile: profile) : [],

            source: source
        )
    }

    /// The source that takes the least work.
    ///
    /// Jellyfin delivers several when a title exists in several versions: 4K next
    /// to 1080p, theatrical next to extended cut. Taking the first blindly would
    /// convert if that happened to be the version that needs converting, although
    /// another one plays unchanged, exactly the case this app exists to avoid.
    ///
    /// On a tie the server's order stays; it already sorts sensibly, and `min(by:)`
    /// is stable as long as the comparison requires strictly smaller.
    static func bestSource(_ sources: [MediaSource]) -> MediaSource? {
        sources.min { left, right in rank(left) < rank(right) }
    }

    private static func rank(_ source: MediaSource) -> Int {
        switch source.deliveryMethod {
        case .directPlay:   0
        case .directStream: 1
        case .transcode:    2
        }
    }

    /// Compares the file's streams with what the profile allows.
    static func diagnose(source: MediaSource, profile: DeviceProfile) -> [TranscodeReason] {
        var found: [TranscodeReason] = []

        let declaredContainers = Set(profile.directPlayProfiles.map(\.container))
        if let container = source.container,
           !container.split(separator: ",").contains(where: { declaredContainers.contains(String($0)) }) {
            found.append(TranscodeReason(kind: .container, codec: container,
                                         detail: translated("nicht im Profil deklariert")))
        }

        let video = Set(DeviceProfile.vlcVideoCodecs)
        let audio = Set(DeviceProfile.vlcAudioCodecs)
        let subs  = Set(profile.subtitleProfiles.map(\.format))

        for stream in source.mediaStreams ?? [] {
            guard let codec = stream.codec?.lowercased() else { continue }
            switch stream.type {
            case "Video" where !video.contains(codec):
                found.append(TranscodeReason(kind: .video, codec: codec, detail: nil))
            case "Audio" where !audio.contains(codec):
                found.append(TranscodeReason(kind: .audio, codec: codec,
                                             detail: stream.channels.map { translated("\($0) Kanäle") }))
            case "Subtitle" where !subs.contains(codec):
                // The most common case: a subtitle format is missing from the profile, the
                // server burns it in and has to re-encode the video for it.
                found.append(TranscodeReason(kind: .subtitle, codec: codec,
                                             detail: translated("würde eingebrannt")))
            default:
                continue
            }
        }
        return found
    }
}
