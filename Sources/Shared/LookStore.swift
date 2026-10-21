import Foundation
import JellyfinKit
import Observation
import SwiftUI
import Synchronization
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// **The look the app draws with: the stored choice, the one being tried on, or for
/// someone who does not support: the original.**
///
/// `Theme.accent` and its tones read from here, so the 160 places that use the accent
/// follow a look without being touched: SwiftUI notes the read while it builds a body and
/// draws again when the look changes.
///
/// **Observable by hand, not with the macro.** `Theme` is read from everywhere, also from
/// code that is not on the main actor (image tone, UIKit layers). A main-actor store would
/// make every one of those reads a compile error. So the state sits behind a lock and the
/// observation calls are made here directly; reads are safe from any thread, and views
/// still update.
///
/// Included in all three Apple targets, like `Colors.swift`.
final class LookStore: Observable, Sendable {
    static let shared = LookStore()

    /// The rules of what shows and what is stored live in the package (`LookTryOn`, with
    /// its tests); this class only keeps the value, stores it and tells SwiftUI.
    private let state: Mutex<LookTryOn>
    private let registrar = ObservationRegistrar()

    private init() {
        let defaults = UserDefaults.standard
        let stored = defaults.data(forKey: LookStorageKey.selection)
        let owned = (defaults.array(forKey: LookStorageKey.owned) as? [String]) ?? []
        state = Mutex(LookTryOn(saved: LookSelection.decoded(from: stored), owned: Set(owned)))
        effects = Mutex(defaults.object(forKey: LookStorageKey.effects) as? Bool ?? true)
    }

    /// "Bats and details", on by default.
    private let effects: Mutex<Bool>

    // MARK: Reading

    /// What the app shows right now.
    var selection: LookSelection {
        registrar.access(self, keyPath: \.selection)
        return state.withLock { $0.shown }
    }

    /// What is stored, whatever is being tried on.
    var saved: LookSelection {
        registrar.access(self, keyPath: \.selection)
        return state.withLock { $0.saved }
    }

    var isPreviewing: Bool {
        registrar.access(self, keyPath: \.selection)
        return state.withLock { $0.isPreviewing }
    }

    var palette: LookPalette { selection.palette }

    /// The gifts picked up.
    var owned: Set<String> {
        registrar.access(self, keyPath: \.selection)
        return state.withLock { $0.owned }
    }

    var ownsLook: Bool { !owned.isEmpty }

    var isSupporter: Bool {
        registrar.access(self, keyPath: \.selection)
        return state.withLock { $0.isSupporter }
    }

    /// "Bats and details" of a seasonal look.
    var effectsOn: Bool {
        get {
            registrar.access(self, keyPath: \.effectsOn)
            return effects.withLock { $0 }
        }
        set {
            registrar.withMutation(of: self, keyPath: \.effectsOn) {
                effects.withLock { $0 = newValue }
            }
            UserDefaults.standard.set(newValue, forKey: LookStorageKey.effects)
        }
    }

    /// The looks this person can pick from right now: the original, gifts picked up or
    /// in their window (supporter looks are not part of this list).
    func freeLooks(now: Date = LookClock.now) -> [Look] {
        let owned = owned
        return Look.free.filter { LookGift.isAvailable($0, owned: owned, now: now) }
    }

    /// **Every look the picker shows**, the locked ones too: the original, gifts in their
    /// window or picked up, and the supporter looks.
    func pickerLooks(now: Date = LookClock.now) -> [Look] {
        let owned = owned
        return Look.all.filter { !$0.isGift || LookGift.isAvailable($0, owned: owned, now: now) }
    }

    /// Whether this person may wear the selection (otherwise it can only be previewed).
    func mayWear(_ selection: LookSelection) -> Bool {
        registrar.access(self, keyPath: \.selection)
        return state.withLock { $0.mayWear(selection) }
    }

    // MARK: Changing

    /// From the support state: only supporters wear a stored look.
    func setSupporter(_ supporter: Bool) {
        change { $0.setSupporter(supporter) }
    }

