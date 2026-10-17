import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// **Prepare the next episode before it is needed.**
///
/// On a switch the player used to wait for two things in sequence: the plan from the
/// server (`PlaybackInfo`) and the start of the new file. Both can be done in the last
/// minutes of the running episode while the network is free anyway; then the plan is
/// already there at the switch, and the start of the file is in the server's memory
/// instead of on disk.
///
/// **Frugal:** only near the end, once per episode, only over a network that costs
/// nothing (no cellular, no data saver), and not for downloaded episodes, which are
/// already on the device.
public enum Prebuffer {

    /// Preparation starts at this much remaining time: three minutes.
    public static let secondsLeft: Double = 180

    /// This much of the start of the file is preloaded: 4 MiB. Enough for the header and
    /// the first seconds of an episode, small enough not to stand out.
    public static let initialBytes: Int = 4 * 1024 * 1024

    /// How long a prepared plan is valid. Pausing in the credits for a quarter of an hour
    /// gets a fresh one at the switch.
    public static let lifetime: TimeInterval = 600

    /// Whether to prepare now.
    ///
    /// - Parameters:
    ///   - creditsFrom: where the credits section begins, if the server knows one; from
    ///     there the episode also counts as almost done.
    ///   - networkFavorable: Wi-Fi or cable, without data saver.
    public static func now(position: Double, duration: Double, creditsFrom: Double?,
                             networkFavorable: Bool) -> Bool {
        guard networkFavorable else { return false }
        guard duration > EpisodeEnd.minRuntime, position.isFinite, position > 0 else { return false }
        if duration - position <= secondsLeft { return true }
        if let creditsFrom, creditsFrom > 0, position >= creditsFrom { return true }
        return false
    }

    /// Whether a prepared plan is still used at the switch.
    public static func freshValue(prepared: Date, now: Date) -> Bool {
        now.timeIntervalSince(prepared) < lifetime
    }

    /// Whether the start of the file is preloaded: only over the network, not for a file
    /// on the device, and not for a transcode, whose URL would trigger a transcode on
    /// the server that may never be needed.
    public static func startLoad(address: URL, method: DeliveryMethod) -> Bool {
        guard !address.isFileURL, let schema = address.scheme?.lowercased(),
              schema == "http" || schema == "https" else { return false }
        return method == .directPlay
    }

    /// **Request the start of the file once**: ``anfangsbytes`` via `Range`, with the
    /// server's custom headers, without cache: the bytes should sit in the server's memory,
    /// not a second time on the device. Returns how many bytes arrived. For iPhone and
    /// Android.
    @discardableResult
    public static func startRequest(_ address: URL) async throws -> Int {
        var petition = URLRequest.withOwnHeaders(address)
        petition.setValue("bytes=0-\(initialBytes - 1)", forHTTPHeaderField: "Range")
        petition.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await session.data(for: petition)
        return data.count
    }

    private static let session: URLSession = {
        let setting = URLSessionConfiguration.ephemeral
        setting.urlCache = nil
        setting.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: setting)
    }()
}
