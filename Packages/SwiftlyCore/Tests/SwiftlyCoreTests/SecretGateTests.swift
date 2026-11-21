import Foundation
import Security
import Testing

@testable import SwiftlyCore

/// A `-SwiftlyLiveMemory` run must never read or write the system Keychain: on a Mac or device with real accounts a
/// 401 signs the fixture account out and the app moves on to the next STORED account, so a test run could switch to
/// (or act on) a real one.
@Suite("Secret gate (memory-only live runs)", .serialized)
struct SecretGateTests {
    /// The query `Sources/Shared/Keychain.swift` builds, for the file keychain (an unsigned test host has no
    /// data-protection entitlement).
    private func query(_ service: String, _ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    @Test func memoryModeIsOnlyForADebugLiveMemoryRun() {
        #expect(ProofIsolation.memoryOnly(arguments: ["Swiftly", "-SwiftlyFixture", "http://127.0.0.1:1", "-SwiftlyLiveMemory"], debugBuild: true))
        #expect(!ProofIsolation.memoryOnly(arguments: ["Swiftly", "-SwiftlyFixture", "http://127.0.0.1:1"], debugBuild: true),
                "a fixture run that restarts must keep its stored accounts")
        #expect(!ProofIsolation.memoryOnly(arguments: ["Swiftly"], debugBuild: true))
        #expect(!ProofIsolation.memoryOnly(arguments: ["Swiftly", "-SwiftlyLiveMemory"], debugBuild: false),
                "a release build never switches")
    }

    @Test func memoryModeNeverWritesTheKeychain() {
        let service = "swiftly.gate.\(UUID().uuidString)"
        let secrets = KeychainSecretStore(service: service, dataProtection: false, gate: SecretGate(memoryOnly: true))
        secrets.set(name: "konten", value: #"{"konten":[]}"#)
        secrets.set(name: "konten", value: #"{"konten":[1]}"#)
        #expect(secrets.get(name: "konten") == #"{"konten":[1]}"#, "the run still reads back what it wrote")
        // The system Keychain, asked directly, has nothing under that service.
        #expect(SecItemCopyMatching(query(service, "konten") as CFDictionary, nil) == errSecItemNotFound)
        secrets.remove(name: "konten")
        #expect(secrets.get(name: "konten") == nil)
    }

    @Test func memoryModeNeverReadsTheKeychain() {
        let service = "swiftly.gate.\(UUID().uuidString)"
        let system = KeychainSecretStore(service: service, dataProtection: false, gate: SecretGate(memoryOnly: false))
        defer { system.remove(name: "konten") }
        var add = query(service, "konten")
        add[kSecValueData as String] = Data("stored account".utf8)
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            Issue.record("keychain not usable in this test host")
            return
        }
        #expect(system.get(name: "konten") == "stored account", "the system gate does read it")
        let memory = KeychainSecretStore(service: service, dataProtection: false, gate: SecretGate(memoryOnly: true))
        #expect(memory.get(name: "konten") == nil, "a memory run does not see a stored account")
        memory.remove(name: "konten")
        #expect(system.get(name: "konten") == "stored account", "and its remove leaves the stored account alone")
    }

    @Test func twoStoresOnOneMemoryGateShareEntries() {
        // The app's `Keychain` wrapper and the core's secrets are the same entries on the system Keychain, so they are
        // in memory too (the wrapper uses `SecretGate.shared`, the core's store the same gate).
        let gate = SecretGate(memoryOnly: true)
        let a = KeychainSecretStore(service: "swiftly.gate.shared", dataProtection: false, gate: gate)
        let b = KeychainSecretStore(service: "swiftly.gate.shared", dataProtection: false, gate: gate)
        a.set(name: "aktiveArt", value: "jellyfin")
        #expect(b.get(name: "aktiveArt") == "jellyfin")
        b.remove(name: "aktiveArt")
        #expect(a.get(name: "aktiveArt") == nil)
    }

    /// Nothing but the gate may talk to the Keychain for accounts: a new `SecItem…` call elsewhere would reopen the hole.
    @Test func onlyTheGateCallsTheKeychain() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 { root.deleteLastPathComponent() }   // Tests/SwiftlyCoreTests, Tests, SwiftlyCore, Packages, repo
        let folders = ["Sources/Shared", "Packages/SwiftlyCore/Sources/SwiftlyCore"].map { root.appendingPathComponent($0) }
        let calls = ["SecItemAdd", "SecItemCopyMatching", "SecItemUpdate", "SecItemDelete"]
        var checked = 0
        var offenders: [String] = []
        for folder in folders {
            let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" && file.lastPathComponent != "SecretGate.swift" {
                checked += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where calls.contains(where: { line.contains($0) }) && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    offenders.append("\(file.lastPathComponent):\(n + 1)")
                }
            }
        }
        #expect(checked > 50, "the source folders were not found")
        #expect(offenders.isEmpty, "SecItem call outside SecretGate: \(offenders)")
    }
}
