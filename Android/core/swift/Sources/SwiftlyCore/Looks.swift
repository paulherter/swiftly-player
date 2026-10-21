import Foundation
import JellyfinKit

// MARK: - Looks, the bridge for Kotlin
//
// **Every rule lives in the package** (`Look`, `LookTryOn`, `LookGift`, `LookEffects`,
// `LookProfileEntry`, `WhatsNew`). Kotlin keeps the records as plain strings in SharedPreferences
// under the package's keys (`LookStorageKey`) and hands them in here; nothing is copied.
//
// Colors travel as `#RRGGBB` strings, dates as epoch milliseconds, selections as the package's own
// JSON (`{"look","accent","glow","icon"}`).

private struct LookColorJSON: Encodable {
    let hex: String
    init(_ color: LookColor) { hex = color.css }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}

private struct AccentJSON: Encodable {
    let id: String
    let main: LookColorJSON
    let light: LookColorJSON
    let quiet: LookColorJSON
    let on: LookColorJSON
    let warning: LookColorJSON?
    init(_ a: LookAccent) {
        id = a.id
        main = LookColorJSON(a.main)
        light = LookColorJSON(a.light)
        quiet = LookColorJSON(a.quiet)
        on = LookColorJSON(a.on)
        warning = a.warning.map(LookColorJSON.init)
    }
}

private struct SeasonJSON: Encodable {
    let id: String
    let fromMonth: Int, fromDay: Int, toMonth: Int, toDay: Int
}

private struct LookJSON: Encodable {
    let id: String
    let nameKey: String
    let accent: AccentJSON
    let glowColor: LookColorJSON
    let defaultGlow: String
    let logoGradient: [LookColorJSON]
    let glowTint: LookColorJSON?
    let iconName: String?
    let isGift: Bool
    let season: SeasonJSON?
    init(_ l: Look) {
        id = l.id
        nameKey = l.nameKey
        accent = AccentJSON(l.accent)
        glowColor = LookColorJSON(l.glowColor)
        defaultGlow = l.defaultGlow.rawValue
        logoGradient = l.logoGradient.map(LookColorJSON.init)
        glowTint = l.glowTint.map(LookColorJSON.init)
        iconName = l.iconName
        isGift = l.isGift
        season = l.availability.map {
            SeasonJSON(id: $0.id, fromMonth: $0.from.month, fromDay: $0.from.day,
                       toMonth: $0.to.month, toDay: $0.to.day)
        }
    }
}

private struct CatalogJSON: Encodable {
    let looks: [LookJSON]
    let accents: [AccentJSON]
    let glows: [String: Double]
}

private struct PaletteJSON: Encodable {
    let look: String
    let accent: AccentJSON
    let glow: String
    let glowOpacity: Double
    let glowColor: LookColorJSON
    let glowTint: LookColorJSON?
    let logoGradient: [LookColorJSON]
    let markColor: LookColorJSON
    let iconName: String?
    init(_ p: LookPalette) {
        look = p.look.id
        accent = AccentJSON(p.accent)
        glow = p.glow.rawValue
        glowOpacity = p.glow.opacity
        glowColor = LookColorJSON(p.glowColor)
        glowTint = p.glowTint.map(LookColorJSON.init)
        logoGradient = p.logoGradient.map(LookColorJSON.init)
        markColor = LookColorJSON(p.markColor)
        iconName = p.iconName
    }
}

/// The `LookTryOn` value as Kotlin stores it between calls.
private struct TryOnState: Codable {
    var saved: LookSelection
    var preview: LookSelection?
    var pending: LookSelection?
    var supporter: Bool
    var owned: [String]
}

private struct TryOnAnswer: Encodable {
    let state: TryOnState
    let shown: LookSelection
    let palette: PaletteJSON
    /// `kept`, `needsSupport`, `nothing` for keep; `stored` with a look for purchase; else empty.
    let result: String
    let accepted: Bool
}

private func lookDate(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

private func lookEncoded<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
}

