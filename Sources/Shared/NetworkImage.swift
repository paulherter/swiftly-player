import CoreGraphics
import ImageIO
import JellyfinKit
import OSLog
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// An image from the network: fetched, **decoded off the main thread**,
/// cached and faded in.
///
/// Replaces `AsyncImage`, which had three problems:
///
/// 1. **It decodes on the main thread.** A grid of fifty tiles decodes fifty
/// images where drawing happens, which shows up as stutter when a page opens.
/// 2. **It caches nothing.** Every appearance reloads.
/// 3. **The fade-in never ran.** `.animation(value: image == nil)` was tied to a
/// value that never changed after creation, so images popped in hard.
///
/// Now `URLSession` fetches, `CGImageSourceCreateThumbnailAtIndex` with
/// `ShouldCacheImmediately` decodes in its own task where it bothers nobody,
/// and only the finished image comes back.

/// Carries a `CGImage` across a concurrency boundary. `CGImage` is immutable,
/// just not declared `Sendable`.
private struct ImageBox: @unchecked Sendable { let image: CGImage }

@MainActor
final class ImageCache {
    static let shared = ImageCache()
    #if DEBUG
    /// For measuring only; this line does not exist in release builds.
    static let imageLog = Logger(subsystem: "de.paulherter.swiftly", category: "bild")
    #endif

    /// Image and its memory cost: width times height times four bytes.
    private struct Record {
        let image: Image
        let byte: Int
        /// How long fetching and decoding took; for measurement only, otherwise unused.
        var fetch: Double = 0
        /// **Computation only**, without time spent in the gate.
        var transform: Double = 0
        /// **Waiting only**, for admission to decoding.
        ///
        /// Keeping the two apart matters. Reported decode time rose from 12 to 64 ms over
        /// six consecutive images, in order of arrival. That is the signature of a queue,
        /// not of work: six images in 64 ms is about 11 ms of real work each, the same load
        /// as before, just distributed differently. Folding both into one number makes
        /// every redistribution look like an improvement.
        var wait: Double = 0
    }

    private var known: [URL: Record] = [:]
    private var railsEpisode: [URL] = []
    private var used = 0
    /// Runs already in flight. Without this a grid fetches the same image several
    /// times when it appears in two rows.
    private var ongoing: [URL: Task<Record?, Never>] = [:]
    /// URLs already split. `key(_:)` builds a `URLComponents`, filters and
    /// reassembles: cheap alone, but it runs per tile and per pass on the main thread.
    private var keyCache: [URL: URL] = [:]

    // MARK: The gate

    /// **How many images may be fetched at once.**
    ///
    /// Measured on device with 134 images: decoding averages 8 ms and is **2%** of
    /// the time. Everything else is fetching, and at peak **25 requests were in
    /// flight at once**.
    ///
    /// That is why a page feels slow although nothing is missing: twenty-five
    /// requests share one connection, all arrive **equally late**, and the page is
    /// empty until then. One row of eleven images arrived within twenty milliseconds,
    /// after a second each.
    ///
    /// A gate barely changes the total time; it changes **when the first image
    /// appears**. Four requests share the line by four instead of twenty-five, so the
    /// first four arrive about six times faster, and the page fills progressively
    /// instead of all at once.
    ///
    /// Four and not one: a single connection leaves the line idle between requests.
    /// Four and not twelve: then there would be no difference again.
    private static let concurrent = 4
    private var inRun = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    // MARK: - The second gate, for decoding
    //
    // **The first orders the connection, this one the CPU.** The admission is
    // deliberately returned **before** decoding (the gate should order the line, not
    // the machine), which left decoding **unbounded**. On a cache hit the first gate
    // is not entered at all, so scrolling over already-fetched tiles ran any number
    // of decodes at once.
    //
    // Measured in a log while scrolling:
    //
    //     Bild 27 ms holen, 26 ms wandeln, 600 KB · Primary
    //     ... same line nine times in a row
    //
    // Nine different images (Jellyfin calls every poster "Primary"), all at the
    // same time, all with **26 ms**. The same image alone takes 3 to 12 ms. So the 26
    // is not the work but waiting for a core: nine `.userInitiated` tasks next to a
    // main thread that has **8.33 ms** per frame at 120 Hz. Occupied for three
    // frames, nine times in a row, that is severe frame drops while scrolling. It
    // also explains why animations feel smooth: nothing is loaded there.
    //
    // Two and not one: a single run leaves the other cores idle, and a poster should
    // not wait for its predecessor. Two and not eight: then the limit would mean
    // nothing again.
    private static let convertSimultaneously = 2
    private var whileConverting = 0
    private var waitingConvert: [CheckedContinuation<Void, Never>] = []
    /// For measurement only: how many were decoding at once.
    private var tipConvert = 0

