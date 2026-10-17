import Foundation
#if os(tvOS)
import TVServices
#endif

/// What is on the Top Shelf: the row above the app icon on the Apple TV home
/// screen.
///
/// **The app writes, the extension reads.** The extension runs in its own process,
/// has no access to the app's keychain and should not talk to the server itself: it
/// is called every time someone moves over the icon on the home screen and must show
/// something immediately. So the app puts a finished list into the shared folder
/// every time the home page loads, and the extension only draws it.
///
/// The image URLs already carry Jellyfin's `api_key`, so the extension needs no
/// sign-in to fetch them.
struct ShelfEntry: Codable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey {
        case id
        case title = "titel"
        case subline = "unterzeile"
        case image = "bild"
        case progress = "fortschritt"
    }
    let id: String
    let title: String
    let subline: String?
    let image: URL?
    /// Fraction between 0 and 1, only for started items.
    let progress: Double?
}

/// A section with its entries: "Continue Watching", "Next Up", "Recently Added".
struct ShelfCategory: Codable, Sendable {
    enum CodingKeys: String, CodingKey {
        case title = "titel"
        case landscape = "quer"
        case entries = "eintraege"
    }
    let title: String
    /// Landscape stills instead of portrait posters. Only "Continue Watching" shows stills, as in the app.
    let landscape: Bool
    let entries: [ShelfEntry]
}

struct ShelfPreview: Codable, Sendable {
    enum CodingKeys: String, CodingKey {
        case categories = "rubriken"
    }
    let categories: [ShelfCategory]
}

/// The shared storage location.
enum Shelf {
    /// Must be in the entitlements of **both** targets, otherwise the folder does not exist for one of them and everything stays silent.
    static let group = "group.de.paulherter.swiftly"

    /// **In `Library/Caches` of the group folder, not its root.**
    ///
    /// tvOS lets apps write only there (plus preferences via UserDefaults). The app
    /// wrote to the root all along, and tvOS rejected it silently. Measured on Apple TV:
    /// group folder reachable, two sections built, "file missing after writing". The
    /// Top Shelf therefore stayed empty; when it ever showed anything, it was an old
    /// leftover.
    private static var file: URL? {
        guard let root = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        let folder = root.appendingPathComponent("Library/Caches", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("regal.json")
    }

    /// The last write error, for ``befund()``.
    nonisolated(unsafe) private static var lastError: String?

    static func write(_ preview: ShelfPreview) {
        guard var file, let data = try? JSONEncoder().encode(preview) else { return }
        // Continue only on a real change: the notification below makes tvOS ask the extension again, and that need not happen on every opening of the home page.
        let before = try? Data(contentsOf: file)
        guard before != data else { return }
        do {
            try data.write(to: file, options: .atomic)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            return
        }
        // **Not in the backup.**
        //
        // The image URLs in here carry Jellyfin's `api_key`, as stated above, because the
        // extension could not reach the images without it. So this file holds a full
        // server access without expiry, unencrypted: the keychain holds it properly, this
        // file does not.
        //
        // The keychain item itself carries `ThisDeviceOnly` and stays out of foreign
        // backups. Without this line the copy next to it would lack exactly the protection
        // the original has; a backup during a running session would take it along. The
        // same line is on the downloads folder for the same reason.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? file.setResourceValues(values)
        giveNotice()
    }

    /// **Tell the system the shelf has changed.**
    ///
    /// Without this line the app wrote the file and nobody asked for it: tvOS queries
    /// the extension on its own only rarely and remembers the last answer. If the first
    /// query fell in the time before any data existed, the home screen stayed at "empty"
    /// permanently, until a random re-query. That is exactly how it looked in testing:
    /// mostly just the icon, sometimes the right shelf.
    private static func giveNotice() {
        #if os(tvOS)
        NotificationCenter.default.post(name: NSNotification.Name.TVTopShelfItemsDidChange,
                                        object: nil)
        #endif
    }

    /// **Clearing on sign-out is mandatory, not cosmetic.**
    ///
    /// The file lives in the shared group and survives signing out. Without clearing,
    /// the Top Shelf keeps showing the previous account's movies and series, visible on
    /// the TV home screen to everyone in the room, even after someone explicitly signed
    /// out.
    static func wipe() {
        guard let file else { return }
        try? FileManager.default.removeItem(at: file)
        // Clearing must arrive too: otherwise the home screen keeps showing the previous account's titles after signing out.
        giveNotice()
    }

    /// For the app's log: whether the app reaches the folder, whether the file is there, how big. The extension has no log, so only a text here and no writing.
    static func finding() -> String {
        guard let file else { return "kein Gruppenordner (Berechtigung?)" }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? nil
        return size.map { "Datei da, \($0) Bytes" } ?? "Datei fehlt: \(lastError ?? "kein Fehler gemeldet")"
    }

    static func read() -> ShelfPreview? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ShelfPreview.self, from: data)
    }
}