    /// Opens a preview; see `LookTryOn.begin`.
    func beginPreview() { change { $0.begin() } }

    /// One change inside the preview. Nothing is stored.
    func tryOn(_ selection: LookSelection) { change { $0.tryOn(selection) } }

    /// Closes the preview without storing anything.
    func endPreview() { change { $0.end() } }

    /// "Keep": stored for a supporter, a wish for everyone else.
    func keep() -> LookTryOn.KeepResult { change { $0.keep() } }

    func supportSheetClosed() { change { $0.supportSheetClosed() } }

    /// A purchase went through; returns the look stored with it.
    func purchaseCompleted() -> LookSelection? { change { $0.purchaseCompleted() } }

    /// A supporter picks a look outside the preview (Settings → Appearance).
    @discardableResult
    func choose(_ selection: LookSelection) -> Bool { change { $0.choose(selection) } }

    /// "Grab it": the gift is picked up for good and worn right away.
    @discardableResult
    func claim(_ look: Look) -> LookSelection? { change { $0.claim(look) } }

    /// Back to a fresh install.
    func reset() {
        change { $0.reset() }
        UserDefaults.standard.removeObject(forKey: LookStorageKey.giftOffered)
        effectsOn = true
    }

    private func change<Result>(_ body: (inout LookTryOn) -> Result) -> Result {
        let (result, saved, owned) = registrar.withMutation(of: self, keyPath: \.selection) {
            state.withLock { value in
                let before = value.saved
                let ownedBefore = value.owned
                let result = body(&value)
                return (result, value.saved == before ? nil : value.saved,
                        value.owned == ownedBefore ? nil : value.owned)
            }
        }
        if let saved {
            UserDefaults.standard.set(saved.encoded, forKey: LookStorageKey.selection)
        }
        if let owned {
            UserDefaults.standard.set(owned.sorted(), forKey: LookStorageKey.owned)
        }
        return result
    }
}

// MARK: - Colors

extension LookColor {
    var color: Color { Color(red: red, green: green, blue: blue) }
}

extension LookAccent {
    /// The original tones come from `Theme`'s own constants, so a non-supporter's app is
    /// the same to the last bit, not just to the eye.
    var mainColor: Color { self == .teal ? Theme.originalAccent : main.color }
    var lightColor: Color { self == .teal ? Theme.originalAccentLight : light.color }
    var quietColor: Color { self == .teal ? Theme.originalAccentQuiet : quiet.color }
    var onColor: Color { self == .teal ? Theme.originalOnAccent : on.color }
    /// The app's warning unless this accent brings its own (an orange accent).
    var warningColor: Color { warning?.color ?? Theme.originalWarning }
}

