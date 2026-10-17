import AVFoundation
import OSLog
import SwiftUI
import UIKit

/// Controls which orientations the app may rotate to.
///
/// On **iPhone** the app stays in portrait; library and detail pages are built
/// for it. Only the player allows landscape, and there it can additionally be
/// locked so the picture does not flip when the phone lies flat.
///
/// On **iPad** this class does nothing, by necessity: without
/// `UIRequiresFullScreen` the app counts as multitasking-capable, and such an
/// app must not force rotation, since it shares the screen with another app
/// that may want something else. `requestGeometryUpdate` is simply rejected
/// there, so the Info.plist set (all four orientations) applies.
@MainActor
final class Orientierung {
    static let shared = Orientierung()
    private init() {}

    /// Nothing is restricted on iPad, so the full mask is set from the start.
    private(set) var allowed: UIInterfaceOrientationMask = Theme.atPad
        ? .all : .portrait

    /// `demand: false` when a transition takes the rotation along itself
    /// (`PlayerFrame`); then only set the mask.
    func setDown(_ mask: UIInterfaceOrientationMask, demand: Bool = true) {
        // On iPad `allowed` stays at `.all`. Setting the mask anyway would make the
        // app delegate report it to iOS, and the app would no longer be
        // multitasking-capable.
        guard Self.landscapeLockPossible else { return }

        allowed = mask
        guard demand else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        scene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// Player open: may rotate.
    /// **Take over audio while a movie plays, otherwise share it.**
    ///
    /// The audio session is activated at launch and stays active. This is
    /// deliberate: activating it only at playback start could fail in the middle of
    /// the player animation, VLC then got a sample rate of 0 and the picture
    /// froze. Do not change that here.
    ///
    /// Only **whether it tolerates other audio** is toggled. With
    /// `.mixWithOthers`, Spotify or a voice message keeps playing while the app
    /// is open; otherwise opening the app paused them even when nothing was
    /// playing. Once a movie starts, audio is taken exclusively and the system
    /// pauses the other playback as expected.
    ///
    /// Changing the category of an already active session does not change its
    /// sample rate, so the VLC failure cannot come back this way.
    private func audioExclusive(_ exclusive: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback,
                                    options: exclusive ? [] : [.mixWithOthers])
        } catch {
            AppLog.writeOut("[Audio] umschalten fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// **Stay in portrait during a handoff** ("continue watching here").
    /// The player opens beneath the card; rotation is allowed only once the card
    /// has zoomed onto the picture and is gone (``handoffShare(landscapeFixed:)``).
    /// Otherwise the page underneath rotated along with it.
    private(set) var handoffHolds = false

    func holdHandoff() { handoffHolds = true }

    /// The card is gone: the player now rotates as its setting says.
    func handoffShare(landscapeFixed: Bool) {
        guard handoffHolds else { return }
        handoffHolds = false
        guard let frameRect = PlayerFrame.active else { return }
        playerOpened(landscapeFixed: landscapeFixed)
        frameRect.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    func playerOpened(landscapeFixed: Bool, demand: Bool = true) {
        audioExclusive(true)
        if handoffHolds {
            setDown(.portrait, demand: false)
            return
        }
        setDown(landscapeFixed ? .landscape : [.portrait, .landscape], demand: demand)
    }

    /// Back to the app: portrait again.
    func playerClosed(demand: Bool = true) {
        handoffHolds = false
        audioExclusive(false)
        setDown(.portrait, demand: demand)
    }

    /// Is the scene currently landscape? Only relevant on iPhone.
    static var sceneLandscape: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?
            .interfaceOrientation.isLandscape ?? false
    }

    /// Whether the lock can be offered at all. Not on iPad, where a switch with
    /// no effect is worse than none.
    ///
    /// **The single place that answers this.** It used to be spelled out three
    /// times (here, in `SettingsView` and `PlayerSettings`), each as its own
    /// `!Theme.atPad`, so a rule change would have left copies behind.
    static var landscapeLockPossible: Bool { !Theme.atPad }

    /// **Whether opening the player triggers a visible rotation.**
    ///
    /// Must be known **beforehand**. Measured in the simulator: if the orientation
    /// is already right, `viewWillTransition` never fires, so waiting for the
    /// callback would wait until the fallback timeout for nothing.
    ///
    /// Without a fixed landscape lock the mask allows both orientations and iOS
    /// forces nothing. On iPad the request is rejected anyway.
    @MainActor
    static func rotationWaits(landscapeFixed: Bool) -> Bool {
        guard landscapeLockPossible, landscapeFixed else { return false }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return false }
        return scene.interfaceOrientation.isPortrait
    }
}

/// **Reports the end of the rotation, an event SwiftUI lacks.**
///
/// Measured in the simulator with `requestGeometryUpdate` to landscape:
///
/// +31 ms   viewWillTransition, coordinator duration 300 ms
/// +33 ms   onGeometryChange already reports the final values
/// +349 ms  completion
///
/// So `onGeometryChange` and `interfaceOrientation` report the **layout**, not
/// the end; a latch on them opens too early. The transition coordinator calls
/// its `completion` only when the animation is done.
///
/// UIKit forwards `viewWillTransition` to an embedded child controller like
/// this, and also when the trigger is `requestGeometryUpdate` rather than a
/// physical rotation; this was measured, not assumed.
struct RotationListener: UIViewControllerRepresentable {
    let done: () -> Void

