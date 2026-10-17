#if DEBUG
import UIKit
import JellyfinKit

/// **Self-test for the first-frame rescue**, no touch input and no server,
/// via the log only.
///
/// xcrun simctl launch <device> <bundle-id> \
///   -erstbildlauf <url> [-erstbildab <s>] [-erstbildzwang <codec-option>] [-erstbildimmer]
///
/// Puts a player over the whole window, plays `<url>` (file or `http://`) for 30
/// seconds and writes an `[Erstbildlauf]` line per second with clock, shown
/// frames and hint. The video track is asserted as if the server had named it.
///
/// - `-erstbildzwang ":codec=araw,none"`: forces a decoder without picture
///   as long as the rule does not demand a software decoder; checks that the
///   second rescue works.
/// - `-erstbildimmer`: the force applies even then; checks the calm afterwards.
@MainActor
enum FirstFrameRun {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var an: Bool { arguments.contains("-erstbildlauf") }

    private static func value(_ name: String) -> String? {
        arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }
    private static func log(_ text: String) { AppLog.writeOut("[Erstbildlauf] " + text) }

    static func start() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let raw = value("-erstbildlauf"),
                  let address = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : URL(string: raw)
            else { log("keine Adresse"); return }
            let window = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
            guard let window else { log("kein Fenster"); return }
            if let force = value("-erstbildzwang") {
                VLCPlayerView.testForce = (force, arguments.contains("-erstbildimmer"))
            }
            let viewRef = VLCPlayerView(frame: window.bounds)
            viewRef.testVideoTrack = true
            window.addSubview(viewRef)
            log("Start \(address.lastPathComponent) · Zwang \(value("-erstbildzwang") ?? "—")"
                + (arguments.contains("-erstbildimmer") ? " (immer)" : ""))
            viewRef.play(url: address, offSeconds: value("-erstbildab").flatMap(Double.init) ?? 0)
            for secondUnit in 1...30 {
                try? await Task.sleep(for: .seconds(1))
                let stats = viewRef.player.media?.statistics
                log("t=\(secondUnit) s · Uhr \(viewRef.player.time.intValue / 1000) s"
                    + " · gezeigt \(stats?.displayedPictures ?? 0) · dekodiert \(stats?.decodedVideo ?? 0)"
                    + " · Hinweis \(viewRef.firstFrameHint ?? "—")")
            }
            viewRef.stop()
            viewRef.removeFromSuperview()
            log("Ende")
        }
    }
}
#endif