extension LookPalette {
    /// The play mark of the wordmark. The original is the flat `Mark.markAccent`.
    var logoStyle: AnyShapeStyle {
        let colors = logoGradient.map(\.color)
        guard colors.count > 1 else {
            return look == .original ? AnyShapeStyle(Mark.markAccent) : AnyShapeStyle(colors.first ?? Mark.markAccent)
        }
        return AnyShapeStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

extension Look {
    /// The name in the app's language. A `switch` and not the stored key, so the catalog
    /// check finds every name.
    var name: String {
        switch id {
        case Look.neonNight.id: String(localized: "Neon-Nacht")
        case Look.halloween.id: String(localized: "Halloween")
        case Look.sunset.id: String(localized: "Sunset")
        case Look.aurora.id: String(localized: "Aurora")
        case Look.ice.id: String(localized: "Eis")
        case Look.ember.id: String(localized: "Glut")
        case Look.gold.id: String(localized: "Gold")
        case Look.emerald.id: String(localized: "Smaragd")
        default: String(localized: "Original")
        }
    }

    /// The tile of the look in the pickers. Alternate app icons cannot be loaded as images,
    /// hence a copy of each as an image set.
    var tileName: String {
        switch id {
        case Look.neonNight.id: "LookIcon-NeonNight"
        case Look.halloween.id: "LookIcon-Halloween"
        case Look.sunset.id: "LookIcon-Sunset"
        case Look.aurora.id: "LookIcon-Aurora"
        case Look.ice.id: "LookIcon-Ice"
        case Look.ember.id: "LookIcon-Ember"
        case Look.gold.id: "LookIcon-Gold"
        case Look.emerald.id: "LookIcon-Emerald"
        default: "LookIcon-Original"
        }
    }
}

// MARK: - Glow

/// **The look's glow: one tone at the top of the screen**, the same on every main page and
/// the profile.
///
/// A plain elliptical gradient, drawn once: no real-time blur, no mask, no material. At
/// "soft" it starts at 20 percent at the top edge of the screen and is gone at about a
/// quarter of the screen height. Nothing at all when the glow is off, which is the
/// original look's default: someone who never picked a look sees today's page.
///
/// **Anchored to the screen, not clipped.** It reads where its own frame sits on screen and
/// moves up by that much, so it always starts behind the status bar and the Dynamic Island,
/// also when the view it hangs on starts lower (the results under the search field). It
/// draws outside its frame on purpose; there is no edge where a frame ends.
struct LookGlowLayer: View {
    /// How far the page has scrolled; the glow goes up with the content.
    var scrolled: CGFloat = 0
    /// The strength; `nil` is the active look's own.
    var glow: LookGlow?
    /// `false`: measured from this view's own top instead of the screen's (the support
    /// sheet, which moves as a whole).
    var anchoredToScreen = true

    var body: some View {
        let palette = LookStore.shared.palette
        let strength = (glow ?? palette.glow).opacity
        GeometryReader { geometry in
            let screenTop = anchoredToScreen ? geometry.frame(in: .global).minY : 0
            let width = geometry.size.width
            // A quarter of a phone's height: 211 pt on a 844 pt screen.
            #if os(tvOS)
            // A quarter of the 1080 pt picture.
            let reach: CGFloat = 270
            #else
            let reach = max(width, 390) * 2.16 * 0.25
            #endif
            let tone = palette.glowColor.color
            ZStack(alignment: .top) {
                // The faint second tone (about a third), reaching a little further to one side.
                if let tint = palette.glowTint?.color {
                    EllipticalGradient(stops: [
                        .init(color: tint.opacity(strength * 0.36), location: 0),
                        .init(color: tint.opacity(strength * 0.16), location: 0.5),
                        .init(color: tint.opacity(0), location: 1),
                    ], center: .topTrailing, startRadiusFraction: 0, endRadiusFraction: 0.6)
                }
            EllipticalGradient(stops: [
                .init(color: tone.opacity(strength), location: 0),
                .init(color: tone.opacity(strength * 0.62), location: 0.35),
                .init(color: tone.opacity(strength * 0.22), location: 0.7),
                .init(color: tone.opacity(0), location: 1),
            ], center: .top, startRadiusFraction: 0, endRadiusFraction: 0.5)
            }
            // The ellipse ends at half the frame: a frame twice the reach ends it at the
            // reach. Wider than the screen, so the corners keep a little of it.
            .frame(width: width * 1.5, height: reach * 2)
            .frame(width: width, alignment: .center)
            .offset(y: -screenTop - scrolled)
            .opacity(strength > 0 ? 1 : 0)
        }
        .frame(height: 0, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// **The look's glow behind a scroll view, going up with its content.** One modifier
    /// for every main page and the profile, so all of them glow the same way. Hang it on
    /// the `ScrollView`; nothing changes for the original look.
    func lookGlow() -> some View {
        modifier(LookGlowScroll())
    }
}

private struct LookGlowScroll: ViewModifier {
    /// Only the first 300 pt count: by then the glow is gone, and further scrolling does
    /// not touch this view again.
    @State private var scrolled: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                min(max(geometry.contentOffset.y + geometry.contentInsets.top, 0), 300).rounded()
            } action: { _, new in
                if new != scrolled { scrolled = new }
            }
            .background(alignment: .top) {
                LookGlowLayer(scrolled: scrolled)
            }
    }
}

// MARK: - App icon

/// **The app icon of a look.** iPhone and iPad switch the alternate icon (the system asks
/// nothing for it, but shows a short notice); the Mac changes the Dock icon while the app
/// runs, since it has no alternate icons. Apple TV keeps its icon.
enum LookIcon {
    /// Only the looks' own icons are switched here: a supporter icon picked in Settings
    /// stays when a look without an icon of its own is chosen.
    @MainActor static func apply(_ name: String?) async {
        #if os(iOS)
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else { return }
        let lookIcons = Set(Look.all.compactMap(\.iconName))
        if name == nil, !lookIcons.contains(app.alternateIconName ?? "") { return }
        guard app.alternateIconName != name else { return }
        do {
            try await app.setAlternateIconName(name)
        } catch {
            AppLog.writeOut("[Looks] Icon nicht gewechselt: \(error)")
        }
        #elseif os(macOS)
        // `nil` brings back the bundle's icon, or the supporter icon picked in Settings
        // (like on iPhone, where a look without an icon leaves that one alone).
        NSApp.applicationIconImage = name.flatMap { NSImage(named: $0.replacingOccurrences(of: "AppIcon-", with: "DockIcon-")) }
        if name == nil {
            SupporterIcon.restoreOnLaunch(isSupporter: SupportModel.shared.isSupporter)
        }
        #endif
    }

    /// At launch: the Dock icon is not stored by the system, and on iPhone a gift's icon
    /// whose look is no longer worn goes back.
    @MainActor static func restore() async {
        await apply(LookStore.shared.palette.iconName)
    }
}

// MARK: - Clock

/// **The date the seasonal looks ask.** The device clock; for a free gift that is enough.
///
/// Debug builds take a stand-in day from the launch arguments, to see the season outside
/// it, and can start from before the gift:
///
///     xcrun simctl launch <device> de.paulherter.swiftly -lookDate 2026-10-26 -lookReset
enum LookClock {
    static var now: Date {
        #if DEBUG
        if let stand = standIn { return stand }
        if seasonOverride {
            return Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12)) ?? .now
        }
        #endif
        return .now
    }