    private func changeInLet() async {
        if whileConverting < Self.convertSimultaneously {
            whileConverting += 1
            tipConvert = max(tipConvert, whileConverting)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waitingConvert.append(continuation)
        }
        tipConvert = max(tipConvert, whileConverting)
    }

    private func changeInLetBack() {
        if waitingConvert.isEmpty {
            whileConverting -= 1
        } else {
            waitingConvert.removeFirst().resume()
        }
    }

    /// First come, first served. Tiles ask from top to bottom, so loading goes top
    /// to bottom too.
    private func admission() async {
        if inRun < Self.concurrent {
            inRun += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting.append(continuation)
        }
        // The slot was handed over to us on release; `inRun` stays.
    }

    private func inLetBack() {
        if waiting.isEmpty {
            inRun -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// **A memory limit in bytes, not a count.**
    ///
    /// This used to be "240 images" and a "1600 point long edge", with a comment
    /// saying each platform must set them. Checked later: **no platform sets them.**
    /// The knob existed, nobody turned it, and the Mac values applied everywhere,
    /// exactly the case the comment warned about.
    ///
    /// It only surfaced when the iPhone build switched from `AsyncImage` to this
    /// cache. Before, little went through here and the number had no consequence.
    ///
    /// **A count is the wrong unit anyway.** 240 posters are something entirely
    /// different from 240 landscape images; counting images does not count what runs
    /// short. Now what a decoded image really occupies (width times height times four
    /// bytes) is measured and the limit is an amount of memory. That can be answered
    /// per platform, and the count follows.
    ///
    /// The amounts are **derived, not measured**: they sit so far below what the
    /// platform allows a foreground app that images can never be the reason it gets
    /// killed. What it really tolerates only a run with the memory tool on a device
    /// can say.
    static var cacheLimit: Int = {
        #if os(macOS)
        256 * 1024 * 1024   // A window can show many grids at once.
        #elseif os(tvOS)
        64 * 1024 * 1024    // Large tiles, tight memory: the narrowest case.
        #else
        96 * 1024 * 1024    // iPhone and iPad.
        #endif
    }()

    /// Longest edge when decoding: larger means sharper and more expensive. No
    /// upscaling: what the server delivers smaller stays smaller.
    static var edgesLength: Int = {
        #if os(macOS)
        1600
        #elseif os(tvOS)
        1200            // Tiles are large and the screen is far away.
        #else
        1200            // Also carries the landscape image at the top of an iPad page.
        #endif
    }()

    func image(_ url: URL) -> Image? {
        let attribute = key(url)
        guard let present = known[attribute] else { return nil }
        recent(attribute)
        return present.image
    }

    /// **A hit moves to the end of the order**, so eviction removes the longest
    /// unused entry and not the longest stored one. Searched from the back, since
    /// what is currently shown is usually there.
    private func recent(_ attribute: URL) {
        guard railsEpisode.last != attribute,
              let i = railsEpisode.lastIndex(of: attribute) else { return }
        railsEpisode.remove(at: i)
        railsEpisode.append(attribute)
    }

    /// **The credential is not part of the image.** Every image URL carries
    /// `api_key`; after an account switch the same poster would suddenly have a
    /// different key and the whole cache would go cold at once: every tile refetched,
    /// and the old entries sit until they fall off the back. With 240 slots for two
    /// accounts that is half.
    ///
    /// A poster is the same image for both accounts, though: the server serves it
    /// under the same id, and `tag` (Jellyfin's fingerprint) stays in the key, so a
    /// changed version still shows up. Fetching uses the full path, caching omits
    /// the credential.
    ///
    /// Nothing needs discarding here: an image carries no watch state.
    private func key(_ url: URL) -> URL {
        if let present = keyCache[url] { return present }
        let new = computed(url)
        // It must not grow along: after two account switches the same images sit under
        // three URLs. Same limit as the images themselves, only in entries; a URL pair
        // costs next to nothing.
        if keyCache.count > 2_000 { keyCache.removeAll() }
        keyCache[url] = new
        return new
    }

    /// **Both spellings.** Jellyfin 12 dropped `api_key` and takes `ApiKey`; old
    /// servers accept both. Checking only the new one would leave old URLs with the
    /// credential in a cache that survives an account switch, and the same images
    /// would sit twice, once per account.
    /// **The computation lives in the package** (`ImageKey`), so Linux and
    /// Windows get it too.
    private func computed(_ url: URL) -> URL {
        URL(string: ImageKey.of(url)) ?? url
    }

    /// `vorrang` skips the gate.
    ///
    /// **For the one image someone is actually waiting for.** On a detail page that is
    /// the banner at the top: it fills half the screen, and while it is missing the
    /// page looks unfinished no matter how many posters below are already there.
    /// Queuing it behind twenty tiles would turn the gate against its own purpose.
    ///
    /// It is exactly **one** per page. With more it would no longer be priority but
    /// abolishing the gate.
    /// `onDevice`: also store the image on the device and show it from there; see
    /// `DevicesStore`. Profile pictures only.
    /// **`border` says how large to decode.**
    ///
    /// Every image used to get the same edge length, 1200. For a hero image that is
    /// right; for a poster shown 112 points wide it is **twelve times** the memory:
    /// 800 x 1200 x 4 bytes is 3.8 MB per tile instead of 0.3.
    ///
    /// While only the visible rows were created, that just worked. Once the home page
    /// carried all rows, dozens of such tiles sat in memory at once (over sixty images
    /// in one second in the log), and the system killed the app (signal 9).
    ///
    /// Whoever knows the size an image is shown at passes it. Whoever does not still
    /// gets 1200.
    func load(_ url: URL, preRank: Bool = false, onDevice: Bool = false,
               border wished: Int? = nil) async -> Image? {
        let attribute = key(url)
        if let present = known[attribute] { recent(attribute); return present.image }
        if let run = ongoing[attribute] { return await run.value?.image }

        // **Read before the fork.** `edgesLength` belongs to the main actor; from the
        // detached task the access would be a jump across the isolation boundary, which
        // Swift 6 rightly rejects.
        let border = min(wished ?? Self.edgesLength, Self.edgesLength)
        // Posters and backgrounds on disk too, only with `tag`; see `ImageStore`.
        // Profile pictures have their own storage.
        let slab = onDevice ? nil : ImageStore.name(attribute)
        let run = Task<Record?, Never> { [self] in
            let begun = Date()
            let data: Data
            // The gate orders the connection; a disk hit needs none and so does not wait
            // in it.
            var admitted = false
            if let slab,
               let stored = await Task.detached(priority: .userInitiated, operation: {
                   ImageStore.read(slab)
               }).value {
                data = stored
            } else if onDevice,
                      // **Read off the main thread, like the posters above.** The profile picture
                      // was the only disk access still on the main thread, once per account when
                      // opening the account list.
                      let stored = await Task.detached(priority: .userInitiated, operation: {
                          DevicesStore.read(attribute)
                      }).value {
                // From the device, immediately, and freshly fetched in the background so a new
                // profile picture is there next time.
                data = stored
                Task.detached(priority: .utility) { await DevicesStore.refresh(url, attribute) }
            } else {
                if !preRank { await admission(); admitted = true }
                guard let (fetched, answer) = try? await URLSession.shared.data(for: .withOwnHeaders(url)) else {
                    if admitted { inLetBack() }
                    return nil
                }
                data = fetched
                let ok = (answer as? HTTPURLResponse)?.statusCode == 200
                if onDevice, ok {
                    Task.detached(priority: .utility) { DevicesStore.write(fetched, attribute) }
                }
                if let slab, ok {
                    Task.detached(priority: .utility) { ImageStore.write(fetched, slab) }
                }
            }
            let fetched = Date()
            // **Return before decoding, not after.** The gate should order the connection,
            // not the machine; decoding runs off-thread anyway and costs eight milliseconds.
            if admitted { inLetBack() }
            // **And now through the second gate.** See there: decoding was unbounded, and
            // nine concurrent runs knocked the main thread off its beat while scrolling.
            let beforeGate = Date()
            await changeInLet()
            let waited = Date().timeIntervalSince(beforeGate)
            defer { changeInLetBack() }
            let container = await Task.detached(priority: .userInitiated) { () -> ImageBox? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                let rules: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    // **The deciding switch.** Without it CoreGraphics defers decoding until the
                    // first draw, which is the main thread again.
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: border
                ]
                guard let raw = CGImageSourceCreateThumbnailAtIndex(
                    source, 0, rules as CFDictionary) else { return nil }
                return ImageBox(image: raw)
            }.value
            guard let container else { return nil }
            // Four bytes per pixel. The decoded image occupies this much regardless of how
            // small the file was, which is why file size says nothing here.
            let byte = container.image.width * container.image.height * 4
            return Record(image: Image(decorative: container.image, scale: 1), byte: byte,
                           fetch: fetched.timeIntervalSince(begun),
                           transform: Date().timeIntervalSince(fetched) - waited,
                           wait: waited)
        }

        ongoing[attribute] = run
        let result = await run.value
        ongoing[attribute] = nil
        #if DEBUG
        // **Provisional, to re-measure a reported regression.** `AppLog.write`
        // only writes in developer builds; in release the line is there and does nothing.
        if let result {
            // **To the unified log**, not only the file in the container: that is not
            // readable from outside, and a measurement nobody can read is none. `%@` carries
            // the image name, which for Jellyfin is "Primary" for **every** poster, so nine
            // lines look alike and are still nine images.
            let row = String(format: "Bild %.0f ms holen, %.0f ms warten, %.0f ms rechnen, %d KB · gleichzeitig bis %d · %@ · %@",
                               (result.fetch) * 1000, (result.wait) * 1000,
                               (result.transform) * 1000,
                               result.byte / 1024, tipConvert,
                               attribute.lastPathComponent,
                               attribute.deletingLastPathComponent()
                                   .deletingLastPathComponent().lastPathComponent)
            AppLog.writeOut(row)
            Self.imageLog.notice("\(row, privacy: .public)")
        }
        #endif
        if let result { remember(result, for: attribute) }
        return result?.image
    }

    private func remember(_ entryRecord: Record, for url: URL) {
        if let alt = known[url] {
            used -= alt.byte
        } else {
            railsEpisode.append(url)
        }
        known[url] = entryRecord
        used += entryRecord.byte

        // **Least recently used first, until the amount fits again.** Hits move to the
        // end in `recent(_:)`. `removeFirst` shifts the array, but this moves pointers
        // against a decoded JPEG; deliberately left as is rather than swapped for a ring
        // buffer that would be more code than benefit.
        while used > Self.cacheLimit, !railsEpisode.isEmpty {
            let out = railsEpisode.removeFirst()
            used -= known.removeValue(forKey: out)?.byte ?? 0
        }
    }

    // MARK: Memory warning

    /// **Release on a memory warning.** Decoded images are the largest item the app
    /// holds itself, up to `cacheLimit`, and all of them exist on disk again.
    /// Nobody listened to the warning before; the system would kill the app sooner
    /// than we freed anything. Running requests stay.
    #if canImport(UIKit)
    private var warning: NSObjectProtocol?

    private init() {
        warning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ImageCache.shared.wipe() }
        }
    }
    #endif

    func wipe() {
        known.removeAll()
        railsEpisode.removeAll()
        keyCache.removeAll()
        used = 0
    }
}

