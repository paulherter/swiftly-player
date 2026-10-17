import CGtk
import Foundation
// On Linux `URLSession` is not in Foundation but in a separate module. On Apple that
// module does not exist.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JellyfinKit

/// Loads posters from the server and puts them into an image widget.
///
/// **Two things make this more than a download.** First, the finished image must be set
/// on the main thread, otherwise GTK breaks. Second, a cache pays off: the same series
/// appears in "Weiterschauen" and "Nächste Folge", and without memory the app loads
/// the same poster twice.
///
/// The cache deliberately has **no size in its key**. This is a finding from Swiftfin:
/// keying on the requested width reloads the same poster for every display size.
actor ImageStorage {
    static let shared = ImageStorage()

    private var saved: [String: Data] = [:]
    /// **The packed images had no limit**, unlike the textures below (``ImageCache``,
    /// 256 MiB). Every poster that ever scrolled past stayed in memory as a JPEG: scrolling
    /// once through "Filme" of a large library means thousands of images at 50-300 KB, and
    /// memory grew until the app died. Same rule as there: the oldest go first.
    private var stored: [String] = []
    private var used = 0
    private static let limit = 96 * 1024 * 1024
    private var ongoing: [String: Task<Data?, Never>] = [:]

    /// **And on disk**, like `ImageStore` on Apple. Without it every cold start reloaded every
    /// poster from the server. The rule (only URLs with `tag`, oldest removed first) lives in
    /// the package (``ImagePlate``); 512 MB as on the Mac. Cleanup runs once per start, on the
    /// first write.
    private static let slab = ImagePlate(
        folder: Platform.cacheFolder.appendingPathComponent("bilder", isDirectory: true),
        limit: 512 * 1024 * 1024)
    private static let cleanedUp: Void = { _ = slab.cleanUp() }()

    // MARK: The gate

    /// **How many images may be fetched at once.**
    ///
    /// On Apple this was measured with 134 images (`Sources/Shared/NetworkImage.swift`): at the
    /// peak **twenty-five fetches were in flight at once**, sharing one connection and so all
    /// arriving **equally late**; until then the page stood empty.
    ///
    /// A gate barely changes the total time; it changes **when the first image appears**.
    /// Four and not one: a single connection leaves the line idle between requests. Four and
    /// not twelve: then there would be no difference again.
    private static let concurrent = 4
    private var inRun = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// First come, first served. Tiles ask from top to bottom, so loading goes top to bottom too.
    private func admission() async {
        if inRun < Self.concurrent {
            inRun += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting.append(continuation)
        }
        // The slot was rebooked to us on release; `inRun` stays.
    }

    private func inLetBack() {
        if waiting.isEmpty { inRun -= 1 }
        else { waiting.removeFirst().resume() }
    }

    func load(_ url: URL, key: String) async -> Data? {
        if let present = saved[key] { return present }
        if let running = ongoing[key] { return await running.value }

        let fileName = ImagePlate.name(url)
        let task = Task<Data?, Never> { [self] in
            // The disk needs no slot in the gate; it does not share a connection with the others.
            if let fileName,
               let present = await Task.detached(priority: .userInitiated, operation: {
                   Self.slab.read(fileName)
               }).value {
                return present
            }
            await admission()
            defer { Task { await inLetBack() } }
            do {
                let (data, answer) = try await URLSession.shared.data(for: .withOwnHeaders(url))
                guard let http = answer as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { return nil }
                if let fileName {
                    Task.detached(priority: .utility) {
                        Self.slab.write(data, fileName)
                        _ = Self.cleanedUp
                    }
                }
                return data
            } catch { return nil }
        }
        ongoing[key] = task
        let result = await task.value
        ongoing[key] = nil
        if let result, saved[key] == nil {
            saved[key] = result
            stored.append(key)
            used += result.count
            while used > Self.limit, stored.count > 1 {
                used -= saved.removeValue(forKey: stored.removeFirst())?.count ?? 0
            }
        }
        return result
    }
}

