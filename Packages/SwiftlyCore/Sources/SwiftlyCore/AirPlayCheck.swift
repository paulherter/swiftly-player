import Foundation

/// The AirPlay decision of the core (`airplaySuitability`, `airplayRemuxRefusal`) as a Swift call: whether a
/// file goes over AirPlay and which audio track gets through. Only the decision lives here; starting AirPlay
/// belongs to the player.
public enum AirPlayCheck {
    /// Checks a `MediaSource` given as the server's JSON. `nil` for JSON that is not a source.
    public static func verdict(sourceJson: String) -> AirPlayVerdict? {
        airplaySuitability(sourceJson: sourceJson)
    }

    /// Checks an encoded `MediaSource` (`JSONEncoder` output of the app's own model).
    public static func verdict<Source: Encodable>(of source: Source) -> AirPlayVerdict? {
        guard let data = try? JSONEncoder().encode(source), let json = String(data: data, encoding: .utf8) else { return nil }
        return verdict(sourceJson: json)
    }

    /// The refusal for a plan with no transcoding address although the container is not for AVPlayer.
    public static func remuxRefusal(directPlay: Bool, hasTranscodingUrl: Bool, container: String?) -> AirPlayVerdict? {
        airplayRemuxRefusal(deliveryDirectPlay: directPlay, hasTranscodingUrl: hasTranscodingUrl, container: container)
    }
}