    #if DEBUG
    /// Settings → Swiftly → Preview: "Halloween season now", for the device.
    static var seasonOverride: Bool {
        get { UserDefaults.standard.bool(forKey: "look.debug.season") }
        set { UserDefaults.standard.set(newValue, forKey: "look.debug.season") }
    }

    private static let standIn: Date? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-lookDate"), index + 1 < arguments.count else { return nil }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = .current
        guard let day = parser.date(from: arguments[index + 1]) else { return nil }
        // Noon of that day, at the current time would cross midnight in some zones.
        return Calendar.current.date(byAdding: .hour, value: 12, to: day)
    }()
    #endif
}

/// **The light at the top of a card**: one tone, and under it, only if there is one, a faint
/// second tone (about a third of the strength) that reaches a little further and sits to
/// one side, so the glow shifts softly from one color to the other like the app icon.
struct CardLight: View {
    let tone: Color
    var tint: Color?

    var body: some View {
        ZStack(alignment: .top) {
            if let tint {
                EllipticalGradient(stops: [
                    .init(color: tint.opacity(0.11), location: 0),
                    .init(color: tint.opacity(0.05), location: 0.5),
                    .init(color: tint.opacity(0), location: 1),
                ], center: .topTrailing, startRadiusFraction: 0, endRadiusFraction: 0.6)
            }
            EllipticalGradient(stops: [
                .init(color: tone.opacity(0.30), location: 0),
                .init(color: tone.opacity(0.12), location: 0.45),
                .init(color: tone.opacity(0.03), location: 0.75),
                .init(color: tone.opacity(0), location: 1),
            ], center: .top, startRadiusFraction: 0, endRadiusFraction: 0.5)
        }
        .frame(height: 260)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