/// **Fully decoded images.**
///
/// ``Bildlager`` remembers the bytes. That saves the trip to the server but not the
/// decoding, which is the actual cost: `gdk_texture_new_from_bytes` decodes the JPEG on
/// GTK's main thread. Leaving a page and coming back would decode the same twenty images
/// again although nothing changed.
///
/// So the texture itself is kept here. If it is present, it is applied **immediately**,
/// with no task, no waiting, no ``Schubsperre``. A second visit to the same page then costs
/// nothing.
///
/// **A memory limit in bytes, not a count.**
///
/// This used to say "at most 200" on the estimate that two hundred posters are about fifty
/// megabytes. That version was rejected on Apple, for a reason documented there
/// (`Sources/Shared/NetworkImage.swift`): **240 posters are something completely different from
/// 240 landscape images.** Counting images does not count what runs short; a grid of
/// landscape images used three times what the number promised.
///
/// What is measured now is what a decoded texture really occupies: width times height times
/// four bytes. The limit is the same amount as on the Mac, since a window can show many
/// grids at once.
///
/// `nonisolated(unsafe)`, like everything here: touched only on GTK's main thread.
enum ImageCache {
    nonisolated(unsafe) private static var textures: [String: OpaquePointer] = [:]
    nonisolated(unsafe) private static var sizes: [String: Int] = [:]
    nonisolated(unsafe) private static var railsEpisode: [String] = []
    nonisolated(unsafe) private static var used = 0

    /// 256 MB, like `NetworkImage.cacheLimit` under `#if os(macOS)`.
    private static let limit = 256 * 1024 * 1024

    static func fetch(_ key: String) -> OpaquePointer? { textures[key] }

    static var count: Int { textures.count }

    /// Takes the texture **together with our reference**; the caller no longer releases it.
    /// The image widget holds its own.
    static func put(_ key: String, _ texture: OpaquePointer) {
        guard textures[key] == nil else {
            g_object_unref(UnsafeMutableRawPointer(texture))
            return
        }
        let width = Int(gdk_texture_get_width(texture))
        let height = Int(gdk_texture_get_height(texture))
        let bytes = max(width * height * 4, 1)
        textures[key] = texture
        sizes[key] = bytes
        railsEpisode.append(key)
        used += bytes
        // **Never throw out the last one.** Otherwise a single image larger than the limit evicts
        // itself again and the loop spins idle, the kind of loop that never makes progress.
        while used > limit, railsEpisode.count > 1 {
            let alt = railsEpisode.removeFirst()
            used -= sizes.removeValue(forKey: alt) ?? 0
            if let out = textures.removeValue(forKey: alt) {
                g_object_unref(UnsafeMutableRawPointer(out))
            }
        }
    }
}

/// Sets a downloaded image into a `GtkPicture`.
///
/// GTK takes raw bytes through `GdkTexture` and detects the format itself: JPEG, PNG,
/// WebP, whatever the server delivers.
/// **And it fades in.** On Apple every network image gets a
/// `withAnimation(.smooth(duration: 0.22))` once the bytes arrive
/// (`Sources/Shared/NetworkImage.swift`), so nothing appears abruptly. Here every poster, header
/// image and episode row used to appear at once; with a grid of twenty tiles that visibly
/// flashes.
///
/// - Parameter kante: The longest edge in pixels the widget needs. Larger images are
///   downscaled **while decoding** (``smallerUnpack(_:kante:)``). The URLs already ask
///   the server for this size; this catches cases where it sends the original anyway, where a
///   150 x 225 poster would otherwise occupy a 2000 x 3000 texture: twelve instead of half a
///   megabyte.
@discardableResult
func imageSet(_ imageField: Widget!, data: Data, key: String, border: Int? = nil) -> Bool {
    if let texture = ImageCache.fetch(key) {
        gtk_picture_set_paintable(OpaquePointer(imageField), texture)
        imageShow(imageField)
        return true
    }
    return imageLayOn(imageField, textureUnpack(data, border: border), data: data,
                        key: key)
}

/// **A decoded texture across threads.** `GdkTexture` is immutable and may change threads;
/// the box carries only the pointer (a reference that ``imageLayOn`` takes over).
struct TextureBox: @unchecked Sendable {
    let texture: OpaquePointer?
}

