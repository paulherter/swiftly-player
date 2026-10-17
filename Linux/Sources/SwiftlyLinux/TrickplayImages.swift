import CGtk
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JellyfinKit

/// **The preview image above the bar while scrubbing,** cut from Jellyfin's
/// trickplay sheets.
///
/// Counterpart of `Sources/Shared/TrickplayImages.swift`: which tile belongs to
/// which position is computed by ``Trickplay`` in the package; only fetching
/// and caching live here. Unlike there, the cache is not a `CGImage` (does not
/// exist on Linux) but a `GdkPixbuf` per sheet. `gdk_pixbuf_new_subpixbuf` cuts
/// from it without copying pixels, and `gdk_texture_new_for_pixbuf` turns that
/// into something `GtkPicture` can show.
///
/// **If the server has no trickplay, `detail` stays `nil`**: the bar then shows
/// only the time while scrubbing, not an empty box.
/// `@unchecked Sendable`, like ``App`` itself: everything here ends up on GTK's
/// main thread, and the assertion holds as long as only ``onMainThread`` (or
/// `load`/`demand` already running there) touches the internals.
final class TrickplayImages: @unchecked Sendable {
    private(set) var detail: Trickplay?
    private var title: String?
    private var source: String?

    /// Whole sheets, by number. A sheet of 10×10 tiles of 320×180 is about 9 MB, so
    /// no more than a handful are kept.
    private var leaves: [Int: OpaquePointer] = [:]
    private var railsEpisode: [Int] = []
    private var onTheGo: Set<Int> = []
    private static let atMost = 6

    deinit { clear() }

    /// For a new title, check once whether trickplay exists.
    func load(client: JellyfinClient, item: Item, plan: PlaybackPlan) {
        guard title != item.id else { return }
        title = item.id
        source = plan.mediaSourceID
        detail = nil
        clear()
        let t = item.id
        let q = source
        // **Captured strongly, not weakly.** A weak reference cannot be touched again
        // inside a nested `@Sendable` closure (``onMainThread``); Swift 6 rejects
        // that. Like ``App`` itself (which also always writes `[self]`, never
        // `[weak self]`), this object only lives as long as the player that holds it;
        // a task that takes longer writes at most into an orphaned instance, which
        // then ends empty.
        Task.detached { [self] in
            let found = await client.trickplay(itemID: t, mediaSourceID: q)
            onMainThread {
                guard self.title == t else { return }
                self.detail = found
            }
        }
    }

    private func clear() {
        for (_, sheet) in leaves { g_object_unref(UnsafeMutableRawPointer(sheet)) }
        leaves = [:]
        railsEpisode = []
        onTheGo = []
    }

    /// The texture for a position, cut from its sheet; `nil` while the sheet is
    /// still on its way (it is requested here right away).
    func tile(at seconds: Double, client: JellyfinClient?) -> OpaquePointer? {
        guard let detail, let title, let client,
              let k = detail.tile(seconds: seconds) else { return nil }
        guard let sheet = leaves[k.sheet] else {
            demand(k.sheet, detail: detail, title: title, client: client)
            return nil
        }
        guard let crop = gdk_pixbuf_new_subpixbuf(
            sheet, Int32(k.x), Int32(k.y), Int32(k.width), Int32(k.height)) else { return nil }
        defer { g_object_unref(UnsafeMutableRawPointer(crop)) }
        return gdk_texture_new_for_pixbuf(crop)
    }

    private func demand(_ number: Int, detail: Trickplay, title: String, client: JellyfinClient) {
        guard !onTheGo.contains(number) else { return }
        onTheGo.insert(number)
        let source = source
        Task.detached { [self] in
            let data = await client.trickplaySheet(itemID: title, mediaSourceID: source,
                                                     width: detail.width, sheet: number)
            // **Decode here, not on the main thread.** A sheet is up to 9 MB of pixels;
            // dragging quickly along the timeline would otherwise stall the playback UI
            // for each new sheet. GdkPixbuf is not part of GTK and may decode on any
            // thread as long as nobody else touches the loader, which lives only in this
            // function.
            let packed = data.flatMap(Self.pixbuf(from:)).map(SheetBox.init)
            onMainThread {
                guard self.title == title else {
                    if let packed { g_object_unref(UnsafeMutableRawPointer(packed.sheet)) }
                    return
                }
                self.onTheGo.remove(number)
                guard let sheet = packed?.sheet else { return }
                self.leaves[number] = sheet
                self.railsEpisode.append(number)
                // Never throw away the last one; same rule as ``ImageCache``.
                if self.railsEpisode.count > Self.atMost, self.railsEpisode.count > 1 {
                    if let alt = self.leaves.removeValue(forKey: self.railsEpisode.removeFirst()) {
                        g_object_unref(UnsafeMutableRawPointer(alt))
                    }
                }
            }
        }
    }

    /// A finished sheet across the thread boundary; same assertion as
    /// ``Zeigerkiste``: after hand-over only the main thread touches it.
    private struct SheetBox: @unchecked Sendable { let sheet: OpaquePointer }

    /// Decode a JPEG sheet. The loader lives only in this call and decodes on the
    /// thread it is called on.
    private static func pixbuf(from data: Data) -> OpaquePointer? {
        guard let loader = gdk_pixbuf_loader_new() else { return nil }
        defer { g_object_unref(UnsafeMutableRawPointer(loader)) }
        let written = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            return gdk_pixbuf_loader_write(loader, base, gsize(buffer.count), nil) != 0
        }
        guard written, gdk_pixbuf_loader_close(loader, nil) != 0,
              let image = gdk_pixbuf_loader_get_pixbuf(loader) else { return nil }
        g_object_ref(UnsafeMutableRawPointer(image))
        return image
    }
}
