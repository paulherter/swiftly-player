import Foundation

/// Was der Player tun soll — und warum.
///
/// Der zweite Teil ist der eigentliche Mehrwert: wenn Jellyfin doch
/// transkodieren will, sagt Swiftly, welcher Strom schuld ist. Andere Clients
/// zeigen nur, *dass* transkodiert wird, nicht *woran* es lag.
public struct PlaybackPlan: Sendable, Equatable {

    public let url: URL
    public let method: DeliveryMethod
    public let mediaSourceID: String?
    public let playSessionID: String?
    public let container: String?
    public let reasons: [TranscodeReason]
    /// Die gewählte Quelle — für den Datei-Auszug auf der Detailseite.
    public let quelle: MediaSource?

    public var isLossless: Bool { method.isLossless }


    /// Kurzer Satz für die Oberfläche.
    public var summary: String {
        switch method {
        case .directPlay:
            return uebersetzt("Direct Play — die Datei läuft unverändert.")
        case .directStream:
            return uebersetzt("Direct Stream — nur der Container wird umgepackt, das Bild bleibt unangetastet.")
        case .transcode:
            guard let first = reasons.first else {
                return uebersetzt("Der Server transkodiert. Grund unbekannt.")
            }
            return uebersetzt("Der Server transkodiert: \(first.text)")
        }
    }
}

/// Der Strom, an dem die Direktwiedergabe scheitert.
public struct TranscodeReason: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case video    = "Video"
        case audio    = "Audio"
        case subtitle = "Untertitel"
        case container = "Container"

        /// `rawValue` bleibt die Kennung, das hier ist die Beschriftung.
        var beschriftung: String {
            switch self {
            case .video:     uebersetzt("Video")
            case .audio:     uebersetzt("Audio")
            case .subtitle:  uebersetzt("Untertitel")
            case .container: uebersetzt("Container")
            }
        }
    }

    public let kind: Kind
    public let codec: String
    public let detail: String?

    public var text: String {
        if let detail {
            return uebersetzt("\(kind.beschriftung) „\(codec)“ wird nicht direkt unterstützt (\(detail)).")
        }
        return uebersetzt("\(kind.beschriftung) „\(codec)“ steht nicht im Geräteprofil.")
    }
}

public extension PlaybackPlan {

    /// Baut aus der Serverantwort den Plan für den Player.
    ///
    /// Bei Direct Play und Direct Stream zeigt die URL auf die Originaldatei.
    /// Nur beim Transcode benutzen wir die vom Server gelieferte `TranscodingUrl`.
    static func make(
        from response: PlaybackInfoResponse,
        itemID: String,
        profile: DeviceProfile,
        streamURL: (String, String?, String?) throws -> URL,
        serverBase: URL
    ) throws -> PlaybackPlan? {

        guard let source = besteQuelle(response.mediaSources) else { return nil }
        let method = source.deliveryMethod

        // **Die Adresse des Servers gilt, sobald es eine gibt.**
        //
        // Bisher nur beim Transcode. Beim Umpacken liefert Jellyfin ebenfalls
        // eine `TranscodingUrl` — und nur die trägt den Startpunkt. Wer
        // stattdessen die Rohdatei nimmt, bekommt sie wieder von vorn.
        //
        let url: URL
        if method != .directPlay, let path = source.transcodingUrl {
            // TranscodingUrl kommt als serverrelativer Pfad zurück.
            guard let composed = URL(string: path, relativeTo: serverBase)?.absoluteURL else {
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

            quelle: source
        )
    }

    /// Die Quelle, die am wenigsten Arbeit macht.
    ///
    /// Jellyfin liefert mehrere, wenn ein Titel in mehreren Fassungen vorliegt
    /// — 4K neben 1080p, Kino- neben Langfassung. Vorher wurde blind die erste
    /// genommen. Stand dort ausgerechnet die Fassung, die umgewandelt werden
    /// müsste, wandelte die App um, obwohl daneben eine lag, die unverändert
    /// läuft. Das ist genau der Fall, den es diese App zu vermeiden gibt.
    ///
    /// Bei Gleichstand bleibt es bei der Reihenfolge des Servers — der sortiert
    /// selbst schon sinnvoll, und `min(by:)` ist stabil, solange der Vergleich
    /// echt kleiner verlangt.
    static func besteQuelle(_ quellen: [MediaSource]) -> MediaSource? {
        quellen.min { links, rechts in rang(links) < rang(rechts) }
    }

    private static func rang(_ quelle: MediaSource) -> Int {
        switch quelle.deliveryMethod {
        case .directPlay:   0
        case .directStream: 1
        case .transcode:    2
        }
    }

    /// Vergleicht die Ströme der Datei mit dem, was das Profil zulässt.
    static func diagnose(source: MediaSource, profile: DeviceProfile) -> [TranscodeReason] {
        var found: [TranscodeReason] = []

        let declaredContainers = Set(profile.directPlayProfiles.map(\.container))
        if let container = source.container,
           !container.split(separator: ",").contains(where: { declaredContainers.contains(String($0)) }) {
            found.append(TranscodeReason(kind: .container, codec: container,
                                         detail: uebersetzt("nicht im Profil deklariert")))
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
                                             detail: stream.channels.map { uebersetzt("\($0) Kanäle") }))
            case "Subtitle" where !subs.contains(codec):
                // Der häufigste Fall: ein Untertitelformat fehlt im Profil,
                // der Server brennt es ein und muss dafür das Video neu rechnen.
                found.append(TranscodeReason(kind: .subtitle, codec: codec,
                                             detail: uebersetzt("würde eingebrannt")))
            default:
                continue
            }
        }
        return found
    }
}
