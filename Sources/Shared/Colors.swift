import JellyfinKit
import SwiftUI

/// The colours - the only part of the appearance both platforms share
/// verbatim.
///
/// Metrics and font sizes are deliberately **not** here: iPhone and Apple TV
/// have nothing in common as far as spacing goes. A poster measures 112 x 168
/// on iPhone and 208 x 312 on TV, and a line readable at arm's length at 15 pt
/// needs 29 from over three metres. So each platform extends `Theme` with its
/// own values - `Sources/iOS/Style.swift` and `Sources/tvOS/Style.swift`.
///
/// Colours, by contrast, do not care about distance. They live here once so
/// they cannot drift apart.
enum Theme {

    // MARK: The three depths
    //
    // **Measured from Plex, not chosen.** The values were counted pixel by pixel
    // from its screenshots, not imitated:
    //
    // Home, background        #101010   (34,567 hits)
    // Library pills           #1C1C1C
    // Settings, background    #101010   (54,643 hits)
    // Settings rows           #1E1E1F
    //
    // Two things in there you do not make up.
    //
    // **First: one background, the same everywhere.** Plex uses #101010 on the home
    // page *and* in settings. The `gruppengrund` once added for card pages thus
    // goes away - it solved a problem only pure black has. #101010 sits at OKLCH
    // L 0.1730, and the step to the card is 0.0534 instead of the whole 0.2443.
    //
    // **Second: truly neutral.** C = 0.000, R = G = B. It first had a hue of
    // 285.9 degrees (read reddish), then the accent's hue (read greenish), then
    // Apple's blue tint. Plex carries none - the right answer for a player whose
    // surfaces are large and whose content is colourful.
    //
    // Pure black stays where it belongs: behind the picture in the player.
    static let reason   = Color(red: 0.063, green: 0.063, blue: 0.063)   // #101010
    /// **Every surface you can touch** - settings card, sheet, the button under
    /// the play button, season button, input field.
    ///
    /// They **looked** identical and were not: buttons and season button used
    /// `erhoeht`, cards `area` - two tones with a gap just under the perception
    /// threshold. That is the worst kind of difference: it costs a decision per call
    /// site and pays nothing back. Now they all use this one.
    /// **Lighter than Plex's own card tone, and for a reason.**
    ///
    /// Plex measured #1C1C1C. There it sits on large, calm blocks - here the same
    /// tone carries the **buttons** under the play button, which are small and sit
    /// next to a filled primary button. A small object needs more distance from the
    /// background than a large one to read as an object.
    ///
    /// #262626 nearly doubles the step to the background (0.0956 instead of 0.0534)
    /// and is also the upper limit: one step higher and `schriftSehrLeise` drops
    /// below 4.5 on it.
    static let area = Color(red: 0.149, green: 0.149, blue: 0.149)   // #262626
    /// **The background of a group on a settings page.**
    ///
    /// `area` carries buttons - small objects that must stand out from the
    /// background to read as objects. A settings card is the opposite: a large,
    /// calm block, and the same tone looks much lighter on it because the surface
    /// is large.
    ///
    /// The step to the background is thus 0.062 instead of 0.096 - about two thirds.
    /// The rows inside stay readable: `schriftSehrLeise` has 5.78.
    static let groupsArea = Color(red: 0.118, green: 0.118, blue: 0.118)  // #1E1E1E

