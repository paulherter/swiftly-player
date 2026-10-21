import Foundation

// **Looks: a thank-you for supporters, and nothing more than a few colors.**
//
// A look changes four things and only these: the accent (selection, progress, state
// symbols), a glow at the top of the home page, the play mark of the wordmark, and the
// app icon. Surfaces, text and everything in the player stay as they are. The full
// concept (seasons, effects, tinted surfaces) is in the notes; this is the part that
// ships first, and it is shaped so the rest can be added without touching it.
//
// The data lives here so every platform reads the same values. Apple turns them into
// `Color`, Android and Linux into their own color types.

/// **One sRGB color as `0xRRGGBB`.** Plain numbers, so the package needs no UI framework.
public struct LookColor: Sendable, Hashable, Codable {
    public let hex: UInt32

    public init(_ hex: UInt32) {
        self.hex = hex & 0xFF_FFFF
    }

    public var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    public var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(hex & 0xFF) / 255 }

    /// `#RRGGBB`, for logs and for platforms that take CSS colors.
    public var css: String { String(format: "#%06X", hex) }
}

/// **An accent and the three tones that go with it.**
///
/// The tones are written out, not computed: the original ones were tuned by hand and must
/// stay exactly as they are, and five accents are few enough to check each by eye.
public struct LookAccent: Sendable, Hashable, Identifiable {
    /// Stored in the selection; never rename one.
    public let id: String
    /// Selection, progress, symbols.
    public let main: LookColor
    /// The focused switch on TV.
    public let light: LookColor
    /// The surface under accent text.
    public let quiet: LookColor
    /// Text and glyphs on an accent surface.
    public let on: LookColor
    /// **The warning color under this accent**; `nil` keeps the app's `#E8833A`.
    ///
    /// Only an accent that is itself orange sets one: next to an orange accent the orange
    /// warning would read as "fine", and in the stream badge "Direct Play" (accent) and
    /// "Transcoding" (warning) would look the same.
    public let warning: LookColor?

    public init(id: String, main: LookColor, light: LookColor, quiet: LookColor, on: LookColor,
                warning: LookColor? = nil) {
        self.id = id
        self.main = main
        self.light = light
        self.quiet = quiet
        self.on = on
        self.warning = warning
    }

    /// Today's turquoise, unchanged.
    public static let teal = LookAccent(id: "teal", main: LookColor(0x50D5DA), light: LookColor(0x7AE6EA),
                                        quiet: LookColor(0x113435), on: LookColor(0x061212))
    public static let violet = LookAccent(id: "violet", main: LookColor(0xB08CFF), light: LookColor(0xC7AEFF),
                                          quiet: LookColor(0x2B2240), on: LookColor(0x0B0716))
    public static let coral = LookAccent(id: "coral", main: LookColor(0xFF8C6B), light: LookColor(0xFFAE95),
                                         quiet: LookColor(0x3F2219), on: LookColor(0x1A0905))
    public static let gold = LookAccent(id: "gold", main: LookColor(0xEEC377), light: LookColor(0xF5D8A0),
                                        quiet: LookColor(0x3A301D), on: LookColor(0x1A1205))
    public static let emerald = LookAccent(id: "emerald", main: LookColor(0x3EDCA6), light: LookColor(0x72E8C0),
                                           quiet: LookColor(0x0F3628), on: LookColor(0x03140D))

    /// **Halloween's pumpkin orange.** Its warning turns amber: the app's warning
    /// (`#E8833A`) has nearly the same hue as this accent and would read as the same color.
    public static let pumpkin = LookAccent(id: "pumpkin", main: LookColor(0xFF8A2B), light: LookColor(0xFFAA66),
                                           quiet: LookColor(0x3D2410), on: LookColor(0x1A0C02),
                                           warning: LookColor(0xF2C14E))