struct NetworkImage: View {
    let url: URL?
    /// How the image fills its area.
    var art: ContentMode = .fill
    /// What to show when no image comes, as a system symbol.
    ///
    /// **An empty area looks like a bug in the app**, and was reported as one. A
    /// symbol says an image belongs here and the server has none.
    var symbolText: String?
    /// Skips the gate, for a page's one large image.
    var preRank = false
    /// **How large the image is shown**, so it is not decoded larger than needed.
    ///
    /// Without it `ImageCache.edgesLength` applies, 1600 on the Mac. For a hero
    /// image that is right; for a poster 150 points wide it is memory and CPU for
    /// nothing. Same calculation that `Picture` does on iPhone.
    ///
    /// The server already delivers posters small (600 KB decoded, roughly 300 x 500),
    /// so the value barely matters there. It matters for the large ones, such as a
    /// `Backdrop` at 792 KB and a `Primary` at 1599 KB.
    var displayEdge: CGFloat?
    /// Size of the symbol; twice as large on TV, where the screen is three meters
    /// away.
    var characterSize: CGFloat = 22

    @State private var image: Image?
    @State private var visible = false
    /// No image expected: no URL, or the request came back without an image. Only
    /// then does the symbol appear, not during loading, otherwise it would flash
    /// briefly before every tile.
    @State private var withoutImage = false

