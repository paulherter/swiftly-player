import JellyfinKit
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// **Looks and the "Help Swiftly grow" sheet: the flow around a purchase.**
//
// The sheet, the looks panel and the thank-you page hang together here: opening the looks
// from the sheet, keeping a look (which asks for support first), and what happens once a
// purchase has gone through. The purchase itself is `SupportModel.buy`.
//
// Included in all three Apple targets.

/// What can be chosen on the sheet.
enum SupportChoice: Hashable {
    case monthly
    case lifetime
    case tip(SupportTip)

    var plan: SupportPlan {
        switch self {
        case .monthly: .monthly
        case .lifetime: .lifetime
        case .tip: .tip
        }
    }

    var productID: String {
        switch self {
        case .monthly: SupportProductID.monthly
        case .lifetime: SupportProductID.lifetime
        case let .tip(tip): tip.productID
        }
    }
}

/// Links the sheet shows, and the key of the profile's one-time pop-up.
enum SupportLinks {
    /// Once per install: the pop-up on the first visit to the profile.
    static let profileIntroKey = "support.preview.profileIntroShown"

    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://swiftlyplayer.com/privacy.html")!
}

/// **Where the looks and support screens stand, for the whole app.**
///
/// The looks preview lies over everything (the real home page, full screen); the support
/// sheet is a system sheet and so always above it. When the sheet opens the preview, it
/// steps aside first and comes back on "Keep".
@MainActor
@Observable
final class SupportFlow {
    static let shared = SupportFlow()

    /// The look the last purchase switched on; the thank-you page names it.
    private(set) var keptWithPurchase: Look?

    private init() {}

    /// What is being tried on (the preview's own state lives in `LookStore`).
    var trying: LookSelection { LookStore.shared.selection }

    /// **A look change is a short cross-fade of color and glow**, nothing that moves.
    static var lookChange: Animation { Motion.change }

    /// A purchase from inside the preview: the preview stays under the thank-you page and
    /// closes with the sheet.
    @ObservationIgnored private var closeWithSheet = false

    /// **Opens the preview over the real home page.** The page the person came from (the
    /// profile, Settings) slides away to the right, and the panel comes up from below once
    /// it has: one movement after the other. The preview starts on the active look. From
    /// inside the support sheet, the sheet goes first: two presentations at once would
    /// collide.
    func openLooks() {
        let supportWasOpen = SupportModel.shared.presented
        if supportWasOpen { SupportModel.shared.presented = false }
        GiftFlow.shared.goHome()
        Task {
            let wait = Theme.motionReduced ? 0.0 : (supportWasOpen ? 0.45 : Motion.pageBeforeSheet)
            try? await Task.sleep(for: .seconds(wait))
            GiftFlow.shared.openLooks()
        }
    }

    /// "Keep …". Supporters keep it right away; for everyone else only the support sheet
    /// opens, and the look follows the purchase.
    func keep() {
        let icon = trying.palette.iconName
        switch withAnimation(Self.lookChange, { LookStore.shared.keep() }) {
        case .kept:
            GiftFlow.shared.close()
            Task { await LookIcon.apply(icon) }
        case .needsSupport:
            SupportModel.shared.open()
        case .nothing:
            break
        }
    }

    /// From the model once a purchase went through. A look waiting for it is switched on and
    /// the preview closes behind the sheet, so the app under it already wears the look.
    func purchaseCompleted() {
        guard let kept = withAnimation(Theme.reveal, { LookStore.shared.purchaseCompleted() }) else {
            keptWithPurchase = nil
            return
        }
        keptWithPurchase = kept.look
        // The sheet sits on the preview's panel; closing the preview now would take the
        // thank-you page with it. It closes with the sheet.
        closeWithSheet = GiftFlow.shared.looksOpen
        let icon = kept.palette.iconName
        Task { await LookIcon.apply(icon) }
    }

    /// The sheet went away. A "Keep" still waiting is dropped, so a later tip from the
    /// heart does not switch a look nobody asked for.
    func sheetClosed() {
        LookStore.shared.supportSheetClosed()
        if closeWithSheet {
            closeWithSheet = false
            GiftFlow.shared.close()
        }
    }

    /// "Show me my Home": everything closes and the home page comes to the front.
    func goHome() {
        SupportModel.shared.presented = false
        GiftFlow.shared.close()
        GiftFlow.shared.goHome()
    }

    /// A supporter picks directly in Settings → Appearance. Returns false for everyone
    /// else, who gets the support sheet instead.
    @discardableResult
    func choose(_ selection: LookSelection) -> Bool {
        guard withAnimation(Self.lookChange, { LookStore.shared.choose(selection) }) else {
            SupportModel.shared.open()
            return false
        }
        let icon = selection.palette.iconName
        Task { await LookIcon.apply(icon) }
        return true
    }

    #if DEBUG
    /// Back to a fresh install, with "Reset support state".
    func reset() {
        keptWithPurchase = nil
        LookStore.shared.reset()
        GiftFlow.shared.reset()
        UserDefaults.standard.removeObject(forKey: SupportLinks.profileIntroKey)
        Task { await LookIcon.apply(nil) }
    }
    #endif
}