    /// **The accents of the supporter looks that no other look shares**: Aurora's cyan,
    /// Ice's pale blue, Ember's red-orange. Sunset, Gold and Emerald use the accents above.
    /// Like the pumpkin, these belong to their look and are not in the dots under "Accent".
    public static let aurora = LookAccent(id: "aurora", main: LookColor(0x5AD3E8), light: LookColor(0x8AE3F1),
                                          quiet: LookColor(0x0F2E35), on: LookColor(0x04141A))
    public static let ice = LookAccent(id: "ice", main: LookColor(0xA9DCFF), light: LookColor(0xCBEBFF),
                                       quiet: LookColor(0x1A2B3A), on: LookColor(0x06121C))
    /// Ember is itself orange, so its warning turns amber like Halloween's.
    public static let ember = LookAccent(id: "ember", main: LookColor(0xFF4D4F), light: LookColor(0xFF8082),
                                         quiet: LookColor(0x3F1416), on: LookColor(0x1A0404),
                                         warning: LookColor(0xF2C14E))
    /// Sunset's pink, so it no longer shares the coral of the picker with Halloween and Ember.
    public static let rose = LookAccent(id: "rose", main: LookColor(0xFF7DB0), light: LookColor(0xFFA5C9),
                                        quiet: LookColor(0x40192E), on: LookColor(0x1A0612))

    /// In the order of the picker: the dots under "Accent".
    public static let all: [LookAccent] = [.violet, .teal, .coral, .gold, .emerald]

    public static func with(id: String) -> LookAccent? {
        (all + [.pumpkin, .aurora, .ice, .ember, .rose]).first { $0.id == id }
    }
}

/// **How strong the glow at the top of the home page is.** The raw values are stored.
public enum LookGlow: String, Sendable, Codable, CaseIterable {
    case off = "off"
    case soft = "soft"
    case bright = "bright"

    /// Opacity of the one tone at its center. Soft is the 20 percent of the design;
    /// it fades to nothing at about a quarter of the screen height.
    public var opacity: Double {
        switch self {
        case .off: 0
        case .soft: 0.20
        case .bright: 0.32
        }
    }
}

/// **A look: everything it changes, in one value.**
public struct Look: Sendable, Hashable, Identifiable {
    /// Stored in the selection; never rename one.
    public let id: String
    /// The German name, which is also the catalog key.
    public let nameKey: String
    public let accent: LookAccent
    /// The one tone of the home glow.
    public let glowColor: LookColor
    /// What the glow starts at when the look is chosen.
    public let defaultGlow: LookGlow
    /// The page background. The same for both looks today; here so a later look can
    /// change it in one place.
    public let background: LookColor
    /// The play mark of the wordmark, top left to bottom right. One color is a flat fill.
    public let logoGradient: [LookColor]
    /// The second tone of the glow, see `LookPalette.glowTint`.
    public var glowTint: LookColor? { logoGradient.count > 1 ? logoGradient.last : nil }
    /// The alternate app icon in the bundle; `nil` is the regular icon.
    public let iconName: String?
    /// **A gift: free for everyone who picks it up**, and kept for good once picked up.
    public let isGift: Bool
    /// The days in the year the look is offered, and its bats and small details run.
    /// `nil`: always. Picked up is picked up: this window never takes a look away.
    public let availability: LookSeason?

    public init(id: String, nameKey: String, accent: LookAccent, glowColor: LookColor,
                defaultGlow: LookGlow, background: LookColor, logoGradient: [LookColor],
                iconName: String?, isGift: Bool = false, availability: LookSeason? = nil) {
        self.id = id
        self.nameKey = nameKey
        self.accent = accent
        self.glowColor = glowColor
        self.defaultGlow = defaultGlow
        self.background = background
        self.logoGradient = logoGradient
        self.iconName = iconName
        self.isGift = isGift
        self.availability = availability
    }

