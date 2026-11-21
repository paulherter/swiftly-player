import Foundation

/// **Proof and fixture launches never touch the real app's accounts.**
///
/// A DEBUG build started with a fixture server or a proof hook (`-SwiftlyFixture`, `-SwiftlyProof…`, `-SwiftlyLive…`,
/// `-SwiftlyOpen…`, `-testsitzung`) signs a made-up "demo" account in. Those runs use the same bundle id as the real app, so
/// without this the account landed in the real Keychain entries and showed up in the account list, one per run. They get
/// their own Keychain service instead; a Release build has no such switch and always uses the real one.
public enum ProofIsolation {
    public static let realKeychainService = "de.paulherter.swiftly"
    public static let proofKeychainService = "de.paulherter.swiftly.proof"

    /// Whether `arguments` start a proof or fixture run.
    public static func isProofRun(_ arguments: [String]) -> Bool {
        arguments.contains { arg in
            arg == "-SwiftlyFixture" || arg == "-testsitzung" || arg == "-testsitzung2"
                || arg.hasPrefix("-SwiftlyProof") || arg.hasPrefix("-SwiftlyLive") || arg.hasPrefix("-SwiftlyOpen")
        }
    }

    /// The Keychain service this launch reads and writes: the real one, except in a DEBUG proof run.
    public static func keychainService(arguments: [String] = ProcessInfo.processInfo.arguments) -> String {
        service(arguments: arguments, debugBuild: isDebugBuild)
    }

    /// The same decision with the build kind given (for tests).
    public static func service(arguments: [String], debugBuild: Bool) -> String {
        debugBuild && isProofRun(arguments) ? proofKeychainService : realKeychainService
    }

    /// Whether this launch keeps accounts and secrets in memory only (`SecretGate`): a DEBUG `-SwiftlyLiveMemory` run. It then
    /// reads no stored account and writes none, not even into the proof service; a Release build never does.
    public static func usesMemoryOnly(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        memoryOnly(arguments: arguments, debugBuild: isDebugBuild)
    }

    /// The same decision with the build kind given (for tests).
    public static func memoryOnly(arguments: [String], debugBuild: Bool) -> Bool {
        debugBuild && arguments.contains("-SwiftlyLiveMemory")
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