/// Decodes image bytes into a texture, **on any thread**.
///
/// `gdk_texture_new_from_bytes` is explicitly thread-safe (GTK >= 4.6, "to avoid blocking
/// the main thread while loading a big image"), as is a separate `GdkPixbufLoader` per call.
/// It lives here so a series with many episodes no longer decodes its images on the main
/// thread: each JPEG cost a few milliseconds there, and twenty in a row were the stutter
/// on opening.
func textureUnpack(_ data: Data, border: Int?) -> TextureBox {
    data.withUnsafeBytes { buffer -> TextureBox in
        guard let base = buffer.baseAddress,
              let bytes = g_bytes_new(base, gsize(buffer.count)) else { return TextureBox(texture: nil) }
        defer { g_bytes_unref(bytes) }
        var error: UnsafeMutablePointer<GError>?
        let hasRead = border.flatMap { smallerUnpack(buffer, border: $0) }
            ?? gdk_texture_new_from_bytes(bytes, &error)
        if hasRead == nil, let error {
            let text = error.pointee.message.map { String(cString: $0) } ?? "unbekannt"
            FileHandle.standardError.write(Data("Bild ließ sich nicht lesen: \(text)\n".utf8))
            g_error_free(error)
        } else if let error {
            g_error_free(error)
        }
        return TextureBox(texture: hasRead)
    }
}

/// Applies a decoded texture, on the main thread only. If the same one is already in memory
/// (a second widget was faster), the remembered one wins.
@discardableResult
func imageLayOn(_ imageField: Widget!, _ container: TextureBox, data: Data,
                  key: String) -> Bool {
    #if DEBUG
    CheckCounter.image(data, hasRead: container.texture != nil)
    #endif
    if let already = ImageCache.fetch(key) {
        if let new = container.texture { g_object_unref(UnsafeMutableRawPointer(new)) }
        gtk_picture_set_paintable(OpaquePointer(imageField), already)
        imageShow(imageField)
        return true
    }
    guard let texture = container.texture else { return false }
    gtk_picture_set_paintable(OpaquePointer(imageField), texture)
    ImageCache.put(key, texture)
    imageShow(imageField)
    return true
}

nonisolated(unsafe) private let sizeReported: @convention(c) (
    UnsafeMutablePointer<GdkPixbufLoader>?, Int32, Int32, gpointer?
) -> Void = { loader, width, height, data in
    let limit = Int32(truncatingIfNeeded: Int(bitPattern: data))
    let longest = max(width, height)
    guard limit > 0, longest > limit else { return }
    let factor = Double(limit) / Double(longest)
    gdk_pixbuf_loader_set_size(loader, max(1, Int32((Double(width) * factor).rounded())),
                               max(1, Int32((Double(height) * factor).rounded())))
}

/// Decodes an image so that its longest edge is at most `border`.
///
/// **While decoding, not afterwards.** `GdkPixbufLoader` asks for the file header how large
/// the result should be; a JPEG is then decoded directly at the smaller step instead of
/// fully first and scaled afterwards. Smaller images stay as they are; nothing is ever
/// enlarged. `nil` if the loader does not know the format; the caller then takes the usual
/// route via `gdk_texture_new_from_bytes`.
private func smallerUnpack(_ buffer: UnsafeRawBufferPointer, border: Int) -> OpaquePointer? {
    guard border > 0, let base = buffer.baseAddress,
          let loader = gdk_pixbuf_loader_new() else { return nil }
    defer { g_object_unref(UnsafeMutableRawPointer(loader)) }
    g_signal_connect_data(UnsafeMutableRawPointer(loader), "size-prepared",
                          unsafeBitCast(sizeReported, to: GCallback.self),
                          UnsafeMutableRawPointer(bitPattern: border), nil, GConnectFlags(rawValue: 0))
    var error: UnsafeMutablePointer<GError>?
    let written = gdk_pixbuf_loader_write(loader, base.assumingMemoryBound(to: guchar.self),
                                              gsize(buffer.count), &error) != 0
    if let f = error { g_error_free(f); error = nil }
    let closed = gdk_pixbuf_loader_close(loader, &error) != 0
    if let f = error { g_error_free(f) }
    guard written, closed, let image = gdk_pixbuf_loader_get_pixbuf(loader),
          let pixel = gdk_pixbuf_read_pixel_bytes(image) else { return nil }
    defer { g_bytes_unref(pixel) }
    // Only the two shapes the loader returns for photos: 8 bits per channel, three or four
    // channels. Everything else takes the usual route.
    guard gdk_pixbuf_get_bits_per_sample(image) == 8 else { return nil }
    let alpha = gdk_pixbuf_get_has_alpha(image) != 0
    guard gdk_pixbuf_get_n_channels(image) == (alpha ? 4 : 3) else { return nil }
    return gdk_memory_texture_new(gdk_pixbuf_get_width(image), gdk_pixbuf_get_height(image),
                                  alpha ? GDK_MEMORY_R8G8B8A8 : GDK_MEMORY_R8G8B8,
                                  pixel, gsize(gdk_pixbuf_get_rowstride(image)))
}