    /// **The app as it is today.** No glow, the regular icon, the turquoise mark: someone
    /// who never picks a look sees no difference at all.
    public static let original = Look(
        id: "original", nameKey: "Original", accent: .teal,
        glowColor: LookColor(0x50D5DA), defaultGlow: .off, background: LookColor(0x101010),
        logoGradient: [LookColor(0x50D5DA)], iconName: nil)

    /// Violet on the same dark ground, the mark from blue to violet like the icon.
    public static let neonNight = Look(
        id: "neonNight", nameKey: "Neon-Nacht", accent: .violet,
        glowColor: LookColor(0x8B5CF6), defaultGlow: .soft, background: LookColor(0x101010),
        logoGradient: [LookColor(0x5B7CFF), LookColor(0xC24BFF)], iconName: "AppIcon-NeonNight")

    /// **Halloween, a gift for everyone** (24 Oct to 2 Nov). Pumpkin orange for the accent,
    /// the glow and the play mark; its own icon, a dark glass tile with a web in the corner.
    public static let halloween = Look(
        id: "halloween", nameKey: "Halloween", accent: .pumpkin,
        glowColor: LookColor(0xFF8A2B), defaultGlow: .soft, background: LookColor(0x101010),
        logoGradient: [LookColor(0xFF8A2B)], iconName: "AppIcon-Halloween",
        isGift: true, availability: .halloween)

    /// **Supporter looks**, each a dark ground with its own color: the accent, a soft glow,
    /// the play mark in the icon's gradient and a glass icon of its own (`AppIcon-Look…`).
    public static let sunset = Look(
        id: "sunset", nameKey: "Sunset", accent: .rose,
        glowColor: LookColor(0xFF5A9E), defaultGlow: .soft, background: LookColor(0x101010),
        logoGradient: [LookColor(0xFFCB57), LookColor(0xFF6E7F), LookColor(0xB83FD0)],
        iconName: "AppIcon-LookSunset")

    public static let aurora = Look(
        id: "aurora", nameKey: "Aurora", accent: .aurora,
        glowColor: LookColor(0x3F7BFF), defaultGlow: .soft, background: LookColor(0x101010),
        logoGradient: [LookColor(0x46DCD8), LookColor(0x3F7BFF), LookColor(0x9B5CFF)],
        iconName: "AppIcon-LookAurora")

    public static let ice = Look(
        id: "ice", nameKey: "Eis", accent: .ice,
        glowColor: LookColor(0x6FB6FF), defaultGlow: .soft, background: LookColor(0x101010),
        logoGradient: [LookColor(0xF2FAFF), LookColor(0x6FB6FF)],
        iconName: "AppIcon-LookIce")

    public static let ember = Look(
        id: "ember", nameKey: "Glut", accent: .ember,
        glowColor: LookColor(0xF02F45), defaultGlow: .soft, background: LookColor(0x101010),
        logoGradient: [LookColor(0xFFB13B), LookColor(0xB3122B)],
        iconName: "AppIcon-LookEmber")

    public static let gold = Look(
        id: "gold", nameKey: "Gold", accent: .gold,
        glowColor: LookColor(0xE0B050), defaultGlow: .soft, background: LookColor(0x101010),
        logoGradient: [LookColor(0xFFF0C2), LookColor(0xF1CB76), LookColor(0xD19B3C), LookColor(0x9C6B1E)],
        iconName: "AppIcon-LookGold")

    public static let emerald = Look(
        id: "emerald", nameKey: "Smaragd", accent: .emerald,
        glowColor: LookColor(0x19C58F), defaultGlow: .soft, background: LookColor(0x101010),
        logoGradient: [LookColor(0x5BE6C9), LookColor(0x0E9E6E)],
        iconName: "AppIcon-LookEmerald")

    /// In the order of the looks sheet.
    public static let all: [Look] = [.original, .halloween, .neonNight, .sunset, .aurora, .ice, .ember, .gold, .emerald]

