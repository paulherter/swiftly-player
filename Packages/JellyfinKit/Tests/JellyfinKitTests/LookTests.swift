import Foundation
import Testing
@testable import JellyfinKit

@Suite("Looks")
struct LookTests {
    @Test("The original look is today's app, value for value")
    func originalIsUnchanged() {
        let palette = LookPalette.original
        #expect(palette.look.id == "original")
        #expect(palette.accent.main.css == "#50D5DA")
        #expect(palette.accent.light.css == "#7AE6EA")
        #expect(palette.accent.quiet.css == "#113435")
        #expect(palette.accent.on.css == "#061212")
        #expect(palette.glow == .off)
        #expect(palette.glow.opacity == 0)
        #expect(palette.iconName == nil)
        #expect(palette.logoGradient == [LookColor(0x50D5DA)])
        #expect(palette.look.background.css == "#101010")
    }

    @Test("Neon Night brings its own accent, glow and icon")
    func neonNight() {
        let palette = LookSelection(lookID: Look.neonNight.id).palette
        #expect(palette.accent == .violet)
        #expect(palette.glow == .soft)
        #expect(palette.glow.opacity == 0.20)
        #expect(palette.iconName == "AppIcon-NeonNight")
        #expect(palette.logoGradient.count == 2)
    }

    @Test("Overrides replace single values of the look")
    func overrides() {
        let selection = LookSelection(lookID: Look.neonNight.id, accentID: LookAccent.coral.id,
                                      glow: .bright, usesLookIcon: false)
        let palette = selection.palette
        #expect(palette.look == .neonNight)
        #expect(palette.accent == .coral)
        #expect(palette.glow == .bright)
        #expect(palette.iconName == nil)
    }

    @Test("Switching looks drops the overrides of the old one")
    func switching() {
        let selection = LookSelection(lookID: Look.original.id, accentID: LookAccent.gold.id, glow: .bright)
        #expect(selection.switching(to: .neonNight) == LookSelection(lookID: Look.neonNight.id))
    }

    @Test("An unknown look or accent falls back instead of failing")
    func unknownIDs() {
        #expect(LookSelection(lookID: "removed").palette.look == .original)
        #expect(LookSelection(lookID: Look.neonNight.id, accentID: "removed").palette.accent == .violet)
        #expect(LookSelection.decoded(from: Data("garbage".utf8)) == .original)
        #expect(LookSelection.decoded(from: nil) == .original)
    }

    @Test("The stored JSON shape is fixed")
    func wireShape() throws {
        let data = try #require(LookSelection(lookID: "neonNight", accentID: "coral", glow: .bright,
                                              usesLookIcon: false).encoded)
        #expect(String(decoding: data, as: UTF8.self)
            == #"{"accent":"coral","glow":"bright","icon":false,"look":"neonNight"}"#)
        #expect(String(decoding: try #require(LookSelection.original.encoded), as: UTF8.self)
            == #"{"look":"original"}"#)
        #expect(LookSelection.decoded(from: data).glow == .bright)
        #expect(LookStorageKey.selection == "look.selection")
    }

    @Test("Every accent has a dark tone for text on it")
    func accentsReadable() {
        for accent in LookAccent.all {
            // Relative luminance of the accent against its text tone: at least 4.5:1.
            func luminance(_ color: LookColor) -> Double {
                func channel(_ value: Double) -> Double {
                    value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
            }
            let ratio = (luminance(accent.main) + 0.05) / (luminance(accent.on) + 0.05)
            #expect(ratio >= 4.5, "\(accent.id): \(ratio)")
        }
    }

    @Test("The support plan is stored under its own key")
    func supportPlan() {
        let storage = InMemorySupportStorage()
        let store = SupportStore(storage: storage)
        #expect(store.plan == nil)
        store.plan = .lifetime
        #expect(store.plan == .lifetime)
        #expect(storage.values["support.plan"] == Data("lifetime".utf8))
        store.plan = nil
        #expect(store.plan == nil)
        #expect(!SupportStorageKey.all.contains(SupportStorageKey.plan))
    }

    @Test("The picker order and the ids of all looks")
    func lookOrder() {
        #expect(Look.all.map(\.id) == ["original", "halloween", "neonNight", "sunset", "aurora",
                                       "ice", "ember", "gold", "emerald"])
        #expect(Look.all.map(\.nameKey) == ["Original", "Halloween", "Neon-Nacht", "Sunset", "Aurora",
                                            "Eis", "Glut", "Gold", "Smaragd"])
        #expect(Look.free == [.original, .halloween])
        #expect(Set(Look.all.map(\.id)).count == Look.all.count)
        #expect(Set(Look.all.compactMap(\.iconName)).count == Look.all.count - 1)
        for look in Look.all {
            #expect(Look.with(id: look.id) == look)
            #expect(LookSelection(lookID: look.id).palette.look == look)
        }
        #expect(Look.with(id: "removed") == .original)
    }

    @Test("The supporter looks: soft glow, no gift, no season, the dark ground, readable accents")
    func supporterLooks() {
        func luminance(_ color: LookColor) -> Double {
            func channel(_ value: Double) -> Double {
                value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
        }
        let ground = luminance(LookColor(0x101010))
        for look in [Look.sunset, .aurora, .ice, .ember, .gold, .emerald] {
            #expect(!look.isGift && look.availability == nil)
            #expect(look.defaultGlow == .soft)
            #expect(look.background.css == "#101010")
            #expect(look.iconName?.hasPrefix("AppIcon-Look") == true)
            #expect(look.logoGradient.count >= 2)
            // Text accent on the page ground: at least 4.5:1; the dark tone on the accent too.
            let onGround = (luminance(look.accent.main) + 0.05) / (ground + 0.05)
            #expect(onGround >= 4.5, "\(look.id): \(onGround)")
            let onAccent = (luminance(look.accent.main) + 0.05) / (luminance(look.accent.on) + 0.05)
            #expect(onAccent >= 4.5, "\(look.id): \(onAccent)")
            #expect(LookAccent.with(id: look.accent.id) == look.accent)
        }
        #expect(Look.sunset.logoGradient.map(\.css) == ["#FFCB57", "#FF6E7F", "#B83FD0"])
        #expect(Look.gold.glowColor.css == "#E0B050")
        #expect(LookAccent.ember.warning != nil)
    }
}
