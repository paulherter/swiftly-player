import Foundation
import JellyfinKit

/// Where the login is stored between launches.
///
/// **On Apple this is the Keychain; here it is a file.** Linux has no
/// system-wide keychain to rely on: depending on the desktop it is GNOME
/// Keyring, KWallet or nothing, and they all speak different protocols. A
/// file with mode `0600` in `~/.config` is the honest replacement: only the
/// own user can read it, and it is where other programs keep their
/// credentials too.
///
/// **What is stored is an access token, not a password.** The password goes
/// to the server once and is never stored; what comes back is a token that
/// can be revoked on the server.
enum Cache {

    struct Stored: Codable {
        enum CodingKeys: String, CodingKey {
            case serverURL
            case token
            case userIdentifier = "benutzerID"
            case username = "benutzername"
            case serverName = "servername"
        }
        let serverURL: URL
        let token: String
        let userIdentifier: String
        let username: String
        let serverName: String?
    }

    private static var folder: URL { Platform.settingFolder }

    /// **Owner only.** The file holds the server's access token; on a machine
    /// with several accounts anyone else could read it otherwise.
    ///
    /// Windows has no Unix permissions. The folder is under `%APPDATA%` and is
    /// only readable by its owner through the system's access list anyway; the
    /// setting would not just be ineffective there but would throw an error on
    /// creation.
    private static var onlyIch: [FileAttributeKey: Any] {
        #if os(Windows)
        return [:]
        #else
        return [.posixPermissions: 0o700]
        #endif
    }

    private static var file: URL { folder.appendingPathComponent("sitzung.json") }

