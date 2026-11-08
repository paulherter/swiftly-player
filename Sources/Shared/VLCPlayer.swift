import AVFoundation
import AVKit
import CoreText
import CryptoKit
import ImageIO
import OSLog
import JellyfinKit
import Network
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// **The subtitle look the app draws** (``SubtitleOverlay``): font, base size and height of the
/// picture; the look itself is the user's saved choice (``SubtitleLook``, shared with the other
/// platforms).
enum SubtitleStyle {
    static let fontName = "Inter18pt-SemiBold"

    /// The saved look. Read from the defaults, not from `AppModel`, because the
    /// library is created far from any model.
    static var look: SubtitleLook {
        SubtitleLook.read(UserDefaults.standard.data(forKey: "utAussehen"))
    }

    /// Base scale on the default size (1 = 6.25 % of the picture height).
    @MainActor static var baseScale: Float {
        #if os(tvOS)
        0.88
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? 0.82 : 0.78
        #else
        0.78
        #endif
    }

    /// The text scale for the look.
    @MainActor static func size(for look: SubtitleLook) -> Float {
        Float(SubtitleLook.textScalePercent(look: look, baseScale: Double(baseScale))) / 100
    }

    /// Height of the screen in pixels in the way the picture is shown (landscape on
    /// the phone). It only sets how far "Higher" lifts the text.
    @MainActor static var outputHeight: Int {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let screen = scenes.first?.screen else { return 1080 }
        let pixels = screen.nativeBounds.size
        return Int(min(pixels.width, pixels.height))
        #else
        guard let screen = NSScreen.main else { return 1080 }
        return Int(screen.frame.height * screen.backingScaleFactor)
        #endif
    }

