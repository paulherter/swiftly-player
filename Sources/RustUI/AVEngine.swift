import AVFoundation
import UIKit

/// The video layer, below the transparent Metal layer.
final class VideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// The Apple half of the player contract: AVPlayer drawing into a `VideoView` under the UI. It speaks to Rust in JSON
/// lines only (`swiftly_rust_engine_commands` in, `swiftly_rust_engine_event` out; format in
/// crates/swiftly-player-surface/src/wire.rs), so the Rust player screen sees the same events as with libmpv or Media3.
/// AVPlayer plays mp4, mov and HLS; the plan asks for exactly that (`Flavour::AirPlay`), everything else is transcoded.
@MainActor
final class AVEngine: NSObject, AVPlayerItemOutputPushDelegate, AVPlayerItemLegibleOutputPushDelegate {
    let view = VideoView()
    /// Called after an event so the display link runs and the command queue is drained.
    var wake: (() -> Void)?

    private let player = AVPlayer()
    private var item: AVPlayerItem?
    private var observers: [NSKeyValueObservation] = []
    private var itemObservers: [NSKeyValueObservation] = []
    private var timeToken: Any?
    private var endToken: NSObjectProtocol?
    private var firstSent = false
    private var seeking = false
    private struct Pick { let group: AVMediaSelectionGroup; let option: AVMediaSelectionOption }
    private var options: [Int: Pick] = [:]
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var desiredRate: Float = 1