    /// **What is known is set immediately**, not on the next pass. A value supplied
    /// later comes too late, the empty pass has already happened, and that is the
    /// flash.
    @MainActor init(url: URL?, art: ContentMode = .fill, symbolText: String? = nil,
                    preRank: Bool = false, displayEdge: CGFloat? = nil,
                    characterSize: CGFloat = 22) {
        self.url = url
        self.art = art
        self.symbolText = symbolText
        self.preRank = preRank
        self.displayEdge = displayEdge
        self.characterSize = characterSize
        let immediate = url.flatMap { ImageCache.shared.image($0) }
        _image = State(initialValue: immediate)
        _visible = State(initialValue: immediate != nil)
        _withoutImage = State(initialValue: url == nil)
    }

    var body: some View {
        ZStack {
            if let image {
                image.resizable().aspectRatio(contentMode: art)
                    .opacity(visible ? 1 : 0)
            } else if withoutImage, let symbolText {
                Image(systemName: symbolText)
                    .font(.system(size: characterSize))
                    .foregroundStyle(Theme.fontVeryQuiet)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; withoutImage = true; return }
            withoutImage = false
            // **A new URL replaces the old image**, as in `Picture`. This used to be
            // `guard image == nil`, which held on to any image the view once had: if the URL
            // changed while the view stayed (other account, other episode), the old image
            // stayed.
            if let present = ImageCache.shared.image(url) {
                image = present
                visible = true
                return
            }
            image = nil
            visible = false
            // The screen has at most three pixels per point; add some so nothing frays,
            // more is not needed.
            let needed = displayEdge.map { Int($0 * 3.2) }
            guard let loaded = await ImageCache.shared.load(url, preRank: preRank,
                                                                border: needed) else {
                withoutImage = true
                return
            }
            image = loaded
            // **`Theme.einblenden`, after all.** This used `.smooth(duration: 0.22)` with a
            // note that referencing `Theme` would break tvOS and macOS because `Style.swift`
            // is only in the iOS target. That is true of the *file*, not of the token:
            // `einblenden` exists in all three versions of `Theme`. The note protected the
            // deviation longer than necessary, and it was visible: on a detail page the
            // banner (0.22) faded in faster than the poster next to it (0.28).
            //
            // With the token every platform uses its own curve, and "Reduce Motion" applies
            // here at last.
            withAnimation(Theme.reveal) { visible = true }
        }
    }
}

