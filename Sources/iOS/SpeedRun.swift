#if DEBUG
import UIKit
import JellyfinKit

/// **Measurement run: how quickly does a speed change take effect?** No
/// touch input, log only.
///
/// xcrun simctl launch <device> <bundle-id> -tempolauf <file>
///
/// Plays the file, sets the speed to 2 after 5 s and back to 1 after another
/// 4 s, and writes the movie time next to the wall clock every 25 ms. The
/// slope (movie time per wall time) shows when VLC really runs faster, since
/// the player's clock follows the audio.
@MainActor
enum SpeedRun {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var an: Bool { arguments.contains("-tempolauf") }
    private static func log(_ t: String) { AppLog.writeOut("[Tempolauf] " + t) }

    static func start() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let i = arguments.firstIndex(of: "-tempolauf"), arguments.indices.contains(i + 1),
                  let window = UIApplication.shared.connectedScenes
                    .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { log("nichts"); return }
            if let j = arguments.firstIndex(of: "-tempozusatz"), arguments.indices.contains(j + 1) {
                VLCPlayerView.testAddition = arguments[j + 1].split(separator: " ").map(String.init)
                log("Zusatz \(VLCPlayerView.testAddition)")
            }
            let viewRef = VLCPlayerView(frame: window.bounds)
            viewRef.testVideoTrack = true
            window.addSubview(viewRef)
            viewRef.play(url: URL(fileURLWithPath: arguments[i + 1]), offSeconds: 0)
            try? await Task.sleep(for: .seconds(5))
            // `-nurspielen`: 65 s without a speed change; audio dropouts count.
            if arguments.contains("-nurspielen") {
                for step in 1...13 {
                    try? await Task.sleep(for: .seconds(5))
                    let st = viewRef.player.media?.statistics
                    log("t=\(step * 5) s · Ton gespielt \(st?.playedAudioBuffers ?? 0)"
                        + " · verloren \(st?.lostAudioBuffers ?? 0) · Film \(viewRef.player.time.intValue / 1000) s")
                }
                viewRef.stop()
                log("Ende")
                return
            }
            for target: Float in [2, 1] {
                let t0 = Date()
                viewRef.tempo = target
                if arguments.contains("-tempospringen") {
                    // Drain the buffer: seek to where VLC currently is.
                    viewRef.player.time = viewRef.player.time
                }
                if arguments.contains("-tempofast") {
                    viewRef.player.jump(withOffset: 0, completion: {})
                }
                log("gesetzt \(target) · rate jetzt \(viewRef.player.rate)")
                var previous = (w: 0.0, m: Double(viewRef.player.time.intValue))
                var reported = false
                for _ in 0..<160 {
                    try? await Task.sleep(for: .milliseconds(25))
                    let w = Date().timeIntervalSince(t0) * 1000
                    let m = Double(viewRef.player.time.intValue)
                    if w - previous.w >= 100 {
                        let slope = (m - previous.m) / (w - previous.w)
                        let st = viewRef.player.media?.statistics
                        log("t=\(Int(w)) ms · Film \(Int(m)) ms · Steigung \(String(format: "%.2f", slope))"
                            + " · Bilder \(st?.displayedPictures ?? 0) · Ton \(st?.playedAudioBuffers ?? 0)"
                            + " · Pos \(String(format: "%.5f", viewRef.player.position))")
                        if !reported, abs(slope - Double(target)) < 0.25 {
                            reported = true
                            log("angekommen nach ~\(Int(w)) ms")
                        }
                        previous = (w, m)
                    }
                }
            }
            viewRef.stop()
            viewRef.removeFromSuperview()
            log("Ende")
        }
    }
}
#endif
