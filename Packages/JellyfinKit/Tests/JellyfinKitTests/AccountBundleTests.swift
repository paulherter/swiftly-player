import Foundation
import Testing
@testable import JellyfinKit

@Suite("Mehrere Konten auf demselben Server")
struct AccountBundleTests {

    private let server = URL(string: "https://jellyfin.example.com")!

    private func account(_ name: String, _ identifier: String) -> Session {
        Session(accessToken: "t-\(identifier)", userID: identifier,
                userName: name, serverURL: server)
    }

    @Test("Ein einzelnes Konto ist sofort das aktive")
    func single() {
        let bundle = AccountBundle(account("paul", "1"))
        #expect(bundle.accounts.count == 1)
        #expect(bundle.activeOne.userName == "paul")
    }

    @Test("Ein zweites Konto wird aufgenommen und gilt sofort")
    func second() {
        var bundle = AccountBundle(account("paul", "1"))
        bundle.record(account("eltern", "2"))
        #expect(bundle.accounts.count == 2)
        #expect(bundle.activeOne.userID == "2")
    }

    /// If the same account signs in again, it must not appear twice in the
    /// strip, and it must keep its place, otherwise the row jumps
    /// around on every expired session.
    @Test("Dieselbe Anmeldung ersetzt an Ort und Stelle, sie hängt nicht an")
    func replace() {
        var bundle = AccountBundle(account("paul", "1"))
        bundle.record(account("eltern", "2"))
        bundle.record(account("oma", "3"))
        bundle.record(Session(accessToken: "neu", userID: "2",
                               userName: "eltern", serverURL: server))
        #expect(bundle.accounts.count == 3)
        #expect(bundle.accounts[1].userID == "2")
        #expect(bundle.accounts[1].accessToken == "neu")
        #expect(bundle.activeOne.userID == "2")
    }

    @Test("Umschalten geht nur auf Konten, die es gibt")
    func switchTo() {
        var bundle = AccountBundle(account("paul", "1"))
        bundle.record(account("eltern", "2"))
        bundle.switchTo(toward: "1")
        #expect(bundle.activeOne.userID == "1")
        bundle.switchTo(toward: "gibtsnicht")
        #expect(bundle.activeOne.userID == "1")
    }

    /// The button is called "Abmelden" (sign out), not "Alle abmelden".
    @Test("Abmelden trifft nur das eine Konto")
    func removeLetsRemaining() throws {
        var bundle = AccountBundle(account("paul", "1"))
        bundle.record(account("eltern", "2"))
        let rest = try #require(bundle.removed("2"))
        #expect(rest.accounts.count == 1)
        #expect(rest.activeOne.userID == "1")
    }

    @Test("War es das aktive, gilt danach das folgende")
    func successorMovesUp() throws {
        var bundle = AccountBundle(account("paul", "1"))
        bundle.record(account("eltern", "2"))
        bundle.record(account("oma", "3"))
        bundle.switchTo(toward: "2")
        let rest = try #require(bundle.removed("2"))
        #expect(rest.activeOne.userID == "3")
    }

    @Test("Fällt das letzte in der Reihe weg, rückt das davor nach")
    func lastOneDropsOut() throws {
        var bundle = AccountBundle(account("paul", "1"))
        bundle.record(account("eltern", "2"))
        let rest = try #require(bundle.removed("2"))
        #expect(rest.activeOne.userID == "1")
    }

    @Test("Das letzte Konto zu entfernen heißt abgemeldet")
    func lastItem() {
        let bundle = AccountBundle(account("paul", "1"))
        #expect(bundle.removed("1") == nil)
    }

    @Test("Ein unbekanntes Konto zu entfernen ändert nichts")
    func unknown() throws {
        var bundle = AccountBundle(account("paul", "1"))
        bundle.record(account("eltern", "2"))
        let rest = try #require(bundle.removed("99"))
        #expect(rest.accounts.count == 2)
    }

    /// If the stored ID points nowhere (turned by hand in the keychain,
    /// or a bundle from an older version), the app should stay
    /// signed in and not end up without a session.
    @Test("Eine ins Leere zeigende Kennung fällt auf das erste Konto zurück")
    func brokenId() throws {
        let bundle = try #require(AccountBundle(accounts: [account("paul", "1"),
                                                    account("eltern", "2")],
                                           active: "weg"))
        #expect(bundle.activeOne.userID == "1")
    }

    @Test("Ohne Konten gibt es keinen Bund")
    func empty() {
        #expect(AccountBundle(accounts: [], active: nil) == nil)
    }

    /// Both spellings occur: one from the user's input, the other
    /// from our normalization.
    @Test("Der Server mit und ohne Schrägstrich am Ende ist derselbe")
    func slash() {
        let bundle = AccountBundle(account("paul", "1"))
        let withLine = Session(accessToken: "t", userID: "2", userName: "eltern",
                                serverURL: URL(string: "https://jellyfin.example.com/")!)
        #expect(bundle.fitsServer(withLine))
    }

    @Test("Ein anderer Server passt nicht in denselben Bund")
    func otherServer() {
        let bundle = AccountBundle(account("paul", "1"))
        let foreign = Session(accessToken: "t", userID: "2", userName: "x",
                            serverURL: URL(string: "https://anders.example")!)
        #expect(!bundle.fitsServer(foreign))
    }

    @Test("Ein Bund übersteht Sichern und Zurücklesen")
    func codable() throws {
        var bundle = AccountBundle(account("paul", "1"))
        bundle.record(account("eltern", "2"))
        bundle.switchTo(toward: "1")
        let back = try JSONDecoder().decode(
            AccountBundle.self, from: JSONEncoder().encode(bundle))
        #expect(back == bundle)
        #expect(back.activeOne.userID == "1")
    }
}

