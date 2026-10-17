import CGtk
import Foundation
import JellyfinKit

/// **Large grids release images far outside the viewport.**
///
/// The grid is a `GtkFlowBox`: every tile lives as long as the page, and each
/// holds its texture; a poster at double resolution is a good half megabyte.
/// Scrolling through "Filme" with two thousand titles once left two thousand
/// textures in memory, because the limit in ``ImageCache`` only releases
/// *its* reference, not that of the image widgets.
///
/// **Why not `GtkGridView` right away.** It would be the right tool, with
/// recycled cells. But each tile here carries badge, bar, right-click path,
/// prefetching and accessible name, all attached to widgets built once;
/// paging, clearing, focus and the remote-control command `grid` rely on
/// FlowBox children. Rebuilding means rewriting all of that without being
/// able to check it visually. The widgets themselves are small; the textures
/// are what grows, and this guard reclaims them.
///
/// **What it does:** throttled while scrolling, look at every tile. More than
/// three screen heights away: take the image out of the widget. Closer than
/// one and a half again: put it back, from the texture cache immediately,
/// otherwise from the image store or disk (``ImagePlate``); the server is not
/// asked. The gap between the two limits prevents a tile at the edge from
/// being removed and restored on every jolt.
final class TileImageGuard {
    final class Record {
        var image: Widget?
        let url: URL
        let key: String
        let border: Int?
        var stored = false
        init(image: Widget!, url: URL, key: String, border: Int?) {
            self.image = image
            self.url = url
            self.key = key
            self.border = border
        }
    }

    private var entries: [Record] = []
    private var scroller: Widget?
    private var planned = false
    private var sinceCleanUp = 0

    /// How many images are currently removed, for the log.
    var stored: Int { entries.lazy.filter(\.stored).count }

    init(scroller: Widget!) {
        self.scroller = scroller
        signal(scroller, "destroy") { [weak self] in
            self?.scroller = nil
            self?.entries = []
        }
        if let verticalRight = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller)) {
            signalRaw(UnsafeMutableRawPointer(verticalRight), "value-changed") { [weak self] in
                self?.planOut()
            }
        }
    }

    func record(_ image: Widget!, url: URL, key: String, border: Int?) {
        let entryRecord = Record(image: image, url: url, key: key, border: border)
        // **Listen for teardown**, otherwise `image` points to freed memory after
        // the grid is cleared.
        signal(image, "destroy") { [weak entryRecord] in entryRecord?.image = nil }
        // Dead entries otherwise only drop out while scrolling; something that
        // filters or sorts repeatedly without scrolling would accumulate them.
        sinceCleanUp += 1
        if sinceCleanUp >= 256 {
            sinceCleanUp = 0
            entries.removeAll { $0.image == nil }
        }
        entries.append(entryRecord)
    }

    /// At most every 150 ms; scrolling emits a signal per frame.
    private func planOut() {
        guard !planned else { return }
        planned = true
        postDeadline(0.15) { [weak self] in
            self?.planned = false
            self?.check()
        }
    }

    private func check() {
        entries.removeAll { $0.image == nil }
        guard let scroller, !entries.isEmpty,
              let verticalRight = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroller))
        else { return }
        let visibility = gtk_adjustment_get_page_size(verticalRight)
        guard visibility > 0 else { return }
        let far = visibility * 3
        let near = visibility * 1.5
        var frameRect = graphene_rect_t()
        for entryRecord in entries {
            guard let image = entryRecord.image,
                  gtk_widget_compute_bounds(image, scroller, &frameRect) != 0 else { continue }
            // Position relative to the visible area: 0 at the top, `visibility` at the bottom.
            let top = Double(frameRect.origin.y)
            let bottom = top + Double(frameRect.size.height)
            let spacing = max(0, -bottom, top - visibility)
            if !entryRecord.stored, spacing > far {
                gtk_picture_set_paintable(OpaquePointer(image), nil)
                entryRecord.stored = true
            } else if entryRecord.stored, spacing < near {
                entryRecord.stored = false
                imageLoad(image, url: entryRecord.url, key: entryRecord.key,
                          border: entryRecord.border)
            }
        }
    }
}
