import Foundation
import Testing
@testable import JellyfinKit

@Suite("Halloween gift")
struct LookGiftTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func context(_ now: Date, owned: Set<String> = [], offered: Set<String> = [],
                         homeReady: Bool = true, playing: Bool = false, asked: Bool = false,
                         seconds: TimeInterval = 10) -> LookGift.Context {
        LookGift.Context(now: now, homeReady: homeReady, playing: playing, askedThisSession: asked,
                         secondsOnHome: seconds, owned: owned, offered: offered)
    }

    // MARK: Window

    @Test("The window runs from 24 October to the end of 2 November")
    func window() {
        let season = LookSeason.halloween
        #expect(!season.isActive(at: day(2026, 10, 23, 23, 59), calendar: calendar))
        #expect(season.isActive(at: day(2026, 10, 24, 0, 0), calendar: calendar))
        #expect(season.isActive(at: day(2026, 10, 31), calendar: calendar))
        #expect(season.isActive(at: day(2026, 11, 2, 23, 59), calendar: calendar))
        #expect(!season.isActive(at: day(2026, 11, 3, 0, 0), calendar: calendar))
        #expect(!season.isActive(at: day(2027, 3, 1), calendar: calendar))
    }

    @Test("A window over New Year counts for both years and names its start year")
    func overNewYear() {
        let winter = LookSeason(id: "winter", from: MonthDay(month: 12, day: 1), to: MonthDay(month: 1, day: 2))
        #expect(winter.crossesNewYear)
        #expect(winter.isActive(at: day(2026, 12, 24), calendar: calendar))
        #expect(winter.isActive(at: day(2027, 1, 2), calendar: calendar))
        #expect(!winter.isActive(at: day(2027, 1, 3), calendar: calendar))
        #expect(winter.seasonYear(at: day(2027, 1, 1), calendar: calendar) == 2026)
        #expect(winter.seasonYear(at: day(2026, 12, 1), calendar: calendar) == 2026)
    }

    @Test("The next start is this year's before the window, next year's in and after it")
    func nextStart() {
        let season = LookSeason.halloween
        #expect(season.nextStart(after: day(2026, 10, 1), calendar: calendar) == day(2026, 10, 24, 0))
        #expect(season.nextStart(after: day(2026, 10, 30), calendar: calendar) == day(2027, 10, 24, 0))
    }

    // MARK: The pop-up

    @Test("The pop-up is due once in the window, after sign-in, on a quiet home page")
    func due() {
        let now = day(2026, 10, 26)
        #expect(LookGift.due(context(now), calendar: calendar) == .halloween)
        #expect(LookGift.due(context(day(2026, 10, 20)), calendar: calendar) == nil)
        #expect(LookGift.due(context(day(2026, 11, 3)), calendar: calendar) == nil)
        #expect(LookGift.due(context(now, homeReady: false), calendar: calendar) == nil)
        #expect(LookGift.due(context(now, playing: true), calendar: calendar) == nil)
        #expect(LookGift.due(context(now, asked: true), calendar: calendar) == nil)
        #expect(LookGift.due(context(now, seconds: 1), calendar: calendar) == nil)
    }

    @Test("Shown once: neither after it was offered nor after it was picked up")
    func once() {
        let now = day(2026, 10, 26)
        let id = LookGift.offerID(.halloween, at: now, calendar: calendar)
        #expect(id == "halloween-2026")
        #expect(LookGift.due(context(now, offered: ["halloween-2026"]), calendar: calendar) == nil)
        #expect(LookGift.due(context(now, owned: ["halloween"]), calendar: calendar) == nil)
        // Next year is another season.
        #expect(LookGift.due(context(day(2027, 10, 26), offered: ["halloween-2026"]), calendar: calendar) == .halloween)
    }

    @Test("A gift can be picked up in its window; picked up, it stays after it")
    func availability() {
        #expect(LookGift.isAvailable(.halloween, owned: [], now: day(2026, 10, 30), calendar: calendar))
        #expect(!LookGift.isAvailable(.halloween, owned: [], now: day(2026, 11, 5), calendar: calendar))
        #expect(LookGift.isAvailable(.halloween, owned: ["halloween"], now: day(2027, 3, 1), calendar: calendar))
        #expect(LookGift.isAvailable(.original, owned: [], now: day(2027, 3, 1), calendar: calendar))
    }

    // MARK: State

    @Test("Grab it: picked up for good, worn by a non-supporter, also after the window")
    func claim() {
        var state = LookTryOn()
        #expect(state.shown == .original)
        let r1 = state.claim(.halloween)
        #expect(r1 == LookSelection(lookID: "halloween"))
        #expect(state.owned == ["halloween"])
        #expect(state.shown.look == .halloween)
        #expect(state.ownsLook)
        // A stored state read on a later day: nothing in it depends on the date.
        let later = LookTryOn(saved: state.saved, isSupporter: false, owned: state.owned)
        #expect(later.shown.look == .halloween)
    }

    @Test("Only gifts can be picked up")
    func claimOnlyGifts() {
        var state = LookTryOn()
        let r2 = state.claim(.neonNight)
        #expect(r2 == nil)
        #expect(state.owned.isEmpty)
        #expect(state.shown == .original)
    }

    @Test("Everyone may switch between the original and a gift they own, nothing else")
    func chooseFree() {
        var state = LookTryOn(owned: ["halloween"])
        let r3 = state.choose(LookSelection(lookID: "halloween"))
        #expect(r3)
        #expect(state.shown.look == .halloween)
        let r4 = state.choose(.original)
        #expect(r4)
        #expect(state.shown == .original)
        let r5 = state.choose(LookSelection(lookID: "neonNight"))
        #expect(!r5)
        // A picked accent color stays with supporters; the home glow is open to all.
        let r6 = state.choose(LookSelection(lookID: "halloween", accentID: "gold"))
        #expect(!r6)
        #expect(state.shown == .original)
        let r8 = state.choose(LookSelection(lookID: "original", glow: .soft))
        #expect(r8)
        let r9 = state.choose(LookSelection(lookID: "halloween", glow: .bright, usesLookIcon: false))
        #expect(r9)
        _ = state.choose(.original)
        var stranger = LookTryOn()
        let r7 = stranger.choose(LookSelection(lookID: "halloween"))
        #expect(!r7)
    }

    @Test("A stored gift that is not owned shows the original")
    func notOwned() {
        let state = LookTryOn(saved: LookSelection(lookID: "halloween"), isSupporter: false, owned: [])
        #expect(state.shown == .original)
    }

    @Test("Keeping an owned gift in the preview stores it without asking for support")
    func keepOwnedGift() {
        var state = LookTryOn(owned: ["halloween"])
        state.begin()
        state.tryOn(LookSelection(lookID: "halloween"))
        let r8 = state.keep()
        #expect(r8 == .kept)
        #expect(state.saved.look == .halloween)
        state.begin()
        state.tryOn(LookSelection(lookID: "neonNight"))
        let r9 = state.keep()
        #expect(r9 == .needsSupport)
    }

    // MARK: Profile

    @Test("The profile's look entry, for every state")
    func profileEntry() {
        // Supporter build (debug prototype).
        #expect(LookProfileEntry.at(supporterFeatures: true, isSupporter: true, ownsLook: false) == .current)
        #expect(LookProfileEntry.at(supporterFeatures: true, isSupporter: true, ownsLook: true) == .current)
        #expect(LookProfileEntry.at(supporterFeatures: true, isSupporter: false, ownsLook: true) == .current)
        #expect(LookProfileEntry.at(supporterFeatures: true, isSupporter: false, ownsLook: false) == .teaser)
        // This version: never a teaser.
        #expect(LookProfileEntry.at(supporterFeatures: false, isSupporter: true, ownsLook: false) == .current)
        #expect(LookProfileEntry.at(supporterFeatures: false, isSupporter: false, ownsLook: true) == .current)
        #expect(LookProfileEntry.at(supporterFeatures: false, isSupporter: false, ownsLook: false) == .none)
        // The plain "Looks" row only where nothing else leads to the looks.
        #expect(LookProfileEntry.showsLooksRow(entry: .none, giftAvailable: true))
        #expect(!LookProfileEntry.showsLooksRow(entry: .none, giftAvailable: false))
        #expect(!LookProfileEntry.showsLooksRow(entry: .current, giftAvailable: true))
        #expect(!LookProfileEntry.showsLooksRow(entry: .teaser, giftAvailable: true))
    }

    // MARK: Effects

    private func effects(_ now: Date, look: Look = .halloween, on: Bool = true, playing: Bool = false,
                         reduce: Bool = false, lowPower: Bool = false, foreground: Bool = true) -> LookEffects.Context {
        LookEffects.Context(look: look, now: now, switchOn: on, playing: playing, reduceMotion: reduce,
                            lowPower: lowPower, foreground: foreground)
    }

    @Test("Bats fly only on the home page, in the window, with nothing against movement")
    func bats() {
        let now = day(2026, 10, 30)
        #expect(LookEffects.bats(on: .home, effects(now), calendar: calendar))
        #expect(!LookEffects.bats(on: .detail, effects(now), calendar: calendar))
        #expect(!LookEffects.bats(on: .profile, effects(now), calendar: calendar))
        #expect(!LookEffects.bats(on: .home, effects(now, playing: true), calendar: calendar))
        #expect(!LookEffects.bats(on: .home, effects(now, reduce: true), calendar: calendar))
        #expect(!LookEffects.bats(on: .home, effects(now, lowPower: true), calendar: calendar))
        #expect(!LookEffects.bats(on: .home, effects(now, foreground: false), calendar: calendar))
        #expect(!LookEffects.bats(on: .home, effects(now, on: false), calendar: calendar))
        #expect(!LookEffects.bats(on: .home, effects(day(2026, 11, 3)), calendar: calendar))
        #expect(!LookEffects.bats(on: .home, effects(now, look: .original), calendar: calendar))
    }

    @Test("A bat that does not fly has a named reason")
    func batReasons() {
        let now = day(2026, 10, 30)
        #expect(LookEffects.batBlock(on: .home, effects(now), calendar: calendar) == nil)
        #expect(LookEffects.batBlock(on: .home, effects(now, reduce: true), calendar: calendar) == .reduceMotion)
        #expect(LookEffects.batBlock(on: .home, effects(now, lowPower: true), calendar: calendar) == .lowPower)
        #expect(LookEffects.batBlock(on: .home, effects(now, playing: true), calendar: calendar) == .playing)
        #expect(LookEffects.batBlock(on: .home, effects(day(2026, 11, 3)), calendar: calendar) == .outsideWindow)
        #expect(LookEffects.batBlock(on: .home, effects(now, foreground: false), calendar: calendar) == .background)
    }

    @Test("The first bat comes after about 6 s, the next ones every 45 to 90 s")
    func batRhythm() {
        #expect(LookEffects.wait(first: true) == 6)
        for _ in 0..<50 { #expect(LookEffects.pause.contains(LookEffects.wait(first: false))) }
        #expect(LookEffects.pause == 45...90)
    }

    @Test("Standing details stay with reduced motion, never on the detail page")
    func details() {
        let now = day(2026, 10, 30)
        #expect(LookEffects.details(on: .home, effects(now, reduce: true), calendar: calendar))
        #expect(LookEffects.details(on: .profile, effects(now), calendar: calendar))
        #expect(!LookEffects.details(on: .detail, effects(now), calendar: calendar))
        #expect(!LookEffects.details(on: .home, effects(day(2026, 11, 3)), calendar: calendar))
    }

    // MARK: Look values

    @Test("The logo's color comes from the look worn, also in the launch animation")
    func logoColor() {
        #expect(LookPalette.original.markColor.css == "#50D5DA")
        #expect(LookSelection(lookID: "halloween").palette.markColor.css == "#FF8A2B")
        // Neon Night's two tones meet in the middle.
        #expect(LookSelection(lookID: "neonNight").palette.markColor.css == "#8E63FF")
        var state = LookTryOn()
        state.claim(.halloween)
        #expect(state.shown.palette.markColor.css == "#FF8A2B")
    }

    @Test("Halloween: pumpkin orange, its own icon, a gift, and a warning that is not orange")
    func halloweenLook() {
        let palette = LookSelection(lookID: Look.halloween.id).palette
        #expect(palette.accent.main.css == "#FF8A2B")
        #expect(palette.iconName == "AppIcon-Halloween")
        #expect(palette.glow == .soft)
        #expect(Look.halloween.isGift)
        #expect(Look.free == [.original, .halloween])
        #expect(LookAccent.pumpkin.warning != nil)
        #expect(LookAccent.teal.warning == nil)
        // Accent against its text tone, as for every other accent.
        func luminance(_ color: LookColor) -> Double {
            func channel(_ value: Double) -> Double {
                value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
        }
        let pumpkin = LookAccent.pumpkin
        #expect((luminance(pumpkin.main) + 0.05) / (luminance(pumpkin.on) + 0.05) >= 4.5)
        // Accent and warning on the page ground (#101010): both readable.
        let ground = LookColor(0x101010)
        #expect((luminance(pumpkin.main) + 0.05) / (luminance(ground) + 0.05) >= 4.5)
        #expect((luminance(pumpkin.warning!) + 0.05) / (luminance(ground) + 0.05) >= 4.5)
    }
}

@Suite("What's new")
struct WhatsNewTests {
    @Test("Only after an update, never on a fresh install, once per version")
    func decide() {
        #expect(WhatsNew.decide(lastSeen: nil, usedBefore: false, current: "1.0.8", hasEntry: true) == .markSeen)
        #expect(WhatsNew.decide(lastSeen: nil, usedBefore: true, current: "1.0.8", hasEntry: true) == .show)
        #expect(WhatsNew.decide(lastSeen: "1.0.7", usedBefore: true, current: "1.0.8", hasEntry: true) == .show)
        #expect(WhatsNew.decide(lastSeen: "1.0.8", usedBefore: true, current: "1.0.8", hasEntry: true) == .nothing)
        #expect(WhatsNew.decide(lastSeen: "1.0.7", usedBefore: true, current: "1.0.8", hasEntry: false) == .markSeen)
        #expect(WhatsNew.decide(lastSeen: "1.0.9", usedBefore: true, current: "1.0.8", hasEntry: true) == .nothing)
    }

    @Test("Versions compare by number parts")
    func versions() {
        #expect(WhatsNew.isNewer("1.0.10", than: "1.0.9"))
        #expect(WhatsNew.isNewer("1.1", than: "1.0.9"))
        #expect(!WhatsNew.isNewer("1.0.8", than: "1.0.8"))
        #expect(!WhatsNew.isNewer("1.0", than: "1.0.0"))
    }

    @Test("The shipped file reads, with three entries and the Halloween gift")
    func bundled() throws {
        let entry = try #require(WhatsNewEntry.bundled(for: "1.0.8"))
        #expect(entry.variant == .gift)
        #expect(entry.items.count == 3)
        #expect(entry.giftLook == .halloween)
        #expect(entry.primary.label == "grab")
        #expect(WhatsNewEntry.bundled(for: "0.0.1") == nil)
    }

    @Test("A draft is never shown")
    func draft() {
        let json = #"{"version":"9","variant":"standard","title":{"en":"a","de":"b"},"items":[{"symbol":"x","title":{"en":"a","de":"b"}},{"symbol":"x","title":{"en":"a","de":"b"}},{"symbol":"x","title":{"en":"a","de":"b"}}],"primary":{"label":"continue","action":"dismiss"},"draft":true}"#
        #expect(WhatsNewEntry.decoded(from: Data(json.utf8)) == nil)
        let ready = json.replacingOccurrences(of: #","draft":true"#, with: "")
        #expect(WhatsNewEntry.decoded(from: Data(ready.utf8)) != nil)
    }
}
