import Foundation
import Testing
import JellyfinKit
@testable import SupportKeyKit

/// `SS2` keys issued by the shop's own code (`SupporterKey::issue2`) with the test pair
/// (seed 32 × 0x01): run the shop's PHPUnit suite with `KASSE_SS2_VECTORS=<file>`.
@Suite("Supporter key SS2", .serialized)
struct SupporterKeyV2Tests {
    static let testKey = SupporterKey.decodePublicKey(SupporterKey.testPublicKeyBase64)!
    static let purchased = Date(timeIntervalSince1970: 1_792_281_600) // 2026-10-18
    static let expires = Date(timeIntervalSince1970: 1_794_960_000)   // 2026-11-18
    static let expiresLater = Date(timeIntervalSince1970: 1_797_638_400) // 2026-12-18

    static let monthly = "SS2-AIAACAKRBBISOAAREIZUIVLGO6EJTKV3ZTO65722N7B2WICNF3VXWHLLDQOVVU6UNFIEFEBC2EJZ7HTDYFTQ63RSH5W55ZLFZZL5AY2GQEBGUIFKT5DSDMC7WI4FHJSAAXDLBFOKR2DH2NC5565OHLIP"
    static let monthlyLater = "SS2-AIAACAKRBBIUMAAREIZUIVLGO6EJTKV3ZTO65722N7B2WICNFZQPX5RFPZNR7F2QXLFUGUIWZ4KDBFBREJNBTKLXJBIX35NN3C6RDKFN25MTNWSDRGPBAQ3INH2TIOGXKUOOR5WE7DUVKBQJ5G4YX6QB"
    static let lifetime = "SS2-AIAACASRBAAAB77O3XGLXKUZRB3WMVKEGMRBCAAHDD6WZNFCPGHPSRYLTY46EOCMCQPD7HWRLPQ2ALYGOGHETIIDG2WKJXHZOG6ZXT6CNFHISLXS5C7QNROB6W3CRGYQYTKLEVSSJ4UAS"
    static let lifetimeTest = "SS2-AIAQCASRBAAAB77O3XGLXKUZRB3WMVKEGMRBCAFEKIVZPSPBPNLQIYYZKR4IB6RODDCCFVB3P7NC5ARBF2ROUZ3TDJGNURUP2Z53XUZLXPD36X7BZL4JX5BJWM2G6JVBTYEZOWCASE5Q6"
    static let otherApp = "SS2-AIAAEASRBAAAAAAREIZUIVLGO6EJTKV3ZTO6574WLEGQ2BL33KQDBU5LMGRMF4S3TQO3TVNLLKZ6HEXJA3X66OUNIES53NNXBWBEEMK5JQZOKNXMYTHAT2CYEIDMPEXWJQVYGHESCVNQQ"
    static let monthlyID = "00112233445566778899aabbccddeeff"
    static let lifetimeID = "ffeeddccbbaa99887766554433221100"

    func read(_ text: String, allowTest: Bool = false) -> Result<SupporterLicense, SupporterKey.Failure> {
        SupporterKey.read(text, publicKey: Self.testKey, allowTestKeys: allowTest)
    }

    @Test("A monthly key reads plan, purchase day, expiry and licence ID")
    func monthlyKey() throws {
        let license = try read(Self.monthly).get()
        #expect(license == SupporterLicense(app: .swiftly, plan: .monthly, issuedAt: Self.purchased,
                                            expiresAt: Self.expires, id: Self.monthlyID, name: "Zoë M.",
                                            isTest: false, isLegacy: false))
        #expect(license.isActive(at: Self.expires.addingTimeInterval(-1)))
        #expect(!license.isActive(at: Self.expires))
        #expect(license.supportPlan == .monthly)
    }

    @Test("verify refuses a monthly key from its expiry day on")
    func monthlyExpiry() {
        let before = SupporterKey.verify(Self.monthly, publicKey: Self.testKey, now: Self.expires.addingTimeInterval(-60))
        #expect(before == .valid(app: .swiftly, issuedAt: Self.purchased, orderID: Self.monthlyID, name: "Zoë M."))
        #expect(SupporterKey.verify(Self.monthly, publicKey: Self.testKey, now: Self.expires) == .invalid(.expired))
    }

    @Test("Lifetime keys never expire; test and foreign keys are refused")
    func lifetimeKey() throws {
        let license = try read(Self.lifetime).get()
        #expect(license.plan == .lifetime && license.expiresAt == nil && license.name == nil && license.id == Self.lifetimeID)
        #expect(SupporterKey.verify(Self.lifetime, publicKey: Self.testKey, now: .distantFuture).isValid)
        #expect(read(Self.lifetimeTest) == .failure(.testKey))
        #expect(try read(Self.lifetimeTest, allowTest: true).get().isTest)
        #expect(read(Self.otherApp) == .failure(.wrongApp))
    }

    @Test("SS1 keys still count, as lifetime keys")
    func legacy() throws {
        let license = try read(SupporterKeyTests.swiftlyNamed).get()
        #expect(license.isLegacy && license.plan == .lifetime && license.expiresAt == nil)
        #expect(license.id == "0123456789abcdef")
    }

    @Test("Tampering with an SS2 key fails, also with the SS1 domain")
    func tampered() throws {
        let chars = Array(Self.monthly)
        for i in stride(from: 4, to: chars.count - 1, by: 17) {
            var c = chars
            c[i] = c[i] == "A" ? "B" : "A"
            #expect(!SupporterKey.verify(String(c), publicKey: Self.testKey, now: Self.purchased).isValid, "position \(i)")
        }
        #expect(read("SS1-" + Self.monthly.dropFirst(4)) != read(Self.monthly))
        #expect(!SupporterKey.verify(Self.monthly, now: Self.purchased).isValid)
        // Forgiving paste works the same as for SS1.
        #expect(try read("  " + Self.lifetime.lowercased() + "\n").get().id == Self.lifetimeID)
    }
}

