import Foundation

public extension PlaybackPlan {

    /// **A plan whose version and delivery were chosen elsewhere** (the Rust core's `playPlan`), assembled the way
    /// ``make(from:itemID:profile:streamURL:serverBase:preferredSourceID:)`` does it at the end: the container
    /// comes from the source, and only a conversion carries reasons.
    static func assembled(
        url: URL, method: DeliveryMethod, mediaSourceID: String?, playSessionID: String?,
        source: MediaSource, itemID: String, profile: DeviceProfile
    ) -> PlaybackPlan {
        PlaybackPlan(
            url: url, method: method, mediaSourceID: mediaSourceID, playSessionID: playSessionID,
            container: source.container,
            reasons: method == .transcode ? diagnose(source: source, profile: profile) : [],
            source: source, itemID: itemID)
    }
}