    static func read() -> Stored? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    static func write(_ entryRecord: Stored) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: onlyIch)
            let data = try JSONEncoder().encode(entryRecord)
            try data.write(to: file, options: [.atomic])
            // **Only after writing.** `write(options:.atomic)` creates a new file and
            // renames it; permissions set beforehand would be gone afterwards.
            #if !os(Windows)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: file.path)
            #endif
        } catch {
            FileHandle.standardError.write(
                Data("Sitzung ließ sich nicht sichern: \(error.localizedDescription)\n".utf8))
        }
    }

    // MARK: Seerr

    /// **The Seerr credentials sit next to the session, not in a keychain.**
    ///
    /// On the Apple builds they go into the Keychain, because the cookie grants
    /// access to a service that can request titles. There is no counterpart here
    /// without a new dependency (libsecret), so it uses the same storage as the
    /// session with the same permissions: folder 0700, file 0600. That is weaker
    /// than a keychain and is stated openly instead of presented as equivalent.
    private static var seerrFile: URL { folder.appendingPathComponent("seerr.json") }

    static func seerrRead() -> SeerrAccess? {
        guard let data = try? Data(contentsOf: seerrFile) else { return nil }
        return try? JSONDecoder().decode(SeerrAccess.self, from: data)
    }

    static func seerrWrite(_ access: SeerrAccess?) {
        guard let access else {
            try? FileManager.default.removeItem(at: seerrFile)
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: onlyIch)
            try JSONEncoder().encode(access).write(to: seerrFile, options: [.atomic])
            #if !os(Windows)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: seerrFile.path)
            #endif
        } catch {
            FileHandle.standardError.write(
                Data("Seerr-Zugang ließ sich nicht sichern: \(error.localizedDescription)\n".utf8))
        }
    }

    // MARK: Custom headers (issue #4)

    /// The whole table from ``OwnHeaders``, **readable by the owner only** like
    /// the session, since the values are credentials.
    private static var headersFile: URL { folder.appendingPathComponent("eigenkoepfe.json") }

    /// At startup, before the first request.
    static func headersLoad() {
        OwnHeaders.load(try? Data(contentsOf: headersFile))
    }

    /// Set and store. An empty list removes the server; only the names go into
    /// the log.
    static func headersSafe(_ headers: [OwnHeader], for server: URL) {
        OwnHeaders.setDown(headers, for: server)
        let panel = OwnHeaders.store()
        guard panel != Data("{}".utf8) else {
            try? FileManager.default.removeItem(at: headersFile)
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: onlyIch)
            try panel.write(to: headersFile, options: [.atomic])
            #if !os(Windows)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: headersFile.path)
            #endif
        } catch {
            FileHandle.standardError.write(
                Data("Eigene Header ließen sich nicht sichern: \(error.localizedDescription)\n".utf8))
        }
    }

    static func erase() {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: accountsFile)
    }

    // MARK: Multiple accounts

    /// The account bundle as stored on disk.
    ///
    /// **Why the server name is included.** ``Kontenbund`` holds sessions, and a
    /// ``Session`` only knows the address. The server name is shown at the
    /// bottom of the bar and in the profile before ``serverStateFetch()`` has
    /// fetched it; without it a lone "·" would flash at startup.
    struct AccountsStore: Codable {
        enum CodingKeys: String, CodingKey {
            case bundle = "bund"
            case serverName = "servername"
        }
        var bundle: AccountBundle
        var serverName: String?
    }

    // MARK: - Downloads

    /// **The list, not the files.** Downloaded movies and episodes live in the
    /// downloads folder; the list only records what they are and how far they
    /// are. Mixing the two is the mistake an aborted download exposes: the file
    /// is half there, the list knows it, and only with both can it resume.
    private static var downloadFile: URL { folder.appendingPathComponent("downloads.json") }

    /// Where the downloaded files live: next to the list, not inside it.
    static var downloadFolder: URL { folder.appendingPathComponent("Downloads") }

    static func downloadsRead() -> [DownloadItem] {
        guard let data = try? Data(contentsOf: downloadFile) else { return [] }
        do {
            return try JSONDecoder().decode([DownloadItem].self, from: data)
        } catch {
            pagePut(downloadFile, because: error)
            return []
        }
    }

    /// **An unreadable file is set aside, not overwritten.**
    ///
    /// `try?` used to return an empty list and the next progress update wrote it
    /// out: a single corrupted file (power loss during a write, full disk) made
    /// **all** downloads vanish from the list while the movies stayed on disk,
    /// invisible and with no way to delete them. Now the old file is kept
    /// alongside and the log says why.
    static func pagePut(_ file: URL, because error: Error) {
        let stamp = Int(Date().timeIntervalSince1970)
        let target = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.lastPathComponent).kaputt-\(stamp)")
        try? FileManager.default.moveItem(at: file, to: target)
        AppLog.writeOut("[Ablage] \(file.lastPathComponent) unlesbar, beiseitegelegt: \(error)")
    }

    static func downloadsWrite(_ entries: [DownloadItem]) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: onlyIch)
            try JSONEncoder().encode(entries).write(to: downloadFile, options: [.atomic])
        } catch {
            FileHandle.standardError.write(
                Data("Downloadliste ließ sich nicht sichern: \(error.localizedDescription)\n".utf8))
        }
    }

    private static var accountsFile: URL { folder.appendingPathComponent("konten.json") }

    /// Reads the bundle and migrates a single session from before bundles.
    ///
    /// **The migration lives here and not in the package** because only this
    /// side knows where things are stored; Apple does the same in
    /// `AppModel.loadBundle()`. The old `sitzung.json` is **not deleted**: starting
    /// an older version again should not log the user out.
    /// What the bundle means is defined in the package:
    /// ``Kontenbund/ausAblage(bund:einzelne:)`` knows the migration from before
    /// multiple accounts and the fallback when the bundle is unreadable. Here
    /// only **where** the data lives.
    ///
    /// The middle tier is a leftover: an early version stored bundle and server
    /// name together in one wrapper. It stays so nobody has to sign in again; it
    /// is gone after the next write.
    static func readBundle() -> AccountsStore? {
        let accountsData = try? Data(contentsOf: accountsFile)
        if let b = AccountBundle.outStore(bundle: accountsData, individual: nil) {
            return AccountsStore(bundle: b, serverName: rememberedServer()?.serverName)
        }
        if let d = accountsData,
           let wrapper = try? JSONDecoder().decode(AccountsStore.self, from: d) {
            return wrapper
        }
        // **The old file has German keys, `Session` English ones.**
        //
        // `AccountBundle.ausAblage(bundle:individual:)` decodes the single entry as a
        // `Session`, which expects `accessToken`, `userID`, `userName`.
        // `sitzung.json` has `token`, `userIdentifier`, `username`; three of four
        // keys do not match, decoding fails silently and the migration returned
        // `nil`. Effect: **every user with a remembered login landed on the sign-in
        // screen after updating.**
        //
        // So the keys are mapped here instead of passed through raw: `Stored` is
        // this side's format, and only this side knows it.
        guard let alt = read() else { return nil }
        let session = Session(accessToken: alt.token, userID: alt.userIdentifier,
                              userName: alt.username, serverURL: alt.serverURL)
        return AccountsStore(bundle: AccountBundle(session), serverName: alt.serverName)
    }

    /// Writes the bundle **and keeps writing the single session next to it.**
    ///
    /// The old file stays at the state of the active account so an older version
    /// of the app does not face an empty sign-in screen after a downgrade. It
    /// costs a few hundred bytes and saves a sign-in.
    static func writeBundle(_ store: AccountsStore) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: onlyIch)
            // **The plain bundle, no wrapper.** This is what
            // ``Kontenbund/ausAblage(bund:einzelne:)`` reads directly; the server name
            // is in the notes anyway.
            try JSONEncoder().encode(store.bundle).write(to: accountsFile, options: [.atomic])
            #if !os(Windows)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: accountsFile.path)
            #endif
        } catch {
            FileHandle.standardError.write(
                Data("Konten liessen sich nicht sichern: \(error.localizedDescription)\n".utf8))
        }
        let active = store.bundle.activeOne
        write(.init(serverURL: active.serverURL, token: active.accessToken,
                        userIdentifier: active.userID, username: active.userName,
                        serverName: store.serverName))
    }

    // MARK: Last connected

    /// **The last used server, also after signing out.**
    ///
    /// Signing out used to delete everything, so the address field was empty at
    /// the next start and the address had to be typed again. The Mac keeps
    /// address, name and version separate from the session
    /// (`Shared/LoginModel.swift`): the credentials are gone, the way back to
    /// the server is not.
    struct RememberSlip: Codable {
        enum CodingKeys: String, CodingKey {
            case serverURL
            case serverName = "servername"
            case version = "fassung"
        }
        let serverURL: URL
        let serverName: String?
        let version: String?
    }

    private static var rememberFile: URL { folder.appendingPathComponent("server.json") }

    static func serverRemember(_ entryRecord: RememberSlip) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: onlyIch)
        guard let data = try? JSONEncoder().encode(entryRecord) else { return }
        try? data.write(to: rememberFile, options: [.atomic])
    }

    static func rememberedServer() -> RememberSlip? {
        guard let data = try? Data(contentsOf: rememberFile) else { return nil }
        return try? JSONDecoder().decode(RememberSlip.self, from: data)
    }
}

