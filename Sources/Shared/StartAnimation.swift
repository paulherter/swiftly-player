import Lottie
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The launch animation: the triangle moves up, then the letters move out.
///
/// The source is a Lottie exported from After Effects. It is not rebuilt by
/// hand: every keyframe carries its own Bezier easing, and recomputing those
/// yields a motion that is *almost* right, which is more noticeable than an
/// extra package.
///
/// **Two arms, one sequence.** The Mac had none for a long time, because the
/// animation needs a canvas that only existed as `UIViewRepresentable`. That is
/// resolved: below is the same sequence again for AppKit.
///
/// **Why not one shared body with two wrappers:** `makeUIView` and `makeNSView`
/// are different requirements of different protocols, and the view classes
/// underneath share no ancestor. An adapter serving both would be longer than
/// the second version and would have to be considered on every change to
/// either side. The motion itself lives in the source file, not in the code.
#if canImport(UIKit)
struct StartAnimation: UIViewRepresentable {
    var postRun: TimeInterval = 0.5
    /// Latest point at which it continues, whatever the animation does.
    var latestBy: TimeInterval = 3.5
    let done: () -> Void

    /// Wrapper without its own intrinsic size.
    ///
    /// `LottieAnimationView` reports the source size (here 1024 x 1024) as its
    /// intrinsic size, and a `UIViewRepresentable` then overrides SwiftUI's frame.
    /// Without this wrapper the animation grows beyond the whole screen.
    final class Wrapper: UIView {
        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
        }
    }

    /// Ensures `done` is called exactly once, by the animation's completion or
    /// by the deadline, whichever comes first.
    final class InTimes {
        private var alreadyCall = false
        func invoke(_ perform: () -> Void) {
            guard !alreadyCall else { return }
            alreadyCall = true
            perform()
        }
    }

    func makeCoordinator() -> InTimes { InTimes() }

    func makeUIView(context: Context) -> Wrapper {
        let wrapper = Wrapper()
        wrapper.setContentHuggingPriority(.defaultLow, for: .horizontal)
        wrapper.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wrapper.setContentHuggingPriority(.defaultLow, for: .vertical)
        wrapper.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let viewRef = LottieAnimationView(name: "startanimation")
        StartAnimation.tint(viewRef)
        viewRef.contentMode = .scaleAspectFit
        viewRef.loopMode = .playOnce
        // Keep running when the screen is not in motion; otherwise the animation
        // stalls while loading happens in the background.
        viewRef.backgroundBehavior = .pauseAndRestore
        viewRef.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(viewRef)
        NSLayoutConstraint.activate([
            viewRef.topAnchor.constraint(equalTo: wrapper.topAnchor),
            viewRef.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            viewRef.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            viewRef.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])
        let inTimes = context.coordinator
        let proceed = { DispatchQueue.main.asyncAfter(deadline: .now() + postRun) {
            inTimes.invoke(done)
        } }

        // Do not play at all without the source.
        //
        // `LottieAnimationView(name:)` returns a view even if the file is missing or
        // unreadable, but `animation` stays nil and `play(completion:)` **never** calls
        // its completion. The curtain would cover the app forever.
        guard viewRef.animation != nil else {
            inTimes.invoke(done)
            return wrapper
        }

        // **With Reduce Motion, the still frame instead of the motion.** The mark
        // appears immediately in its final position and stays as long as the animation
        // would take; then the app fades in as usual.
        if Theme.motionReduced {
            viewRef.currentProgress = 1
            proceed()
            return wrapper
        }

        viewRef.play { _ in
            // Hold the still frame for a moment before the app fades in; otherwise the
            // mark looks like it was just passed through.
            proceed()
        }

        // Second way to the same goal. Lottie does not call its completion if the
        // view is paused in the background and no longer runs. A deadline alongside
        // costs nothing and cannot leave the app hanging.
        DispatchQueue.main.asyncAfter(deadline: .now() + latestBy) {
            inTimes.invoke(done)
        }
        return wrapper
    }

    func updateUIView(_ viewRef: Wrapper, context: Context) {}
}

#else

