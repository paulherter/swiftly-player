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
import VLCKit

/// **How text subtitles look** (SRT, WebVTT, ASS without its own style).
///
/// VLC's default was Helvetica Neue, 6.25 % of the picture height, a thick
/// black outline (4 % of the font height) and a hard semi-dark offset: loud
/// and cheap. The model is Netflix: semibold, white, thin outline, light
/// shadow, a bit higher above the edge. Linux, Windows and Android use the
/// same values (`Player.swift`, `PlayerPage.kt`).
///
/// - **Font:** Inter SemiBold ships with the app (`Medium/`, OFL). The system
/// font does not reach VLC: `fonts/darwin.c` looks up family names via
/// CoreText, where SF Pro is invisible. Registered for the process, CoreText
/// finds Inter and hands VLC the file path.
/// - **Size:** factor on VLC's default (6.25 % of the picture height), a bit
/// larger on TV because viewers sit farther away.
/// - **Outline/shadow:** `outline-thickness` is a percentage of the font
/// height; 3 instead of VLC's 4. VLC cannot do a soft shadow, so only a short,
/// semi-transparent downward offset. Compared against a 2 % outline on a
/// bright picture: that looked hollow and was hard to read.
/// - **Margin:** `sub-margin` in video pixels; VLC 4 otherwise places the
/// text closer to the bottom edge than VLC 3.
///
/// ASS with its own style is drawn by libass, and picture subtitles (PGS,
/// VobSub, DVB) are finished images; both stay as they are.
enum SubtitleStyle {
    static let fontName = "Inter18pt-SemiBold"

    static let vlcOptions = [
        "--freetype-font=\(fontName)",
        "--freetype-color=16777215",
        "--freetype-outline-thickness=3",
        "--freetype-outline-opacity=230",
        "--freetype-shadow-opacity=120",
        "--freetype-shadow-distance=0.04",
        "--freetype-shadow-angle=-70",
        "--sub-margin=30",
    ]

    /// Factor on VLC's default (1 = 6.25 % of the picture height).
    @MainActor static var size: Float {
        #if os(tvOS)
        0.88
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? 0.82 : 0.78
        #else
        0.78
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
        #if !DEBUG
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

    /// VLC messages additionally let through inside the window: everything
    /// about clock, audio output and late pictures.
    static let vlcStitchWords = ["late", "early", "sampl", "discontinu", "flush",
                                "jitter", "drift", "screwed", "clock", "restart",
                                "buffering done", "decoder wait", "first picture",
                                "aout", "vout"]

    /// Of the `debug` lines only those saying when audio really starts and
    /// whether the clock jumps afterwards. Narrow on purpose: at `debug` VLC
    /// emits hundreds of lines per second, and writing them all measures the
    /// writing.
    static let vlcDebugKeywords = ["deferring start", "starting late", "outputlatency",
                                     "iobufferduration", "displayed late", "clock context",
                                     "resetting master clock", "discontinuity", "too late",
                                     "audio output", "output on", "underrun",
                                     "timing report", "sample renderer started", "timebase came up"]
}

#if os(iOS)
/// What VLC needs to know about playback. All times in milliseconds.
///
/// VLC calls these methods from its own thread, hence no main-actor
/// isolation and no access to the UI.
final class MediaController: NSObject, VLCPictureInPictureMediaControlling {
    private let player: VLCMediaPlayer
    init(player: VLCMediaPlayer) { self.player = player }

    func play()  { player.play() }
    func pause() { player.pause() }

    func seek(by offset: Int64, completion: @escaping () -> Void) {
        player.jump(withOffset: Int32(clamping: offset), completion: completion)
    }

    func mediaLength() -> Int64    { Int64(player.media?.length.intValue ?? 0) }
    func mediaTime() -> Int64      { Int64(player.time.intValue) }
    func isMediaSeekable() -> Bool { player.isSeekable }
    func isMediaPlaying() -> Bool  { player.isPlaying }
}
#endif

/// The view the picture lands in, and also VLC's drawing surface.
///
/// According to the header, `drawable` accepts a UIView directly. That is
/// used here instead of an intermediate object: VLC attaches its video surface
/// and expects it to be attached **immediately**. A detour through
/// `Task { @MainActor in ... }` is too late: on every seek VLC rebuilds the
/// video output and the surface was never attached. That caused the frozen
/// picture after seeking, along with a stuck player.
///
/// For picture-in-picture, `VLCPictureInPictureDrawable` suffices; its two
/// return values do not collide with UIView. The conformance is further down
/// in its own extension: tvOS has no picture-in-picture, and a conditional
/// inheritance list would need an unbalanced body.
///
/// **This file deliberately lives in `Shared`.** Everything here (the
/// `mkv_trusted` trick, the start position as a media option, stall
/// detection, reconnecting after a network change) applies verbatim on both
/// platforms. Maintained twice it would drift apart, and the seek bug would
/// return on one side.
@MainActor
final class VLCPlayerView: BaseView {

    static let log = Logger(subsystem: "de.paulherter.swiftly", category: "player")

    /// Debugging only: disables picture-in-picture entirely to measure whether
    /// VLC's video output is built differently as a result.
    /// Swiftfin has no PiP, and Swiftfin seeks quickly.
    static var pipDisabled = false

    /// **A custom library so VLC does not drop pictures up front.**
    ///
    /// DVD rips stuttered on Apple TV and iPhone, 4K HEVC did not; a tester saw
    /// all DVD rips stutter, progressive ones too. Device feedback: decoded
    /// avg 22.6-25.4, shown avg 22.6-23.7, dropped up to 298.
    ///
    /// **The output path, logged in the tvOS simulator** (its VLCKit is built
    /// with TARGET_OS_IPHONE like the device): `samplebufferdisplay` only
    /// accepts `CVPX_BGRA` (VLCSampleBufferDisplay.m, CreateCVPXConverter).
    /// Software pictures therefore go `I420 -> swscale -> BGRA -> cvpx`, every
    /// picture on the CPU. HEVC arrives from VideoToolbox as a CVPixelBuffer
    /// already. The Mac takes a different path (`vout_macosx`, OpenGL) and shows
    /// none of this.
    ///
    /// **Dropping happens before drawing, based on an estimate.** The vout takes
    /// the *maximum* of filter and render duration (video_output.c,
    /// IsPictureLateToStaticFilter) and discards a picture if it would then be
    /// too late. A single time spike in the converter costs whole pictures even
    /// though the CPU is not saturated.
    ///
    /// Measured on the tvOS simulator, process throttled to background priority,
    /// rebuilt files (MPEG-2 720x576 5 Mbit/s, AC-3 5.1, VobSub, MKV), 25 s each,
    /// deinterlace `bob`:
    ///
    /// Setting                              shown/s     lost
    /// default, interlaced (2 runs)         12.4-12.8   311
    /// default, progressive (2 runs)        14.0-16.4   211-284
    /// --no-drop-late-frames, interlaced    24.9-25.3   0
    /// --no-drop-late-frames, progressive   24.0-24.9   0
    /// :no-drop-late-frames (media)         11.2        344
    /// --no-skip-frames alone               15.5        230
    /// --swscale-mode=0                     15.2        246
    ///
    /// Unthrottled, everything runs at 25/s. **As a media option it has no
    /// effect:** the vout hangs off the player and inherits from the library, not
    /// from the input. `initWithOptions:` appends to VLCKit's defaults
    /// (VLCLibrary.m:169), so nothing is lost. Android has always set the option
    /// in `PlayItem`.
    ///
    /// Cost: a really late picture is shown late instead of skipped. With
    /// VideoToolbox material this hardly occurs.
    /// Sources: code.videolan.org/videolan/vlc/-/merge_requests/3436
    /// (samplebufferdisplay), VLC source in the build tree.
    static let library: VLCLibrary = {
        SubtitleStyle.fontSignIn()
        // `--deinterlace-mode=bob` here and not on the media for the same reason;
        // see `open`, section "Entflechten".
        return VLCLibrary(options: ["--no-drop-late-frames", "--deinterlace-mode=bob"]
                          + SubtitleStyle.vlcOptions)
    }()

    let player = VLCMediaPlayer(library: VLCPlayerView.library)

    #if os(iOS)
    fileprivate lazy var controller = MediaController(player: player)
    fileprivate var pipWindow: VLCPictureInPictureWindowControlling?

    var onPiPAvailable: ((Bool) -> Void)?
    var onPiPStateChanged: ((Bool) -> Void)?
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if canImport(UIKit)
        backgroundColor = .black
        #else
        // AppKit has no background color on the view; it sits on the layer, which
        // must be requested first.
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        #endif

        // **VLC's own log, sent where it can be read.**
        //
        // It used to go to `VLCConsoleLogger`, i.e. the system console. Nobody can
        // reach that on a TV; the lines that say what the demuxer is stuck on were
        // written and still unreachable. Same mistake as the own log writing to
        // `Documents`, where tvOS permits no writes: a tool that silently runs into
        // nothing looks like one with nothing to report.
        VLCPlayerView.library.loggers = [FileLog()]
        player.currentSubTitleFontScale = SubtitleStyle.size

        // Must be the view itself: VLC checks the drawable for
        // VLCPictureInPictureDrawable, and the interface lives here. Placed on an
        // inner view, PiP never becomes ready, and the inner view brings nothing
        // anyway.
        player.drawable = self
        player.delegate = reporter
        reporter.startPlay = { [weak self] in
            Task { @MainActor in self?.startPositionSet() }
        }

        // VLC 4 does not reconnect a dropped HTTP connection. In
        // modules/access/http/resource.c there is a 'retry:', but it applies only to
        // authentication and redirects, not to a drop mid-stream. The prefetch
        // buffer (16 MiB, a good ten seconds) then runs dry and the picture freezes.
        // That is exactly why Plex and Streamyfin hang at the same spot.
        networkGuard.pathUpdateHandler = { [weak self] path in
            let leg = path.availableInterfaces.map(\.name).joined(separator: ",")
            let reachable = path.status == .satisfied
            Task { @MainActor in self?.legSwitched(leg, reachable: reachable) }
        }
        reporter.stateSwitch = { [weak self] condition in
            Task { @MainActor in self?.stateSwitched(condition) }
        }
        reporter.subtitleTo = { [weak self] in
            Task { @MainActor in self?.openSubtitleSet() }
        }
        networkGuard.start(queue: DispatchQueue(label: "de.paulherter.swiftly.netz"))
    }

    // MARK: - Network change and stalls

    private let networkGuard = NWPathMonitor()
    private var lastLeg: String?
    private var lastAddress: URL?
    private var lastContainer: String?
    private var lastNewLayout = Date.distantPast
    private var watchdog: Timer?
    private var lastKnownTime: Int32 = -1

    /// Last state of the two VLC counters, for ``bildfluss(now:)``.
    /// `nil` means no comparison value yet, hence no verdict.
    private var lastImages: UInt64?
    private var lastBytes: UInt64?
    private var standsSince: Date?
    private var networkReachable = true
    private var waitsNetwork = false
    private var networkSwitchSince: Date?
    private var settleSince: Date?
    /// Ended by the user. Without it, closing the player would itself count as
    /// a drop and reopen the stream.
    private var intentionalEnded = false
    /// `stop()` is final: the surface is torn down afterwards. Separate from
    /// `intentionalEnded` because `play` resets that one. Otherwise a later
    /// episode change would keep playing on the torn-down surface: audio without
    /// picture.
    private var finallyStopped = false
    /// While set, the freshly built stream has not reached its position yet.
    /// Until then its time must not overwrite the good position, or the watchdog
    /// remembers the seconds the new stream plays from the start, and the next
    /// recovery lands at the beginning of the movie.
    private var firstPoint: Double?

    /// **Muted while the start position is being sought.**
    ///
    /// The jump to the remembered position deliberately happens *after* opening,
    /// not as `:start-time`; see `startPositionSet()`. It needs a running
    /// picture (`player.time > 0`). The picture is hidden meanwhile, **the audio
    /// was not**: you heard about a second from the start of the episode, then it
    /// jumped to the right place.
    ///
    /// Reported on the Mac, but it affects every platform since it is the same
    /// path.
    ///
    /// Controlled via the volume, **not** `isMuted`: a deadlock is reported for
    /// VLCKit's `setMuted:` (bug 111).
    private var volumePrior: Int32?

    /// The volume set by the viewer (0 to 100), `nil` = never set.
    /// Applied when the hold is released, otherwise immediately.
    private var requestVolume: Int32?

    func volumeSet(_ percent: Int) {
        let value = Int32(min(max(percent, 0), 100))
        requestVolume = value
        // While audio is held back, the hold owns the volume.
        guard volumePrior == nil, let audio = player.audio else { return }
        audio.volume = value
    }

    private func holdBackAudio(_ back: Bool) {
        // **The silent exit.** If the audio output does not exist yet at opening,
        // the hold silently fails here, and the viewer hears exactly the second from
        // the start that they should not hear. Reported again although the hold is
        // in place; only a measurement can say whether this exit is the cause.
        guard let audio = player.audio else {
            AppLog.writeOut("[Ton] Rueckhalt(\(back)) ohne Tonausgang — wirkungslos")
            return
        }
        if back {
            guard volumePrior == nil else { return }
            // **What VLC reports before the first sound is not a measurement.**
            //
            // `holdBackAudio(true)` runs in `open(...)`, before `player.media` is
            // set: the audio output does not exist yet and `volume` is 0 or -1. Storing
            // that and later "restoring" it meant permanently silent.
            //
            // That is exactly what happened.
            let now = audio.volume
            volumePrior = now > 0 ? now : 100
            audio.volume = 0
            AppLog.writeOut("[Ton] stumm ab jetzt (war \(now), gemerkt \(volumePrior!))")
        } else if let before = volumePrior {
            volumePrior = nil
            StartMeasurement.shared.mark("Ton freigegeben")
            // The viewer's wish (volume slider), otherwise the state from before the
            // hold. 0 is a target only if the viewer set it.
            let target = requestVolume ?? (before > 0 ? before : 100)
            if Self.handoffFadeIn {
                Self.handoffFadeIn = false
                audioFadeIn(audio, on: target)
            } else {
                audio.volume = target
                AppLog.writeOut("[Ton] wieder laut (\(before))")
            }
            audioStateReport()
        }
    }