    static func fontSignIn() {
        guard let address = Bundle.main.url(forResource: "Inter-SemiBold", withExtension: "ttf") else {
            AppLog.writeOut("[Untertitel] Inter-SemiBold.ttf fehlt im Paket")
            return
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(address as CFURL, .process, &error) {
            AppLog.writeOut("[Untertitel] Schrift nicht angemeldet: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
    }
}

/// Additionally writes messages to a file in the app container.
///
/// When testing with Wi-Fi off, the log connection to the Mac drops too; without
/// a file the interesting part stays invisible.
enum AppLog {
    nonisolated(unsafe) private static var grip: FileHandle?
    private static let barrier = NSLock()

    /// **Not `Documents` on TV.**
    ///
    /// tvOS gives apps no writable documents directory; `createFile` fails there,
    /// silently, because nobody checks the return value. The log therefore
    /// **never** wrote on tvOS and nobody noticed: a tool that silently does
    /// nothing looks like one with nothing to show.
    ///
    /// `Caches` is what works there. For a file that is capped at 256 KB anyway
    /// and serves debugging only, that is right; it should not persist.
    static let path: URL = {
        #if os(tvOS)
        let folder: FileManager.SearchPathDirectory = .cachesDirectory
        #else
        let folder: FileManager.SearchPathDirectory = .documentDirectory
        #endif
        return FileManager.default
            .urls(for: folder, in: .userDomainMask)[0]
            .appendingPathComponent("swiftly.log")
    }()

    static func writeOut(_ text: String) {
        // **The buffer applies in every build.** The user shares their log from it
        // (`LogRing`, Profile -> "Share log"). Redaction happens there on
        // entry.
        LogRing.shared.append(text)

        // A debugging tool does not belong in the shipped version: the file lives in
        // `Documents`, is backed up to iCloud and grows to 256 KB at runtime.
        // `Logger` stays, it is made for this.
        // `DEVLOG` is set by `Werkzeuge/to-iphone.sh` for a fast (Release) test build.
        #if !DEBUG && !DEVLOG
        return
        #else
        print(text)
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        let row = "\(stamp) \(text)\n"
        barrier.lock(); defer { barrier.unlock() }
        if grip == nil {
            let fm = FileManager.default
            if !fm.fileExists(atPath: path.path) {
                fm.createFile(atPath: path.path, contents: nil)
            }
            // Truncate at launch if it has grown large. It is for debugging, not
            // archiving.
            if let size = try? fm.attributesOfItem(atPath: path.path)[.size] as? Int,
               size > 256 * 1024 {
                try? Data().write(to: path)
            }
            grip = try? FileHandle(forWritingTo: path)
            // `_ =` because `seekToEnd()` returns the new offset and `try?` turns it
            // into a `UInt64?` that nobody reads.
            _ = try? grip?.seekToEnd()
        }
        try? grip?.write(contentsOf: Data(row.utf8))
        #endif
    }
}

/// **The first seconds after opening, to the millisecond.**
///
/// Reported: on all devices the picture stalls briefly about a second after
/// every start, then runs fine. The tech badge sees nothing of it because it
/// averages over a second. Which candidate it is (audio output and clock,
/// track selection, loading screen, first report to the server, blocked main
/// thread) only a timeline can tell. Every line therefore carries
/// `[Start] +ms` from opening and lands in the shared log.
///
/// Runs only for the first ``dauer`` seconds after opening. On in debug
/// builds, off otherwise: the 10 ms tick should not run for testers.
/// Enable: key `startmessung` set to `true` in the user defaults.
/// Remove once the cause is known.
final class StartMeasurement: @unchecked Sendable {
    static let shared = StartMeasurement()

    /// Measured for this long after opening.
    static let duration: TimeInterval = 4

    static var an: Bool {
        #if DEBUG
        UserDefaults.standard.object(forKey: "startmessung") as? Bool ?? true
        #else
        UserDefaults.standard.bool(forKey: "startmessung")
        #endif
    }

    private let barrier = NSLock()
    private var beginning: Date?

    /// New start: the clock begins at zero.
    func begin() {
        guard Self.an else { return }
        barrier.lock(); beginning = Date(); barrier.unlock()
    }

    /// Milliseconds since opening, or `nil` outside the window.
    var milliseconds: Int? {
        barrier.lock(); defer { barrier.unlock() }
        guard let beginning else { return nil }
        let since = Date().timeIntervalSince(beginning)
        return since <= Self.duration ? Int(since * 1000) : nil
    }

    /// A timestamped line, only inside the window, from any thread.
    func mark(_ text: String) {
        guard let ms = milliseconds else { return }
        AppLog.writeOut("[Start] +\(ms) ms \(text)")
    }
}

// MARK: - The player surface

/// **The player surface the screens talk to.** One view per screen; the Aether engine
/// (``AetherPlayerEngine``) draws into it and this class forwards: position, tracks, tempo,
/// delays, fit, picture in picture. The name stays from the time when two players stood behind it.
@MainActor
final class VLCPlayerView: BaseView {

    static let log = Logger(subsystem: "de.paulherter.swiftly", category: "player")

    /// Set by the test runs to switch picture in picture off.
    static var pipDisabled = false

    private static let liveViews = NSHashTable<VLCPlayerView>.weakObjects()
    /// A player is open: the subtitle look read at its start stays until the next title.
    static var playersOpen: Bool { liveViews.allObjects.contains { !$0.finallyStopped } }

    #if os(iOS)
    var onPiPAvailable: ((Bool) -> Void)?
    var onPiPStateChanged: ((Bool) -> Void)?
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if canImport(UIKit)
        backgroundColor = .black
        #else
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        #endif
        Self.liveViews.add(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var intentionalEnded = false
    var finallyStopped = false

    // MARK: Volume

    var requestVolume: Int32?

    func volumeSet(_ percent: Int) {
        requestVolume = Int32(min(max(percent, 0), 100))
        avEngine?.volume(percent)
    }

    /// The engine starts its sound itself after the start seek; there is nothing to hold back.
    func holdBackAudio(_ back: Bool) {}

    static var handoffFadeIn = false

    /// The hand-over's still image: Aether draws into a layer that cannot be snapshotted.
    func stillImage(width: Int) async -> CGImage? { nil }

    // MARK: State

    private(set) var restoring = false
    var onRestoration: ((Bool) -> Void)?

    var goodPoint: Double { avEngine?.lastGood ?? lastGoodPosition }
    var seeksToStart: Bool { avEngine.map { !$0.startSettled } ?? false }
    var startReady: Bool { avEngine?.startSettled ?? false }
    var showsImage: Bool { avEngine?.pictureShown ?? false }
    var lastGoodPosition: Double = 0
    var firstFrameHint: String? { nil }
    var matroskaTrusted: Bool { false }
    /// The engine does not report decoder counters.
    var statistics: PlayStats? { nil }

    override func didAddSubview(_ subview: BaseView) {
        super.didAddSubview(subview)
        subview.frame = bounds
        subview.autoresizingMask = BaseView.growing
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: BaseView.withoutRequestMetric, height: BaseView.withoutRequestMetric)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        areasCatchUp()
    }
    #else
    override func layout() {
        super.layout()
        areasCatchUp()
    }
    #endif

    private func areasCatchUp() {
        for sub in subviews { sub.frame = bounds }
        avEngine?.place(in: bounds)
    }

    // MARK: Picture in picture

    #if os(iOS)
    var isPiPPossible: Bool { avEngine?.pipPossible ?? false }

    var pipUnavailableReason: String? {
        if !AVPictureInPictureController.isPictureInPictureSupported() {
            return String(localized: "Dieses Gerät kann kein Bild-im-Bild. Im Simulator geht es nie, auf dem iPhone schon.")
        }
        return avEngine?.pipPossible == true ? nil : String(localized: "Bild-im-Bild wird vorbereitet…")
    }
    func startPiP() { avEngine?.startPiP() }
    func stopPiP()  { avEngine?.stopPiP() }
    #endif

    func refreshPiPState() {
        #if os(iOS)
        guard !Self.pipDisabled else { return }
        avEngine?.refreshPiP()
        #endif
    }

    // MARK: Start

    /// How much buffer the next start keeps; Aether manages its own, kept for the callers.
    var buffer: BufferLevel = .normal

    /// Which tracks the next start wants; set before `play(url:)`.
    var trackRequest: TrackRequest?

    /// The inputs of ``wendeLanguagesAn(audio:subtitle:automatic:source:title:originalLanguage:)``.
    struct TrackRequest {
        let audio: String
        let subtitle: String
        let automatic: Bool
        let source: MediaSource?
        let title: String?
        /// Sent by another device with the title (``PlayOrder``). Belongs to this
        /// request only: the next episode gets a new one without it.
        var ordered: TrackIndices? = nil
        /// What the engine needs besides the address; `nil` for files on the device.
        var engine: EngineRequest? = nil
    }

    /// The engine while it plays this title.
    var avEngine: (any PlaybackBackend)?
    /// Fill, tempo: asked for before the engine exists (the screen sets them right after `play`),
    /// so they are kept and handed to it.
    var fillWish = false
    var tempoWish: Float = 1
    /// Counts starts so a late answer for an old start is dropped.
    var avCall = 0

    /// `softwareDecoder` is kept for the callers: Aether picks its software route itself.
    func play(url: URL, offSeconds: Double = 0, container: String? = nil,
              subtitle: [SubtitleFile] = [], softwareDecoder: Bool = false) {
        guard !finallyStopped else {
            AppLog.writeOut("[Player] play nach stop verworfen")
            return
        }
        startEngine(url: url, offSeconds: offSeconds, container: container, subtitle: subtitle)
    }

    // MARK: Reports

    /// Called when the engine's clock starts or stops. The play button hangs on this.
    var runsReported: ((Bool) -> Void)?
    /// Called on every external seek with the target, so the server learns of it at once.
    var jumpReported: ((Double) -> Void)?
    /// If the engine cannot open the title or fails before the first picture, this reports the
    /// reason. The UI then shows a message instead of endless black.
    var startErrorReported: ((String) -> Void)?

    func pause() {
        if pausedSince == nil { pausedSince = Date() }
        avEngine?.pause()
        refreshPiPState()
    }

    /// Since when it has been paused, for ``PauseJumpBack``; cleared as soon as it runs again.
    var pausedSince: Date?

    /// Whole picture (`false`) or fill (`true`), both without distortion.
    func fillFrame(_ an: Bool) {
        fillWish = an
        avEngine?.fill(an)
    }

    /// The stream's picture size in pixels, `zero` before the first picture.
    var videoSize: CGSize { avEngine?.videoSize ?? .zero }

    /// Continues playback, with the audio session active (after an interruption it is not).
    /// `jumpBack`: a bit back after a long pause (``PauseJumpBack``). Returns the target so the
    /// display adopts it at the same moment.
    @discardableResult
    func resume(jumpBack: Bool = false) -> Double? {
        let since = pausedSince
        pausedSince = nil
        var target: Double?
        if jumpBack,
           let z = PauseJumpBack.target(position: positionSeconds, pausedSince: since,
                                        now: Date(), inGroup: false) {
            AppLog.writeOut("[Player] Fortsetzen nach \(Int(Date().timeIntervalSince(since ?? Date()))) s Pause"
                + " — vorher auf \(Int(z)) s")
            seek(toSeconds: z)
            target = z
        }
        #if os(iOS) || os(tvOS)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            AppLog.writeOut("[Ton] Sitzung vor dem Weiterspielen nicht aktivierbar: "
                + error.localizedDescription)
        }
        #endif
        avEngine?.resume()
        refreshPiPState()
        return target
    }

    func stop() {
        intentionalEnded = true
        finallyStopped = true
        avCall += 1
        avEngine?.stop(resetDisplay: true)
        avEngine = nil
        // The screen's closures capture its whole state; release them.
        onRestoration = nil
        runsReported = nil
        jumpReported = nil
        startErrorReported = nil
        tracksReported = nil
        #if os(iOS)
        onPiPAvailable = nil
        onPiPStateChanged = nil
        #endif
    }

    // MARK: Tracks and speed

    var audioTracks: [SurfaceTrack] { avEngine.map(avAudioTracks) ?? [] }
    var subtitleTracks: [SurfaceTrack] { avEngine.map(avSubtitleTracks) ?? [] }
    var selectedAudioTrack: SurfaceTrack? { audioTracks.first(where: \.isSelected) }
    var selectedSubtitle: SurfaceTrack? { subtitleTracks.first(where: \.isSelected) }

    /// What the log says about the sound at the start: the tracks and the output.
    func channelsPostMeasure() {
        let selected = selectedAudioTrack?.trackName ?? "—"
        #if os(macOS)
        AppLog.writeOut("[Kanäle] gewählt: \(selected)")
        #else
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        AppLog.writeOut("[Kanäle] gewählt: \(selected)"
            + " · Ausgang \(output?.portType.rawValue ?? "—")"
            + " nimmt \(output?.channels?.count ?? 0)"
            + ", könnte \(session.maximumOutputNumberOfChannels)")
        #endif
    }

    var trackTitle: String?
    var trackSource: MediaSource?
    var trackOriginal: String?
    var subtitleFiles: [SubtitleFile] = []
    var reportedTracks = TrackIndices()

    /// The server indices of the tracks that play now.
    var playingTracks: TrackIndices {
        if let avEngine { return TrackIndices(audio: avEngine.audioIndex, subtitle: avEngine.subtitleIndex) }
        return reportedTracks
    }

    var tracksReported: ((TrackIndices) -> Void)?

    #if DEBUG
    static weak var recent: VLCPlayerView?
    #endif

    static func subtitleRememberTimes(_ address: URL) -> String {
        Insecure.MD5.hash(data: Data(address.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func audioLabel(_ surface: SurfaceTrack) -> String {
        guard let stream = surface.stream else { return surface.prettyName }
        return OriginalAudio.label(surface.prettyName, language: stream.language, stream: stream,
                                   originalLanguage: trackOriginal)
    }

    func wendeLanguagesAn(audio: String, subtitle: String, automatic: Bool,
                          source: MediaSource?, title: String?, originalLanguage: String? = nil) {
        guard let avEngine else { return }
        avTracksApply(avEngine, audio: audio, subtitle: subtitle, automatic: automatic,
                      source: source, title: title, originalLanguage: originalLanguage)
    }

    func trackIndicesReport(_ new: TrackIndices) {
        guard new != reportedTracks else { return }
        reportedTracks = new
        tracksReported?(new)
    }

    func selectAudioTrack(_ surface: SurfaceTrack) {
        if let avEngine { avAudioChosen(avEngine, surface) }
    }

    func selectSubtitle(_ surface: SurfaceTrack?) {
        if let avEngine { avSubtitleChosen(avEngine, surface) }
    }

    func subtitleNames() -> [String: String] {
        avEngine.map(avSubtitleNames) ?? [:]
    }

    var tempo: Float {
        get { avEngine?.tempo ?? tempoWish }
        set {
            tempoWish = newValue
            avEngine?.tempo = newValue
            refreshPiPState()
        }
    }

    // MARK: Delay

    var subtitleDelay = Delay.null {
        didSet { avEngine?.subtitleDelay = subtitleDelay }
    }
    var audioDelay = Delay.null {
        didSet { avEngine?.audioDelay = audioDelay }
    }

    func delayForNewTitle(oldTitle: String, oldSeries: String?,
                          newTitle: String, addedSeries: String?) {
        subtitleDelay = .forNewTitle(subtitleDelay, oldTitle: oldTitle,
                                     oldSeries: oldSeries, newTitle: newTitle,
                                     addedSeries: addedSeries)
        audioDelay = .forNewTitle(audioDelay, oldTitle: oldTitle,
                                  oldSeries: oldSeries, newTitle: newTitle,
                                  addedSeries: addedSeries)
    }

    // MARK: Position

    var positionSeconds: Double { avEngine?.position ?? 0 }
    var durationSeconds: Double { avEngine?.durationSeconds ?? trackSource?.runtimeSeconds ?? 0 }
    var isPlaying: Bool { avEngine?.isPlaying ?? false }

    func seek(toSeconds seconds: Double) {
        // A target of NaN or infinity must not reach the engine.
        guard let seconds = JumpTarget.seconds(seconds) else {
            AppLog.writeOut("[Player] Sprungziel ohne Zahl verworfen")
            return
        }
        avEngine?.move(to: seconds)
        jumpReported?(seconds)
    }

    func jump(seconds: Int32) {
        guard let avEngine else { return }
        let target = max(avEngine.position + Double(seconds), 0)
        avEngine.move(to: target)
        jumpReported?(target)
    }
}
