import SwiftUI

/// The app's icons. On iPhone, iPad and Mac an SF Symbol name resolves to our own
/// symbol (Phosphor, plus a few drawn in the same stroke) wherever the design kit
/// maps it; unmapped names and the other platforms keep the SF Symbol. Our symbols
/// are custom symbols, so `.font`, `.imageScale` and colour work as before.
enum AppIcon {
    static func asset(for systemName: String, size: CGFloat? = nil) -> String? {
        #if os(iOS) || os(macOS)
        guard let base = IconMap.assets[systemName] else { return nil }
        guard let size, IconMap.outlined.contains(base) else { return base }
        return base + suffix(for: size)
                #elseif os(tvOS)
        // The TV draws everything at double the iPhone size, so the stroke is picked at half.
        guard let base = IconMap.assets[systemName] else { return nil }
        guard let size, IconMap.outlined.contains(base) else { return base }
        return base + suffix(for: size / 2)
        #else
        nil
        #endif
    }

    /// **The same stroke at every size.** A symbol's stroke grows with its point size, so the
    /// 15 pt plus on "Anfragen" read thinner than the 20 pt row icons. Each outline icon comes in
    /// strokes 16, 24, 28 and 32 (256 grid); this picks the one closest to 24 at 20 pt.
    static func suffix(for size: CGFloat) -> String {
        let wanted = 24 * 20 / max(size, 1)
        let strokes: [(CGFloat, String)] = [(16, ".light"), (24, ""), (28, ".w28"), (32, ".w32")]
        return strokes.min { abs($0.0 - wanted) < abs($1.0 - wanted) }!.1
    }
}

extension Image {
    /// Use instead of `Image(systemName:)`. Pass the point size the icon is drawn at, so its
    /// stroke matches the other icons.
    init(icon systemName: String, size: CGFloat? = nil) {
        if let asset = AppIcon.asset(for: systemName, size: size) {
            self.init(asset)
        } else {
            self.init(systemName: systemName)
        }
    }
}

extension Label where Title == Text, Icon == Image {
    /// Use instead of `Label(_:systemImage:)`.
    init(_ titleKey: LocalizedStringKey, icon systemName: String) {
        self.init { Text(titleKey) } icon: { Image(icon: systemName) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, icon systemName: String) {
        self.init { Text(title) } icon: { Image(icon: systemName) }
    }
}