    func makeUIViewController(context: Context) -> Listener {
        let h = Listener(); h.done = done; return h
    }
    func updateUIViewController(_ vc: Listener, context: Context) { vc.done = done }

    final class Listener: UIViewController {
        var done: (() -> Void)?
        override func viewWillTransition(to size: CGSize,
                                         with koordinator: UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: koordinator)
            koordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.done?()
            }
        }
    }
}

/// Without a delegate iOS has nowhere to ask for the allowed orientations;
/// SwiftUI alone does not provide one.
final class SwiftlyAppDelegate: NSObject, UIApplicationDelegate {

    private static let log = Logger(subsystem: "de.paulherter.swiftly", category: "start")

    /// Set up the audio session once at launch.
    ///
    /// Doing it only at playback start put it in the middle of the player's
    /// transition animation. If `setActive` fails there, VLC's audio output gets
    /// a sample rate of 0 ("too low audio sample frequency"), delivers no clock,
    /// and the video waits for it.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil)
        -> Bool {
        growImageCache()
        #if DEBUG
        if FirstFrameRun.an { FirstFrameRun.start() }
        if CardsRun.an { CardsRun.start() }
        if SpeedRun.an { SpeedRun.start() }
        #endif

        let session = AVAudioSession.sharedInstance()
        do {
            // .playback + .moviePlayback: audio keeps playing when the window
            // shrinks, otherwise picture-in-picture would be silent.
            //
            // **At launch, though, with `.mixWithOthers`**, see `tonFreigeben`.
            // An active playback session otherwise claims audio exclusively, and iOS
            // paused Spotify or a voice message as soon as the app was merely opened,
            // with nothing playing here.
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            // **System alerts must not pause the movie.**
            //
            // Pulling down the notification center caused an audio interruption, which
            // paused playback (VLC reported `pausing` every time). Only leaving the
            // app for real should pause: backgrounded without picture-in-picture,
            // closed, or device off.
            //
            // `setPrefersNoInterruptionsFromSystemAlerts` exists for this. Apple's
            // documentation does not explicitly say the notification center is covered,
            // so the interruption reason is also logged instead of assumed.
            if #available(iOS 14.5, tvOS 14.5, *) {
                try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
            }
            try session.setActive(true)
            Self.log.info("Tonsitzung aktiv · \(Int(session.sampleRate)) Hz · \(session.outputNumberOfChannels) Kanäle")
        } catch {
            Self.log.error("Tonsitzung: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }
    /// Keep posters in memory instead of refetching them while scrolling.
    ///
    /// `AsyncImage` stores nothing itself; it relies entirely on
    /// `URLCache.shared`, whose default memory capacity (half a megabyte) is so
    /// small that the second row evicts the first. Scrolling back then refetches
    /// every poster. 64 MB holds a few hundred posters; the disk cache can be
    /// more generous since it is cheap.
    private func growImageCache() {
        // Must happen before the first request: `URLSession.shared` reads
        // `URLCache.shared` on first access and keeps whatever is set then.
        // `didFinishLaunching` is the earliest point where our code runs, before any
        // view and thus before any image.
        let cache = URLCache(memoryCapacity: 64 * 1024 * 1024,
                                diskCapacity: 512 * 1024 * 1024)
        URLCache.shared = cache
        Self.log.info("Bildspeicher: \(cache.memoryCapacity / 1024 / 1024) MB im Arbeitsspeicher")
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?)
        -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { Orientierung.shared.allowed }
    }
}

/// Restores the swipe-back gesture.
///
/// Hiding the navigation bar loses it: iOS ties the gesture to the bar's back
/// button. Without this only the custom arrow works, which nobody expects on
/// iOS.
struct SwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        Holder()
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    private final class Holder: UIViewController, UIGestureRecognizerDelegate {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            adopt()
        }