    /// **The eight tones of the profile marks.**
    ///
    /// They are the one place where the app carries more than one colour, for a
    /// reason: a profile mark stands for a person. Grey looked like a list that
    /// had not finished loading.
    ///
    /// Eight hues 45 degrees apart, the first being the accent's. All with **the
    /// same lightness and saturation** so none is louder than another - OKLCH
    /// L 0.52 / C 0.105 at the top, L 0.36 / C 0.085 at the bottom. White on them
    /// has between 5.13 and 5.84.
    ///
    /// They do not count as semantic colours: they say nothing about a state, they
    /// only tell people apart.
    static let profileAudio: [(top: Color, bottom: Color)] = [
        (Color(red: 0.000, green: 0.478, blue: 0.498), Color(red: 0.000, green: 0.290, blue: 0.306)),
        (Color(red: 0.157, green: 0.431, blue: 0.631), Color(red: 0.020, green: 0.255, blue: 0.400)),
        (Color(red: 0.404, green: 0.369, blue: 0.631), Color(red: 0.235, green: 0.204, blue: 0.404)),
        (Color(red: 0.553, green: 0.314, blue: 0.510), Color(red: 0.341, green: 0.165, blue: 0.314)),
        (Color(red: 0.612, green: 0.302, blue: 0.318), Color(red: 0.384, green: 0.157, blue: 0.169)),
        (Color(red: 0.573, green: 0.353, blue: 0.106), Color(red: 0.357, green: 0.192, blue: 0.000)),
        (Color(red: 0.431, green: 0.427, blue: 0.078), Color(red: 0.255, green: 0.251, blue: 0.000)),
        (Color(red: 0.180, green: 0.478, blue: 0.298), Color(red: 0.039, green: 0.290, blue: 0.153)),
    ]
    /// **What lies on a `area`** - a chip in a card, a selected filter chip,
    /// the press on a row. Not what lies on the page: that is `area`.
    static let raised = Color(red: 0.188, green: 0.188, blue: 0.188)   // #303030

    /// **Full values, no opacity.** Opacity changes the effect as soon as
    /// something else is underneath - over a poster "quiet" became "unreadable".
    ///
    /// Computed on `reason`: 19.03 / 11.85 / 6.60. On `area` 15.13 / 9.42 / 5.25,
    /// on `erhoeht` 13.58 / 8.22 / 4.58.
    ///
    /// **The quietest level is Apple's `systemGray`, unchanged.** Exactly that tone
    /// is in the images under "Your library is empty" and next to "Film - Action -
    /// 2025". That it is 4.27 on `erhoeht`, just under 4.5: Apple's own
    /// `secondaryLabel` is 4.22 there, so Apple ships this pairing itself. On
    /// `reason` and `area`, where it nearly always sits, it has 6.44 and 5.22.
    ///
    /// `schriftLeise` is the middle level Apple does not have: it only has `label`
    /// and `secondaryLabel` plus a placeholder tone. Our views have three ranks, so
    /// one in between is needed - white at 80 percent, computed fixed.
    static let font          = Color(red: 1.000, green: 1.000, blue: 1.000)  // #FFFFFF
    static let fontQuiet     = Color(red: 0.800, green: 0.800, blue: 0.800)  // #CCCCCC

