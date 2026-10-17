import CGtk
import Foundation
import JellyfinKit

/// **The running account switch with flight:** state between click and rest.
final class AccountTransition {
    let curve: AccountSwitchCurve?
    let beginning = Date()
    /// The flying profile picture, a layer above the whole window.
    var flyer: (wrapper: Widget, image: Widget, symbolText: Widget)?
    /// The picture that was clicked; it stays empty while it flies.
    var source: Widget?
    /// The actual switch, once.
    var switchTo: (() -> Void)?
    var swapped = false
    var popped = false
    var tick: guint = 0
    /// The home rows stay still until the swap.
    var holdRails = true
    var waitingRails: (rails: [StartRailsRow], disrupted: Bool)?

    init(curve: AccountSwitchCurve?) { self.curve = curve }
    var since: Double { Date().timeIntervalSince(beginning) }
}

/// **The account switch as motion** (modeled on `AccountSwitchTransition` on iPhone,
/// also on TV).
///
/// 1. **Click** an account in the profile: the page fades out (as on TV; the
///    desktop does not slide still images away), the old content is gone at
///    once, and the profile picture lifts off and flies in an arc to the circle
///    at the bottom of the sidebar (``Kontowechselkurve``, same springs as on
///    iPhone).
/// 2. **Switch** 0.3 s before it comes to rest (``Kontowechselkurve/wechsel``).
/// 3. **Swap** when it rests: the real picture is shown there; the ring pops on
///    landing.
/// 4. **Rows**: staggered 30 ms later, 80 ms per row.
///
/// **The profile is reachable again immediately**: if someone opens it
/// mid-flight, everything pending happens at once (``accountTransitionComplete``).
/// **Reduce motion** (`gtk-enable-animations`): no flight, only a cross-fade,
/// as on iPhone.
extension App {