/// The AppKit version. Same sequence, same deadlines, same caution: do not
/// play without the source, and keep a deadline alongside so the curtain never
/// stays.
struct StartAnimation: NSViewRepresentable {
    var postRun: TimeInterval = 0.5
    var latestBy: TimeInterval = 3.5
    let done: () -> Void

    /// As on iOS: without its own wrapper `LottieAnimationView` imposes its
    /// intrinsic size of 1024 x 1024 against SwiftUI's frame.
    final class Wrapper: NSView {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
    }

    final class InTimes {
        private var alreadyCall = false
        func invoke(_ perform: () -> Void) {
            guard !alreadyCall else { return }
            alreadyCall = true
            perform()
        }
    }

    func makeCoordinator() -> InTimes { InTimes() }

    func makeNSView(context: Context) -> Wrapper {
        let wrapper = Wrapper()
        let viewRef = LottieAnimationView(name: "startanimation")
        StartAnimation.tint(viewRef)
        viewRef.contentMode = .scaleAspectFit
        viewRef.loopMode = .playOnce
        viewRef.backgroundBehavior = .pauseAndRestore
        viewRef.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(viewRef)
        NSLayoutConstraint.activate([
            viewRef.topAnchor.constraint(equalTo: wrapper.topAnchor),
            viewRef.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            viewRef.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            viewRef.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])

        let inTimes = context.coordinator
        let proceed = { DispatchQueue.main.asyncAfter(deadline: .now() + postRun) {
            inTimes.invoke(done)
        } }

        guard viewRef.animation != nil else {
            inTimes.invoke(done)
            return wrapper
        }
        // As on iOS: with Reduce Motion, the still frame right away.
        if Theme.motionReduced {
            viewRef.currentProgress = 1
            proceed()
            return wrapper
        }
        viewRef.play { _ in proceed() }
        DispatchQueue.main.asyncAfter(deadline: .now() + latestBy) {
            inTimes.invoke(done)
        }
        return wrapper
    }

    func updateNSView(_ viewRef: Wrapper, context: Context) {}
}
#endif

extension StartAnimation {
    /// **The play mark in the look's color**, set before the first frame, so the launch
    /// never shows turquoise and then switches. The look is read from what is stored:
    /// `SupportModel` is touched first, because a supporter's look counts only once it
    /// knows. The system launch screen before this stays neutral; it cannot know the look.
    @MainActor
    static func tint(_ view: LottieAnimationView) {
        _ = SupportModel.shared
        let palette = LookStore.shared.palette
        guard palette.look != .original else { return }
        let color = palette.markColor
        view.setValueProvider(ColorValueProvider(LottieColor(r: color.red, g: color.green, b: color.blue, a: 1)),
                              keypath: AnimationKeypath(keypath: "swiftly-wortmarke Konturen 2.Gruppe 1.Füllen 1.Color"))
    }
}

/// The launch curtain: solid base color with the animation on top. When it
/// finishes, the app fades in underneath.
struct StartCurtain: View {
    let done: () -> Void

    private var border: CGFloat {
        #if os(tvOS)
        900
        #elseif os(macOS)
        // The window is smaller than a TV and larger than a phone; 520 sits between
        // the two.
        520
        #else
        440
        #endif
    }

    var body: some View {
        // The stack itself must ignore the safe area, not just the color in it;
        // otherwise its center sits 12 points too low, because 59 points are reserved
        // at the top and only 34 at the bottom.
        ZStack {
            Theme.reason
            StartAnimation(done: done)
                // The source is square and the wordmark sits centered in it, filling only the
                // middle strip, so the square must be much larger than the mark should appear.
                //
                // On TV correspondingly more: 440 points is a postage stamp at 1920 x 1080.
                .frame(width: border, height: border)
                // **The curtain also says who is starting.** The animation is an image with
                // text and carried neither a label nor `accessibilityHidden`: someone who
                // cannot see it sat for two to three and a half seconds in front of a silent
                // surface and did not learn that the app is starting. The wrapper and the
                // Lottie view bring no element of their own for VoiceOver to land on; so first
                // `accessibilityElement`, then the same name that `Wordmark` and `Emblem` in
                // `Marks.swift` already carry.
                .accessibilityElement()
                .accessibilityLabel(Text("Swiftly"))
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }
}