private func lookSelection(_ json: String) -> LookSelection {
    LookSelection.decoded(from: json.isEmpty ? nil : Data(json.utf8))
}

extension Kern {
    /// Every look, the accent dots and the glow strengths.
    public static func looksCatalog() -> String {
        var glows: [String: Double] = [:]
        for g in LookGlow.allCases { glows[g.rawValue] = g.opacity }
        return lookEncoded(CatalogJSON(looks: Look.all.map(LookJSON.init),
                                       accents: LookAccent.all.map(AccentJSON.init), glows: glows))
    }

    /// A stored selection read the way the package reads it; anything unreadable is the original.
    public static func looksNormalize(selection: String) -> String {
        let s = lookSelection(selection)
        return s.encoded.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The finished values for a selection.
    public static func looksPalette(selection: String) -> String {
        lookEncoded(PaletteJSON(lookSelection(selection).palette))
    }

    /// A selection of another look, clean of the old overrides.
    public static func looksSwitch(to lookID: String) -> String {
        let s = LookSelection.original.switching(to: Look.with(id: lookID))
        return s.encoded.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// `LookTryOn` without a held object. `state` is the JSON this returned before (empty: fresh).
    /// `op`: begin, tryOn (arg: selection), end, keep, sheetClosed, purchase, supporter (arg: 1/0),
    /// choose (arg: selection), claim (arg: look id), reset, show (no change).
    public static func looksTryOn(state: String, op: String, arg: String) -> String {
        var s = (try? JSONDecoder().decode(TryOnState.self, from: Data(state.utf8)))
            ?? TryOnState(saved: .original, preview: nil, pending: nil, supporter: false, owned: [])
        var t = LookTryOn(saved: s.saved, isSupporter: s.supporter, owned: Set(s.owned))
        if let preview = s.preview {
            t.begin()
            // `begin` previews what is shown; set it to the stored preview.
            t.tryOn(preview)
        }
        if let pending = s.pending, s.preview != nil, !s.supporter {
            // Rebuild a waiting keep: preview the pending look and press keep for a non-supporter.
            t.tryOn(pending)
            _ = t.keep()
            if let p = s.preview { t.tryOn(p) }
        }
        var result = ""
        var accepted = true
        switch op {
        case "begin": t.begin()
        case "tryOn": t.tryOn(lookSelection(arg))
        case "end": t.end()
        case "keep":
            switch t.keep() {
            case .kept: result = "kept"
            case .needsSupport: result = "needsSupport"
            case .nothing: result = "nothing"
            }
        case "sheetClosed": t.supportSheetClosed()
        case "purchase": result = t.purchaseCompleted()?.lookID ?? ""
        case "supporter": t.setSupporter(arg == "1")
        case "choose": accepted = t.choose(lookSelection(arg))
        case "claim":
            let look = Look.with(id: arg)
            accepted = t.claim(look) != nil
        case "reset": t.reset()
        default: break
        }
        s = TryOnState(saved: t.saved, preview: t.preview, pending: t.pendingKeep,
                       supporter: t.isSupporter, owned: t.owned.sorted())
        return lookEncoded(TryOnAnswer(state: s, shown: t.shown, palette: PaletteJSON(t.shown.palette),
                                       result: result, accepted: accepted))
    }

    /// `LookGift.due`: the id of the gift whose pop-up is due, or empty.
    public static func looksGiftDue(nowMs: Int64, homeReady: Bool, playing: Bool, askedThisSession: Bool,
                                    secondsOnHome: Double, owned: String, offered: String) -> String {
        let context = LookGift.Context(now: lookDate(nowMs), homeReady: homeReady, playing: playing,
                                       askedThisSession: askedThisSession, secondsOnHome: secondsOnHome,
                                       owned: lookIDs(owned), offered: lookIDs(offered))
        return LookGift.due(context)?.id ?? ""
    }

    /// The stored id of the offer for a look today (`halloween-2026`), or empty outside its window.
    public static func looksGiftOfferID(lookID: String, nowMs: Int64) -> String {
        LookGift.offerID(Look.with(id: lookID), at: lookDate(nowMs)) ?? ""
    }

    /// Whether the gift can be picked up now (or is picked up already).
    public static func looksGiftAvailable(lookID: String, owned: String, nowMs: Int64) -> Bool {
        LookGift.isAvailable(Look.with(id: lookID), owned: lookIDs(owned), now: lookDate(nowMs))
    }

    /// Whether any gift can be picked up now.
    public static func looksAnyGiftAvailable(owned: String, nowMs: Int64) -> Bool {
        Look.all.contains { $0.isGift && LookGift.isAvailable($0, owned: lookIDs(owned), now: lookDate(nowMs)) }
    }

    /// `{"home":Bool,"profile":Bool,"batBlock":"" or reason}` for the look shown.
    public static func looksEffects(lookID: String, nowMs: Int64, switchOn: Bool, playing: Bool,
                                    reduceMotion: Bool, lowPower: Bool, foreground: Bool) -> String {
        let context = LookEffects.Context(look: Look.with(id: lookID), now: lookDate(nowMs), switchOn: switchOn,
                                          playing: playing, reduceMotion: reduceMotion, lowPower: lowPower,
                                          foreground: foreground)
        struct Out: Encodable { let home: Bool; let profile: Bool; let batBlock: String }
        return lookEncoded(Out(home: LookEffects.details(on: .home, context),
                               profile: LookEffects.details(on: .profile, context),
                               batBlock: LookEffects.batBlock(on: .home, context)?.rawValue ?? ""))
    }

    /// `LookProfileEntry`: `{"entry":"none|teaser|current","showsRow":Bool}`.
    public static func looksProfileEntry(supporterFeatures: Bool, isSupporter: Bool, ownsLook: Bool,
                                         giftAvailable: Bool) -> String {
        let entry = LookProfileEntry.at(supporterFeatures: supporterFeatures, isSupporter: isSupporter,
                                        ownsLook: ownsLook)
        struct Out: Encodable { let entry: String; let showsRow: Bool }
        let name: String
        switch entry {
        case .none: name = "none"
        case .teaser: name = "teaser"
        case .current: name = "current"
        }
        return lookEncoded(Out(entry: name, showsRow: LookProfileEntry.showsLooksRow(entry: entry,
                                                                                    giftAvailable: giftAvailable)))
    }

    /// `WhatsNew.decide`: `markSeen`, `show` or `nothing`.
    public static func whatsNewDecide(lastSeen: String, usedBefore: Bool, current: String,
                                      hasEntry: Bool) -> String {
        switch WhatsNew.decide(lastSeen: lastSeen.isEmpty ? nil : lastSeen, usedBefore: usedBefore,
                               current: current, hasEntry: hasEntry) {
        case .markSeen: return "markSeen"
        case .show: return "show"
        case .nothing: return "nothing"
        }
    }

    /// Whether a shipped what's-new file is usable (not a draft, 3 to 5 items); returns the id of its
    /// gift look or empty, as `{"valid":Bool,"giftLook":""}`.
    public static func whatsNewCheck(json: String) -> String {
        struct Out: Encodable { let valid: Bool; let giftLook: String }
        guard let entry = WhatsNewEntry.decoded(from: Data(json.utf8)) else {
            return lookEncoded(Out(valid: false, giftLook: ""))
        }
        return lookEncoded(Out(valid: true, giftLook: entry.giftLook?.id ?? ""))
    }

    /// Version comparison by number parts.
    public static func versionIsNewer(_ version: String, than other: String) -> Bool {
        WhatsNew.isNewer(version, than: other)
    }
}

/// A JSON list of strings (the stored owned/offered ids) as a set.
private func lookIDs(_ json: String) -> Set<String> {
    guard !json.isEmpty, let list = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return [] }
    return Set(list)
}