    /// **0.48 and not 0.38 - at 0.38 it was too faint to read.**
    ///
    /// Computed, not estimated. White at 0.38 opacity gives contrasts of 3.52
    /// (`reason`), 3.58 (`area`) and 3.54 (`erhoeht`) against this app's three
    /// backgrounds. Text under 18 pt requires **4.5** - and this tone carries exactly
    /// such text: secondary lines, hints, empty states, across all six versions at
    /// 12 to 13 pt.
    ///
    /// 0.46 would have sufficed (4.67 / 4.65 / 4.54), but on `erhoeht` is only four
    /// hundredths above the threshold - one decimal of rounding and we would be
    /// below again.
    ///
    /// As a full value it has 6.60 / 5.25 / 4.58 and stays clearly behind
    /// `schriftLeise` (11.85): the gradation stays visible. On `erhoeht` 4.58 is the
    /// tightest case in the app and above 4.5. It moved with the surfaces: on the
    /// old #8E8E8E it would have dropped to 4.00 there. Whoever raises the surfaces
    /// raises the quiet text with them.
    ///
    /// The tone also carries icons and circles that would not need 4.5. They get a
    /// touch lighter - no loss, and sorting eighty-eight call sites individually to
    /// keep an icon its grey would be the wrong order.
    /// Neutral like the rest of the ladder - Apple's #8E8E93 carries a hint of
    /// blue, which stands out next to a background without any chroma.
    static let fontVeryQuiet = Color(red: 0.596, green: 0.596, blue: 0.596)  // #989898
    /// **Back to 7 and 12 percent.**
    ///
    /// They were briefly 20 and 22, extrapolated from Apple's `separator`
    /// (#545458 at 60 percent, over black #323235 - equal to white at about 20).
    /// The math is right, the transfer is not: Apple's separator is a **fixed colour
    /// with alpha**, ours a **white opacity**. Over black both land the same; over
    /// the card (`area`) Apple's lands at #3E3E41 and ours at #49494B. In settings
    /// nearly all lines lie on a card, and that is exactly where it showed: the
    /// lines looked far too bright and contrasts no longer matched.
    ///
    /// At 12 percent over the card #373739 results, almost exactly Apple's value.
    /// The 7 for `linie` stay where they were.
    ///
    /// As opacity and not a fixed value, because both also lie over posters - there
    /// the line should go with the picture, not stand on it as a grey stroke.
    static let line            = Color.white.opacity(0.07)
    static let margin             = Color.white.opacity(0.12)

    /// **The surface of a selected or playing row: eight percent.**
    ///
    /// Selected means white and weight, not colour - and where a whole row is meant,
    /// a quiet surface says the same without using up the accent. It used to be a
    /// raw value in three places.
    static let selected         = Color.white.opacity(0.08)

    /// **The surface of a pressed secondary button.**
    ///
    /// This was once `erhoeht.opacity(1.6)` - opacity above 1 clamps to 1.0, and
    /// `erhoeht` is opaque: the press was invisible. This is the same colour, one
    /// step lighter, as its own value so nobody tries it via opacity again.
    /// **Only full text on it.** Computed: `font` 11.38:1, `schriftSehrLeise` only
    /// **3.94:1** - too little for text (4.5 is the limit), just above 3 for a
    /// control glyph. It used to say 2.74; that was too pessimistic and so useless as
    /// a warning, because the real number is closer. Today the case does not occur:
    /// quiet text is carried only by the **disabled** secondary button, and a
    /// disabled button gets no `isPressed`. Whoever later puts quiet text in an
    /// operable state here should have read the number.
    static let pressedArea = Color(red: 0.227, green: 0.227, blue: 0.227)  // #3A3A3A

    /// Carries only progress, selection and the Direct Play proof - never
    /// surfaces or buttons. Deliberately neither Plex orange nor Netflix red.
    ///
    /// On tvOS it also carries the focus ring - that is the same rule, not a
    /// loosening of it: the ring shows a selection.
    static let accent  = Color(red: 0.314, green: 0.835, blue: 0.855)   // #50D5DA

    /// **The accent, lightened - the focused switch on TV.** Nowhere else: iPhone
    /// has no focus, and the pressed state goes through surface and scale, not a
    /// second accent colour. (`akzentTief` sat next to it as a counterpart and
    /// was never used - removed.)
    static let accentLight = Color(red: 0.478, green: 0.902, blue: 0.918)  // #7AE6EA
    /// The surface under accent text - badges carry 15 percent, this value is
    /// the same tone already computed.
    static let accentQuiet = Color(red: 0.067, green: 0.204, blue: 0.208)  // #113435
    /// Text on an accent surface.
    static let onAccent = Color(red: 0.024, green: 0.071, blue: 0.071)   // #061212

    /// **Removed: `kuehl` and `scheinMitte`.**
    ///
    /// `kuehl` (#7E9BFF) carried what happens on another device - the "continue
    /// watching here" offer, the remote control - and `scheinMitte` (#6EB4E1) was the
    /// anchor that led the home page's glow from turquoise to blue.
    ///
    /// Both are gone because the rule is clearer than the distinction was:
    /// **the accent carries state, and "playing elsewhere" is one.** The difference
    /// is made by the glyph - a device icon says "elsewhere" more clearly than a
    /// second blue. The glow now runs in one tone from 0.22 to 0.14; its depth
    /// comes from quantity, not a colour change.

