#if DEBUG
import AppKit
import Foundation
import JellyfinKit

/// **`-SwiftlyPruneFixtureAccounts`: removes the made-up accounts that old fixture runs left in the real Keychain items.**
///
/// A development build only (compiled out of Release). Run once with the real app quit: it lists the saved accounts
/// through the app's own store (`ServerBundles` over `Keychain`, removal through `AccountsHost`), writes a backup first
/// (addresses and user names, no tokens), removes only the accounts whose server is on this machine
/// (`FixtureAccountPrune`), logs the counts and quits. Real servers and Plex accounts with a real address stay.
@MainActor
enum PruneFixtureAccounts {
    static let flag = "-SwiftlyPruneFixtureAccounts"

    /// Runs the clean-up and ends the process when the launch asks for it; does nothing otherwise.
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(flag) else { return }
        let code = run()
        AppLog.writeOut("[Prune] done, exit \(code)")
        exit(code)
    }

    private static func all() -> [Session] {
        let stored = ServerBundles.load { Keychain.load(key: $0) }
        return stored.kinds.flatMap { stored.bundle(for: $0)?.accounts ?? [] }
    }

    private static func run() -> Int32 {
        let before = all()
        let doomed = FixtureAccountPrune.selection(from: before)
        AppLog.writeOut("[Prune] before: \(before.count) accounts, \(doomed.count) on this machine")

        // The backup comes first; without it nothing is removed.
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmm"
            return f.string(from: Date())
        }()
        let name = "mac-konten-\(stamp).json"
        let wanted = URL(fileURLWithPath: "/Users/paul/Documents/Swiftly/Sicherungen/\(name)")
        let fallback = AppLog.path.deletingLastPathComponent().appendingPathComponent(name)
        var written: URL?
        if let data = try? FixtureAccountPrune.backup(of: before) {
            for target in [wanted, fallback] where (try? data.write(to: target)) != nil {
                written = target
                break
            }
        }
        guard let written else {
            AppLog.writeOut("[Prune] backup failed, nothing removed")
            return 2
        }
        AppLog.writeOut("[Prune] backup: \(written.path)")

        for s in doomed { AccountsHost.shared.remove(key: s.accountKey) }

        let after = all()
        AppLog.writeOut("[Prune] after: \(after.count) accounts, hosts: "
            + Set(after.compactMap { $0.serverURL.host(percentEncoded: false) }).sorted().joined(separator: ","))
        return after.count == before.count - doomed.count ? 0 : 3
    }
}
#endif
