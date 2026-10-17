import Foundation

/// **Posters and backgrounds on disk**: the rule for all platforms.
///
/// Previously only on Apple (`ImageStore` in `NetworkImage.swift`); Linux and Windows
/// kept images in memory only and reloaded every poster from the server after
/// each cold start. Since both only reach the package, the store lives here and
/// Apple calls it from here.
///
/// **No ETag needed.** Which address may go to disk is decided by
/// ``Bildablageschluessel``: only with Jellyfin's `tag`, the fingerprint of the
/// image. If the image changes on the server, the address changes, and the old
/// entry is never hit again. Asking the server would be one request per tile for
/// an answer that is already known.
///
/// **Cleanup follows the age of the last access**: ``read(_:)`` refreshes the
/// date, ``aufraeumen()`` removes the oldest until three quarters of the limit
/// are reached, so that not every start cleans up.
public struct ImagePlate: Sendable {
    public let folder: URL
    public let limit: Int

    public init(folder: URL, limit: Int) {
        self.folder = folder
        self.limit = limit
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// FNV-1a, 64 bit, as the file name. Stable across launches; `hashValue` is not.
    public static func fileName(_ text: String) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value &*= 0x100000001b3
        }
        return String(value, radix: 16)
    }

    /// The file name for an image address, `nil` without `tag`.
    public static func name(_ url: URL) -> String? {
        ImageStoreKey.of(url).map(fileName)
    }

    /// Reads and refreshes the date so that ``aufraeumen()`` keeps what was shown
    /// last. Do not call on the main thread.
    public func read(_ name: String) -> Data? {
        let file = folder.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    public func write(_ data: Data, _ name: String) {
        guard !data.isEmpty else { return }
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    /// Removes the files not shown for the longest time until the total is below
    /// three quarters of the limit. Returns how many went.
    @discardableResult
    public func cleanUp() -> Int {
        let fields: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: fields) else { return 0 }
        var list = files.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: Set(fields)) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var sum = list.reduce(0) { $0 + $1.1 }
        guard sum > limit else { return 0 }
        list.sort { $0.2 < $1.2 }
        var distance = 0
        for (file, size, _) in list where sum > limit * 3 / 4 {
            try? FileManager.default.removeItem(at: file)
            sum -= size
            distance += 1
        }
        return distance
    }
}
