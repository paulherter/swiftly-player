import JellyfinKit

/// What the AVPlayer engine needs from the signed-in server, built when a title opens.
extension AppModel {

    /// `nil` for downloads (a file on the device is VLC's) and when nobody is signed in.
    /// The plan closure asks the server for the copy-only address of one audio track; a server
    /// without one answers `nil` and VLC plays.
    func engineRequest(for itemID: String, plan: PlaybackPlan) -> EngineRequest? {
        guard !plan.url.isFileURL, let session, let client, let source = plan.source else { return nil }
        let (server, key) = liveAddress(session)
        let files = SubtitleFile.forAVPlayer(
            streams: source.mediaStreams ?? [], itemID: itemID, source: plan.mediaSourceID,
            server: server, key: key, keyName: EmbyPaths.tokenName(for: session.kind),
            serverExtracts: fileStyleAdjustable)
        let av1 = EngineProbe.device.av1
        return EngineRequest(itemID: itemID, source: source, subtitleFiles: files) { audio in
            try? await client.avPlayerPlan(for: itemID, source: source, audioIndex: audio, av1: av1)
        }
    }
}