    static let warning = Color(red: 0.910, green: 0.514, blue: 0.227)   // #E8833A

    /// **Something went wrong - and that is not the same as "waiting".**
    ///
    /// The token was in the design spec and missing in code: sign-in errors,
    /// failed downloads and the conversion warning all used `warning`. Two meanings
    /// in one colour is exactly the confusion that five semantic colours are meant
    /// to avoid. Computed on `reason`: 6.30:1.
    static let error  = Color(red: 0.937, green: 0.396, blue: 0.404)   // #EF6567
}

// MARK: - Colour from the image

/// **How strongly a page takes the colour of its header image** - TV and
/// iPhone with the same numbers (`ImageTone.farbe(_:at:)`). Only the hue comes
/// from the image; the app sets saturation and lightness so every page stays
/// equally calm however colourful the image.
///
/// `naehe` is 1 at the backdrop (top right) and falls toward the bottom left.
/// The colour stays dark enough for white text to work everywhere: at the
/// lightest point text reaches on iPhone (bottom edge of the header image,
/// `naehe` <= 0.8), luminance is at most 0.024 - `schriftSehrLeise` still has
/// 5 : 1 there.
extension Theme {
    /// Saturation away from the backdrop.
    static let avSaturation = AvComputation.saturation
    /// Saturation added at the backdrop.
    static let avSaturationNear = AvComputation.saturationNear
    /// Lightness away from the backdrop - just above `reason`.
    static let avBrightness = AvComputation.brightness
    /// Lightness added at the backdrop.
    static let avBrightnessNear = AvComputation.brightnessNear
    /// How fast lightness falls with distance (exponent).
    static let avDrop = AvComputation.drop
    /// How far the secondary tones may deviate from the main tone (fraction).
    static let avSpanRange = AvComputation.spanRange
}

// MARK: - Surfaces over image colour

/// **Translucent instead of `area` where image colour lies behind** - the
/// same opacity as in Swiftly Music (`Seitenfarbe.ongoing`). A fixed grey
/// looks like a foreign block on a coloured page; white with low opacity picks
/// up the colour beneath. Only where colour really lies (movie and series
/// page); otherwise `area` stays. No glass, no blur.
extension Theme {
    /// Button or highlighted row over image colour: white 8%.
    static let surfaceTranslucent = Color.white.opacity(0.08)
    // Active carries no surface of its own: the state is in the glyph
    // (accent), the surface stays like its neighbours (a full turquoise surface
    // did not fit the row).
}

/// **Does image colour lie behind?** (`experiment-glas` attempt) Then buttons
/// carry translucent surfaces instead of `area` - see
/// `Theme.flaecheDurchsichtig`. Set by the movie and series page - here and
/// not in `Style.swift`, so the Mac reads the same keys.
private struct ImageColorKey: EnvironmentKey {
    static let defaultValue = false
}

/// The header image whose colour lies behind - for panels that open over
/// content and therefore must be opaque (``Aufklappliste``).
private struct ImageColorSourceKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

extension EnvironmentValues {
    var onImageTint: Bool {
        get { self[ImageColorKey.self] }
        set { self[ImageColorKey.self] = newValue }
    }
    var imageColorSource: URL? {
        get { self[ImageColorSourceKey.self] }
        set { self[ImageColorSourceKey.self] = newValue }
    }
}

extension Theme {
    /// The surface of a button - fixed on `reason`, translucent over image
    /// colour. **Active does not change it**: the glyph carries the state.
    static func buttonArea(onImage: Bool) -> Color {
        onImage ? surfaceTranslucent : area
    }
}