    override init() {
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
        timeToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.player.timeControlStatus == .playing, t.seconds.isFinite else { return }
                self.send(["e": "clock", "p": t.seconds])
            }
        }
        observers.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            MainActor.assumeIsolated {
                guard let self, self.item != nil, !self.seeking else { return }
                switch status {
                case .playing: self.send(["e": "state", "s": "playing"])
                case .paused: if self.item?.status == .readyToPlay { self.send(["e": "state", "s": "paused"]) }
                default: self.send(["e": "state", "s": "loading"])
                }
            }
        })
        observers.append(view.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] l, _ in
            let ready = l.isReadyForDisplay
            MainActor.assumeIsolated {
                guard let self, ready, !self.firstSent else { return }
                self.firstSent = true
                self.send(["e": "first"])
            }
        })
        view.playerLayer.player = player
    }

    private func send(_ o: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: o), let s = String(data: data, encoding: .utf8) else { return }
        _ = swiftly_rust_engine_event(s)
        wake?()
    }

    /// Applies the command lines Rust queued since the last frame.
    func apply(_ lines: String) {
        for line in lines.split(separator: "\n") {
            guard let c = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let cmd = c["c"] as? String else { continue }
            switch cmd {
            case "load": load(c)
            case "play": player.playImmediately(atRate: desiredRate)
            case "pause": player.pause()
            case "seek":
                guard let s = c["s"] as? Double else { break }
                seeking = true
                send(["e": "state", "s": "seeking"])
                player.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.seeking = false
                        self.send(["e": "state", "s": self.player.timeControlStatus == .playing ? "playing" : "paused"])
                    }
                }
            case "rate":
                desiredRate = Float((c["v"] as? Double) ?? 1)
                if player.timeControlStatus != .paused { player.rate = desiredRate }
            case "volume": player.volume = Float((c["v"] as? Double) ?? 100) / 100
            case "audio": select(c["i"] as? Int ?? -1, audio: true)
            case "sub": select(c["i"] as? Int ?? -1, audio: false)
            case "fill": view.playerLayer.videoGravity = (c["on"] as? Bool) == true ? .resizeAspectFill : .resizeAspect
            case "stop": stop()
            default: break // place, delay, pip: not wired (ios-shell.md)
            }
        }
    }

    private func load(_ c: [String: Any]) {
        guard let s = c["url"] as? String, let url = URL(string: s) else { return }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        var opts: [String: Any] = [:]
        if let h = c["headers"] as? [[String]], !h.isEmpty {
            opts["AVURLAssetHTTPHeaderFieldsKey"] = Dictionary(h.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }, uniquingKeysWith: { $1 })
        }
        let asset = AVURLAsset(url: url, options: opts)
        let item = AVPlayerItem(asset: asset)
        self.item = item
        let legible = AVPlayerItemLegibleOutput()
        legible.suppressesPlayerRendering = true
        legible.setDelegate(self, queue: .main)
        item.add(legible)
        itemObservers.append(item.observe(\.status, options: [.new]) { [weak self] i, _ in
            nonisolated(unsafe) let i = i
            MainActor.assumeIsolated { self?.statusChanged(i) }
        })
        itemObservers.append(item.observe(\.presentationSize, options: [.new]) { [weak self] i, _ in
            let size = i.presentationSize
            MainActor.assumeIsolated {
                guard let self, size.width > 0 else { return }
                self.send(["e": "size", "w": Double(size.width), "h": Double(size.height)])
            }
        })
        endToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(["e": "state", "s": "ended"]) }
        }
        firstSent = false
        player.replaceCurrentItem(with: item)
        send(["e": "state", "s": "loading"])
        if let start = c["start"] as? Double, start > 0 {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.playImmediately(atRate: desiredRate)
    }

    private func statusChanged(_ i: AVPlayerItem) {
        switch i.status {
        case .readyToPlay:
            if i.duration.seconds.isFinite { send(["e": "duration", "d": i.duration.seconds]) }
            Task { @MainActor in await self.loadTracks(i) }
        case .failed:
            let e = i.error as NSError?
            send(["e": "state", "s": "error", "msg": e?.localizedDescription ?? "Playback failed", "kind": e.map { "\($0.domain) \($0.code)" } ?? "unknown"])
        default: break
        }
    }

    private func loadTracks(_ i: AVPlayerItem) async {
        let asset = i.asset
        audioGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        subtitleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
        options = [:]
        var next = 0
        var listed: [[String: Any]] = []
        func add(_ g: AVMediaSelectionGroup?) -> [[String: Any]] {
            listed = []
            guard let g else { return [] }
            for o in g.options {
                options[next] = Pick(group: g, option: o)
                listed.append(["id": next, "codec": o.mediaType.rawValue, "lang": o.locale?.identifier ?? "", "name": o.displayName,
                               "ch": 0, "def": false, "forced": o.hasMediaCharacteristic(.containsOnlyForcedSubtitles)])
                next += 1
            }
            return listed
        }
        let audio = add(audioGroup), subs = add(subtitleGroup)
        var o: [String: Any] = ["e": "tracks", "audio": audio, "sub": subs]
        func active(_ g: AVMediaSelectionGroup?) -> Int? {
            guard let g, let sel = i.currentMediaSelection.selectedMediaOption(in: g) else { return nil }
            return options.first { $0.value.group === g && $0.value.option == sel }?.key
        }
        if let a = active(audioGroup) { o["aa"] = a }
        if let s = active(subtitleGroup) { o["as"] = s }
        send(o)
        if let t = try? await asset.loadTracks(withMediaType: .video).first, let fps = try? await t.load(.nominalFrameRate) {
            send(["e": "hints", "hdr": "sdr", "fps": Double(fps)])
        }
    }

    private func select(_ id: Int, audio: Bool) {
        guard let item else { return }
        if id < 0 {
            if !audio, let g = subtitleGroup { item.select(nil, in: g) }
        } else if let pick = options[id] {
            item.select(pick.option, in: pick.group)
        }
    }

    private func stop() {
        itemObservers.removeAll()
        if let t = endToken { NotificationCenter.default.removeObserver(t); endToken = nil }
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil
        options = [:]
    }

    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString], nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        let text = strings.map(\.string).joined(separator: "\n")
        Task { @MainActor in self.send(["e": "cue", "text": text]) }
    }

    /// The app left the foreground: a paused picture, no stray audio.
    func suspend() { player.pause() }
}