/// A transport that answers from a closure and remembers what was sent.
final class FakeTransport: SupporterLicenseTransport, @unchecked Sendable {
    var sent: [String] = []
    let answer: @Sendable (String) -> (Int, String)?

    init(_ answer: @escaping @Sendable (String) -> (Int, String)?) { self.answer = answer }

    func post(_ url: URL, body: Data) async throws -> (status: Int, body: Data) {
        let text = String(decoding: body, as: UTF8.self)
        sent.append(text)
        guard let (status, body) = answer(text) else { throw URLError(.notConnectedToInternet) }
        return (status, Data(body.utf8))
    }
}

@Suite("Supporter key keeper", .serialized)
struct SupporterKeyKeeperTests {
    typealias V = SupporterKeyV2Tests

    func keeper(_ transport: FakeTransport) -> SupporterKeyKeeper {
        SupporterKeyKeeper(store: SupportStore(storage: InMemorySupportStorage()),
                           publicKey: V.testKey, transport: transport)
    }

    @Test("Activating stores the key, status and plan; no request right away")
    func activate() async {
        let transport = FakeTransport { _ in (200, #"{"state":"active"}"#) }
        let k = keeper(transport)
        #expect(k.activate(V.monthly, now: V.purchased).isValid)
        #expect(k.storedKey == V.monthly)
        #expect(k.store.status == .supporter(source: .key, since: V.purchased))
        #expect(k.store.plan == .monthly)
        #expect(await k.refreshIfDue(now: V.purchased.addingTimeInterval(3600)) == .notDue)
        #expect(transport.sent.isEmpty)
        #expect(!k.activate("SS2-AAAA", now: V.purchased).isValid)
        #expect(k.storedKey == V.monthly)
    }

    @Test("Every refusal has its own friendly line; the status stays off")
    func friendlyRefusals() {
        let k = keeper(FakeTransport { _ in nil })
        func line(_ text: String, allowTest: Bool = false, now: Date = V.purchased) -> String {
            guard case let .invalid(failure) = k.activate(text, now: now) else { return "valid" }
            return SupportCopy.keyMessage(for: failure).en
        }
        #expect(line(V.monthly, now: V.expires) == SupportCopy.keyExpired.en)
        #expect(line("") == SupportCopy.keyIncomplete.en)
        #expect(line("SS2-AIAA") == SupportCopy.keyIncomplete.en)
        #expect(line("hello") == SupportCopy.keyIncomplete.en)
        #expect(line(V.lifetimeTest) == SupportCopy.keyTest.en)
        #expect(line(V.otherApp) == SupportCopy.keyOtherApp.en)
        var broken = Array(V.lifetime); broken[20] = broken[20] == "A" ? "B" : "A"
        #expect(line(String(broken)) == SupportCopy.keyInvalid.en)
        #expect(k.store.status == .none)
        #expect(k.storedKey == nil)
    }

    @Test("A restart keeps the key: lifetime stays, monthly lapses and returns with a renewal")
    func restart() {
        let storage = InMemorySupportStorage()
        func launch() -> SupporterKeyKeeper {
            SupporterKeyKeeper(store: SupportStore(storage: storage), publicKey: V.testKey,
                               transport: FakeTransport { _ in nil })
        }
        launch().activate(V.monthly, now: V.purchased)
        let again = launch()
        again.applyExpiry(now: V.expires.addingTimeInterval(-86_400))
        #expect(again.store.status.isSupporter && again.store.plan == .monthly)
        let late = launch()
        late.applyExpiry(now: V.expires.addingTimeInterval(86_400))
        #expect(!late.store.status.isSupporter)
        // Pasting the renewed key (as from the mail) switches it on again.
        #expect(late.activate(V.monthlyLater, now: V.expires.addingTimeInterval(86_400)).isValid)
        #expect(late.store.status.isSupporter)
        // A lifetime key never lapses, even far in the future.
        let life = launch()
        life.activate(V.lifetime, now: V.purchased)
        life.applyExpiry(now: V.purchased.addingTimeInterval(20 * 365 * 86_400))
        #expect(life.store.status.isSupporter && life.store.plan == .lifetime)
    }

    @Test("Near the expiry day the renewed key replaces the old one")
    func renew() async {
        let transport = FakeTransport { _ in (200, #"{"state":"active","key":"\#(V.monthlyLater)"}"#) }
        let k = keeper(transport)
        k.activate(V.monthly, now: V.purchased)
        let soon = V.expires.addingTimeInterval(-5 * 86_400)
        #expect(await k.refreshIfDue(now: soon) == .renewed)
        #expect(transport.sent == ["id=" + V.monthlyID])
        #expect(k.storedKey == V.monthlyLater)
        #expect(k.license?.expiresAt == V.expiresLater)
        // Checked just now: not again within 12 hours.
        #expect(await k.refreshIfDue(now: soon.addingTimeInterval(3600)) == .notDue)
    }

    @Test("An expired key turns the status off, a late renewal turns it back on")
    func expiryAndLateRenewal() async {
        let transport = FakeTransport { _ in nil }
        let k = keeper(transport)
        k.activate(V.monthly, now: V.purchased)
        k.applyExpiry(now: V.expires)
        #expect(k.store.status == .none)
        #expect(k.storedKey == V.monthly)
        #expect(await k.refreshIfDue(now: V.expires) == .failed)
        #expect(k.store.status == .none)

        let online = FakeTransport { _ in (200, #"{"state":"active","key":"\#(V.monthlyLater)"}"#) }
        let k2 = SupporterKeyKeeper(store: k.store, publicKey: V.testKey, transport: online)
        #expect(await k2.refreshIfDue(now: V.expires.addingTimeInterval(86_400)) == .renewed)
        #expect(k2.store.status == .supporter(source: .key, since: V.purchased))
    }

    @Test("Refunds remove the key; a key for another licence or an older one is ignored")
    func revokedAndForeign() async {
        let revoked = FakeTransport { _ in (200, #"{"state":"revoked"}"#) }
        let k = keeper(revoked)
        k.activate(V.lifetime, now: V.purchased)
        #expect(await k.refreshIfDue(now: V.purchased.addingTimeInterval(10 * 86_400)) == .notDue)
        #expect(await k.refreshIfDue(now: V.purchased.addingTimeInterval(31 * 86_400)) == .revoked)
        #expect(k.storedKey == nil && k.store.status == .none)

        let foreign = FakeTransport { _ in (200, #"{"state":"active","key":"\#(V.lifetime)"}"#) }
        let k2 = keeper(foreign)
        k2.activate(V.monthly, now: V.purchased)
        #expect(await k2.refreshIfDue(now: V.expires.addingTimeInterval(-86_400)) == .unchanged)
        #expect(k2.storedKey == V.monthly)

        let older = FakeTransport { _ in (200, #"{"state":"active","key":"\#(V.monthly)"}"#) }
        let k3 = keeper(older)
        k3.activate(V.monthlyLater, now: V.purchased)
        #expect(await k3.refreshIfDue(now: V.expiresLater.addingTimeInterval(-86_400)) == .unchanged)
        #expect(k3.storedKey == V.monthlyLater)
    }

    @Test("Server errors and unknown answers change nothing")
    func errorsChangeNothing() async {
        for answer in [(500, "oops"), (200, "not json"), (200, #"{"state":"unknown"}"#)] {
            let k = keeper(FakeTransport { _ in answer })
            k.activate(V.lifetime, now: V.purchased)
            _ = await k.refreshIfDue(now: V.purchased.addingTimeInterval(40 * 86_400))
            #expect(k.storedKey == V.lifetime)
            #expect(k.store.status == .supporter(source: .key, since: V.purchased))
        }
    }

    @Test("A store purchase is never touched by key expiry")
    func storeStatusUntouched() {
        let k = keeper(FakeTransport { _ in nil })
        k.activate(V.monthly, now: V.purchased)
        k.store.status = .supporter(source: .store, since: nil)
        k.applyExpiry(now: V.expiresLater)
        #expect(k.store.status == .supporter(source: .store, since: nil))
    }
}

/// End-to-end check against a key from the shop's test mode. Runs only when
/// `SUPPORTER_E2E_FILE` points to a JSON file `{"key": "SS2-…", "pk": "<Base64 public key>"}`.
@Suite("Supporter key from shop test mode")
struct SupporterKeyShopE2ETests {
    static let file = ProcessInfo.processInfo.environment["SUPPORTER_E2E_FILE"]

    @Test(.enabled(if: file != nil))
    func keyFromTestPurchaseVerifies() throws {
        let path = try #require(Self.file)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try #require(object as? [String: String])
        let base64 = try #require(json["pk"])
        let publicKey = try #require(SupporterKey.decodePublicKey(base64))
        let key = try #require(json["key"])
        let license = try SupporterKey.read(key, publicKey: publicKey, allowTestKeys: true).get()
        #expect(license.isTest)
        #expect(!license.isLegacy)
        #expect(SupporterKey.verify(key, publicKey: publicKey, allowTestKeys: true).isValid)
        // Test keys never pass a release check.
        #expect(SupporterKey.verify(key, publicKey: publicKey) == .invalid(.testKey))
        print("E2E \(license.plan) id=\(license.id) expires=\(license.expiresAt.map { "\($0)" } ?? "never")")
    }
}