@Suite("Aufnehmen und Ablage")
struct AccountBundleStoreTests {

    private let server = URL(string: "https://jellyfin.example.com")!
    private func account(_ name: String, _ identifier: String) -> Session {
        Session(accessToken: "t-\(identifier)", userID: identifier,
                userName: name, serverURL: server)
    }

    @Test("Ohne vorhandenen Bund ist es kein Wechsel")
    func firstLogin() {
        let (bundle, change) = AccountBundle.record(account("paul", "1"), in: nil)
        #expect(!change)
        #expect(bundle.accounts.count == 1)
    }

    @Test("Ein zweites Konto auf demselben Server ist ein Wechsel")
    func secondAccount() {
        let firstly = AccountBundle(account("paul", "1"))
        let (bundle, change) = AccountBundle.record(account("eltern", "2"), in: firstly)
        #expect(change)
        #expect(bundle.accounts.count == 2)
        #expect(bundle.activeOne.userID == "2")
    }

    /// A different server no longer starts over; it is added like
    /// another account.
    @Test("Ein anderer Server kommt dazu, statt neu anzufangen")
    func otherServer() {
        let firstly = AccountBundle(account("paul", "1"))
        let foreign = Session(accessToken: "t", userID: "9", userName: "x",
                            serverURL: URL(string: "https://anders.example")!)
        let (bundle, change) = AccountBundle.record(foreign, in: firstly)
        #expect(change)
        #expect(bundle.accounts.count == 2)
        #expect(bundle.activeOne.userID == "9")
        #expect(bundle.server.count == 2)
        #expect(bundle.serverURL == URL(string: "https://anders.example")!)
    }

    @Test("Dieselbe Anmeldung noch einmal gilt als Wechsel, nicht als Neuanfang")
    func sameAgain() {
        let firstly = AccountBundle(account("paul", "1"))
        let (bundle, change) = AccountBundle.record(account("paul", "1"), in: firstly)
        #expect(change)
        #expect(bundle.accounts.count == 1)
    }

    @Test("Aus der Ablage kommt der Bund, wenn einer da ist")
    func storeBundle() throws {
        var b = AccountBundle(account("paul", "1"))
        b.record(account("eltern", "2"))
        b.switchTo(toward: "1")
        let data = try JSONEncoder().encode(b)
        let single = try JSONEncoder().encode(account("wer", "9"))
        let back = try #require(AccountBundle.outStore(bundle: data, individual: single))
        #expect(back == b)
    }

    /// The path for everyone who signed in before multiple accounts.
    @Test("Ohne Bund wird die einzelne Sitzung von früher übernommen")
    func storeTakeover() throws {
        let single = try JSONEncoder().encode(account("paul", "1"))
        let back = try #require(AccountBundle.outStore(bundle: nil, individual: single))
        #expect(back.accounts.count == 1)
        #expect(back.activeOne.userID == "1")
    }

    @Test("Ist nichts da, kommt nichts zurück")
    func storeEmpty() {
        #expect(AccountBundle.outStore(bundle: nil, individual: nil) == nil)
    }

    /// An unreadable bundle must not cost the sign-in as long as the old
    /// single session is still there.
    @Test("Ein kaputter Bund fällt auf die einzelne Sitzung zurück")
    func storeBroken() throws {
        let single = try JSONEncoder().encode(account("paul", "1"))
        let garbage = Data("kein JSON".utf8)
        let back = try #require(AccountBundle.outStore(bundle: garbage, individual: single))
        #expect(back.activeOne.userID == "1")
    }
    /// **The case that would have cost Linux and Windows the sign-in.**
    ///
    /// There the old storage was passed on raw, although it uses different
    /// key names (`token`, `userIdentifier`, `username`); three of
    /// four did not match, `try?` swallowed it, and every existing
    /// user faced the sign-in screen after updating.
    ///
    /// On the Apple side this cannot happen, because the same
    /// `Session` writes with the same names. This test pins exactly that, with
    /// **literal** JSON instead of a fresh encoding: otherwise it would only check
    /// that our encoder matches our decoder, and would silently go along
    /// with a rename.
    @Test("Die alte Apple-Ablage wird wörtlich übernommen")
    func oldAppleStore() throws {
        let alt = Data("""
        {"accessToken":"t-1","userID":"1","userName":"paul",
         "serverURL":"https://jellyfin.example.com"}
        """.utf8)
        let bundle = try #require(AccountBundle.outStore(bundle: nil, individual: alt))
        #expect(bundle.activeOne.userID == "1")
        #expect(bundle.activeOne.userName == "paul")
        #expect(bundle.activeOne.accessToken == "t-1")
    }

