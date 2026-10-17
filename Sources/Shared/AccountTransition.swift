import JellyfinKit
import OSLog
import QuartzCore
import SwiftUI

// MARK: - Account switch, shared by iPhone, iPad, Mac and TV
//
// Flow and curve of the account switch and the entrance of the rows afterwards.
// The stage differs per platform: UIKit (iPhone, iPad, TV) in
// `Sources/Shared/AccountSwitchStageUIKit.swift`, on Mac in
// `Sources/macOS/AccountSwitchStage.swift`. Spring and card from the badge are in
// `Sources/Shared/Transitions.swift`. TV differences are `#if os(tvOS)` where
// they apply: profile image target size, margin, ring, and the page fades out
// instead of sliding away.

// MARK: - Account switch

/// **The account switch from the profile picker, "calm" variant** (`experiment-glas`).
///
/// **The motion runs in the render server, not on the main thread.** SwiftUI used
/// to draw the flying image frame by frame and the profile page went back via
/// navigation - both depended on the main thread, which is busy during a switch
/// (building the home page, account, storage). That showed as stutter at the
/// start and end. Now:
///
/// 1. **Tap:** a snapshot of the screen (`snapshotView`, copied in the render
///    server) lies over everything and slides away to the right as a page;
///    next to it the profile image flies as a finished layer. Both are
///    Core Animation animations with precomputed keyframes (120 per second) -
///    they keep running even if the main thread stalls.
/// 2. **Only afterwards**, one pass later, the stack jumps back without
///    animation - under the snapshot, invisible.
/// 3. **Switch:** 0.3 s before rest (``switchPreIdle``).
/// 4. **Swap:** only once the image rests is the real one there, and the
///    layer goes one pass later.
/// 5. **Rows:** staggered 30 ms later (``Reihenauftritt``).
///
/// The log (category `accountSwitch`) has every stage with a time; the debug
/// build also logs every frame that takes too long (``Bildzeitmesser``).
///
/// **On TV** the same flow, with focus instead of a tap: pressing an account in
/// the account strip starts it, the page **fades out** instead of sliding right
/// (tvOS does not push pages, it cross-fades), and focus ends up on the profile
/// image at the top right - the profile is reachable again at once
/// (``MainView``, `profileFocus`).
@MainActor @Observable
final class AccountSwitchTransition {
    static let shared = AccountSwitchTransition()

    struct Transition {
        let account: String
        /// The real image in the header is already there (step 4).
        var replaced = false
    }

    private(set) var transition: Transition?
    /// Between tap and release - the home page holds its rows back meanwhile.
    private(set) var waits = false
    /// Increments after the tap: `MainView` uses it to clear the stacks, without
    /// animation, under the snapshot.
    private(set) var back = 0
    /// Where the profile image sits, globally - reported by ``Profilziel``
    /// (iPhone), the sidebar (wide iPad) or the profile row (Mac).
    @ObservationIgnored var target: CGRect = .zero
    /// Size of the image there - 34 at the top right, 26 in the Mac sidebar.
    @ObservationIgnored var targetSize: CGFloat = Curve.targetSize
    /// Content starts here (right of the sidebar). Only this part slides away
    /// as a page; the sidebar stays. 0 without a sidebar.
    @ObservationIgnored var contentOff: CGFloat = 0
    /// Accounts known at tap time to have no image: the top image then shows
    /// the letter from the very first pass.
    private(set) var withoutImage: Set<URL> = []

    static let log = Logger(subsystem: "de.paulherter.swiftly", category: "kontowechsel")

    /// To the system log **and** the app's log file - the latter is pulled
    /// from the device with `Werkzeuge/fetch-log.sh`, with a timestamp per line.
    static func note(_ text: String) {
        log.info("\(text, privacy: .public)")
        AppLog.writeOut("[Kontowechsel] \(text)")
    }
    static let symbolText = OSSignposter(subsystem: "de.paulherter.swiftly", category: "kontowechsel")
    /// The old profile steps back: from 80 ms, linear over 0.2 s.
    static var lift: Animation { .linear(duration: 0.2).delay(0.08) }