/// **Profile pictures on the device.**
///
/// With multiple servers, the profile shows accounts of servers the app is not
/// currently connected to, and they should keep their picture across restarts and
/// while the other server is not answering. Once loaded it is stored here and
/// appears immediately.
///
/// **Profile pictures only.** Posters and backgrounds would fill the device;
/// `ImageCache` keeps those in memory only. Stored in the cache folder: if the
/// system cleans up there, the image just comes from the server next time.
enum DevicesStore {
    nonisolated private static var folder: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = base.appendingPathComponent("Profilbilder", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A stable file name from the URL without the credential (FNV-1a, 64 bit).
    /// `hashValue` does not work: it changes on every launch.
    nonisolated private static func file(_ attribute: URL) -> URL? {
        folder?.appendingPathComponent(fileName(attribute.absoluteString))
    }

    nonisolated static func read(_ attribute: URL) -> Data? {
        file(attribute).flatMap { try? Data(contentsOf: $0) }
    }

    nonisolated static func write(_ data: Data, _ attribute: URL) {
        guard let target = file(attribute) else { return }
        try? data.write(to: target, options: .atomic)
    }

    /// Fresh from the server, only on a real response: an error page must not
    /// overwrite a profile picture.
    static func refresh(_ url: URL, _ attribute: URL) async {
        guard let (data, answer) = try? await URLSession.shared.data(for: .withOwnHeaders(url)),
              (answer as? HTTPURLResponse)?.statusCode == 200 else { return }
        write(data, attribute)
    }
}

/// Stable file name; the rule lives in the package (`ImagePlate.fileName`).
private func fileName(_ text: String) -> String { ImagePlate.fileName(text) }

/// **Posters and backgrounds on disk.**
///
/// `ImageCache` held them in memory only; after every cold start each tile came
/// anew from the server. Swiftfin stores up to 1 GB. Which URLs may go to disk
/// and under which key (no host, no credential, only `tag`) is in
/// `ImageStoreKey` in the package.
///
/// Stored in the cache folder, which the system empties when space is short;
/// beyond that `aufraeumen` removes the oldest files once per launch until the
/// limit fits again.
enum ImageStore {
    /// Derived, not measured: a landscape image at 1200 points is 100-300 KB as
    /// JPEG, a poster less.
    static let limit: Int = {
        #if os(tvOS)
        256 * 1024 * 1024
        #else
        512 * 1024 * 1024
        #endif
    }()

    /// Folder, reading, writing and cleanup live in the package (`ImagePlate`) so
    /// Linux and Windows share the same storage.
    private static let slab: ImagePlate? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return ImagePlate(folder: base.appendingPathComponent("Bilder", isDirectory: true), limit: limit)
    }()

    /// The file name for an image key; `nil` without `tag`.
    static func name(_ attribute: URL) -> String? { ImagePlate.name(attribute) }

    /// Reads and refreshes the date. Do not call on the main thread.
    nonisolated static func read(_ name: String) -> Data? { slab?.read(name) }

    nonisolated static func write(_ data: Data, _ name: String) {
        slab?.write(data, name)
        _ = cleanedUp
    }

    /// Once per launch, on the first write.
    private static let cleanedUp: Void = { _ = slab?.cleanUp() }()
}