extension Cache {

    /// **What the server does not know yet.**
    ///
    /// A stop report that did not get through is the one piece of information
    /// nobody else has: where someone stopped. If it were lost, the server would
    /// keep the position from the start of playback, and at home the episode
    /// would start from the beginning. That is what downloads are for.
    ///
    /// The rules live in ``Nachmelderegeln`` in the package and were never
    /// called on Linux: `reportStopped` swallowed its failure with `try?`. Here
    /// only the file.
    private static var postReportFile: URL {
        folder.appendingPathComponent("nachmeldungen.json")
    }

    static func pendingReportsRead() -> [PendingReport] {
        guard let data = try? Data(contentsOf: postReportFile) else { return [] }
        return (try? JSONDecoder().decode([PendingReport].self, from: data)) ?? []
    }

    static func pendingReportsWrite(_ list: [PendingReport]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: onlyIch)
        try? JSONEncoder().encode(list).write(to: postReportFile, options: [.atomic])
    }
}

/// **The note of what the server does not know yet.**
///
/// Two small jobs: record a failed stop report, and send everything left
/// over once the server is demonstrably back. The rules (which report wins,
/// what is due, what drops out afterwards) are in ``Nachmelderegeln`` in the
/// package; here only when to call.
/// **Not pinned to the main thread.** The note lives on disk, not in the UI;
/// it is written from a detached task, exactly when a report fails.
enum PostReportSlip {

    static func record(_ itemID: String, ticks: Int64, account: String) {
        guard !account.isEmpty else { return }
        let new = PendingReport(itemID: itemID, account: account, ticks: ticks)
        Cache.pendingReportsWrite(
            PostReportRules.record(new, in: Cache.pendingReportsRead()))
    }

    /// Sends everything left over.
    ///
    /// **The package decides what applies** (`JellyfinClient.reportLater`):
    /// oldest first, a newer state on the server wins, at the first error the
    /// rest stays. **Never twice at once**: it is called when the home page
    /// loads and before downloads catch up, and two passes side by side sent the
    /// same position twice. Same as `AppModel.pendingSubmit()`.
    static func submit(_ client: JellyfinClient, account: String) async {
        guard !account.isEmpty else { return }
        let opened = PostReportRules.due(Cache.pendingReportsRead(), account: account)
        guard !opened.isEmpty, barrier.grab() else { return }
        defer { barrier.share() }
        let completed = await client.reportLater(opened) { AppLog.writeOut($0) }
        guard !completed.isEmpty else { return }
        Cache.pendingReportsWrite(
            PostReportRules.completed(completed, in: Cache.pendingReportsRead()))
    }

    /// A stop report that arrives later clears the pending one; an older
    /// position must not go out afterwards.
    static func overFetches(_ itemID: String, account: String) {
        guard !account.isEmpty else { return }
        Cache.pendingReportsWrite(
            PostReportRules.overFetches(itemID: itemID, account: account,
                                      in: Cache.pendingReportsRead()))
    }

    /// One pass at a time, across threads.
    private static let barrier = ThroughGaitLock()
}

/// A flag with a lock: `nehmen` only succeeds while nobody is inside.
private final class ThroughGaitLock: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func grab() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }

    func share() {
        lock.lock(); used = false; lock.unlock()
    }
}