        /// Also when returning from a subpage.
        ///
        /// The recognizer has only *one* delegate. Pushing another page makes that
        /// page's holder take it over; when it disappears the delegate points at
        /// nothing and the swipe does nothing.
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            adopt()
        }

        private func adopt() {
            guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
            gesture.delegate = self
            gesture.isEnabled = true
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

/// Lets the horizontal scroll view of a row yield to the back gesture.
///
/// A `ScrollView(.horizontal)` swallows the drag from the left screen edge, so
/// the row scrolls instead of the page going back. In UIKit this is a one-liner,
/// `require(toFail:)`, but both recognizers must be reachable, hence this
/// detour via an embedded view.
///
/// Placed as a row background; from there it finds the enclosing scroll view
/// and the navigation's back recognizer.
struct EdgeGesturePreRank: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Holder() }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    private final class Holder: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            // The view hierarchy exists only after being attached.
            DispatchQueue.main.async { [weak self] in self?.hookUp() }
        }

        private func hookUp() {
            guard let back = navigationController?.interactivePopGestureRecognizer
            else { return }

            // The *innermost* scroll view above us is the row's; the list's vertical one
            // is further out. Do not search by contentSize: it is still zero right after
            // attaching.
            var viewRef: UIView? = view.superview
            while let a = viewRef {
                if let scroll = a as? UIScrollView {
                    scroll.panGestureRecognizer.require(toFail: back)
                    return
                }
                viewRef = a.superview
            }
        }
    }
}

/// **Hide the system bar on the stack, not on each page.**
///
/// `.toolbar(.hidden, for: .navigationBar)` sits on every destination, yet a
/// system back button still flashed at the top when opening a detail page.
/// The modifier cannot prevent this: when pushing, UIKit creates the bar for
/// the new page, and SwiftUI hides it only after the destination's preference
/// is evaluated. One frame is drawn in between.
///
/// `setNavigationBarHidden` applies to the navigation controller, not a
/// page: once set, the bar stays away across all pushes, so it never appears
/// instead of being removed afterwards.
///
/// the way back belongs in the content, not in a system
/// bar. `DetailHeader` and `PagesArrow` carry it.
struct SystemBarDistance: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Holder() }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    private final class Holder: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            navigationController?.setNavigationBarHidden(true, animated: false)
        }

        /// Also on the way back: SwiftUI restores the bar when a page is torn down
        /// if its preference goes with it.
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            navigationController?.setNavigationBarHidden(true, animated: false)
        }
    }
}