    func accountSwitchWithTransition(toward identifier: String, account: Session, from source: Widget!) {
        guard accountTransition == nil else {
            AppLog.writeOut("[Kontowechsel] zweiter Klick ignoriert")
            return
        }
        guard let new = bundle, new.activeId != identifier, new.account(identifier) != nil else { return }
        let calm = motionReduced()

        // Where the picture sits and where it flies to, in points of the window
        // surface.
        var curve: AccountSwitchCurve?
        if !calm, let cover = windowCover, let source, let target = profileCircle {
            var a = graphene_rect_t(), b = graphene_rect_t()
            if gtk_widget_compute_bounds(source, cover, &a) != 0,
               gtk_widget_compute_bounds(target, cover, &b) != 0, a.size.width > 0 {
                // The front circle sits 2 points inside the field (ring), 26 large.
                let targetSize = 26.0
                curve = AccountSwitchCurve(
                    from: (Double(a.origin.x + a.size.width / 2), Double(a.origin.y + a.size.height / 2)),
                    size: Double(a.size.width),
                    to: (Double(b.origin.x) + 2 + targetSize / 2, Double(b.origin.y) + 2 + targetSize / 2),
                    targetSize: targetSize)
            }
        }
        let transition = AccountTransition(curve: curve)
        accountTransition = transition
        transition.switchTo = { [weak self] in self?.switchAccount(toward: identifier, inProfileRemain: false) }
        AppLog.writeOut("[Kontowechsel] 1: klick, flug \(curve == nil ? "aus" : "an")"
            + (curve.map { String(format: ", wechsel %.2f s, tausch %.2f s, landung %.2f s", $0.change, $0.swap, $0.landing) } ?? ""))

        // The flying picture: the same image from the same memory.
        if let curve, let cover = windowCover {
            let parts = profileCharacter(name: account.userName, border: Int(curve.size),
                                      style: "swiftly-kontoflug", fontStyle: "swiftly-zeichen26")
            profileImageLoad(parts, url: addresses?.user(account.userID, border: 200),
                            key: "konto-\(account.userID)")
            gtk_widget_set_halign(parts.wrapper, GTK_ALIGN_START)
            gtk_widget_set_valign(parts.wrapper, GTK_ALIGN_START)
            gtk_widget_set_can_target(parts.wrapper, 0)
            gtk_overlay_add_overlay(OpaquePointer(cover), parts.wrapper)
            transition.flyer = parts
            flyerSet(transition, curve.status(0))
            if let source { gtk_widget_set_opacity(source, 0); transition.source = source }
            // The real picture below waits until the flying one rests there.
            if let target = profileCircle { gtk_widget_set_opacity(target, 0) }
        }

        // The page fades out and the old content is gone at once: the stack returns
        // to the section, the rows are empty.
        if let b = stage { crossfade(b, on: 0, duration: calm ? Theme.timeReduced : 0.2, curve: .easeInOut) }
        postDeadline(calm ? Theme.timeReduced : 0.22) { [weak self] in
            guard let self, self.accountTransition === transition else { return }
            if let r = self.railsStack { wipe(r) }
            AppLog.writeOut("[Kontowechsel] 1b: seite aus, reihen leer")
        }

        // **Stages run on the clock, the position on the frame clock.** The frame
        // clock stops when the window does not draw (covered, headless); switch and
        // swap should still happen on time.
        let change = curve?.change ?? 0.15
        let swap = curve?.swap ?? 0.2
        let landing = curve?.landing
        let end = curve.map { max($0.paintEnd, $0.swap) + 0.1 } ?? 0.3
        postDeadline(change) { [weak self] in
            guard let self, self.accountTransition === transition else { return }
            self.switchRun(transition)
        }
        postDeadline(swap) { [weak self] in
            guard let self, self.accountTransition === transition, !transition.swapped else { return }
            self.exchange(transition)
        }
        if let landing {
            postDeadline(landing) { [weak self] in
                guard let self, self.accountTransition === transition, !transition.popped else { return }
                self.ringPop(transition)
            }
        }
        postDeadline(end) { [weak self] in self?.accountTransitionEnd(transition) }
        guard curve != nil, let cover = windowCover else { return }
        transition.tick = gtk_widget_add_tick_callback(cover, accountTransitionTick,
                                                 Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// One frame of the flight, in the window's frame clock; position only.
    fileprivate func accountTransitionStep() -> Bool {
        guard let transition = accountTransition, let curve = transition.curve, !transition.swapped else { return false }
        flyerSet(transition, curve.status(transition.since))
        return true
    }

    private func flyerSet(_ transition: AccountTransition, _ status: (x: Double, y: Double, s: Double)) {
        guard let parts = transition.flyer else { return }
        let s = max(status.s, 1)
        gtk_widget_set_margin_start(parts.wrapper, Int32(max(0, (status.x - s / 2).rounded())))
        gtk_widget_set_margin_top(parts.wrapper, Int32(max(0, (status.y - s / 2).rounded())))
        // The size is set on the empty box that dictates the dimensions.
        if let mass = gtk_widget_get_first_child(parts.wrapper) {
            gtk_widget_set_size_request(mass, Int32(s.rounded()), Int32(s.rounded()))
        }
    }

    private func switchRun(_ transition: AccountTransition) {
        guard let w = transition.switchTo else { return }
        transition.switchTo = nil
        let a = Date()
        AppLog.writeOut(String(format: "[Kontowechsel] 2: konto wechselt (%.2f s nach klick)", transition.since))
        w()
        AppLog.writeOut("[Kontowechsel] 2a: wechsel im hauptfaden \(Int(Date().timeIntervalSince(a) * 1000)) ms")
    }

    /// The picture rests: the real one is there now, the page returns, and the rows
    /// may come.
    private func exchange(_ transition: AccountTransition) {
        transition.swapped = true
        if let parts = transition.flyer {
            if let cover = windowCover { gtk_overlay_remove_overlay(OpaquePointer(cover), parts.wrapper) }
            transition.flyer = nil
        }
        if let target = profileCircle { gtk_widget_set_opacity(target, 1) }
        if let q = transition.source { gtk_widget_set_opacity(q, 1); transition.source = nil }
        if let b = stage { crossfade(b, on: 1, duration: motionReduced() ? Theme.timeReduced : 0.26) }
        AppLog.writeOut(String(format: "[Kontowechsel] 4: bild ruht, tausch (%.2f s nach klick)", transition.since))
        postDeadline(AccountSwitchCurve.railsPostSwap) { [weak self] in
            guard let self else { return }
            self.railsShare(transition, staggered: true)
        }
    }

    private func railsShare(_ transition: AccountTransition, staggered: Bool) {
        guard transition.holdRails else { return }
        transition.holdRails = false
        AppLog.writeOut("[Kontowechsel] 5: reihen duerfen kommen\(transition.waitingRails == nil ? " (noch nicht geladen)" : "")")
        if let w = transition.waitingRails {
            transition.waitingRails = nil
            railsShow(w.rails, disrupted: w.disrupted, staggered: staggered)
        } else if staggered, section == .start {
            // If they come later, they still come staggered.
            accountTransitionSeasonPostGl = true
        }
    }

    /// The ring pops on the front circle when the picture lands.
    private func ringPop(_ transition: AccountTransition) {
        transition.popped = true
        guard let circles = profileCircle, let front = gtk_widget_get_last_child(circles) else { return }
        gtk_widget_add_css_class(front, "swiftly-ringpop")
        let container = held(front)
        postDeadline(0.8) {
            gtk_widget_remove_css_class(container.widget, "swiftly-ringpop")
            letGo(container)
        }
    }

    private func accountTransitionEnd(_ transition: AccountTransition) {
        guard accountTransition === transition else { return }
        if transition.tick != 0, let cover = windowCover { gtk_widget_remove_tick_callback(cover, transition.tick) }
        transition.tick = 0
        accountTransition = nil
        AppLog.writeOut(String(format: "[Kontowechsel] ende (%.2f s)", transition.since))
    }

    /// **Everything pending, immediately:** the profile was opened mid-flight (iOS
    /// `complete`). The account switches now, the flying picture goes, the real
    /// one is shown, and the home page builds its rows underneath without stagger.
    func accountTransitionComplete() {
        guard let transition = accountTransition else { return }
        AppLog.writeOut("[Kontowechsel] profil geoeffnet, rest sofort")
        if transition.tick != 0, let cover = windowCover { gtk_widget_remove_tick_callback(cover, transition.tick) }
        transition.tick = 0
        switchRun(transition)
        if !transition.swapped {
            transition.swapped = true
            if let parts = transition.flyer, let cover = windowCover {
                gtk_overlay_remove_overlay(OpaquePointer(cover), parts.wrapper)
            }
            transition.flyer = nil
            if let target = profileCircle { gtk_widget_set_opacity(target, 1) }
            if let q = transition.source { gtk_widget_set_opacity(q, 1) }
            if let b = stage { gtk_widget_set_opacity(b, 1) }
        }
        accountTransition = nil
        railsShare(transition, staggered: false)
    }

    /// **A row pops in** (iOS `Reihenauftritt`): 80 ms per row, linear opacity over
    /// 0.22 s, from 14 points lower and 96 % size. The style sheet carries the
    /// curve; with "reduce motion" GTK turns transitions off itself.
    ///
    /// **The deadline runs on the frame clock, not the wall clock.** `postDeadline`
    /// removed the class after 30 ms + 80 ms per row, but building the rows takes
    /// longer: the first deadlines had expired before GTK laid out the row once
    /// with `reihe-vor`. Without a start state there is no transition and the rows
    /// appeared abruptly. Now the deadline counts from the first drawn frame
    /// (``laufen(on:dauer:linear:schritt:done:)``) and the class is removed in
    /// the frame after at the earliest.
    func railOccur(_ rail: Widget!, number: Int) {
        gtk_widget_add_css_class(rail, "swiftly-reihenauftritt")
        gtk_widget_add_css_class(rail, "swiftly-reihe-vor")
        let container = held(rail)
        let lag = AccountSwitchCurve.railsPostSwap + Double(number) * AccountSwitchCurve.railsSeason
        runningCount(on: rail, duration: lag, linear: true) { _ in } done: {
            gtk_widget_remove_css_class(container.widget, "swiftly-reihe-vor")
            letGo(container)
        }
    }
}

nonisolated(unsafe) private let accountTransitionTick: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, gpointer?
) -> gboolean = { _, _, data in
    guard let data else { return 0 }
    let app = Unmanaged<App>.fromOpaque(data).takeUnretainedValue()
    let proceed = app.accountTransitionStep()
    if !proceed, let transition = app.accountTransition { transition.tick = 0 }
    return proceed ? 1 : 0
}