    /// And the control: if the keys are named differently, nothing comes back,
    /// not a half-filled bundle.
    @Test("Fremde Schlüsselnamen liefern nichts, nicht Halbfertiges")
    func foreignKey() {
        let foreign = Data("""
        {"token":"t-1","benutzerID":"1","benutzername":"paul",
         "serverURL":"https://jellyfin.example.com"}
        """.utf8)
        #expect(AccountBundle.outStore(bundle: nil, individual: foreign) == nil)
    }
    /// Literal, as the GTK version wrote it, not via a fresh
    /// encoding. That is exactly what it hinged on: three of four
    /// names do not match `Session`.
    @Test("Die alte GTK-Ablage wird übersetzt, nicht durchgereicht")
    func oldGtkStore() throws {
        let alt = Data("""
        {"serverURL":"https://jellyfin.example.com","token":"t-1",
         "benutzerID":"1","benutzername":"paul","servername":"Testkiste"}
        """.utf8)
        let s = try #require(AccountBundle.outOldGtkStore(alt))
        #expect(s.accessToken == "t-1")
        #expect(s.userID == "1")
        #expect(s.userName == "paul")
        #expect(s.serverURL.absoluteString == "https://jellyfin.example.com")
    }

    /// And the path taken without translation: it returns nothing.
    /// The test pins down **why** the translation is needed.
    @Test("Ohne Übersetzung liefert die alte GTK-Ablage nichts")
    func gtkStoreWithoutTranslation() {
        let alt = Data("""
        {"serverURL":"https://jellyfin.example.com","token":"t-1",
         "benutzerID":"1","benutzername":"paul"}
        """.utf8)
        #expect(AccountBundle.outStore(bundle: nil, individual: alt) == nil)
    }
}

@Suite("Mehrere Server")
struct AccountBundleServerTests {

    private let homeBase = URL(string: "https://jellyfin.example.com")!
    private let secondary = URL(string: "https://jellyfin2.example.com")!
    private func account(_ name: String, _ identifier: String, _ server: URL) -> Session {
        Session(accessToken: "t-\(identifier)", userID: identifier, userName: name, serverURL: server)
    }

    @Test("Dieselbe Benutzerkennung auf zwei Servern sind zwei Konten")
    func sameId() {
        var bundle = AccountBundle(account("paul", "1", homeBase))
        bundle.record(account("paul", "1", secondary))
        #expect(bundle.accounts.count == 2)
        #expect(bundle.activeOne.serverURL == secondary)
    }

    @Test("Wechseln über den Schlüssel trifft den richtigen Server")
    func switchServer() {
        var bundle = AccountBundle(account("paul", "1", homeBase))
        bundle.record(account("paul", "1", secondary))
        bundle.switchTo(toward: account("paul", "1", homeBase).accountKey)
        #expect(bundle.activeOne.serverURL == homeBase)
    }

    @Test("Die Konten eines Servers, in ihrer Reihenfolge")
    func accountsJeServer() {
        var bundle = AccountBundle(account("paul", "1", homeBase))
        bundle.record(account("gast", "5", secondary))
        bundle.record(account("eltern", "2", homeBase))
        #expect(bundle.server == [homeBase, secondary])
        #expect(bundle.accounts(on: homeBase).map(\.userName) == ["paul", "eltern"])
        #expect(bundle.accounts(on: secondary).map(\.userName) == ["gast"])
    }

    @Test("Abmelden auf einem Server lässt den anderen stehen")
    func signOutInServer() {
        var bundle = AccountBundle(account("paul", "1", homeBase))
        bundle.record(account("gast", "5", secondary))
        let rest = bundle.removed(account("gast", "5", secondary).accountKey)
        #expect(rest?.accounts.count == 1)
        #expect(rest?.activeOne.serverURL == homeBase)
    }

    @Test("Ein gemerkter Bund mit bloßer Benutzerkennung liest sich weiter")
    func oldId() throws {
        let json = #"{"konten":[{"accessToken":"t","userID":"1","userName":"paul","serverURL":"https://jellyfin.example.com"},{"accessToken":"u","userID":"2","userName":"eltern","serverURL":"https://jellyfin.example.com"}],"aktiveKennung":"2"}"#
        let bundle = try JSONDecoder().decode(AccountBundle.self, from: Data(json.utf8))
        #expect(bundle.activeOne.userName == "eltern")
    }
}
