import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The app's typeface. Inter on iPhone, iPad and Mac, where it is bundled; the system
/// font on TV until it gets the same design.
enum AppFont {
    static let family = "Inter Variable"

    static let bundled: Bool = {
        #if os(iOS)
        UIFont.familyNames.contains(family)
        #elseif os(tvOS)
        UIFont.familyNames.contains(family)
        #elseif os(macOS)
        NSFontManager.shared.availableFontFamilies.contains(family)
        #else
        false
        #endif
    }()
}

extension Font {
    /// Use instead of `.system(size:weight:)`: same size and weight, our typeface.
    static func app(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        AppFont.bundled
            ? .custom(AppFont.family, fixedSize: size).weight(weight)
            : .system(size: size, weight: weight)
    }
}