    /// **When the account really switches**: 0.3 s before the image rests. The
    /// switch and everything hanging off it costs the main thread time; shortly
    /// before rest the image moves only by fractions of a point, and the new
    /// profile image is in the header before the swap.
    static var switchPreIdle: Double { AccountSwitchCurve.switchPreIdle }

    /// **Only if it really sits at the top right.** The target also reports
    /// mid-push, when it sits a third of the screen further left - nothing
    /// should fly there.
    func targetReport(_ frameRect: CGRect) {
        guard frameRect.width > 0 else { return }
        let window = AccountSwitchStage.windowWidthValue ?? frameRect.maxX
        #if os(tvOS)
        // TV keeps an 80 pt margin and the header bar is fixed - nothing slides in
        // from the side here.
        let margin: CGFloat = 200
        #else
        let margin: CGFloat = 60
        #endif
        if frameRect.maxX > window - margin {
            target = frameRect
            targetSize = Curve.targetSize
            contentOff = 0
        }
    }

    /// **The profile image in a sidebar** (wide iPad, Mac): it sits at the
    /// bottom left, not the top right, and always counts there. `size` is the
    /// circle itself, `contentOff` the right edge of the sidebar.
    func targetInBarReport(_ frameRect: CGRect, size: CGFloat, contentOff: CGFloat) {
        guard frameRect.width > 0 else { return }
        target = frameRect
        targetSize = size
        self.contentOff = contentOff
    }

    /// **This switch has already cleared the stacks** (on press, via
    /// ``back``). `MainView` checks this on `kontowechsel` instead of looking
    /// at ``waits``: if someone opens the profile mid-flight, ``abschliessen()``
    /// finishes it, `waits` is already false when SwiftUI reports the changed
    /// counter - and clearing there removed the just-opened profile page again
    /// (`-profileTip 300`). Read once, consumed.
    @ObservationIgnored private var stackEmptied = false
    func stackAlreadyEmpty() -> Bool {
        defer { stackEmptied = false }
        return stackEmptied
    }

    /// Tap on an account. `image` is the profile image as it should fly
    /// (``ProfileCharacter``), `flaeche` the colour beneath it in the card.
    /// The running switch - pending stages and the stage. A switch can finish
    /// earlier than planned (``abschliessen``); its schedule then runs into
    /// nothing, since each stage runs only once.
    private final class Run {
        let number: Int
        var switchTo: (() -> Void)?
        var stage: AccountSwitchStage.Parts?
        init(number: Int, switchTo: @escaping () -> Void) {
            self.number = number
            self.switchTo = switchTo
        }
    }
    @ObservationIgnored private var run: Run?
    @ObservationIgnored private var runCount = 0

    func start(account: String, image: some View, from: CGRect, area: Color,
                 address: URL?, switchTo: @escaping () -> Void) {
        guard !waits else {
            Self.note("wechsel: zweiter tipp ignoriert")
            return
        }
        let now = CACurrentMediaTime()
        runCount += 1
        let myOwn = Run(number: runCount, switchTo: switchTo)
        run = myOwn
        waits = true
        stackEmptied = false
        if let address, ImageCache.shared.image(address) == nil { withoutImage.insert(address) }
        #if DEBUG && canImport(UIKit)
        ImageTimeMeasure.shared.start()
        #endif
        let calm = Theme.motionReduced
        var curve: Curve?
        if !calm, from.width > 0, target.width > 0 {
            curve = Curve(from: CGPoint(x: from.midX, y: from.midY), size: from.width,
                          to: CGPoint(x: target.midX, y: target.midY), targetSize: targetSize)
        }
        // The stage differs per platform: layers in the render server on iPhone,
        // an overlay above the window on Mac. Without a window, no motion.
        myOwn.stage = AccountSwitchStage.play(curve: curve, image: image, from: from, area: area,
                                                   contentOff: contentOff, calm: calm, start: now)
        if myOwn.stage == nil { curve = nil }
        if curve != nil { transition = Transition(account: account) }
        #if DEBUG && canImport(UIKit)
        ImageTimeMeasure.shared.curve = curve
        #endif
        Self.note("wechsel 1: tipp, flug \(curve == nil ? "aus" : "an"), standbild faehrt weg")
        // One pass later: the animations are then already at the render server,
        // and what the stack costs does not hold them up.
        Task { @MainActor in
            await Task.yield()
            self.back += 1
            Self.note("wechsel 1b: stapel leer (unter dem standbild)")
        }
        Task { @MainActor in
            func until(_ t: Double) async {
                try? await Task.sleep(for: .seconds(max(0, t - (CACurrentMediaTime() - now))))
            }
            @MainActor func applies() -> Bool { self.run === myOwn }
            await until(curve.map { $0.computation.change } ?? (calm ? 0.15 : 0.45))
            guard applies() else { return }
            self.switchRun(myOwn)
            if let curve {
                await until(curve.swap)
                guard applies() else { return }
                Self.note("wechsel 4: bild ruht, tausch gegen das echte (\(Int(curve.swap * 1000)) ms nach tipp)")
                self.transition?.replaced = true
            }
            try? await Task.sleep(for: .milliseconds(30))
            guard applies() else { return }
            Self.note("wechsel 5: reihen duerfen kommen")
            self.waits = false
            if let curve {
                await until(curve.paintEnd + 0.1)
                guard applies() else { return }
            }
            self.finish(myOwn)
        }
    }

