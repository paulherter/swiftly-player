import Foundation
import Testing
@testable import JellyfinKit

/// What sits in storage is older than the code that reads it.
///
/// **The bug these checks catch.** Swift's generated
/// `init(from:)` requires **every** key. Adding a field to a stored
/// struct makes every file written before the change unreadable, and
/// because both read sites use `try?`, nobody throws an error: the app
/// starts, looks normal, and has simply forgotten everything.
///
/// It has happened twice, both times silently:
///
/// - Apple: the old storage was passed on raw, three of
///   four keys did not match, **every existing user faced the sign-in
///   screen after updating.** On a machine with new storage none of this
///   is visible; it was only noticed because a test machine still carried
///   the old state.
/// - Linux: two new keys were missing in `wahlen.json`,
///   `decode` threw, and `read()` returned the defaults without a word. **All
///   settings gone**, and an app with default values looks normal.
///
/// **Why frozen text and not `encode` followed by `decode`.** A
/// round trip checks the code against itself and therefore always succeeds;
/// it would have found neither case. Only a string that
/// *stands there* measures against an earlier version. That is why the text below
/// is neither generated nor adjusted.
///
/// **What to do when one of these checks breaks.** Do not update the text;
/// that switches off exactly the alarm it is there for. Make the
/// new field **optional** so old storage stays readable.
/// Only then add an *additional* section for the new version;
/// the old one stays.
///
/// **A default value does not save you.** Measured on this check,
/// because the assumption is obvious and wrong:
///
///     public var neuesFeld: Bool = false   -> check BREAKS
///     public var neuesFeld: Bool?          -> check passes
///
/// The generated `init(from:)` requires the key even when the
/// declaration has a value next to it; the default applies to the
/// memberwise init, not to reading. Whoever relies on it considers a
/// struct backward compatible that is not.
@Suite("Ablagen aus früheren Fassungen bleiben lesbar")
struct StoreVersionTests {

    /// An accounts bundle as written by the shipped version 1.0.1.
    /// Frozen text. Do not touch; see above.
    private let bundleLike101 = Data("""
    {
      "konten": [
        {
          "accessToken": "abc123",
          "userID": "u-1",
          "userName": "paul",
          "serverURL": "https://jellyfin.example.com"
        },
        {
          "accessToken": "def456",
          "userID": "u-2",
          "userName": "eltern",
          "serverURL": "https://jellyfin.example.com"
        }
      ],
      "aktiveKennung": "u-2"
    }
    """.utf8)

    /// A single session from before multiple accounts.
    /// Frozen text. Do not touch.
    private let singleHowEarlier = Data("""
    {
      "accessToken": "abc123",
      "userID": "u-1",
      "userName": "paul",
      "serverURL": "https://jellyfin.example.com"
    }
    """.utf8)

    @Test("Ein Bund aus 1.0.1 wird vollständig gelesen")
    func bundleStaysReadable() throws {
        // Comment takes only a literal, not a composed string.
        let bundle = try #require(AccountBundle.outStore(bundle: bundleLike101, individual: nil),
                                "Ein neues Feld ohne Vorgabewert macht jede aeltere Ablage unlesbar, und ausAblage verschluckt das mit try?")
        #expect(bundle.accounts.count == 2)
        #expect(bundle.activeOne.userID == "u-2")
        #expect(bundle.activeOne.userName == "eltern")
        #expect(bundle.accounts[0].accessToken == "abc123")
        #expect(bundle.serverURL.host() == "jellyfin.example.com")
    }

    @Test("Eine Einzelsitzung von früher wird weiter übernommen")
    func singleStaysReadable() throws {
        let bundle = try #require(AccountBundle.outStore(bundle: nil, individual: singleHowEarlier))
        #expect(bundle.accounts.count == 1)
        #expect(bundle.activeOne.userName == "paul")
        #expect(bundle.activeOne.accessToken == "abc123")
    }

    /// The reverse path: an older version reads what a newer one
    /// wrote. That happens as soon as someone switches back or
    /// two devices are at different versions.
    @Test("Ein unbekannter Schlüssel in der Ablage stört nicht")
    func newStoreDisturbNot() throws {
        let withAddition = Data("""
        {
          "konten": [
            {
              "accessToken": "abc123",
              "userID": "u-1",
              "userName": "paul",
              "serverURL": "https://jellyfin.example.com",
              "einFeldAusDerZukunft": 42
            }
          ],
          "aktiveKennung": "u-1",
          "nochEinsAusDerZukunft": ["a", "b"]
        }
        """.utf8)
        let bundle = try #require(AccountBundle.outStore(bundle: withAddition, individual: nil))
        #expect(bundle.accounts.count == 1)
        #expect(bundle.activeOne.userName == "paul")
    }

    /// The rule is not limited to the bundle. Whoever stores another structure
    /// permanently adds its frozen text here; that is
    /// cheaper than the evening someone finds out why everyone
    /// is signed out.
    @Test("Session allein bleibt aus eigenem Recht lesbar")
    func sessionStaysReadable() throws {
        let session = try JSONDecoder().decode(Session.self, from: singleHowEarlier)
        #expect(session.userID == "u-1")
        #expect(session.serverURL.absoluteString == "https://jellyfin.example.com")
    }
}
