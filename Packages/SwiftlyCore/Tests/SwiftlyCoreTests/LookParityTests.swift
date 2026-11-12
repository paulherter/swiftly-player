import Foundation
import Testing

import JellyfinKit
@testable import SwiftlyCore

/// The core's `LookModel` against the old Swift `LookTryOn` rules on the same stored bytes (the old `setting.look.*`
/// UserDefaults keys): equal shown/saved/owned after scripted steps, and bytes written by the core read back as before.
@Suite(.serialized) struct LookParityTests {
    private static func suite() -> (UserDefaults, UserDefaultsKeyValueStore) {
        let defaults = UserDefaults(suiteName: "look-parity-\(UUID().uuidString)")!
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (defaults, UserDefaultsKeyValueStore(defaults: defaults, downloadsFolder: tmp))
    }

    private static func info(_ s: LookSelection) -> LookSelectionInfo {
        LookSelectionInfo(lookId: s.lookID, accentId: s.accentID, glow: s.glow?.rawValue, usesLookIcon: s.usesLookIcon)
    }

    private enum Step { case supporter(Bool), begin, tryOn(String), end, keep, closed, purchase, choose(String), claim(String), reset }

    private static func scripts() -> [[Step]] {
        let ids = Look.all.map(\.id)
        var all: [[Step]] = []
        for id in ids {
            all.append([.begin, .tryOn(id), .keep, .closed])
            all.append([.begin, .tryOn(id), .keep, .supporter(true), .purchase, .reset])
            all.append([.supporter(true), .choose(id), .begin, .tryOn(Look.original.id), .end, .reset])
            all.append([.claim(id), .supporter(false), .begin, .tryOn(id), .keep, .end])
            all.append([.supporter(true), .begin, .tryOn(id), .keep, .supporter(false), .reset])
        }
        return all
    }

    @Test func scriptedSessionsMatchTheOldRules() throws {
        var steps = 0
        for script in Self.scripts() {
            let (defaults, kv) = Self.suite()
            defaults.set(LookSelection().encoded, forKey: LookStorageKey.selection)
            var old = LookTryOn(saved: LookSelection.decoded(from: defaults.data(forKey: LookStorageKey.selection)), owned: [])
            let core = makeCore(store: kv).lookModel()
            for step in script {
                switch step {
                case .supporter(let on): old.setSupporter(on); try core.setSupporter(supporter: on)
                case .begin: old.begin(); try core.beginPreview()
                case .tryOn(let id):
                    let s = LookSelection(lookID: id)
                    old.tryOn(s); try core.tryOn(selection: Self.info(s))
                case .end: old.end(); try core.endPreview()
                case .keep:
                    let a = old.keep(), b = try core.keep()
                    #expect(String(describing: a).lowercased() == String(describing: b).lowercased())
                case .closed: old.supportSheetClosed(); try core.supportSheetClosed()
                case .purchase:
                    #expect(old.purchaseCompleted().map(Self.info) == (try core.purchaseCompleted()))
                case .choose(let id):
                    let s = LookSelection(lookID: id)
                    #expect(old.choose(s) == (try core.choose(selection: Self.info(s))))
                case .claim(let id):
                    #expect(old.claim(Look.with(id: id)).map(Self.info) == (try core.claim(lookId: id)))
                case .reset: old.reset(); try core.reset()
                }
                steps += 1
                #expect(Self.info(old.shown) == core.shown())
                #expect(Self.info(old.saved) == core.saved())
                #expect(Self.info(old.shown) == core.selection())
                #expect(old.owned == Set(core.owned()))
                #expect(old.isSupporter == core.isSupporter())
                #expect(old.isPreviewing == core.isPreviewing())
            }
        }
        #expect(steps > 200)
    }

    @Test func listsMatchTheOldGiftWindows() throws {
        let cal = Calendar.current
        let offset = Int64(cal.timeZone.secondsFromGMT())
        var checked = 0
        for day in stride(from: 0, to: 366, by: 5) {
            let now = Date(timeIntervalSince1970: 1_767_225_600 + Double(day) * 86_400 + 12 * 3_600)
            for owned in [Set<String>(), Set(Look.all.filter(\.isGift).prefix(1).map(\.id))] {
                let (_, kv) = Self.suite()
                let core = makeCore(store: kv).lookModel()
                if let id = owned.first { _ = try core.claim(lookId: id) }
                let free = Look.free.filter { LookGift.isAvailable($0, owned: owned, now: now) }.map(\.id)
                let picker = Look.all.filter { !$0.isGift || LookGift.isAvailable($0, owned: owned, now: now) }.map(\.id)
                #expect(core.freeLooks(now: now.timeIntervalSince1970, utcOffset: offset) == free)
                #expect(core.pickerLooks(now: now.timeIntervalSince1970, utcOffset: offset) == picker)
                checked += 1
            }
        }
        #expect(checked > 100)
    }

    @Test func oldStoredDataSurvivesAndCoreWritesReadBack() throws {
        let gift = Look.all.first { $0.isGift }!
        let (defaults, kv) = Self.suite()
        let chosen = LookSelection(lookID: Look.all.last!.id, accentID: nil, glow: .bright, usesLookIcon: false)
        defaults.set(chosen.encoded, forKey: LookStorageKey.selection)
        defaults.set([gift.id], forKey: LookStorageKey.owned)
        defaults.set(false, forKey: LookStorageKey.effects)
        let core = makeCore(store: kv).lookModel()
        #expect(core.saved() == Self.info(chosen))
        #expect(core.owned() == [gift.id])
        #expect(core.effectsOn() == false)
        // A write by the core is read by the old keys.
        try core.setSupporter(supporter: true)
        _ = try core.choose(selection: Self.info(LookSelection(lookID: Look.original.id)))
        try core.setEffectsOn(on: true)
        kv.flush()
        #expect(LookSelection.decoded(from: defaults.data(forKey: LookStorageKey.selection)).lookID == Look.original.id)
        #expect(defaults.object(forKey: LookStorageKey.effects) as? Bool == true)
        #expect((defaults.array(forKey: LookStorageKey.owned) as? [String]) == [gift.id])
    }
}