    private func switchRun(_ l: Run) {
        guard let w = l.switchTo else { return }
        l.switchTo = nil
        stackEmptied = true
        Self.note("wechsel 2: konto wechselt, laden beginnt")
        let interval = Self.symbolText.beginInterval("kontoWechseln")
        let a = CACurrentMediaTime()
        w()
        Self.symbolText.endInterval("kontoWechseln", interval)
        Self.note("wechsel 2a: wechsel im hauptlauf \(Int((CACurrentMediaTime() - a) * 1000)) ms")
    }

    private func finish(_ l: Run) {
        guard run === l else { return }
        run = nil
        transition = nil
        waits = false
        #if DEBUG && canImport(UIKit)
        ImageTimeMeasure.shared.halt()
        #endif
    }

    /// **The profile page opens while the switch is still running** (the profile
    /// at the top is tappable again at once). Everything pending is then done
    /// immediately: the account switches now, snapshot and flying image go, the
    /// real image is there, and the home page may build its rows - in the
    /// background, under the page.
    func complete() {
        guard let l = run else { return }
        Self.note("wechsel: profil geoeffnet, rest sofort")
        switchRun(l)
        l.stage?.cancel()
        transition?.replaced = true
        finish(l)
    }

    /// **The arc of the profile image** - the math is in the package
    /// (``Kontowechselkurve``, with tests) so Linux, Windows and Android fly the
    /// same arc. Here only the translation into points.
    struct Curve {
        let computation: AccountSwitchCurve
        let to: CGPoint
        var size: CGFloat { CGFloat(computation.size) }
        /// Size of the image at the target.
        var targetSize: CGFloat { CGFloat(computation.target) }
        /// When the image rests (to 0.3 pt) - seconds after the tap.
        var swap: Double { computation.swap }
        /// When it first falls back to target height: the ring pops there.
        var landing: Double { computation.landing }
        var paintEnd: Double { computation.paintEnd }

        static var grow: Double { AccountSwitchCurve.grow }
        #if os(tvOS)
        /// The header's profile image (60), with the focus magnification that sits
        /// there after the switch (``Stil/focusMagnifierSmall``).
        static let targetSize: CGFloat = 60 * Theme.focusMagnifierSmall
        #else
        /// Top right on iPhone and iPad.
        static let targetSize: CGFloat = 34
        #endif

        init(from: CGPoint, size: CGFloat, to: CGPoint, targetSize: CGFloat = Self.targetSize) {
            self.to = to
            computation = AccountSwitchCurve(from: (Double(from.x), Double(from.y)), size: Double(size),
                                         to: (Double(to.x), Double(to.y)),
                                         targetSize: Double(targetSize))
        }

        func status(_ t: Double) -> (x: CGFloat, y: CGFloat, s: CGFloat) {
            let b = computation.status(t)
            return (CGFloat(b.x), CGFloat(b.y), CGFloat(b.s))
        }