    /// **Where the audio stands after release**, part of ``Startmessung``.
    /// Volume and mute as VLC reads them, whether audio buffers are really
    /// played, and the state of the audio session, for the case that a start
    /// yields picture without sound.
    private func audioStateReport() {
        guard StartMeasurement.an else { return }
        for delay in [1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let audio = self.player.audio else { return }
                let stats = self.player.media?.statistics
                var row = "Tonstand · Lautstärke \(audio.volume) · stumm \(audio.isMuted)"
                    + " · Ton dekodiert \(stats?.decodedAudio ?? 0), gespielt \(stats?.playedAudioBuffers ?? 0),"
                    + " verloren \(stats?.lostAudioBuffers ?? 0)"
                #if !os(macOS)
                let session = AVAudioSession.sharedInstance()
                let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue)/\($0.channels?.count ?? 0)" }
                row += " · Sitzung \(session.category.rawValue)/\(session.mode.rawValue)"
                    + " Politik \(session.routeSharingPolicy.rawValue) Optionen \(session.categoryOptions.rawValue)"
                    + " · Ausgang \(outputs.joined(separator: ",")) · Systemlautstärke \(session.outputVolume)"
                    + " · andere spielen \(session.isOtherAudioPlaying)"
                #endif
                StartMeasurement.shared.mark(row)
            }
        }
    }

    /// **The next playback comes from a handoff** ("continue watching here"):
    /// it starts muted and fades the audio in as soon as its first picture is
    /// up, instead of starting at full volume beneath the card. Applies to
    /// exactly one start.
    static var handoffFadeIn = false

    /// **The frozen frame as an image**, for the handing-off card, which lies in
    /// its own layer above everything. VLC writes it as PNG; this waits up to
    /// 0.6 s for it. `width` in pixels, aspect ratio preserved. `nil` if
    /// nothing arrived.
    func stillImage(width: Int) async -> CGImage? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uebergabe-\(UUID().uuidString).png")
        player.saveVideoSnapshot(at: url.path, withWidth: Int32(width), andHeight: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        for _ in 0 ..< 40 {
            try? await Task.sleep(for: .milliseconds(15))
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            return image
        }
        return nil
    }

    /// Linear to `target` over 0.6 s in 40 ms steps; VLC has no ramp of its own.
    /// Via the volume, not `isMuted` (see above).
    private func audioFadeIn(_ audio: VLCAudio, on target: Int32) {
        AppLog.writeOut("[Ton] Übergabe: blendet auf (\(target))")
        let steps = 15
        Task { @MainActor [weak self] in
            for i in 1 ... steps {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, !self.intentionalEnded, self.volumePrior == nil else { return }
                audio.volume = Int32(Double(target) * Double(i) / Double(steps))
            }
        }
    }


    /// **Safety net against permanent silence.**
    ///
    /// Audio is held back in exactly one place and released in four. If one of
    /// them is ever missed, or a path appears that nobody knows today, the movie
    /// stays silent, the worst silent failure this player can have. The tick
    /// therefore checks as well: if fading in is no longer in progress, nothing
    /// may remain held back.
    private func releaseAudioIfDue() {
        guard volumePrior != nil, !seeksToStart else { return }
        AppLog.writeOut("[Ton] Rueckhalt hing noch — freigegeben")
        holdBackAudio(false)
    }

    /// The stream is currently being rebuilt.
    ///
    /// The UI needs this: on a drop VLC reads an end of file, sets the time to the
    /// length and discards the picture. Without this knowledge the slider shows
    /// the end of the movie and the screen stays black, as if the movie were over
    /// rather than just the connection missing.
    private(set) var restoring = false {
        didSet {
            guard oldValue != restoring else { return }
            onRestoration?(restoring)
        }
    }
    var onRestoration: ((Bool) -> Void)?

    /// The position the UI should show during the rebuild, instead of the movie
    /// end VLC jumped to.
    var goodPoint: Double { lastGoodPosition }

    /// The stream is still seeking its start position.
    ///
    /// While that runs, VLC reports the time of the not-yet-seeked stream, i.e.
    /// nearly zero. Showing it makes the slider sit at the start first and then
    /// visibly jump forward.
    var seeksToStart: Bool { startPosition != nil || firstPoint != nil }

    /// **Is the start fully complete?** Including the paused start
    /// (`startJump`), which resumes by itself at the target. Pausing earlier
    /// (watch together: reporting "ready") would let the movie start running again
    /// unnoticed.
    var startReady: Bool { startJump == nil && !seeksToStart }

    /// Whether `mkv_trusted` was set for this stream; see `open`.
    private(set) var matroskaTrusted = false

    // MARK: Seek by byte position

    /// **Whether time-based seeks work for this file.**
    ///
    /// Measured, not assumed. For one episode VLC read the file's index and
    /// aborted while parsing ("MKV/Ebml Parser: m_el[mi_level] == NULL"), then
    /// "loading cues done" with zero entries. For the next seek it then chose
    /// `fpos 3154, pts 0`, the start of the file, and read 125 MB forward. At
    /// 11 Mbit/s that is a minute and a half per seek, and the next one starts
    /// over.
    ///
    /// Both VLCKit versions in use behave the same; the same file plays instantly
    /// in Swiftfin on VLCKit 3. So this is not an alpha bug but a file whose
    /// index VLC 4 cannot read.
    /// **Measurement only, not a switch.**
    ///
    /// A first attempt seeked by byte fraction instead of time when the index was
    /// unusable. Measured: that lands **just as** at the start of the file. VLC 4
    /// sends both through the same seeker, which without seek points has only the
    /// clusters already read. The fallback was the same path under another name,
    /// and because it triggers extra seeks that each read forward anew, it made
    /// things worse.
    ///
    /// What remains is the question: did the seek arrive? It goes to the log and
    /// holds back the emergency brake while one is in flight.
    private var openTarget: Double?
    private var openSince: Date?
    /// How often another path has already been tried for this target.
    private var jumpLevel = 0
    /// When a seek was last triggered, whether or not it arrived.
    private var lastJumpCommand = Date.distantPast
    /// Whether the second path is the better one for this file; measured once,
    /// then remembered for all later seeks.
    private var timeSetBetter = false



    /// Whether VLC is already outputting a picture. Before that the surface is
    /// black.
    ///
    /// After an episode change only once the **new** media has shown a picture;
    /// until then the video output and clock still belong to the old episode
    /// (`TimeAssumption.imageBelongsMedium`).
    var showsImage: Bool {
        let images = mediumSwitched ? (player.media?.statistics.displayedPictures ?? 0) : 0
        let applies = TimeAssumption.imageBelongsMedium(videoOutput: player.hasVideoOut,
                                                    shownImages: images,
                                                    afterChange: mediumSwitched)
        if applies, mediumSwitched { mediumSwitched = false }
        return applies
    }
    /// `play` on a surface that already had media.
    private var mediumSwitched = false

    /// The last position at which playback demonstrably ran.
    ///
    /// This value is the core of the recovery. On a drop VLC reads an end of
    /// file, sets the time to the movie length and goes to Stopped; querying the
    /// position only then returns the movie end, and rebuilding there gives a
    /// black picture in the last second. So the position is recorded continuously
    /// while the picture really moves forward.
    private var lastGoodPosition: Double = 0

    private var lengthSeconds: Double { durationSeconds }

    /// When switching Wi-Fi <-> cellular the device gets a different source
    /// address; the existing TCP connection is dead without anyone closing it.
    ///
    /// Without a network a rebuild is pointless; the attempt would only use up
    /// the cooldown and block the real attempt when the network returns. Instead
    /// it is noted that something is still pending.
    private func legSwitched(_ leg: String, reachable: Bool) {
        guard !finallyStopped else { return }
        let before = lastLeg
        lastLeg = leg
        networkReachable = reachable

        guard reachable else {
            if lastGoodPosition > 1 { waitsNetwork = true }
            AppLog.writeOut("[Netz] kein Weg mehr — vorgemerkt bei \(Int(lastGoodPosition)) s")
            return
        }
        // If playback had already stopped, act right away.
        if waitsNetwork {
            AppLog.writeOut("[Netz] wieder da (\(leg)) → nachholen")
            waitsNetwork = false
            newConnect(reason: "Netz zurueck")
            return
        }
        guard let before, before != leg else { return }

        // Rebuilding immediately here used to throw away a full buffer from which
        // VLC could have kept playing for minutes. The change is only noted; action
        // is taken only when the picture really stops. If the interruption is shorter
        // than the buffer, nobody notices.
        networkSwitchSince = Date()
        AppLog.writeOut("[Netz] Wechsel: \(before) → \(leg) — Puffer laeuft weiter")
    }

    /// A drop looks like an end of movie. They are told apart by the last good
    /// position: if it is well before the end, it was a dead stream, not an end.
    private func stateSwitched(_ condition: VLCMediaPlayerState) {
        StartMeasurement.shared.mark("Zustand \(VLCMediaPlayerStateToString(condition))")
        // Update on every change, otherwise the picture-in-picture window's button
        // keeps showing playback although it is paused.
        refreshPiPState()
        displaySleepLet()
        holdIdleLock()

        // Paused start: every change is a reason to act immediately rather than at
        // the next tick; for Paused this is the moment to resume.
        if startJump != nil { startJumpCheck(occasion: VLCMediaPlayerStateToString(condition)) }

        // **The button follows the machine, not the clock.**
        //
        // The play button's state used to depend on the tick, which fires every
        // 500 ms (`PlaybackTick.tickLength`), so the button flipped up to half a
        // second after the press.
        //
        // Setting it instantly in the click instead is too **early**: the picture
        // still needs its time. Measured on the Mac, three times:
        //
        // click -> VLC reports "paused"        17-25 ms
        // click -> movie time really stops    26-36 ms
        //
        // All devices here run at **120 Hz**, so a frame is 8.3 ms: that gap is three
        // to four frames, not one to two.
        //
        // So neither: the button hangs on exactly the event with which the machine
        // itself switches. Button and picture then stop at the same moment and the
        // gap disappears, not because it shrinks but because there are no longer two
        // points in time.
        //
        // Why not faster: Jellyfin Media Player and Jellium do not have the problem,
        // but both build on **libmpv**, not libvlc, which has a different output
        // queue. That is not a trick to copy, that is a different engine.
        switch condition {
        case .playing:  pausedSince = nil; runsReported?(true); delayCatchUp()
        case .paused:   if pausedSince == nil { pausedSince = Date() }; runsReported?(false)
        default:        break
        }
        guard !intentionalEnded else { return }
        guard condition == .stopped || condition == .stopping || condition == .error else { return }
        // An error before the first picture: the log says so, the vlc lines before
        // it give the reason. The UI learns of it too and shows "This will not
        // start" instead of endless black.
        if condition == .error, lastGoodPosition <= 1 {
            AppLog.writeOut("[VLC] Fehler vor dem ersten Bild")
            startErrorReported?("VLC-Fehler vor dem ersten Bild")
        }
        let length = lengthSeconds
        guard lastGoodPosition > 1 else { return }
        // If VLC does not know the length, a drop and an intended end cannot be
        // told apart. Then only act if the route changed shortly before; otherwise
        // every stop would rebuild the stream in a loop.
        let freshValue = networkSwitchSince.map { Date().timeIntervalSince($0) < 90 } ?? false
        guard length > 0 ? lastGoodPosition < length - 10 : freshValue else { return }
        AppLog.writeOut("[Netz] Zustand \(condition.rawValue): Strom tot bei \(Int(lastGoodPosition)) s von \(Int(length)) s")
        newConnect(reason: "Strom abgerissen")
    }

    /// **Did the seek arrive where it should?**
    ///
    /// Without this question "seeked" remains an intention. If VLC does not
    /// arrive, the other of the two seek paths is tried; which one works depends
    /// on the file, see `seek(toSeconds:)`.
    ///
    /// Two and a half seconds grace: a seek over a usable index lands in under a
    /// second (one range request, one cluster). Waiting longer only delays the
    /// path that arrives.
    private func jumpPostMeasure() {
        guard let target = openTarget, let since = openSince else { return }
        guard Date().timeIntervalSince(since) > 2.5 else { return }

        let actualValue = positionSeconds
        let beside = abs(actualValue - target)
        if beside <= 5 {
            openTarget = nil
            openSince = nil
            return
        }

        // **First the other path, only then the server.**
        //
        // The second attempt costs nothing but another seek command, and if it
        // arrives, the file stays on direct play without the server doing anything.
        // Only when it fails too is it really the file and not the path.
        if jumpLevel == 0 {
            jumpLevel = 1
            timeSetBetter.toggle()
            AppLog.writeOut("[VLC] Sprung auf \(Int(target)) s kam nicht an (steht bei \(Int(actualValue)) s) → anderer Weg")
            jumpTrigger(on: target, overTime: timeSetBetter)
            openSince = Date()
            return
        }

        // **It ends here.** This used to ask the server to deliver from the target
        // position, which remuxed the stream. That was the emergency exit while VLC 4
        // could not seek in some Matroska files. Since the patch to the mkv seeker
        // the player seeks by itself; if a seek still fails on both paths, that is a
        // finding and not an opportunity to break the app's basic rule.
        timeSetBetter.toggle()
        AppLog.writeOut("[VLC] Sprung auf \(Int(target)) s kam auf beiden Wegen nicht an")
        openTarget = nil
        openSince = nil
    }

    /// **Only VLC's idle lock may keep the screen awake, not the picture layer.**
    ///
    /// With the movie paused, Apple TV never went to the screensaver or to
    /// sleep. It was not the idle lock: measured in the simulator,
    /// `isIdleTimerDisabled` is `true` only while playing and becomes `false`
    /// immediately on pause and close, even after 75 s of pause. VLC's
    /// `uikit_inhibit` hangs on `vout_ChangePause` and does this correctly.
    ///
    /// What kept it awake was the `AVSampleBufferDisplayLayer` VLC puts the
    /// picture in. `preventsDisplaySleepDuringVideoPlayback` is `true` by default
    /// on iOS and tvOS, and the layer has no timebase of its own (rate always
    /// 1.0). So every picture that arrives counts as playback for it, and VLC
    /// keeps feeding pictures while paused: the last one is redisplayed every
    /// 80 ms (`VOUT_REDISPLAY_DELAY`), measured a good 11 per second, 330 in 30 s
    /// of pause. Reproduced on the Mac: the same layer with the switch on holds
    /// `PreventUserIdleDisplaySleep` as long as pictures arrive, with the switch
    /// off it does not.
    ///
    /// VLC rebuilds the layer with every new video output (episode change,
    /// rebuild after a network drop), and it sits one level deeper inside VLC's
    /// own window view. So check on every state change and every second; walking
    /// a handful of layers costs nothing. On the Mac the switch defaults to
    /// `false`, where this is a safeguard.
    private func displaySleepLet() {
        func share(_ layer: CALayer) {
            if let image = layer as? AVSampleBufferDisplayLayer, image.preventsDisplaySleepDuringVideoPlayback {
                image.preventsDisplaySleepDuringVideoPlayback = false
            }
            layer.sublayers?.forEach(share)
        }
        let root: CALayer? = layer
        root.map(share)
    }

    /// **Hold the idle lock ourselves while playing, not just VLC.**
    ///
    /// Reported on tvOS: the first episode plays without the screensaver, but
    /// after "Next episode" it appears every five minutes over the picture. VLC
    /// locks idle per window (`vlc_window_UpdateInhibitionUnlocked`: only if the
    /// window is active and fullscreen, set when creating the window and in
    /// `vout_ChangePause`). On an episode change VLC rebuilds the video output
    /// with its window; whether the lock arrives again depends on its startup.
    /// We do not rely on that: while actually playing, the lock is `true`, and on
    /// pause, end and close immediately `false`; pause may keep allowing the
    /// screensaver.
    private func holdIdleLock() {
        #if canImport(UIKit)
        let should = !intentionalEnded && !finallyStopped && player.media != nil && player.isPlaying
        if UIApplication.shared.isIdleTimerDisabled != should {
            UIApplication.shared.isIdleTimerDisabled = should
        }
        #endif
    }

    /// Second safeguard for drops where VLC stays in Playing and only the time
    /// stops: dead zone, server hiccup.
    private func checkStandstill() {
        // Second path for the start seek, in case no state change comes.
        if startPosition != nil { startPositionSet() }

        guard !intentionalEnded, player.media != nil, player.isPlaying else { return }

        jumpPostMeasure()
        releaseAudioIfDue()

        let now = player.time.intValue
        let spot = Double(now) / 1000

        // Is the stream still seeking its start position? Then the time naturally
        // stands still; that is no stall, and nothing is recorded.
        //
        // This check must live *here* and not as a guard in front: it is also the
        // only place that clears firstPoint again. As an early guard it blocked
        // itself, the loading screen stayed forever and only the audio played.
        if let target = firstPoint {
            standsSince = nil
            lastKnownTime = now
            if spot >= target - 10 {
                firstPoint = nil
                holdBackAudio(false)
            } else {
                settleSince = settleSince ?? Date()
                // Emergency brake: if the seek never arrives, the UI must still not hang on
                // the loading screen forever.
                if Date().timeIntervalSince(settleSince!) > 20 {
                    AppLog.writeOut("[VLC] Einsteuern auf \(Int(target)) s aufgegeben, weiter bei \(Int(spot)) s")
                    firstPoint = nil
                    holdBackAudio(false)
                    settleSince = nil
                }
            }
            return
        }
        settleSince = nil
        guard startPosition == nil else { standsSince = nil; return }

        if restoring, now > 0 {
            restoring = false
            AppLog.writeOut("[Netz] wiederhergestellt bei \(Int(spot)) s")
            tracksAgainSet()
        }

        if now != lastKnownTime {
            if firstFrameCheck(now: now) { return }
            imageFlow(now: now)
            lastKnownTime = now
            standsSince = nil
            // **The clock runs, but does a picture come?** Without these lines the
            // check ended here, and a stream whose clock keeps running counted as
            // healthy forever. Same thresholds as below: `StreamWatch` keeps them in one
            // place, and a wrong one costs the viewer ten seconds of movie.
            if let since = imagesStateSince {
                let duration = Date().timeIntervalSince(since)
                if case .newConnect = StreamWatch.rat(
                    standstillSince: duration,
                    networkChangeForward: networkSwitchSince.map { Date().timeIntervalSince($0) },
                    jumpOpen: openTarget != nil,
                    lastJumpForward: Date().timeIntervalSince(lastJumpCommand),
                    bufferGrewPre: reporter.bufferGrewPre) {
                    imagesStateSince = nil
                    newConnect(reason: "kein neues Bild seit \(Int(duration)) s, Uhr laeuft weiter")
                    return
                }
            }
            let length = lengthSeconds
            // Only record what is plausible: after a drop, the movie end would
            // otherwise be stored here.
            if spot > 0, length <= 0 || spot < length - 1 {
                lastGoodPosition = spot
            }
            return
        }

        let since = standsSince ?? Date()
        standsSince = since
        let duration = Date().timeIntervalSince(since)

        // **The decision lives in `StreamWatch`, no longer here.**
        //
        // Five thresholds, all measured, and a wrong one costs the viewer ten
        // seconds of movie; the brake once created exactly the stall it was meant
        // to fix. In the package it is testable without a player; the reasons are
        // given there per constant.
        switch StreamWatch.rat(
            standstillSince: duration,
            networkChangeForward: networkSwitchSince.map { Date().timeIntervalSince($0) },
            jumpOpen: openTarget != nil,
            lastJumpForward: Date().timeIntervalSince(lastJumpCommand),
            bufferGrewPre: reporter.bufferGrewPre
        ) {
        case .notYet:
            return
        case .jumpRunning:
            AppLog.writeOut("[Netz] Bild steht seit \(Int(duration)) s, Sprung noch unterwegs → abwarten")
            return
        case .bufferGrows:
            AppLog.writeOut("[Netz] Bild steht seit \(Int(duration)) s, Puffer waechst noch → abwarten")
            return
        case .newConnect:
            break
        }

        newConnect(reason: "Bild steht seit \(Int(duration)) s")
    }

    /// **The clock runs, the picture is frozen: `checkStandstill` knows
    /// nothing about that.**
    ///
    /// The safeguard above triggers when the *time* stops. The reverse case was
    /// reported: the app sat in the background for a long time with the player
    /// paused; back in the app it ran for half a minute, then froze, while the
    /// time kept running. For `StreamWatch` that is a healthy stream, since `now`
    /// changes every second. It is blind to exactly this error, by design.
    ///
    /// Hence the second quantity here, which VLC keeps itself: `displayedPictures`
    /// are the pictures shown, `demuxReadBytes` what arrives from the server at
    /// all. Together they separate the two explanations that otherwise look the
    /// same:
    ///
    /// - Bytes grow, pictures do not: data arrives, the output is dead.
    /// - Both stand: nothing arrives, the connection is gone.
    ///
    /// **For now it only records, it does not intervene.** Nobody knows which of
    /// the two it is, and a brake on suspicion once created the stall it was meant
    /// to fix in this file; see `StreamWatch`. Measure first. Since when no new
    /// picture was output.
    ///
    /// **The second sensor, and the better one.** The watchdog above compares
    /// `player.time`; if the clock runs, the stream counts as alive. Measured on
    /// a device: `displayedPictures` **frozen for 76 seconds** at 15925, the
    /// increase of `demuxReadBytes` constantly 0, while the clock ran in the same
    /// time from 6388 to 6464 s in step with the wall clock.
    ///
    /// The sensor was there all along: `imageFlow` read it and **only wrote it to
    /// the log**. Now it acts.
    private var imagesStateSince: Date?

    private func imageFlow(now: Int32) {
        guard let stats = player.media?.statistics else { return }
        defer {
            lastImages = stats.displayedPictures
            lastBytes = stats.demuxReadBytes
        }
        guard let beforeBytes = lastBytes,
              StreamWatch.imagesState(before: lastImages, now: stats.displayedPictures) == true
        else {
            imagesStateSince = nil
            return
        }
        imagesStateSince = imagesStateSince ?? Date()

        // Only the conspicuous case goes to the log. Writing a line every second
        // makes the file unreadable and hides exactly the moment that matters.

        let bytes = StreamWatch.growth(stats.demuxReadBytes, since: beforeBytes)
        AppLog.writeOut("[Bild] Uhr bei \(now / 1000) s laeuft, aber kein neues Bild"
            + " (gezeigt \(stats.displayedPictures), verloren \(stats.lostPictures),"
            + " neue Bytes \(bytes)) → \(bytes > 0 ? "Daten kommen an, Ausgabe steht" : "es kommt nichts mehr")")
    }

    // MARK: First frame

    /// What has already been tried for this title; see ``FirstFrame``.
    /// Applies per title (`play`), not per rebuild: otherwise every rebuild would
    /// start over at the first rescue and there would be no rest.
    private var firstFrameLevel: FirstFrame.Level = .no
    /// Movie time since the last rebuild in which the clock ran. Per rebuild.
    private var firstFrameRun: TimeInterval = 0
    private var firstFrameBefore: TimeInterval?
    /// After the second rescue, or from the start for MPEG-4 Part 2, the title
    /// stays on the software decoder, also across a later network rebuild.
    private var softwareDecoder = false
    private var firstFrameWatched = false
    /// Is picture-in-picture running? There the system draws, not this rule.
    private var imageImageRuns = false
    #if DEBUG
    /// Only for ``Erstbildlauf``: claim a video track, without a server source.
    var testVideoTrack = false
    /// Only for ``Erstbildlauf``: force this `codec` option (no picture) as long
    /// as no software decoder is requested, or always.
    static var testForce: (option: String, alsoSoftware: Bool)?
    /// Only for measurement runs: further options on the media (`Tempolauf`).
    static var testAddition: [String] = []
    #endif

    /// For the tech badge: `nil` as long as nothing was intervened.
    var firstFrameHint: String? { FirstFrame.hint(firstFrameLevel) }

    private var hasVideoTrack: Bool {
        #if DEBUG
        if testVideoTrack { return true }
        #endif
        return trackSource.flatMap(FileDetails.videoTrack) != nil
    }

    /// **The clock runs, the audio plays, and a picture never came.**
    ///
    /// `imageFlow` is silent here: ``Stromwacht/imagesStand(vorher:jetzt:)``
    /// returns `nil` for zero pictures shown. The decision lives in ``FirstFrame``
    /// in the package; here only the counters and the execution.
    /// Runs only if the clock advanced (`checkStandstill`), so never while
    /// paused, buffering or during AirPlay (VLC stands still then).
    ///
    /// - Returns: `true` if the stream was rebuilt.
    private func firstFrameCheck(now: Int32) -> Bool {
        let spot = Double(now) / 1000
        firstFrameRun += FirstFrame.growth(before: firstFrameBefore, now: spot)
        firstFrameBefore = spot
        guard let stats = player.media?.statistics else { return false }
        if stats.displayedPictures > 0 {
            if !firstFrameWatched, firstFrameLevel != .no {
                AppLog.writeOut("[Bild] erstes Bild nach Rettung (\(firstFrameLevel)) bei \(Int(spot)) s"
                    + " · Dekoder \(softwareDecoder ? "Software" : "frei")")
            }
            firstFrameWatched = true
            return false
        }
        let rat = FirstFrame.rat(hasVideoTrack: hasVideoTrack, excluded: imageImageRuns,
                               shown: stats.displayedPictures, runtime: firstFrameRun,
                               untilFrom: firstFrameLevel)
        switch rat {
        case .nothing, .wait: return false
        case .outputNew, .softwareDecoder, .giveUp: break
        }
        let track = player.videoTracks.first
        let server = trackSource.flatMap(FileDetails.videoTrack)?.codec ?? "—"
        AppLog.writeOut("[Bild] kein erstes Bild nach \(Int(firstFrameRun)) s Laufzeit bei \(Int(spot)) s"
            + " · Server \(server) · VLC-Spur \(track.map { TechDetails.codecNameValue(vlcId: $0.codec) ?? $0.codecName() } ?? "keine")"
            + " · dekodiert \(stats.decodedVideo), gezeigt \(stats.displayedPictures), verloren \(stats.lostPictures)"
            + " · Ton gespielt \(stats.playedAudioBuffers) · Dekoder \(softwareDecoder ? "Software" : "frei") → \(rat)")
        firstFrameLevel = FirstFrame.next(to: rat, untilFrom: firstFrameLevel)
        guard !finallyStopped, let address = lastAddress else { return false }
        switch rat {
        case .outputNew:
            buildUp(reason: "kein erstes Bild", since: spot, address: address)
            return true
        case .softwareDecoder:
            softwareDecoder = true
            buildUp(reason: "kein erstes Bild, jetzt mit Software-Dekoder", since: spot, address: address)
            return true
        default:
            return false
        }
    }

    /// Reopen the stream and jump to the last good position.
    ///
    /// This is a good idea only since 'mkv_trusted': before, the seek back cost
    /// twenty seconds and the rescue would have been worse than the damage. Now
    /// it is about fifty milliseconds.
    private func newConnect(reason: String) {
        // After `stop()` there is nothing to rebuild; otherwise a torn-down view
        // starts playing again, audible but not visible.
        guard !finallyStopped else { return }
        guard let address = lastAddress, lastGoodPosition > 1 else { return }

        guard networkReachable else {
            waitsNetwork = true
            AppLog.writeOut("[Netz] \(reason), aber kein Netz — vorgemerkt bei \(Int(lastGoodPosition)) s")
            return
        }
        // After a change the monitor reports several times. Without a cooldown the
        // stream would be rebuilt in a loop and never finish.
        guard Date().timeIntervalSince(lastNewLayout) > 5 else { return }
        buildUp(reason: reason, since: lastGoodPosition, address: address)
    }

    /// The shared part of ``newConnect(reason:)`` and the first-picture
    /// rescue: reopen the stream at `since`, keeping the track selection.
    private func buildUp(reason: String, since: Double, address: URL) {
        lastNewLayout = Date()
        standsSince = nil
        lastKnownTime = -1
        restoring = true
        // **Carry over the current track selection.** A newly opened stream brings
        // VLC's own default, mostly the subtitle track flagged "default" in the
        // MKV. Without this, subtitles the viewer had turned off would come back on
        // by themselves after a short drop.
        tracksPostLayout = reportedTracks
        AppLog.writeOut("[Netz] \(reason) → Strom neu aufbauen bei \(Int(since)) s")
        // The offset stays: the same address delivers from the same position again,
        // only the rest is seeked.
        open(url: address, offSeconds: max(since, 0), container: lastContainer)
    }


    /// Set the start position as soon as VLC can seek.
    ///
    /// **Not as a ':start-time' option, and the original reason for that is no
    /// longer the right one.**
    ///
    /// The option forces VLC to seek while opening, and that used to cost many
    /// times more. That held before `mkv_trusted`, when a seek without an index
    /// took twenty seconds. Today it is milliseconds, so it was rebuilt to use
    /// the option, and reverted on the device within minutes.
    ///
    /// **The new reason is a different and better one.** The remembered position
    /// can lie at the end of the file: an episode plays through, the app stores
    /// 3707 s, and the next time it opens the start position is exactly there.
    /// With ':start-time', VLC then reports `end of stream` immediately (measured,
    /// 141 ms after opening), end-of-episode detection fires and the app jumps to
    /// the next episode.
    ///
    /// Seeking afterwards does not have this error: there the stream is already
    /// running, and a seek to its own end is harmless.
    ///
    /// Anyone retrying the option needs the duration and a distance from the end
    /// **beforehand**, and the duration is not known at opening. That is the real
    /// effort, not the option.
    ///
    /// Deliberately **not** hung only on the state change to Playing. If the
    /// stream is rebuilt while VLC is already playing, it stays at Playing
    /// internally: no transition, the callback never fires and the new stream
    /// plays from second 0. That is exactly why the rescue after the network
    /// change failed. The watchdog therefore calls here as well.
    private func startPositionSet() {
        // The paused start takes precedence; this path is only the fallback for
        // start positions under one second.
        guard startJump == nil else { return }
        guard let target = startPosition else { return }
        guard target > 1 else {
            startPosition = nil
            firstPoint = nil
            holdBackAudio(false)
            return
        }
        // Before the first picture a seek has no effect.
        guard player.isSeekable, player.time.intValue > 0 else { return }

        // If `:start-time` hit, a follow-up seek would be a seek for nothing, and
        // the loading screen would stay up longer for it.
        if positionSeconds >= target - 10 {
            AppLog.writeOut("[VLC] Strom steht schon bei \(Int(positionSeconds)) s — kein Nachsprung")
            startPosition = nil
            firstPoint = nil
            holdBackAudio(false)
            return
        }

        startPosition = nil
        AppLog.writeOut("[VLC] Startposition gesetzt: \(Int(target)) s (von \(Int(positionSeconds)) s)")
        // Via the same path as every other seek, including the check afterwards.
        // The start position is the seek that hurts most when the index yields
        // nothing: it comes before the first picture.
        seek(toSeconds: target)
    }

    private var startPosition: Double?

    /// Reports VLC's state. Its own object because VLCKit reports from its own
    /// thread; calling a main-actor-isolated view there is an immediate crash
    /// under Swift 6.
    private lazy var reporter = StateReporter(player: player)

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("nicht aus Storyboards") }

    /// VLC attaches its render surface without a frame and rebuilds it after a
    /// seek. Without this it stays 0 x 0 or sticks in the corner.
    override func didAddSubview(_ subview: BaseView) {
        super.didAddSubview(subview)
        subview.frame = bounds
        subview.autoresizingMask = BaseView.growing
    }

    /// Otherwise after picture-in-picture the surface drags the small window's
    /// size along as its preferred size.
    override var intrinsicContentSize: CGSize {
        CGSize(width: BaseView.withoutRequestMetric, height: BaseView.withoutRequestMetric)
    }

    /// The layout hook has a different name in the two build sets. The body is
    /// the same and therefore appears only once.
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
    }

    #if os(iOS)
    var isPiPPossible: Bool { pipWindow != nil }

    /// Why PiP does not work right now, for the UI.
    var pipUnavailableReason: String? {
        if !AVPictureInPictureController.isPictureInPictureSupported() {
            // Always true in the simulator: AVKit reports
            // isPictureInPictureSupported = NO there. Only real devices support PiP.
            return String(localized: "Dieses Gerät kann kein Bild-im-Bild. Im Simulator geht es nie, auf dem iPhone schon.")
        }
        if pipWindow == nil { return String(localized: "Bild-im-Bild wird vorbereitet…") }
        return nil
    }
    func startPiP() { pipWindow?.startPictureInPicture() }
    func stopPiP()  { pipWindow?.stopPictureInPicture() }
    #endif

    /// Needed after every state change, otherwise the PiP window and player
    /// drift apart.
    ///
    /// A no-op on tvOS, deliberately not compiled out so the call sites in
    /// `pause`, `resume` and `stop` stay the same on both platforms.
    func refreshPiPState() {
        #if os(iOS)
        guard !Self.pipDisabled else { return }
        pipWindow?.invalidatePlaybackState()
        #endif
    }

    /// Opens the file and starts at `offSeconds`.
    ///
    /// The start position goes along as a media option instead of being seeked
    /// to after opening. Seeking was why resumed titles showed only a still
    /// frame: for large files over HTTPS a seek takes longer than the wait, the
    /// position still read as old, another seek followed, and the demuxer never
    /// settled. Titles started from the beginning therefore played, resumed ones
    /// did not.
    /// How much buffer the next start keeps. Set before `play(url:)`, since the
    /// options hang on the media, which is only created there.
    var buffer: BufferLevel = .normal

    /// Which tracks the next start wants; set before `play(url:)`, like
    /// ``buffer``. These become `:audio-track`/`:sub-track` on the media so VLC
    /// starts with the right track instead of switching after the first picture
    /// (see ``Spurzuordnung/startpositionen(stroeme:ton:untertitel:)``).
    /// `nil`: VLC chooses itself, as before.
    var trackRequest: TrackRequest?

    /// The inputs of ``wendeLanguagesAn(audio:subtitle:automatic:source:title:)``.
    struct TrackRequest {
        let audio: String
        let subtitle: String
        let automatic: Bool
        let source: MediaSource?
        let title: String?
    }

    /// - Parameter softwareDekoder: open with the software decoder right away:
    /// ``PlaybackPlan/softwareDekoder`` (MPEG-4 Part 2).
    func play(url: URL, offSeconds: Double = 0, container: String? = nil,
              subtitle: [SubtitleFile] = [], softwareDecoder initialSoftware: Bool = false) {
        guard !finallyStopped else {
            AppLog.writeOut("[Player] play nach stop verworfen")
            return
        }
        // As with seeking: a start position that is not a number begins at the
        // start, instead of crashing later in `Int(...)`.
        let offSeconds = JumpTarget.seconds(offSeconds) ?? 0
        // A new title does not inherit the old one's pause.
        pausedSince = nil
        // The session is set up at app launch. Here only verify and, if needed,
        // correct, with a visible error instead of a silent try?.
        //
        // This whole section does not exist on the Mac: `AVAudioSession` is not
        // available there. macOS mixes and routes audio itself, and no app has to
        // register a session. That is not a missing piece but a task that does not
        // apply.
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        if session.sampleRate < 1 {
            do {
                try session.setCategory(.playback, mode: .moviePlayback)
            // **System alerts must not pause the movie.**
            //
            // Pulling down the notification center caused an audio interruption, which
            // paused playback (VLC reported `pausing` each time). Only leaving the app
            // for real should pause: backgrounded without picture-in-picture, closed,
            // or device off.
            //
            // `setPrefersNoInterruptionsFromSystemAlerts` exists for this. Apple's
            // documentation does not explicitly say the notification center is covered,
            // so the interruption reason is also logged instead of assumed.
            if #available(iOS 14.5, tvOS 14.5, *) {
                try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
            }
                try session.setActive(true)
                AppLog.writeOut("[Audio] nachgezogen · \(Int(session.sampleRate)) Hz")
            } catch {
                AppLog.writeOut("[Audio] FEHLER: \(error.localizedDescription)")
            }
        }
        // **How many channels does the output accept?**
        //
        // Swiftfin reports that its VLCKit player outputs only stereo for 5.1 files
        // while the native player delivers all channels (jellyfin/Swiftfin#2199,
        // open); Streamyfin had no sound at all with 7.1 (#1515). For an app that
        // never wants to transcode, a silent downmix in the client would be the
        // most embarrassing bug: the server delivers direct play and we throw the
        // channels away.
        //
        // Whether that happens here cannot be read from source, only from this line
        // on a device. `maximumOutputNumberOfChannels` is what the route could do;
        // `currentRoute.outputs.channels` is what it currently carries. Two channels
        // are right on the iPhone speaker; it gets interesting on HDMI, AirPlay and
        // Apple TV.
        let output = session.currentRoute.outputs.first
        AppLog.writeOut("[Audio] beim Öffnen: \(Int(session.sampleRate)) Hz"
            + " · Ausgang \(output?.portType.rawValue ?? "—")"
            + " führt \(output?.channels?.count ?? 0) Kanäle"
            + ", könnte \(session.maximumOutputNumberOfChannels)")
        #endif

        #if DEBUG
        Self.recent = self
        #endif
        mediumSwitched = player.media != nil
        lastAddress = url
        lastContainer = container
        subtitleFiles = subtitle
        trackSource = nil
        firstFrameLevel = .no
        softwareDecoder = initialSoftware
        player.videoAspectRatio = nil
        currentSubtitle = nil
        trackIndicesReport(TrackIndices())
        lastGoodPosition = offSeconds
        intentionalEnded = false
        openTarget = nil
        openSince = nil
        jumpLevel = 0
        timeSetBetter = false

        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkStandstill()
                self?.displaySleepLet()
                self?.holdIdleLock()
                self?.delayCatchUp()
            }
        }

        open(url: url, offSeconds: offSeconds, container: container)
    }

    /// The actual setup, also the way back after a network change.
    private func open(url: URL, offSeconds: Double, container: String?) {
        // **The picture count belongs to the media.** If it survived the setup,
        // `imageFlow` compared the new count with the old one.
        lastImages = nil
        lastBytes = nil
        imagesStateSince = nil
        firstFrameRun = 0
        firstFrameBefore = nil
        firstFrameWatched = false
        // In the side, without waiting for it: how VLC's sockets reach the server.
        // Log only, see `NetworkProbe`.
        NetworkProbe.start(url)
        // **Behind a proxy the app fetches the stream itself** (issue #4):
        // VLC cannot send custom headers. Without configured headers the address
        // comes back unchanged. AirPlay still talks to the server directly and so
        // stays silent behind a proxy.
        let vlcAddress = StreamForwarder.gemeinsam.address(for: url)
        if vlcAddress != url {
            AppLog.writeOut("[VLC] Strom über den Weiterleiter (Header: \(OwnHeaders.names(OwnHeaders.of(url))))")
        }
        guard let medium = VLCMedia(url: vlcAddress) else {
            Self.log.error("Medium ließ sich nicht öffnen: \(url.withoutSecret, privacy: .public)")
            AppLog.writeOut("[VLC] Medium ließ sich nicht öffnen")
            startErrorReported?("Medium ließ sich nicht öffnen")
            return
        }

        // This one option is set after reading VLC's MKV demuxer, not on a hunch.
        // It is why seeks now land correctly.
        //
        // VLC 4 registers the Matroska demuxer twice (mkv.cpp:85-93):
        //
        // Open        -> OpenInternal(..., trust_cues: false)   rank 50
        // OpenTrusted -> OpenInternal(..., trust_cues: true )   rank  0
        //
        // So the regular path distrusts the file's index. Every cue point is entered
        // only as QUESTIONABLE (matroska_segment.cpp:213), and on a seek
        // find_greatest_seekpoints_in_range filters exactly those out again via
        // get_first_seekpoint_around(..., TrustLevel = TRUSTED). What remains are the
        // clusters that were read anyway, i.e. the start of the file.
        //
        // To cross-check, VLC scans the range with index_range(). That depends on
        // b_fastseekable (matroska_segment_seeker.cpp:321), which over HTTP is always
        // false: the prefetch filter never reports STREAM_CAN_FASTSEEK
        // (prefetch.c:355), so mkv.cpp:130 sets the flag to false. The index is read,
        // present, and discarded.
        //
        // Measured: a seek to 1546 s in a 10.3 GB file went to byte 16,601,095, about
        // 12 seconds of movie. From there VLC silently fast-forwarded, hence the
        // 20+ seconds.
        //
        // VLC 3 has no trust levels and always takes the cues. That is why Swiftfin,
        // which sits on MobileVLCKit (version 3), seeks in half a second. The
        // submodule 'mkv_trusted' restores this behavior in version 4; it has rank 0
        // and is never chosen by itself, only by name.
        //
        // Set only for Matroska: the option forces the demuxer, and for MP4 or TS it
        // would simply be wrong.
        // Enlarging the lookahead: 'prefetch-buffer-size' counts in KiB, the default
        // of 1<<14 is 16 MiB, just under eleven seconds at about 11 Mbit/s. 64 MiB
        // gives about three quarters of a minute.
        //
        // The buffer bridges a network change because prefetch.c in Read() checks
        // the error only when nothing is left in it:
        //
        // while ((copy = BufferLevel(stream, &eof)) == 0 && !eof)
        // if (sys->error) { ... return 0; }
        //
        // First the buffer empties, then the stream fails. That is why nothing is
        // torn down on a route change but waited out.
        //
        // **And exactly that cost seeking.**
        //
        // 65536 KiB was 64 MiB, four times the default. A lookahead only helps while
        // it is full; on every seek VLC discards it and refills, and no picture moves
        // until then. Measured on an episode where seeking took thirty to fifty
        // seconds: the buffer rose to 96 % in four seconds, so the line was never the
        // problem; it was just too big to refill quickly. The same file plays
        // instantly in Swiftfin, which does not set this option.
        //
        // 16384 KiB is VLC's default, about eleven seconds at 11 Mbit/s. A network
        // change is still bridged, only not for three quarters of a minute, and that
        // is the better trade: a change is rare, a seek happens in every episode.
        // **Measured: the filter cannot be deselected this way.** With size zero it
        // still loads, just without a buffer, which is worse than before.
        // `STREAM_CAN_FASTSEEK` stays off, and so Matroska's range scan stays
        // unreachable. Back to 16 MiB.
        // **The level comes from settings, the numbers from the package.**
        // 16 MiB stays the default; with a shaky connection, set it higher and pay
        // with a longer start-up after every seek.
        medium.addOption(":prefetch-buffer-size=\(buffer.prefetchKiB)")
        if let preRun = buffer.networkLeadMilliseconds, url.isFileURL == false {
            // Set only at an increased level; see the measurement below for why this
            // brings nothing in the normal case and makes seeks more expensive.
            medium.addOption(":network-caching=\(preRun)")
        }

        // **After a longer pause the connection is gone.**
        //
        // Logged twice: paused for 25 seconds, and on resume `local stream N error:
        // Cancellation (0x8)` appears in the log, because the server cleaned up the
        // idle stream. VLC then rebuilds everything (reset PCR, seek again, buffer),
        // and because iOS had also invalidated the decoder session in the background
        // (`kVTInvalidSessionErr`), this takes about two seconds.
        //
        // `http-reconnect` lets VLC absorb the drop itself instead of treating it as
        // end of stream. It changes nothing as long as the connection holds.
        if url.isFileURL == false {
            medium.addOption(":http-reconnect")
        }

        // **Deinterlacing: `bob` instead of `x`, and only where VLC detects fields.**
        //
        // DVD rips (MPEG-2, 720x576, interlaced) stuttered on Apple TV and iPhone,
        // 4K HEVC did not. VLC 4 deinterlaces by itself (`deinterlace` -1) once a
        // picture is flagged interlaced, and `auto` means **`x`** in the filter
        // (deinterlace.c, SetFilterMethod), not yadif2x. That runs on the CPU after
        // the decoder. MPEG-2 itself always goes through avcodec in our VLCKit:
        // `libmpeg2` is not built, and VideoToolbox has MPEG-2 disabled (decoder.c,
        // `#if 0`).
        //
        // Measured on the Mac (M1 Max, same build, rebuilt file: MPEG-2 TFF
        // 5 Mbit/s, AC-3 5.1, VobSub, MKV), 30 s each, throttled to the efficiency
        // cores (`taskpolicy -c background`):
        //
        // Mode           decoded    shown       lost
        // x (default)    24.7/s     12.9-13.2   346-352
        // bob            24.8/s     15.0        295
        // linear         24.7/s     14.7        301
        // off            24.8-25.0  13.9-16.8   243-335
        // x without VobSub 25.1/s   12.7        371
        //
        // The decoder always keeps up; the loss happens behind it. The subtitle costs
        // nothing measurable. `x` is the most expensive method, `bob` wins back about
        // the gap to "off" without leaving combing artifacts. Unthrottled, all
        // variants sit at 25/s and 8-15 % of a core; the Mac shows the difference only
        // with the brake, and part of the loss remains in the output even with "off".
        //
        // **Why set globally:** the mode only applies when VLC detects a picture as
        // interlaced. HEVC/4K is progressive and never takes the filter, so nothing
        // changes there.
        //
        // **It is set on the library (`library`), not here.** Here was
        // `medium.addOption(":deinterlace-mode=bob")`, which never took effect: the
        // filter hangs off the vout, which inherits from the player, not from the
        // input; same trap as `--no-drop-late-frames`. Re-measured on MPEG-2 and
        // H.264 1080i50 (TS): with the media option VLC 4 reports "using x
        // deinterlace method" like VLC 3, with the library option "using bob" and
        // twice as many shown pictures (one field per picture). The table above was
        // therefore noise: `x` was measured twice.

        // **The buffer was not the cause; re-measured, not guessed.**
        //
        // `:network-caching=10000` briefly stood here, because VLC's default of
        // 1000 ms looked thin and another client shows eleven seconds of buffer.
        // The measurement on the device settled it: read minus unpacked gave **211
        // seconds**. The `prefetch` filter above holds 16 MiB, which at this bitrate
        // is three and a half minutes of content. A time-based buffer would have
        // changed nothing but made every seek more expensive.
        //
        // What "input 0 kbit/s" on a frozen picture really meant: not "nothing is
        // arriving" but "nothing needs to arrive right now". The bottleneck is
        // behind the demuxer, not in front of it.


        // **The decision must be readable.**
        //
        // It is the difference between "seek lands" and "seek lands at the start of
        // the file and takes twenty seconds". When it goes wrong you cannot see it;
        // you only see a player that jumps to the beginning when scrubbing, and look
        // everywhere else.
        matroskaTrusted = isMatroska(container: container, url: url)
        if matroskaTrusted {
            medium.addOption(":demux=mkv_trusted")
            AppLog.writeOut("[VLC] Matroska erkannt → Demuxer mkv_trusted (Cues gelten)")
        }

        // **Open paused, seek while stopped, then resume.**
        //
        // This is the path that never shows or plays the start of the episode: not
        // because it hides it, but because it never outputs it. Measured before:
        // VLC `started` at +0.41 s, our seek at +1.00 s, data from the target at
        // +1.12 s. The 0.85 s in between were picture and sound from second zero, and
        // the old latch ("a seek before the first picture fizzles") forced exactly
        // that: it waited for `time > 0`, i.e. running output.
        //
        // What VLC 4 really does (libvlc/vlc, checked in source):
        //
        // - `:start-paused` arrives at the input via input_item_ApplyOptions
        // (input.c:249) and pauses it at the start of MainLoop (input.c:647).
        // - During buffering the pause is deferred (input.c:1755) and applied at the
        // end of buffering **before** the decoders are released (es_out.c:1268-1285).
        // No picture, no sample is output.
        // - A seek in the paused state is executed; buffering then happens at the
        // target, and decoders created later inherit the pause (es_out.c:1288,
        // decoder.c:436). Audio stays silent.
        // - Resuming via `player.play()`: VLCKit calls set_pause(0) directly on
        // `Paused`. **Only on a reported Paused**; before that play() would be a
        // no-op (vlc_player_Start: already started, not paused), and the deferred
        // pause would leave the player stopped afterwards.
        //
        // `:start-time` was the wrong shortcut: it shifts the time axis (i_stop +=
        // i_start, input.c:916), and VLC then reports the remaining length. The audio
        // hold via volume never worked: before the first sound there is no audio
        // output, vlc_player_aout_SetVolume returns -1 (aout.c:137) and VLCKit
        // ignores that. Both remain as a fallback but no longer carry anything.
        // **Software decoder after the second first-picture rescue**, or from the
        // start for MPEG-4 Part 2; see ``Erstbild/softwareOption`` and
        // ``Erstbild/softwareFromStart(bildcodec:methode:)``.
        var codec: String? = softwareDecoder ? FirstFrame.softwareOption : nil
        #if DEBUG
        if let force = Self.testForce, !softwareDecoder || force.alsoSoftware { codec = force.option }
        for addition in Self.testAddition { medium.addOption(addition) }
        #endif
        if let codec {
            medium.addOption(codec)
            AppLog.writeOut("[Bild] Dekoderwahl \(codec)")
        }

        // **No clock of its own** (`clock-master=input` brought 2x down to 0.3 s,
        // but on iPhone the audio dropped out every ~3 s; reverted). The audio
        // clock stays; a speed change therefore needs about 2 s (`Tempolauf`).

        let pausedStart = offSeconds > 1
        if pausedStart {
            medium.addOption(":start-paused")
        }

        startPosition = offSeconds
        firstPoint = pausedStart ? offSeconds : nil
        // From a handoff muted even without a seek; the audio then fades in as soon
        // as it is steered in (`releaseAudioIfDue`).
        holdBackAudio(firstPoint != nil || Self.handoffFadeIn)
        reporter.newBegin()
        AppLog.writeOut("[VLC] Öffne \(url.lastPathComponent), Startposition \(Int(offSeconds)) s"
            + (pausedStart ? " (pausiert, Sprung im Stillstand)" : ""))
        // **External subtitles**: VLC does not look for neighboring files
        // over HTTP, but the server names them. Priority 0 so VLC does not enable any
        // of them itself; `TrackRule` decides that.
        for file in subtitleFiles {
            let attached = medium.addSlave(VLCMediaSlave(url: StreamForwarder.gemeinsam.address(for: file.address), type: .subtitle, priority: 0))
            AppLog.writeOut("[Spuren] Datei \(file.index) angehängt \(attached), Merkmal \(file.attribute ?? "—")")
        }
        if StartMeasurement.an {
            // VLC otherwise counts its pictures only every 250 ms, too coarse for a gap
            // of one or two pictures.
            medium.addOption(":stats-min-report-interval=20")
        }
        for option in trackOptions() { medium.addOption(option) }
        startMeasurementBegin()
        StartMeasurement.shared.mark("Öffne (ab \(Int(offSeconds)) s\(pausedStart ? ", pausiert" : ""))")
        player.media = medium
        player.play()
        refreshPiPState()

        startJump = pausedStart ? offSeconds : nil
        startJumpSince = pausedStart ? Date() : nil
        targetWatched = nil
        lastStartJumpCommand = .distantPast
        startGuards?.invalidate()
        if pausedStart {
            // 50 ms so that seeking and resuming take effect without a noticeable
            // delay. The tick lives only until the start is complete.
            startGuards = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.startJumpCheck(occasion: "Takt") }
            }
        }
    }

    /// Track selection per ``Spurregel`` as media options.
    ///
    /// Checked in VLC source (es_out.c, `EsOutSelect`): `audio-track` and
    /// `sub-track` are "explicit" wishes and beat the file's preselection; counting
    /// is per kind in creation order. There is no number for "no subtitles":
    /// `sub-track=-1` means "VLC chooses", and then Matroska's default track wins.
    /// An id that does not exist (`sub-track-id=aus`) is also explicit and matches
    /// nothing: VLC turns no subtitle on by itself. A later manual choice goes
    /// through with emphasis and is not affected.
    private func trackOptions() -> [String] {
        guard let w = trackRequest else { return [] }
        let streams = w.source?.mediaStreams ?? []
        guard !streams.isEmpty else { return [] }
        let memory = TrackMemory()
        let audioIndex = TrackRule.audio(streams: streams,
                                     remembered: w.title.flatMap { memory.audio(for: $0) },
                                     preferredLanguage: w.audio,
                                     serverPreGift: w.source?.defaultAudioStreamIndex)
        let choice = TrackRule.subtitle(streams: streams,
                                        remembered: w.title.flatMap { memory.subtitle(for: $0) },
                                        serverPreGift: w.source?.defaultSubtitleStreamIndex,
                                        automatic: w.automatic, audioIndex: audioIndex,
                                        tonwunsch: w.audio, preferredLanguage: w.subtitle)
        let status = TrackMapping.startPositions(streams: streams, audio: audioIndex, subtitle: choice)
        var options: [String] = []
        if let audio = status.audio { options.append(":audio-track=\(audio)") }
        if let subtitle = status.subtitle {
            options.append(":sub-track=\(subtitle)")
        } else {
            options.append(":sub-track-id=aus")
        }
        AppLog.writeOut("[Spuren] beim Öffnen: Ton \(audioIndex.map(String.init) ?? "Datei") · Untertitel \(choice)"
            + " → \(options.joined(separator: " "))")
        return options
    }

    // MARK: - Paused start

    /// The target position while the paused start is still running.
    private var startJump: Double?
    private var startJumpSince: Date?
    private var lastStartJumpCommand = Date.distantPast
    private var startGuards: Timer?

    /// A start must not stay paused longer than this. After that it resumes
    /// wherever the stream is; a stopped player is worse than a wrong entry
    /// point.
    private static let startJumpDeadline: TimeInterval = 20

    /// Drives the paused start forward: trigger the seek until the clock is
    /// near, resume once VLC reports paused.
    ///
    /// The seek command goes into VLC's queue and is postponed during buffering,
    /// not discarded (input.c, ControlPop with b_postpone_seek); repeats are
    /// merged there (ControlGetReducedIndexLocked). Before the first state change
    /// there is no input yet and the command fizzles, so it is resent each tick
    /// until it arrives.
    private func startJumpCheck(occasion: String) {
        guard let target = startJump else { startGuards?.invalidate(); startGuards = nil; return }
        let spot = positionSeconds
        let condition = player.state
        let since = startJumpSince.map { Date().timeIntervalSince($0) } ?? 0

        if since > Self.startJumpDeadline {
            AppLog.writeOut("[Start] \(Int(since)) s pausiert, Ziel \(Int(target)) s nicht erreicht (bei \(Int(spot)) s) — fortsetzen trotzdem")
            startJumpComplete(resume: condition == .paused)
            return
        }

        if spot < target - 10 {
            if Date().timeIntervalSince(lastStartJumpCommand) > 0.25,
               condition != .stopped, condition != .error {
                lastStartJumpCommand = Date()
                player.time = VLCTime(int: Int32(clamping: Int(target * 1000)))
                AppLog.writeOut("[Start] Sprung auf \(Int(target)) s angestossen (\(occasion), Zustand \(VLCMediaPlayerStateToString(condition)), Uhr \(Int(spot)) s)")
            }
            return
        }

        // The clock is at the target. Resume once VLC is really paused; before
        // that play() is a no-op, see oeffnen().
        if condition == .paused {
            AppLog.writeOut("[Start] am Ziel (\(Int(spot)) s) und pausiert → fortsetzen, \(String(format: "%.2f", since)) s nach dem Öffnen")
            startJumpComplete(resume: true)
            return
        }

        // **`Playing` means nothing here yet.** Measured in the simulator: VLC
        // reports Playing at +0.405 s, the deferred pause only takes effect at
        // +0.699 s (end of buffering, input.c:1755 / es_out.c:1268). Finishing on
        // Playing leaves the player paused afterwards, which happened on the first
        // attempt. The only proof that it is really playing is a clock that keeps
        // running from the target; when paused it stands still.
        if condition == .playing {
            if let before = targetWatched {
                if spot > before + 0.5 {
                    AppLog.writeOut("[Start] am Ziel und die Uhr laeuft (\(Int(spot)) s) — ohne Pause abgeschlossen")
                    startJumpComplete(resume: false)
                }
            } else {
                targetWatched = spot
            }
        }
    }

    /// First time reported at the target while Playing; see above.
    private var targetWatched: Double?

    private func startJumpComplete(resume: Bool) {
        startGuards?.invalidate()
        startGuards = nil
        startJump = nil
        startJumpSince = nil
        targetWatched = nil
        startPosition = nil
        firstPoint = nil
        StartMeasurement.shared.mark("Startsprung abgeschlossen, fortsetzen: \(resume)")
        holdBackAudio(false)
        if resume { player.play() }
    }

    // MARK: Start measurement - picture flow of the first seconds

    private var measureTick: Timer?
    private var messHit: Date?
    private var messImages: UInt64 = 0
    private var messLate: UInt64 = 0
    private var messLost: UInt64 = 0
    private var messAudioLost: UInt64 = 0

    /// Samples every 10 ms while ``Startmessung`` is measuring: is the main
    /// thread blocked (the tick arrives late), and does VLC count late or dropped
    /// pictures and audio blocks. At the end, the numbers of the video layer.
    ///
    /// **No more picture gaps.** VLC's counters come from the input thread and
    /// stall with it (after every "gap", three or four pictures at once). The
    /// layer's displayed picture (`displayedPixelBuffer()`) is also unsuitable:
    /// it reported still frames nobody saw, and none where it stuttered.
    private func startMeasurementBegin() {
        measureTick?.invalidate()
        measureTick = nil
        guard StartMeasurement.an else { return }
        StartMeasurement.shared.begin()
        messHit = nil
        messImages = 0
        messLate = 0
        messLost = 0
        messAudioLost = 0
        let tick = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startMeasurementTick() }
        }
        RunLoop.main.add(tick, forMode: .common)
        measureTick = tick
    }

    private func startMeasurementTick() {
        let now = Date()
        guard !finallyStopped, StartMeasurement.shared.milliseconds != nil else {
            measureTick?.invalidate()
            measureTick = nil
            AppLog.writeOut("[Start] Messung zu Ende · gezeigt \(messImages), spät \(messLate), verloren \(messLost), Ton verloren \(messAudioLost)")
            Self.videoLayer(in: layer)?.sampleBufferRenderer.loadVideoPerformanceMetrics { values in
                guard let values else { return }
                AppLog.writeOut("[Start] Schicht: \(values.totalNumberOfFrames) Bilder,"
                    + " verworfen \(values.numberOfDroppedFrames), beschädigt \(values.numberOfCorruptedFrames)")
            }
            return
        }
        if let before = messHit {
            let gap = now.timeIntervalSince(before)
            if gap > 0.05 { StartMeasurement.shared.mark("Hauptlauf stand \(Int(gap * 1000)) ms") }
        }
        messHit = now
        guard let stats = player.media?.statistics else { return }
        if stats.displayedPictures != messImages {
            if messImages == 0 {
                StartMeasurement.shared.mark("erstes Bild gezeigt · Uhr \(player.time.intValue) ms")
            }
            messImages = stats.displayedPictures
        }
        if stats.latePictures != messLate || stats.lostPictures != messLost
            || stats.lostAudioBuffers != messAudioLost {
            messLate = stats.latePictures
            messLost = stats.lostPictures
            messAudioLost = stats.lostAudioBuffers
            StartMeasurement.shared.mark("VLC zählt spät \(messLate) · verloren \(messLost)"
                + " · Ton verloren \(messAudioLost) · gezeigt \(stats.displayedPictures)")
        }
    }

    /// The `AVSampleBufferDisplayLayer` VLC attaches below the surface.
    private static func videoLayer(in root: CALayer?) -> AVSampleBufferDisplayLayer? {
        guard let root else { return nil }
        if let stratum = root as? AVSampleBufferDisplayLayer { return stratum }
        for kind in root.sublayers ?? [] {
            if let stratum = videoLayer(in: kind) { return stratum }
        }
        return nil
    }

    /// What matters is the *delivered* container, not the file's: with direct
    /// stream the server remuxes. Jellyfin's address carries it as the extension
    /// (".../stream.mkv"), which therefore takes precedence. The reported
    /// container is only the fallback when no extension is present.
    private func isMatroska(container: String?, url: URL) -> Bool {
        let names: Set<String> = ["mkv", "matroska", "webm", "mka", "mks"]
        let suffix = url.pathExtension.lowercased()
        if !suffix.isEmpty { return names.contains(suffix) }
        guard let container else { return false }
        return container.lowercased().split(separator: ",").contains {
            names.contains($0.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Called as soon as **VLC itself** switches, not when we ask it to. The play
    /// button hangs on this; see `stateSwitched`.
    var runsReported: ((Bool) -> Void)?

    /// Called on every external seek with the target, so the server learns of it
    /// immediately regardless of which of the many paths was used.
    /// The internal retry of a seek does not report.
    var jumpReported: ((Double) -> Void)?

    /// If VLC aborts before the first picture (file not readable, stream
    /// unreachable, media cannot be opened), this reports the reason. The UI then
    /// shows a message instead of endless black.
    var startErrorReported: ((String) -> Void)?

    func pause() {
        if pausedSince == nil { pausedSince = Date() }
        player.pause()
        refreshPiPState()
    }

    /// **Since when it has been paused**, for ``Pausenruecksprung``. Set on
    /// pausing, also when VLC pauses by itself (picture-in-picture, a call);
    /// cleared as soon as it runs again.
    private var pausedSince: Date?

    /// **How the picture is placed in the surface: whole or fill.**
    ///
    /// `Smaller` places the whole picture and leaves bars, `Larger` fills the
    /// surface and crops. Both without distortion; a third state would only be a
    /// wrong stretch, so there are two.
    ///
    /// Not via `videoAspectRatio`: that sets an aspect ratio and pulls the picture
    /// to it instead of cropping. Faces get wide, which nobody wants.
    func fillFrame(_ an: Bool) {
        player.videoFitMode = an ? .larger : .smaller
    }

    /// The stream's picture size in pixels, `zero` before the first picture.
    /// Needed to compute how far apart "fit" and "fill" are.
    var videoSize: CGSize { player.videoSize }
    /// **Activate the audio session before continuing playback.**
    ///
    /// After an interruption (alarm, stopwatch, call) it is inactive. The
    /// automatic resume in `PlaybackHub` already corrected that; the play
    /// button did not. If no automatic end of the interruption came (an alarm
    /// often does not report one), the user pressed play themselves, and VLC
    /// started audio on the inactive session: a few seconds of silence, then it
    /// set in late. `setActive(true)` on an already active session costs nothing.
    ///
    /// **`jumpBack`: a bit back after a long pause.** The position is set while
    /// VLC is still stopped and only then played, so the first new picture is
    /// already the one from five seconds earlier and no visible jump back
    /// happens. When is decided by ``Pausenruecksprung``. Only at the UI's
    /// request: SyncPlay, returning from AirPlay and the end of scrubbing call
    /// without. Returns the target so the display adopts it at the same moment.
    @discardableResult
    func resume(jumpBack: Bool = false) -> Double? {
        let since = pausedSince
        pausedSince = nil
        var target: Double?
        if jumpBack, !startJumpOpen,
           let z = PauseJumpBack.target(position: positionSeconds, pausedSince: since,
                                          now: Date(), inGroup: false) {
            AppLog.writeOut("[VLC] Fortsetzen nach \(Int(Date().timeIntervalSince(since ?? Date()))) s Pause"
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
        player.play()
        refreshPiPState()
        return target
    }

    /// A start seek that has not arrived yet: then the position is not in place,
    /// and a step back from it would go nowhere.
    private var startJumpOpen: Bool { startJump != nil }

    func stop() {
        intentionalEnded = true
        finallyStopped = true
        holdBackAudio(false)
        holdIdleLock()
        watchdog?.invalidate()
        watchdog = nil
        startGuards?.invalidate()
        startGuards = nil
        startJump = nil
        player.stop()
        // **The view must be able to go away afterwards.** According to the VLCKit
        // header `drawable` is strong, so `player` holds the view and the view holds
        // the `player`: a cycle. Measured: a view with `drawable = self` outlives
        // `stop()`, without the reference it does not.
        //
        // With it, the network watch lived on. When the machine went to sleep, the
        // network dropped and `legSwitched` noted the last position; on wake,
        // `newConnect` rebuilt the stream and played audio from a player that had
        // long been closed.
        //
        // `stop()` is final (see `finallyStopped`); an episode change goes via
        // `play(url:)` on the same view and does not pass here. So the network watch
        // may end here.
        networkGuard.cancel()
        waitsNetwork = false
        player.drawable = nil
        // **And release the callbacks, otherwise the whole player stays in memory.**
        //
        // The cycle above is not completely gone: VLC 4 keeps the last video output
        // for the next media, and its surface holds the view until the
        // `VLCMediaPlayer` goes, which the view holds. Measured in the iOS
        // simulator: after opening and closing twelve times, twelve `VLCPlayerView`
        // were alive. That costs little. What hung on it was expensive: the callbacks
        // capture `PlayerScreen` and with it its whole state (`PlaybackHub`,
        // preview images, `RemoteTarget`, `ScreenTick`), once more per opening. After
        // `stop()` nobody calls anything here anyway: "playing" and "paused" no
        // longer arrive, and an episode change goes via `play(url:)`.
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

    // MARK: - Tracks and speed

    /// Available audio tracks. With direct play these are the file's real tracks,
    /// including DTS and TrueHD, which an AVPlayer would never see.
    var audioTracks: [VLCMediaPlayer.Track] { player.audioTracks }
    var subtitleTracks: [VLCMediaPlayer.Track] { player.textTracks }

    var selectedAudioTrack: VLCMediaPlayer.Track? { player.audioTracks.first(where: \.isSelected) }
    var selectedSubtitle: VLCMediaPlayer.Track? { player.textTracks.first(where: \.isSelected) }

    /// VLC's counters: dropped pictures, bitrates, decoder blocks.
    ///
    /// **Read-only, intervenes in nothing.** It answers the one question you
    /// cannot otherwise tell about stuttering playback: does the file really play
    /// smoothly, or does it only look smooth because VLC silently drops pictures?
    /// `lostPictures` then rises while `displayedPictures` lags, and for an app
    /// that never wants to transcode that is the difference between "works" and
    /// "barely works".
    ///
    /// `nil` as long as no media is loaded.
    var statistics: VLCMedia.Stats? { player.media?.statistics }

    /// **Do the channels get through, or does something silently mix down to stereo?**
    ///
    /// Swiftfin reports that its VLCKit player mixes 5.1 to stereo while the
    /// native player delivers all channels (jellyfin/Swiftfin#2199, open);
    /// Streamyfin had no sound at all with 7.1 (#1515). For an app that never
    /// wants to transcode, a silent downmix in the client would be the most
    /// embarrassing bug: the server delivers direct play, and we throw the
    /// channels away unseen.
    ///
    /// **The line is only meaningful on TV.** An iPhone speaker has two channels,
    /// and two at the output are right there, so the same result means nothing.
    /// Only when the route could do more (HDMI on Apple TV, an AirPlay receiver)
    /// does a stereo output tell anything.
    func channelsPostMeasure() {
        // **Two different track lists, and that is deliberate.**
        // `player.audioTracks` says what is *selected*: only there are `isSelected`
        // and a name. `media.audioTracks` describes the *file* and alone carries the
        // channel count, but no name. Instead of marrying the two through a brittle
        // name comparison, both are simply listed one under the other: what is
        // selected, and what the file offers at all.
        let selected = player.audioTracks.first(where: \.isSelected)?.trackName ?? "—"
        let tracks = (player.media?.audioTracks ?? []).map { track -> String in
            let language = track.language ?? track.trackDescription ?? "?"
            return "\(language) \(track.audio?.channelsNumber ?? 0)ch"
        }.joined(separator: ", ")

        #if os(macOS)
        AppLog.writeOut("[Kanäle] gewählt: \(selected) · Datei: \(tracks)")
        #else
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        AppLog.writeOut("[Kanäle] gewählt: \(selected) · Datei: \(tracks)"
            + " · Ausgang \(output?.portType.rawValue ?? "—")"
            + " nimmt \(output?.channels?.count ?? 0)"
            + ", könnte \(session.maximumOutputNumberOfChannels)")
        #endif
    }

    // MARK: Track choice

    /// Series or movie for which a manual choice is remembered. Set by
    /// ``wendeLanguagesAn(audio:subtitle:automatic:source:title:)`` at every
    /// start and episode change.
    private var trackTitle: String?
    /// The server's information on the running file: `MediaStream`s and defaults.
    private var trackSource: MediaSource?
    /// Subtitle files attached to the media. Set before `play(url:)` and
    /// reattached after a rebuild.
    private var subtitleFiles: [SubtitleFile] = []
    /// A chosen subtitle file whose track VLC does not report yet.
    private var currentSubtitle: Int?
    private var reportedTracks = TrackIndices()
    /// The track selection before a rebuild, until the new stream runs.
    private var tracksPostLayout: TrackIndices?

    /// After a rebuild, set the previous track selection again.
    ///
    /// The tracks exist only once the stream runs, hence here and not in
    /// `newConnect`. Subtitle `nil` means "off", not "don't care": exactly the
    /// case that was lost before.
    private func tracksAgainSet() {
        guard let before = tracksPostLayout else { return }
        tracksPostLayout = nil
        let audio = player.audioTracks, text = player.textTracks
        let z = mapping(audio: audio, subtitle: text)
        if let index = before.audio, let position = z.audioPositionValue(index: index), position < audio.count {
            audio[position].isSelectedExclusively = true
        }
        if let index = before.subtitle, let position = z.subtitlePosition(index: index),
           position < text.count {
            text[position].isSelectedExclusively = true
        } else if before.subtitle == nil {
            player.deselectAllTextTracks()
        }
        AppLog.writeOut("[Spuren] nach Neuaufbau wieder gesetzt: Ton \(before.audio.map(String.init) ?? "—"), "
            + "Untertitel \(before.subtitle.map(String.init) ?? "aus")")
    }

    /// The running tracks as Jellyfin indexes, on every change, for start and
    /// progress reports.
    var tracksReported: ((TrackIndices) -> Void)?

    #if DEBUG
    /// For the `-trackRun` probe (tvOS), otherwise unused.
    static weak var recent: VLCPlayerView?
    #endif

    /// MD5 of the address as hex: how libVLC names the tracks of a
    /// side-loaded file (see ``Abspielerspur/zusatzkennung``).
    static func subtitleRememberTimes(_ address: URL) -> String {
        Insecure.MD5.hash(data: Data(address.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func playerTrack(_ track: VLCMediaPlayer.Track) -> PlayerTrack {
        PlayerTrack(identifier: track.trackId, name: track.trackName, language: track.language,
                      codec: TechDetails.codecNameValue(vlcId: track.codec),
                      channels: track.audio.map { Int($0.channelsNumber) })
    }

    private func mapping(audio: [VLCMediaPlayer.Track], subtitle: [VLCMediaPlayer.Track]) -> TrackMapping {
        TrackMapping.compose(audio: audio.map(Self.playerTrack),
                             subtitle: subtitle.map(Self.playerTrack),
                             streams: trackSource?.mediaStreams ?? [],
                             files: subtitleFiles)
    }

    /// Selects audio and subtitle track per ``Spurregel``: manual choice per
    /// series, settings, server defaults, forced subtitles.
    ///
    /// The decision uses Jellyfin's index; where the track sits in VLC is told by
    /// ``Spurzuordnung``. Before, both went by track name, and audio was
    /// not remembered at all.
    func wendeLanguagesAn(audio: String, subtitle: String, automatic: Bool,
                         source: MediaSource?, title: String?) {
        trackTitle = title
        trackSource = source
        let streams = source?.mediaStreams ?? []
        let audioTracks = player.audioTracks
        let subTracks = player.textTracks
        let z = mapping(audio: audioTracks, subtitle: subTracks)
        let memory = TrackMemory()
        // Only the state *before* the selection: VLC applies a track selection on
        // the input thread, milliseconds to tenths of a second later. An "after"
        // directly following still shows the old state (e.g. "audio/2 -> audio/2"
        // although another audio track was just selected). What is requested is in
        // separate lines.
        StartMeasurement.shared.mark("Spuren vorher · Ton \(audioTracks.first(where: \.isSelected)?.trackId ?? "—")"
            + " · Untertitel \(subTracks.first(where: \.isSelected)?.trackId ?? "—")")

        var audioIndex = TrackRule.audio(streams: streams,
                                     remembered: title.flatMap { memory.audio(for: $0) },
                                     preferredLanguage: audio,
                                     serverPreGift: source?.defaultAudioStreamIndex)
        // **Only select what is not already playing.** At start the wanted track is
        // usually the file's own already; setting it anyway sends a track selection
        // through player and input in the middle of the first pictures, for
        // nothing.
        if let searched = audioIndex, let position = z.audioPositionValue(index: searched) {
            if !audioTracks[position].isSelected {
                StartMeasurement.shared.mark("Tonwechsel nach dem Start → \(audioTracks[position].trackId) (Jellyfin \(searched))")
                audioTracks[position].isSelectedExclusively = true
            }
        } else {
            // Cannot be mapped: the old way via the name, otherwise the file.
            if !audio.isEmpty, let hit = audioTracks.first(where: { Language.fits($0.trackName, toward: audio) }),
               !hit.isSelected {
                StartMeasurement.shared.mark("Tonwechsel angefordert → \(hit.trackId) (nach Name)")
                hit.isSelectedExclusively = true
            }
            audioIndex = audioTracks.firstIndex(where: \.isSelected).flatMap { z.audio[$0] }
        }

        let choice = TrackRule.subtitle(streams: streams,
                                        remembered: title.flatMap { memory.subtitle(for: $0) },
                                        serverPreGift: source?.defaultSubtitleStreamIndex,
                                        automatic: automatic, audioIndex: audioIndex,
                                        tonwunsch: audio, preferredLanguage: subtitle)
        AppLog.writeOut("[Spuren] Ton \(audioIndex.map(String.init) ?? "Datei") · Untertitel \(choice)"
            + " · Vorgaben \(source?.defaultAudioStreamIndex.map(String.init) ?? "—")/"
            + "\(source?.defaultSubtitleStreamIndex.map(String.init) ?? "—")"
            + " · Zuordnung Ton \(z.audio) Untertitel \(z.subtitle)"
            + " · Kennungen \(subTracks.map(\.trackId))")
        subtitleSet(choice, tracks: subTracks, mapping: z)
        trackIndicesReport(TrackIndices(audio: audioIndex, subtitle: subtitleIndex(choice)))
        pagesRatioCheck(source)
    }

    /// **Anamorphic Matroska from ffmpeg: VLC 4 squashes the picture**; see
    /// ``Seitenverhaeltnis``. Then Jellyfin's display ratio applies.
    /// Reset in `open`, otherwise the next episode would inherit it.
    private func pagesRatioCheck(_ source: MediaSource?) {
        guard let image = source?.mediaStreams?.first(where: { $0.type == "Video" }),
              let track = player.videoTracks.first(where: \.isSelected) ?? player.videoTracks.first,
              let video = track.video,
              let should = PagesRatio.correction(
                  sar: (UInt32(video.sourceAspectRatio), UInt32(video.sourceAspectRatioDenominator)),
                  width: image.width ?? 0, height: image.height ?? 0, display: image.aspectRatio)
        else { return }
        player.videoAspectRatio = should
        StartMeasurement.shared.mark("Seitenverhältnis gesetzt")
        AppLog.writeOut("[Bild] VLC meldet \(video.sourceAspectRatio):\(video.sourceAspectRatioDenominator)"
            + " fuer \(image.width ?? 0)x\(image.height ?? 0) \(image.aspectRatio ?? "?") — Anzeige auf \(should) gesetzt")
    }

    private func subtitleIndex(_ choice: TrackRule.Subtitle) -> Int {
        if case .feed(let index) = choice { return index }
        return -1
    }

    private func subtitleSet(_ choice: TrackRule.Subtitle, tracks: [VLCMediaPlayer.Track],
                                  mapping z: TrackMapping) {
        currentSubtitle = nil
        guard case .feed(let index) = choice else {
            // Actively turn off: the file often brings its own preselection.
            // If none is selected, there is nothing to turn off.
            if tracks.contains(where: \.isSelected) {
                StartMeasurement.shared.mark("Untertitel abgeschaltet")
                player.deselectAllTextTracks()
            }
            return
        }
        if let position = z.subtitlePosition(index: index) {
            if !tracks[position].isSelected { tracks[position].isSelectedExclusively = true }
        } else {
            player.deselectAllTextTracks()
            if subtitleFiles.contains(where: { $0.index == index }) {
                // The file is attached but not read yet.
                currentSubtitle = index
                AppLog.writeOut("[Spuren] Untertiteldatei \(index) noch nicht da, wartet")
            } else {
                AppLog.writeOut("[Spuren] Untertitel \(index) nicht zuzuordnen, bleibt aus")
            }
        }
    }

    /// VLC reports a new subtitle track, perhaps the chosen file.
    func openSubtitleSet() {
        guard let index = currentSubtitle else { return }
        let tracks = player.textTracks
        let z = mapping(audio: player.audioTracks, subtitle: tracks)
        guard let position = z.subtitlePosition(index: index) else { return }
        currentSubtitle = nil
        tracks[position].isSelectedExclusively = true
        AppLog.writeOut("[Spuren] Untertiteldatei \(index) nachgereicht")
        trackIndicesReport(TrackIndices(audio: reportedTracks.audio, subtitle: index))
    }

    private func trackIndicesReport(_ new: TrackIndices) {
        guard new != reportedTracks else { return }
        reportedTracks = new
        tracksReported?(new)
    }

    /// Chosen by hand: applies immediately and to the whole series.
    func selectAudioTrack(_ track: VLCMediaPlayer.Track) {
        track.isSelectedExclusively = true
        let tracks = player.audioTracks
        let z = mapping(audio: tracks, subtitle: [])
        let position = tracks.firstIndex { $0.trackId == track.trackId }
        let index = position.flatMap { z.audio[$0] }
        if let trackTitle {
            let streams = trackSource?.mediaStreams ?? []
            let imprint = index.flatMap { i in streams.first { $0.type == "Audio" && $0.index == i } }
                .map { TrackImprint(feed: $0, in: streams, name: track.trackName) }
                ?? TrackImprint(track: Self.playerTrack(track))
            TrackMemory().rememberAudio(imprint, for: trackTitle)
            AppLog.writeOut("[Spuren] Ton von Hand: \(index.map(String.init) ?? "?") \(imprint)")
        }
        trackIndicesReport(TrackIndices(audio: index, subtitle: reportedTracks.subtitle))
    }

    /// `nil` turns subtitles off.
    ///
    /// Here, and only here, the choice is remembered for the series: the panel
    /// is the only way a person touches the subtitle track.
    func selectSubtitle(_ track: VLCMediaPlayer.Track?) {
        currentSubtitle = nil
        guard let track else {
            if let trackTitle { TrackMemory().rememberSubtitle(.off, for: trackTitle) }
            player.deselectAllTextTracks()
            AppLog.writeOut("[Spuren] Untertitel von Hand: aus")
            trackIndicesReport(TrackIndices(audio: reportedTracks.audio, subtitle: -1))
            return
        }
        track.isSelectedExclusively = true
        let tracks = player.textTracks
        let z = mapping(audio: [], subtitle: tracks)
        let index = tracks.firstIndex { $0.trackId == track.trackId }.flatMap { z.subtitle[$0] }
        if let trackTitle {
            let streams = trackSource?.mediaStreams ?? []
            let imprint = index.flatMap { i in streams.first { $0.type == "Subtitle" && $0.index == i } }
                .map { TrackImprint(feed: $0, in: streams, name: track.trackName) }
                ?? TrackImprint(track: Self.playerTrack(track))
            TrackMemory().rememberSubtitle(.track(imprint), for: trackTitle)
            AppLog.writeOut("[Spuren] Untertitel von Hand: \(index.map(String.init) ?? "?") \(imprint)")
        }
        trackIndicesReport(TrackIndices(audio: reportedTracks.audio, subtitle: index))
    }

    /// Names for the subtitle list, per `trackId`.
    ///
    /// VLC's track name, unless the server knows more: a side-loaded file is
    /// just "Track 1" to VLC, and two tracks named "German" cannot be told apart
    ///. Then language, format and whether it is forced or a separate
    /// file.
    func subtitleNames() -> [String: String] {
        let tracks = player.textTracks
        let z = mapping(audio: [], subtitle: tracks)
        let streams = trackSource?.mediaStreams ?? []
        var names: [String: String] = [:]
        for (position, track) in tracks.enumerated() {
            let double = tracks.filter { $0.trackName == track.trackName }.count > 1
            guard let index = z.subtitle[position],
                  let feed = streams.first(where: { $0.type == "Subtitle" && $0.index == index }),
                  double || feed.isExternal == true || feed.isHearingImpaired == true else {
                names[track.trackId] = track.trackName
                continue
            }
            let parts: [String?] = [
                feed.languageName ?? track.trackName,
                TechDetails.codecNameValue(feed.codec),
                feed.isForced == true ? String(localized: "Erzwungen") : nil,
                feed.isHearingImpaired == true ? String(localized: "Hörgeschädigt") : nil,
                feed.isExternal == true ? String(localized: "Datei") : nil,
            ]
            names[track.trackId] = parts.compactMap { $0 }.joined(separator: " · ")
        }
        return names
    }


    /// 1.0 is normal. VLC accepts values between 0.25 and 4.
    var tempo: Float {
        get { player.rate }
        set { player.rate = newValue; refreshPiPState() }
    }

    // MARK: - Delay

    /// Subtitles and audio shifted against the picture, only here, only locally.
    /// SyncPlay sees none of it: the group compares movie time, and that does
    /// not change.
    var subtitleDelay = Delay.null {
        didSet { if subtitleDelay != oldValue { delayCatchUp() } }
    }
    var audioDelay = Delay.null {
        didSet { if audioDelay != oldValue { delayCatchUp() } }
    }

    /// Before every `play` of another title: the same series keeps the value,
    /// everything else starts at zero (`Delay.forNewTitle`).
    func delayForNewTitle(oldTitle: String, oldSeries: String?,
                                    newTitle: String, addedSeries: String?) {
        subtitleDelay = .forNewTitle(subtitleDelay, oldTitle: oldTitle,
                                                 oldSeries: oldSeries, newTitle: newTitle,
                                                 addedSeries: addedSeries)
        audioDelay = .forNewTitle(audioDelay, oldTitle: oldTitle,
                                          oldSeries: oldSeries, newTitle: newTitle,
                                          addedSeries: addedSeries)
    }

    /// **VLC forgets the delay with every new media**, also after a rebuild,
    /// and set before `play` it does not arrive at all (measured, see
    /// `Delay`). So do not set it once but set it again whenever VLC reads
    /// something else: on change, on "playing" and in the watchdog's one-second
    /// tick.
    private func delayCatchUp() {
        guard player.media != nil else { return }
        let text = player.currentVideoSubTitleDelay, audio = player.currentAudioPlaybackDelay
        if subtitleDelay.softOff(fromMicroseconds: text) {
            player.currentVideoSubTitleDelay = subtitleDelay.microseconds
            StartMeasurement.shared.mark("Untertitelverzögerung gesetzt")
            AppLog.writeOut("[Verzögerung] Untertitel \(subtitleDelay.milliseconds) ms"
                + " gesetzt, VLC liest \(player.currentVideoSubTitleDelay) µs")
        }
        if audioDelay.softOff(fromMicroseconds: audio) {
            player.currentAudioPlaybackDelay = audioDelay.microseconds
            StartMeasurement.shared.mark("Tonverzögerung gesetzt")
            AppLog.writeOut("[Verzögerung] Ton \(audioDelay.milliseconds) ms"
                + " gesetzt, VLC liest \(player.currentAudioPlaybackDelay) µs")
        }
    }

    // MARK: - Position

    /// Current position in seconds.
    var positionSeconds: Double { Double(player.time.intValue) / 1000 }

    /// Total length in seconds. 0 while VLC is still reading the file.
    ///
    /// **If VLC reports none, the server's applies.** libVLC 4 never knows a
    /// length for MPEG-TS over HTTP (``MediaSource/laufzeitSekunden``); without
    /// it there was no bar and no progress report. The source exists only with
    /// the tracks; until then it stays 0 as before.
    var durationSeconds: Double {
        guard let ms = player.media?.length.intValue, ms > 0 else {
            return trackSource?.runtimeSeconds ?? 0
        }
        // The server delivers the remaining length; the UI needs the whole. With
        // offset zero both are the same.
        return Double(ms) / 1000
    }

    var isPlaying: Bool { player.isPlaying }

    /// Seeks to an absolute position.
    ///
    /// Deliberately via `jump(withOffset:)` instead of `player.time = ...`. From
    /// the device log: with `time =` VLC requested byte 21.7 MB for second 1222,
    /// i.e. second 30, and read sequentially forward 2.3 GB from there. That took
    /// 28 seconds. The same seek via `jump(withOffset:)` requests the right byte
    /// immediately (22.5 % of the file) and arrives after six seconds.
    /// **Two paths, and the file decides which works.**
    ///
    /// `jump(withOffset:)` and `player.time = ...` end up in different seekers in
    /// VLC 4. For one file `jump` was fast and `time` took 28 seconds; for
    /// another it is exactly the reverse: its seek points are unreadable, `jump`
    /// reads forward from the start of the file, and `time` lands instantly.
    /// Swiftfin always uses `time` and seeks that file without delay with direct
    /// play, i.e. the same raw file.
    ///
    /// So no path is always right. Instead of choosing one and hoping, the first
    /// is tried and **verified afterwards**; if it does not arrive, the next one
    /// takes the other. This costs a few seconds once per file and never again.
    func seek(toSeconds seconds: Double) {
        // **Bounded at the entry.** A target of NaN or infinity (a runtime of zero
        // that was divided by) made `Int(seconds * 1000)` crash further down; the
        // conversion does not check.
        guard let seconds = JumpTarget.seconds(seconds) else {
            AppLog.writeOut("[VLC] Sprungziel ohne Zahl verworfen")
            return
        }
        reporter.jumpNow()
        jumpTrigger(on: seconds, overTime: timeSetBetter)
        jumpObserve(target: seconds)
        refreshPiPState()
        jumpReported?(seconds)
    }

    private func jumpTrigger(on seconds: Double, overTime: Bool) {
        if overTime {
            AppLog.writeOut("[VLC] Sprung auf \(Int(seconds)) s ueber die Zeit (von \(Int(positionSeconds)) s)")
            player.time = VLCTime(int: Int32(clamping: Int(seconds * 1000)))
        } else {
            let spacing = seconds - positionSeconds
            AppLog.writeOut("[VLC] Sprung auf \(Int(seconds)) s ueber den Abstand \(Int(spacing)) s")
            player.jump(withOffset: Int32(clamping: Int(spacing * 1000)), completion: {})
        }
    }

    /// Remembers where the seek should go; `jumpPostMeasure` checks a second
    /// later whether it worked.
    private func jumpObserve(target: Double) {
        openTarget = target
        openSince = Date()
        jumpLevel = 0
        lastJumpCommand = Date()
    }


    /// Relative seek.
    ///
    /// **If the previous seek is still in flight, its target counts**: "Skip
    /// intro", right after "30 s forward", and playback jumped back to the end of
    /// the intro. Two reasons: `jump(withOffset:)` computes from VLC's own, still
    /// old time, and `jumpPostMeasure` kept watching the **old** target, saw
    /// playback 30 s off and jumped back there "to the rescue". Now a seek on a
    /// pending one is absolute from the pending target, and the new target is
    /// verified.
    func jump(seconds: Int32) {
        reporter.jumpNow()
        if let opened = openTarget {
            let target = max(opened + Double(seconds), 0)
            AppLog.writeOut("[VLC] Sprung um \(seconds) s vom offenen Ziel \(Int(opened)) s")
            jumpTrigger(on: target, overTime: timeSetBetter)
            jumpObserve(target: target)
            refreshPiPState()
            jumpReported?(target)
            return
        }
        let row = "[VLC] Sprung um \(seconds) s von \(Int(positionSeconds)) s"
        Self.log.info("\(row, privacy: .public)")
        let target = positionSeconds + Double(seconds)
        player.jump(withOffset: seconds * 1000, completion: {})
        refreshPiPState()
        jumpReported?(target)
    }
}

extension VLCMediaPlayer.Track {
    /// "German - AAC - 5.1" instead of VLC's raw track name.
    ///
    /// **Deliberately not via Jellyfin's `MediaStream` list**, although it is
    /// already nicely formatted: the position in VLC's track list would have to
    /// match the position in Jellyfin's list, and a miss would show a wrong
    /// language, worse than the raw name. Everything comes from the track.
    /// Identity and comparison stay with `trackName`.
    var prettyName: String {
        let libvlcName = codecName()
        return TechDetails.audioTrackName(
            language: language,
            codec: TechDetails.codecNameValue(vlcId: codec) ?? (libvlcName.isEmpty ? nil : libvlcName),
            channels: audio.map { Int($0.channelsNumber) }
        ) ?? trackName
    }
}


/// Observes VLC's state, deliberately without actor isolation because VLCKit
/// reports from its own thread.
/// Routes VLC's own messages into the same file as ours and into the buffer
/// from which a user shares their log. In the shipped build only from warning
/// up: there VLC's connection errors appear, and nothing more should add
/// load.
///
/// **Filtered, not complete.** At `debug` VLC writes hundreds of lines per
/// second; unfiltered, the file would hit its limit within seconds and the
/// logging itself would be the bottleneck. What answers where the wait comes
/// from is let through: access layer, demuxer, buffer, decoder, plus
/// everything VLC itself rates as error or warning.
final class FileLog: NSObject, VLCLogging, @unchecked Sendable {
    /// **The level is a load itself, not a mere filter.**
    ///
    /// At `debug` VLC emits hundreds of lines per second during playback, and
    /// each runs through `print`, a lock and a file write. Anyone measuring how
    /// evenly pictures reach the screen measures largely themselves; four
    /// measurements on Apple TV came about that way, whose stutter may have come
    /// from logging.
    ///
    /// `warning` lets through exactly what says something about the output: VLC
    /// rates late pictures and clock deviations as warnings. For the demuxer
    /// search that needs `debug`, a set key suffices; then it may be slow.
    #if DEBUG
    private var reasonLevel: VLCLogLevel = UserDefaults.standard.bool(forKey: "vlcAusfuehrlich")
        ? .debug : .info
    #else
    private var reasonLevel: VLCLogLevel = .warning
    #endif

    /// In the ``Startmessung`` window at `debug`: the lines describing the start
    /// of audio and clock ("deferring start", "starting late", the output
    /// latency) are rated `debug` by VLC. Of these only
    /// ``Startmessung/vlcDebugKeywords`` get through; the rest is discarded
    /// before it sees a lock or the disk.
    var level: VLCLogLevel {
        get { StartMeasurement.shared.milliseconds != nil ? .debug : reasonLevel }
        set { reasonLevel = newValue }
    }

    /// **Filter by content, not by module.**
    ///
    /// The first attempt let through only messages from certain modules: mkv,
    /// avcodec, videotoolbox. The log then contained only `http` and `libvlc`:
    /// VLCKit does not pass the module name for most messages. The filter thus
    /// threw away exactly what was being looked for, and the result looked like
    /// radio silence. What remained was only what VLC itself rated as an error.
    ///
    /// Now the other way round: keep everything except HTTP framing traffic. That
    /// is the real flood, a thousand lines in thirty seconds, and it says nothing
    /// the range requests do not already say.
    private static let flood = ["frame of", "window update", "setting:", "headers:"]

    /// **What still gets through at `info`.**
    ///
    /// The level is `info` because the one line that says *what* decodes falls
    /// there: "using video decoder module ...". Without it you cannot tell whether
    /// HEVC runs on VideoToolbox or on the CPU, and both look the same from
    /// outside. So only what answers that question is written, plus everything
    /// from warning up; the rest is discarded before it sees a lock or the
    /// disk.
    private static let searched = ["decoder module", "using video", "using audio",
                                  "videotoolbox", "hardware", "vout display",
                                  "picture is too late", "clock"]

    func handleMessage(_ postDirection: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        let text = postDirection.lowercased()
        guard !Self.flood.contains(where: { text.contains($0) }) else { return }
        let moduleRef = context?.module ?? "?"
        if let ms = StartMeasurement.shared.milliseconds {
            let list = logLevel == .debug ? StartMeasurement.vlcDebugKeywords : StartMeasurement.vlcStitchWords
            if list.contains(where: { text.contains($0) }) {
                AppLog.writeOut("[Start] +\(ms) ms [vlc/\(moduleRef)] \(postDirection)")
                return
            }
        }
        guard logLevel != .debug || reasonLevel == .debug else { return }
        let important = logLevel == .error || logLevel == .warning
        guard important || Self.searched.contains(where: { text.contains($0) }) else { return }
        AppLog.writeOut("[vlc/\(moduleRef)] \(postDirection)")
    }
}

final class StateReporter: NSObject, VLCMediaPlayerDelegate, @unchecked Sendable {
    private weak var player: VLCMediaPlayer?
    private let lock = NSLock()
    private var lastJump: Date?

    init(player: VLCMediaPlayer) {
        self.player = player
        super.init()
    }

    func jumpNow() {
        lock.lock(); lastJump = Date(); lock.unlock()
    }

    private var bufferState: Float = 0
    private var bufferGrewLast = Date.distantPast

    /// **When the buffer last grew.**
    ///
    /// This is the difference between "slow" and "dead". A dropped stream fills
    /// nothing anymore; a sluggish one keeps filling, just not fast enough.
    /// Treating both the same pulls the rug from under exactly the one that is
    /// about to recover.
    var bufferGrewPre: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(bufferGrewLast)
    }

    private var sinceJump: String {
        lock.lock(); defer { lock.unlock() }
        guard let lastJump else { return "—" }
        return String(format: "%.1f", Date().timeIntervalSince(lastJump))
    }

    /// Called on the first transition to Playing.
    var startPlay: (() -> Void)?
    var stateSwitch: ((VLCMediaPlayerState) -> Void)?
    /// A subtitle track was added, e.g. a side-loaded file.
    var subtitleTo: (() -> Void)?

    func mediaPlayerTrackAdded(_ trackId: String, with trackType: VLCMedia.TrackType) {
        guard trackType == .text else { return }
        subtitleTo?()
    }
    private var hasPlay = false

    /// Before a new setup: otherwise the start position would stay unset because
    /// the transition to Playing is reported only the first time.
    func newBegin() {
        lock.lock(); defer { lock.unlock() }
        hasPlay = false
    }

    func mediaPlayerStateChanged(_ new: VLCMediaPlayerState) {
        let name = VLCMediaPlayerStateToString(new)
        let position = Int((player?.time.intValue ?? 0) / 1000)
        AppLog.writeOut("[VLC] Zustand: \(name) · Position \(position) s · \(sinceJump) s nach Sprung")

        // Under the same lock as newBegin(): the state comes from VLC's thread,
        // the reset from the main thread.
        lock.lock()
        let firstTimes = (new == .playing && !hasPlay)
        if firstTimes { hasPlay = true }
        lock.unlock()

        if firstTimes { startPlay?() }
        stateSwitch?(new)
    }

    private var lastMessage = Date.distantPast

    func mediaPlayerBufferingChanged(_ progress: Float) {
        // The value arrives as 0.0-1.0. And the callback fires dozens of times per
        // second; unthrottled, the logging alone slows the app.
        guard progress < 1 else { return }
        lock.lock()
        // A reset to zero is the start of a new fill, not a step back; otherwise the
        // restart would count as a stall.
        //
        // **Only the jump to zero, not staying there.** It used to be
        // `progress == 0`, which also hits a buffer that stays at zero: every
        // callback refreshed the timestamp, `bufferGrewPre` stayed at zero, and the
        // emergency brake would never have triggered in exactly the situation it
        // exists for. Found while cross-reading; in our measurement no callbacks came
        // in that situation at all, so the error was never seen: a gap in the logic,
        // not an observed failure.
        if progress > bufferState || (progress == 0 && bufferState > 0) {
            bufferGrewLast = Date()
        }
        bufferState = progress
        let due = Date().timeIntervalSince(lastMessage) > 1
        if due { lastMessage = Date() }
        lock.unlock()
        guard due else { return }
        AppLog.writeOut("[VLC] puffert: \(Int(progress * 100)) %")
    }
}

#if os(iOS)
// MARK: - Picture in picture

/// The reason for this app, and the reason it embeds VLCKit 4 instead of 3.
/// tvOS does not have it: there the TV is already the big picture, and a
/// small one beside it has no home.
extension VLCPlayerView: @preconcurrency VLCPictureInPictureDrawable {

    func mediaController() -> VLCPictureInPictureMediaControlling { controller }

    func pictureInPictureReady() -> (((any VLCPictureInPictureWindowControlling)?) -> Void)? {
        if Self.pipDisabled {
            AppLog.writeOut("[VLC] Bild-im-Bild für diesen Lauf abgeschaltet")
            return nil
        }
        return { [weak self] window in
            Task { @MainActor in
                guard let self else { return }
                self.pipWindow = window
                window?.stateChangeEventHandler = { [weak self] started in
                    Task { @MainActor in
                        self?.imageImageRuns = started
                        self?.onPiPStateChanged?(started)
                    }
                }
                self.onPiPAvailable?(window != nil)
            }
        }
    }
}
#endif
