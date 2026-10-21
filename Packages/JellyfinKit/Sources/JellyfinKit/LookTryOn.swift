import Foundation

/// **Which look the app wears, and what trying one on may change.** The rules as one value,
/// so they can be tested without a screen.
///
/// | | no preview | preview open |
/// |---|---|---|
/// | **not a supporter** | always the original, whatever is stored | the look tried on |
/// | **supporter** | the stored look | the look tried on |
///
/// - Trying on never stores anything. Closing the preview shows the stored look again
///   (for a non-supporter: the original).
/// - "Keep" stores the look only for a supporter. For anyone else it only remembers the
///   wish and asks for support; the look is stored when the purchase is through, and the
///   wish is forgotten when the support sheet closes without one.
/// - When the support ends, what shows is the original again; the stored choice waits.
/// - **Gifts** (`Look.isGift`) are free once picked up (`claim`): they are worn, chosen and
///   kept like a supporter's look, for everyone and for good. The original is always free.
public struct LookTryOn: Sendable, Equatable {
    /// The stored choice.
    public private(set) var saved: LookSelection
    /// The look being tried on; `nil` without a preview.
    public private(set) var preview: LookSelection?
    /// "Keep" by a non-supporter, waiting for the purchase.
    public private(set) var pendingKeep: LookSelection?
    public private(set) var isSupporter: Bool
    /// The gifts picked up, by look id.
    public private(set) var owned: Set<String>

    public init(saved: LookSelection = .original, isSupporter: Bool = false, owned: Set<String> = []) {
        self.saved = saved
        self.isSupporter = isSupporter
        self.owned = owned
    }

    /// What the app draws with now.
    public var shown: LookSelection {
        if let preview { return preview }
        return mayWear(saved) ? saved : .original
    }

    /// The original and picked-up gifts for everyone, with the home glow and the look's icon
    /// as they like (those two are open to all); a picked accent color and every other look
    /// are a supporter's.
    public func mayWear(_ selection: LookSelection) -> Bool {
        if isSupporter { return true }
        let look = selection.look
        guard look == .original || (look.isGift && owned.contains(look.id)) else { return false }
        return selection.accentID == nil
    }

    /// Picked up at least one gift: there is a look to choose besides the original.
    public var ownsLook: Bool { !owned.isEmpty }

    public var isPreviewing: Bool { preview != nil }

    /// What "Keep" does.
    public enum KeepResult: Sendable, Equatable {
        /// Stored; the preview is closed.
        case kept
        /// Nothing stored; the support sheet should open.
        case needsSupport
        /// There was no preview to keep.
        case nothing
    }

    /// Opens the preview on exactly what is shown now: the preview chooses nothing by
    /// itself.
    public mutating func begin() {
        preview = shown
        pendingKeep = nil
    }

    /// One change inside the preview. Ignored without a preview: nothing outside it may
    /// change the look by trying.
    public mutating func tryOn(_ selection: LookSelection) {
        guard preview != nil else { return }
        preview = selection
    }

    /// "End preview" or the preview going away for any other reason.
    public mutating func end() {
        preview = nil
        pendingKeep = nil
    }

    public mutating func keep() -> KeepResult {
        guard let preview else { return .nothing }
        if mayWear(preview) {
            saved = preview
            self.preview = nil
            pendingKeep = nil
            return .kept
        }
        pendingKeep = preview
        return .needsSupport
    }

    /// The support sheet closed. A completed purchase came through `purchaseCompleted`
    /// before; anything still waiting is forgotten.
    public mutating func supportSheetClosed() {
        pendingKeep = nil
    }

    /// A purchase went through. A look waiting for it is stored and the preview ends;
    /// returns that look.
    @discardableResult
    public mutating func purchaseCompleted() -> LookSelection? {
        isSupporter = true
        guard let pending = pendingKeep else { return nil }
        saved = pending
        preview = nil
        pendingKeep = nil
        return pending
    }

    /// The supporter state changed from elsewhere (restore, refund, the preview reset).
    public mutating func setSupporter(_ supporter: Bool) {
        isSupporter = supporter
        if supporter == false { pendingKeep = nil }
    }

    /// A look picked directly (Settings → Appearance, the looks sheet): any look for a
    /// supporter, the original and picked-up gifts for everyone. Ignored otherwise.
    @discardableResult
    public mutating func choose(_ selection: LookSelection) -> Bool {
        guard mayWear(selection) else { return false }
        saved = selection
        return true
    }

    /// "Grab it": the gift is picked up for good and worn right away. Anything that is not
    /// a gift is ignored. Returns the selection now stored.
    @discardableResult
    public mutating func claim(_ look: Look) -> LookSelection? {
        guard look.isGift else { return nil }
        owned.insert(look.id)
        saved = LookSelection(lookID: look.id)
        preview = nil
        pendingKeep = nil
        return saved
    }

    /// Back to a fresh install.
    public mutating func reset() {
        self = LookTryOn()
    }
}