        static func spring(_ from: CGFloat, _ to: CGFloat, _ v0: Double,
                          _ r: Double, _ z: Double, _ t: Double) -> CGFloat {
            CGFloat(AccountSwitchCurve.spring(Double(from), Double(to), v0, r, z, t))
        }
    }
}

/// **A home page row that pops in after the switch** - 80 ms per row, opacity
/// linear over 0.22 s, offset 14 pt and scale 0.96 via a 0.55/0.82 spring. Only
/// opacity, scale and offset: none changes layout, so nothing jumps. Hiding is
/// fast and unstaggered.
struct RailsEntrance: ViewModifier {
    let index: Int
    let present: Bool

    func body(content: Content) -> some View {
        let calm = Theme.motionReduced
        let lag = Double(index) * AccountSwitchCurve.railsSeason
        content
            .scaleEffect(present || calm ? 1 : AccountSwitchCurve.railsMass, anchor: .top)
            .offset(y: present || calm ? 0 : AccountSwitchCurve.railsOffset)
            .animation(calm ? Theme.fadeReduced
                       : present ? .spring(response: 0.55, dampingFraction: 0.82).delay(lag)
                            : .easeOut(duration: 0.12), value: present)
            .opacity(present ? 1 : 0)
            .animation(calm ? Theme.fadeReduced
                       : present ? .linear(duration: AccountSwitchCurve.railsFade).delay(lag) : .easeOut(duration: 0.12), value: present)
    }
}

extension View {
    func railEntrance(_ index: Int, present: Bool) -> some View {
        modifier(RailsEntrance(index: index, present: present))
    }
}

/// **A part of a page that disappears on account switch without a fade-out
/// motion** and comes back staggered with the new content - ``Reihenauftritt``
/// without its short slide-away (there a snapshot covers the page, here it
/// stands open).
struct AccountSwitchPart: ViewModifier {
    let index: Int
    let present: Bool

    func body(content: Content) -> some View {
        let calm = Theme.motionReduced
        let lag = Double(index) * AccountSwitchCurve.railsSeason
        content
            .scaleEffect(present || calm ? 1 : AccountSwitchCurve.railsMass, anchor: .top)
            .offset(y: present || calm ? 0 : AccountSwitchCurve.railsOffset)
            .opacity(present ? 1 : 0)
            .animation(present ? (calm ? Theme.fadeReduced
                                   : .spring(response: 0.55, dampingFraction: 0.82).delay(lag))
                          : nil, value: present)
    }
}

/// **A whole page (Movies, Series, Search) holds its content back on account
/// switch** - like the home page its rows: on tap in the profile picker the old
/// account's content is gone at once, and only when the flight is over and
/// `ready` holds does the new content come in staggered. `ready` must be
/// false while the page still holds the previous account's titles. The state
/// belongs to the page (`change`) so header and error banner can read it;
/// after four seconds it ends in any case.
struct AccountSwitchFade: ViewModifier {
    let model: AppModel
    let ready: Bool
    @Binding var change: Bool

    private var free: Bool { ready && !AccountSwitchTransition.shared.waits }

    func body(content: Content) -> some View {
        content
            .modifier(AccountSwitchPart(index: 1, present: !change && !AccountSwitchTransition.shared.waits))
            .onChange(of: AccountSwitchTransition.shared.waits) { _, waits in
                if waits { change = true } else if free { change = false }
            }
            .onChange(of: model.accountSwitch) { _, _ in change = !free }
            .onChange(of: free) { _, now in
                if now, change { change = false }
            }
            .task(id: change) {
                guard change else { return }
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { change = false }
            }
    }
}

extension View {
    func accountSwitchFade(model: AppModel, ready: Bool, change: Binding<Bool>) -> some View {
        modifier(AccountSwitchFade(model: model, ready: ready, change: change))
    }
    func accountSwitchPart(_ index: Int = 0, present: Bool) -> some View {
        modifier(AccountSwitchPart(index: index, present: present))
    }
}

/// Reports a view's global frame without setting state - for the account
/// switch (profile page on iPhone and Mac).
struct FrameReporter: ViewModifier {
    let report: (CGRect) -> Void
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { report($0) }
    }
}
