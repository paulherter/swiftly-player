import Foundation
import Testing

@testable import SwiftlyCore

/// The core's `AccountsModel` reads the Keychain bundle bytes the Swift app wrote (`ServerBundles`:
/// `konten`, `konten.emby`, `konten.plex`) and writes bytes the Swift app reads back.
@Suite("Accounts (Keychain bundle bytes stay the same)")
struct AccountsParityTests {
    private let jellyfin =
        #"{"konten":[{"accessToken":"t","userID":"1","userName":"paul","serverURL":"https://jellyfin.example.com"},"#
        + #"{"accessToken":"u","userID":"2","userName":"eltern","serverURL":"https://jellyfin.example.com"}],"aktiveKennung":"2"}"#

    private func model(_ secrets: FakeSecrets) throws -> AccountsModel {
        let core = Core(
            platform: FakePlatform(), secrets: secrets, store: MemoryKeyValue(), http: testHttp())
        return try core.accountsModel(deviceId: "test-device", locale: "de")
    }

    @Test func swiftWrittenBundleIsRead() throws {
        let secrets = FakeSecrets()
        secrets.set(name: "konten", value: jellyfin)
        secrets.set(name: "aktiveArt", value: "jellyfin")
        let accounts = try model(secrets).accounts()
        #expect(accounts.map(\.userName) == ["paul", "eltern"])
        #expect(accounts.first { $0.active }?.userId == "2")
        #expect(accounts.allSatisfy { $0.kind == .jellyfin })
    }

    @Test func switchingWritesTheSameBundleShape() throws {
        let secrets = FakeSecrets()
        secrets.set(name: "konten", value: jellyfin)
        secrets.set(name: "aktiveArt", value: "jellyfin")
        let accounts = try model(secrets)
        let first = try #require(accounts.accounts().first)
        #expect(accounts.switchTo(key: first.key)?.userId == "1")
        // The Swift `ServerBundles` decodes `{"konten":[...],"aktiveKennung":...}` with these keys.
        let written = try #require(secrets.get(name: "konten"))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(written.utf8)) as? [String: Any])
        // The pointer is the account key (server and user), like `Session.accountKey`.
        #expect(object["aktiveKennung"] as? String == first.key)
        #expect(first.key == "https://jellyfin.example.com|1")
        #expect((object["konten"] as? [[String: Any]])?.count == 2)
    }

    /// Old build writes, new build reads and writes, old build reads again (and writes), new build reads again.
    @Test func oldAndNewBuildsHandTheKeychainBackAndForth() throws {
        struct Bundle: Codable {
            struct Account: Codable { var accessToken, userID, userName, serverURL: String }
            var konten: [Account]
            var aktiveKennung: String
        }
        let secrets = FakeSecrets()
        secrets.set(name: "konten", value: jellyfin)
        secrets.set(name: "aktiveArt", value: "jellyfin")
        // New build reads and switches to the first account (writes).
        let first = try #require(try model(secrets).accounts().first)
        #expect(try model(secrets).switchTo(key: first.key)?.userId == "1")
        // Old build reads what the new one wrote: same accounts, the pointer moved, nothing else lost.
        var old = try JSONDecoder().decode(Bundle.self, from: Data(try #require(secrets.get(name: "konten")).utf8))
        #expect(old.konten.map(\.userName) == ["paul", "eltern"] && old.aktiveKennung == first.key)
        #expect(old.konten.map(\.accessToken) == ["t", "u"])
        // Old build writes: a third account, active.
        old.konten.append(.init(accessToken: "v", userID: "3", userName: "kind", serverURL: "https://other.example.com"))
        old.aktiveKennung = "https://other.example.com|3"
        secrets.set(name: "konten", value: String(decoding: try JSONEncoder().encode(old), as: UTF8.self))
        // New build reads the old build's write.
        let again = try model(secrets)
        #expect(again.accounts().map(\.userName) == ["paul", "eltern", "kind"])
        #expect(again.accounts().first { $0.active }?.userName == "kind")
        // New build removes it again (writes); old build reads that.
        _ = again.remove(key: "https://other.example.com|3")
        let back = try JSONDecoder().decode(Bundle.self, from: Data(try #require(secrets.get(name: "konten")).utf8))
        #expect(back.konten.map(\.userName) == ["paul", "eltern"])
    }
}
