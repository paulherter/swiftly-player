import JellyfinKit

/// What the Aether engine needs from the signed-in server, built when a title opens.
extension AppModel {

    /// `nil` for downloads (the engine then plays the file with the tracks it finds itself)
    /// and when nobody is signed in.
    func engineRequest(for itemID: String, plan: PlaybackPlan) -> EngineRequest? {
        guard !plan.url.isFileURL, let session, let source = plan.source else { return nil }
        let (server, key) = liveAddress(session)
        let files = SubtitleFile.forAVPlayer(
            streams: source.mediaStreams ?? [], itemID: itemID, source: plan.mediaSourceID,
            server: server, key: key, keyName: EmbyPaths.tokenName(for: session.kind),
            serverExtracts: fileStyleAdjustable,
            // The engine draws the file's own style while "keep the file's style" is on (Plex has no choice: always on).
            keepFileStyle: subtitleLook.keepFileStyle || !fileStyleAdjustable)
        return EngineRequest(itemID: itemID, source: source, subtitleFiles: files, transcoded: plan.method == .transcode)
    }
}