    /// **The looks everyone may use**, in the order of the looks sheet: the original and the
    /// gifts. The supporter looks are not in this list.
    public static let free: [Look] = all.filter { $0 == .original || $0.isGift }

    /// An unknown id (a look removed in a later version) falls back to the original.
    public static func with(id: String) -> Look {
        all.first { $0.id == id } ?? .original
    }
}

/// **What the person picked: a look, and what they changed on it.**
///
/// The look is stored by id, not copied, so a later fix to a look reaches everyone who
/// uses it. `nil` overrides mean "as the look has it".
public struct LookSelection: Sendable, Hashable, Codable {
    public var lookID: String
    public var accentID: String?
    public var glow: LookGlow?
    /// The icon follows the look unless switched off here; `false` keeps the regular one.
    public var usesLookIcon: Bool?

    private enum CodingKeys: String, CodingKey {
        case lookID = "look"
        case accentID = "accent"
        case glow = "glow"
        case usesLookIcon = "icon"
    }

    public init(lookID: String = Look.original.id, accentID: String? = nil,
                glow: LookGlow? = nil, usesLookIcon: Bool? = nil) {
        self.lookID = lookID
        self.accentID = accentID
        self.glow = glow
        self.usesLookIcon = usesLookIcon
    }

    public static let original = LookSelection()

    public var look: Look { Look.with(id: lookID) }

    /// The selection with all overrides applied.
    public var palette: LookPalette {
        let look = look
        let accent = accentID.flatMap(LookAccent.with(id:)) ?? look.accent
        let glow = glow ?? look.defaultGlow
        return LookPalette(look: look, accent: accent, glow: glow,
                           iconName: usesLookIcon == false ? nil : look.iconName)
    }

    /// A different look starts clean: the overrides belonged to the old one.
    public func switching(to look: Look) -> LookSelection {
        LookSelection(lookID: look.id)
    }
}

/// **The finished values one screen draws with.**
public struct LookPalette: Sendable, Hashable {
    public let look: Look
    public let accent: LookAccent
    public let glow: LookGlow
    public let iconName: String?

    public static let original = LookSelection.original.palette

    public var glowColor: LookColor { look.glowColor }
    public var logoGradient: [LookColor] { look.logoGradient }

    /// **A second, faint tone for the glow**: the last color of a mark gradient, like the
    /// icon's. `nil` for a flat mark (the original, Halloween): their glow stays one tone.
    public var glowTint: LookColor? { look.glowTint }

    /// **The play mark as one color**, for places that cannot draw a gradient (the launch
    /// animation): the look's color, or the middle of its two.
    public var markColor: LookColor {
        guard let first = logoGradient.first else { return look.accent.main }
        guard logoGradient.count > 1, let last = logoGradient.last else { return first }
        func mid(_ a: UInt32, _ b: UInt32, _ shift: UInt32) -> UInt32 {
            ((((a >> shift) & 0xFF) + ((b >> shift) & 0xFF)) / 2) << shift
        }
        return LookColor(mid(first.hex, last.hex, 16) | mid(first.hex, last.hex, 8) | mid(first.hex, last.hex, 0))
    }
}

/// The fixed storage keys. Changing one loses what devices have stored.
public enum LookStorageKey {
    public static let selection = "look.selection"
    /// The gifts picked up, as a JSON list of look ids. Never shrinks by itself.
    public static let owned = "look.owned"
    /// The gift pop-ups already shown, as `<look>-<year>` ids.
    public static let giftOffered = "look.gift.offered"
    /// "Bats and details": the moving and small extras of a seasonal look. Default on.
    public static let effects = "look.effects"
}

extension LookSelection {
    /// Reads a stored selection; anything unreadable is the original.
    public static func decoded(from data: Data?) -> LookSelection {
        guard let data, let selection = try? JSONDecoder().decode(LookSelection.self, from: data) else {
            return .original
        }
        return selection
    }

    public var encoded: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(self)
    }
}