/// 0 to 1 over 220 ms, the same duration as `.smooth(duration: 0.22)`.
///
/// **Only if the widget is fully visible.** Otherwise an image that another run is
/// half-way through fading would restart its fade, and a tile image set twice (memory hit,
/// then fresh bytes) would visibly flicker.
private func imageShow(_ imageField: Widget!) {
    guard gtk_widget_get_opacity(imageField) >= 0.999 else { return }
    // While a page is moving, every fade costs a frame of the movement.
    guard !PushLock.drives else { return }
    gtk_widget_set_opacity(imageField, 0)
    runningCount(on: imageField, duration: motionReduced() ? Theme.timeReduced : 0.22) { e in
        gtk_widget_set_opacity(imageField, e)
    } done: {
        gtk_widget_set_opacity(imageField, 1)
    }
}

/// Loads any image into a `GtkPicture`, the same as ``posterLaden`` but with a ready URL.
/// Needed for the user picture in the sidebar, which has no `Item`.
///
/// `immediate` is for the few large ones, the header image and the poster on top. The many
/// small ones (episodes, cast, similar) wait until the page has settled; they are what
/// costs the transition.
/// - Parameter fertig: Called on the main thread once it is known whether an image arrived.
///   **There is exactly one reason for this:** a profile symbol shows its letter only once it
///   is clear that no image is coming. Placing it underneath as a precaution would make it
///   flash briefly for every account *with* an image, the same trap as in `ProfileCharacter` on
///   Apple: the letter is a fallback, not a base layer.
/// - Parameter kante: see ``imageSet(_:data:key:kante:)``.
/// - Parameter fallbackSeries: If no image arrives (network, server, broken file), the tile puts
///   its placeholder symbol (series or movie) into the frame instead of standing empty. It is
///   the same symbol a tile without an image URL already carries. `nil`: no substitute, e.g.
///   where a caller decides itself via `done`.
func imageLoad(_ imageField: Widget!, url: URL, key: String, immediate: Bool = false,
               border: Int? = nil, fallbackSeries: Bool? = nil,
               done: (@Sendable (Bool) -> Void)? = nil) {
    // A downscaled texture is a different one from the full one; otherwise a large widget with
    // the same URL would get the small image from memory.
    let textureKey = border.map { "\(key)@\($0)" } ?? key
    // **Already decoded means no work at all.** No detour through a task, no waiting for the
    // transition; the image is simply there.
    if let texture = ImageCache.fetch(textureKey) {
        gtk_picture_set_paintable(OpaquePointer(imageField), texture)
        done?(true)
        return
    }
    g_object_ref(imageField)
    let container = PointerBox(imageField)
    Task.detached {
        let data = await ImageStorage.shared.load(url, key: key)
        // **Decoding happens here, off the main thread** (``textureUnpack``).
        let unpacked = data.map { textureUnpack($0, border: border) }
        let layOn: @Sendable () -> Void = {
            let laid = data.map {
                imageLayOn(container.widget, unpacked ?? TextureBox(texture: nil), data: $0,
                             key: textureKey)
            } ?? false
            // Only while the widget still hangs in its frame: a page that has been torn down in the
            // meantime gets no symbol anymore. The frame is the `GtkOverlay` from ``framedImage``;
            // whoever sets `fallbackSeries` promises that it is one.
            if !laid, let fallbackSeries, let frameRect = gtk_widget_get_parent(container.widget) {
                characterPut(frameRect, series: fallbackSeries)
            }
            g_object_unref(container.widget)
            done?(data != nil)
        }
        // Applied after the transition: applying also costs a frame, and a dozen episode images
        // in the middle of the movement would be visible.
        if immediate { onMainThread(layOn) } else { postPush(layOn) }
    }
}
