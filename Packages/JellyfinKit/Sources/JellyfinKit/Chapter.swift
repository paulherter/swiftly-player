import Foundation

/// A chapter of a movie or episode, as stored in the file.
///
/// Comes from `/Items/{id}` with `Fields=Chapters` as `ChapterInfo`: a start in
/// ticks and a name. **There is no end**: a chapter runs to the start of the
/// next, the last to the end of the file.
///
/// **Not to be confused with ``Abschnitt``.** Segments come from the server's
/// analysis (intro, credits) and have a button; chapters live in the file
/// itself and divide the scrubber. Both can sit at the same spot but mean
/// different things.
///
/// Field names follow the OpenAPI description (`ChapterInfo`).
public struct Chapter: Sendable, Equatable, Decodable {
    /// As the server names it. Unnamed chapters and those named by time
    /// ("00:05:00.000") are already called "Chapter 3" there, in the server's
    /// language, not the device's. Empty only if nothing came.
    public let name: String
    /// Seconds, not ticks; converted when decoding.
    public let from: Double

    public init(name: String, from: Double) {
        self.name = name
        self.from = from
    }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case fromTicks = "StartPositionTicks"
    }

    /// **A chapter without a start is none.** If `StartPositionTicks` is missing,
    /// decoding throws, and ``ChapterResponse`` drops exactly that one, not the whole
    /// list. A chapter silently starting at 0 would otherwise sit on top of the
    /// first.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        from = Double(try c.decode(Int64.self, forKey: .fromTicks)) / 10_000_000
    }
}

/// The part of an item response that carries the chapters.
public struct ChapterResponse: Sendable, Decodable {
    public let chapter: [Chapter]

    enum CodingKeys: String, CodingKey { case chapter = "Chapters" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chapter = try c.decodeIfPresent(Lenient<Chapter>.self, forKey: .chapter)?.values ?? []
    }
}

// MARK: - The split bar

/// **The scrubber, split at chapter boundaries.**
///
/// A bar in pieces shows how the film is built before you grab it, and while
/// scrubbing the piece under the handle rises. Which chapters qualify and where
/// the cuts go belongs in the package: three scrubbers draw the same pieces,
/// and dropping cuts that are too close is the kind of rule that otherwise
/// differs per platform.
///
/// **Without chapters the bar is a single piece** and looks as before.
public enum ChapterBar {

    /// A piece of the bar, as a fraction of the runtime (0...1).
    public struct Piece: Sendable, Equatable {
        public let from: Double
        public let until: Double

        public init(from: Double, until: Double) {
            self.from = from
            self.until = until
        }

        /// **Where the piece lies on the bar, in points.**
        ///
        /// The gap is taken half from each neighbor, not all from one: the middle of
        /// the gap then sits exactly on the chapter boundary and the time under the
        /// handle matches the picture above. Nothing is taken at the two ends.
        public func frameRect(width: Double, gap: Double) -> (x: Double, width: Double) {
            let left = from > 0 ? gap / 2 : 0
            let right = until < 1 ? gap / 2 : 0
            let x = from * width + left
            return (x, max(until * width - right - x, 0))
        }
    }

    /// **The chapters allowed to divide the bar**: sorted, without duplicate
    /// starts, without nonsense.
    ///
    /// Anything outside the film (negative, not finite) is dropped before
    /// counting. Empty afterwards means no division. That applies in two cases:
    ///
    /// - **Fewer than two chapters.** A single one starting at 0 divides nothing.
    /// - **A uniform grid from 0.** For files without chapters Jellyfin can create
    ///   placeholders (`DummyChapterDuration`), all the same number of seconds
    ///   apart, and older versions did so by default. Their names do not help:
    ///   the server also calls real unnamed chapters "Chapter 3". The grid gives
    ///   them away, since chapters set by hand or from a disc are never exactly
    ///   equally spaced. And even if they were, a ruler says nothing about the
    ///   film.
    public static func usable(_ chapter: [Chapter]) -> [Chapter] {
        var watched = Set<Double>()
        let sorted = chapter
            .filter { $0.from.isFinite && $0.from >= 0 }
            .sorted { $0.from < $1.from }
            // Two chapters at the same start: the first wins, as in players that read the
            // list in order.
            .filter { watched.insert($0.from).inserted }
        guard sorted.count >= 2, !isGrid(sorted) else { return [] }
        return sorted
    }

    /// How far apart the spacings of a grid may be. The server places its
    /// placeholders exact to the second; tools that set chapters "every five
    /// minutes" often snap them to the nearest keyframe, which is still a ruler.
    static let gridTolerance: Double = 0.5

    /// Starts at 0, and every spacing equals the first.
    static func isGrid(_ sorted: [Chapter]) -> Bool {
        guard sorted.count >= 3, let firstOne = sorted.first,
              firstOne.from <= gridTolerance else { return false }
        let step = sorted[1].from - firstOne.from
        guard step > 0 else { return false }
        return zip(sorted, sorted.dropFirst())
            .allSatisfy { abs(($1.from - $0.from) - step) <= gridTolerance }
    }

    /// **Where to cut**, in seconds: every chapter start inside the runtime. The
    /// one at 0 is dropped (the bar starts there anyway), as is anything at or past
    /// the end of the file (chapters of another version, or a duration VLC does
    /// not know yet).
    ///
    /// `chapter` as from ``brauchbar(_:)``, which is what the client delivers.
    public static func limits(_ chapter: [Chapter], duration: Double) -> [Double] {
        guard duration > 0 else { return [] }
        return chapter.map(\.from).filter { $0 > 0 && $0 < duration }
    }

    /// **The pieces of the bar.**
    ///
    /// A cut that would leave a piece narrower than `minWidth` points is
    /// dropped, and the piece before it extends to the next cut. Twenty chapters on
    /// a narrow iPhone would otherwise be a dashed line where no piece is
    /// recognizable, and pieces thinner than the gap vanish entirely.
    ///
    /// This affects drawing only. Which chapter applies at a position is still
    /// decided by ``chapter(at:in:)``, even if its cut is missing.
    ///
    /// - Parameters:
    ///   - grenzen: the cuts in seconds (``grenzen(_:dauer:)``).
    ///   - dauer: the runtime in seconds.
    ///   - breite: the width of the bar in points.
    ///   - mindestbreite: no piece gets narrower than this, in points.
    public static func pieces(limits: [Double], duration: Double, width: Double,
                               minWidth: Double) -> [Piece] {
        let whole = [Piece(from: 0, until: 1)]
        guard duration > 0, width > 0 else { return whole }
        let cuts = limits.map { $0 / duration }.filter { $0 > 0 && $0 < 1 }.sorted()
        var pieces: [Piece] = []
        var beginning = 0.0
        for cut in cuts
        where (cut - beginning) * width >= minWidth
            && (1 - cut) * width >= minWidth {
            pieces.append(Piece(from: beginning, until: cut))
            beginning = cut
        }
        pieces.append(Piece(from: beginning, until: 1))
        return pieces
    }

    /// **What the slider snaps to**: the cuts between pieces, in seconds, but only
    /// those with room on both sides.
    ///
    /// ``Kerbenfang`` catches ``Kerbenfang/fangweite`` points left and right of each
    /// cut. If cuts are closer than two catch ranges plus some free bar need, the
    /// slider would only jump from chapter to chapter: thirty disc chapters on a
    /// portrait iPhone, and no spot in between could be hit. A cut therefore
    /// catches only if both neighbor pieces are at least ``fangabstand`` catch
    /// widths wide; it is drawn regardless.
    public static func snapCuts(_ pieces: [Piece], duration: Double, width: Double) -> [Double] {
        guard duration > 0, width > 0, pieces.count > 1 else { return [] }
        let needed = snapSpacing * NotchesSnap.snapRange / width
        return zip(pieces, pieces.dropFirst())
            .filter { $0.until - $0.from >= needed && $1.until - $1.from >= needed }
            .map { $1.from * duration }
    }

    /// How many catch widths a piece must be wide for its edges to snap: two for
    /// the catch ranges at both ends, two for the free middle.
    static let snapSpacing: Double = 4

    /// The piece containing a fraction. A boundary belongs to the piece starting
    /// there, as a chapter belongs to its start.
    public static func piece(at share: Double, in pieces: [Piece]) -> Int? {
        guard !pieces.isEmpty, share.isFinite else { return nil }
        return pieces.lastIndex { $0.from <= share } ?? 0
    }

    /// **The chapter at a position**, or `nil` before it: if the first chapter
    /// starts after 0, the beginning belongs to none.
    ///
    /// `chapter` sorted, as from ``brauchbar(_:)``. Asked on every frame while
    /// scrubbing, so no second sort here.
    ///
    /// **With one millisecond of slack.** When the slider snaps to a cut, the
    /// position comes back via fraction and runtime and often lies the last digit
    /// of the float *before* the chapter start. Without slack the preview named the
    /// previous chapter while the right piece was already raised.
    public static func chapter(at spot: Double, in chapter: [Chapter]) -> Chapter? {
        guard spot.isFinite else { return nil }
        return chapter.last { $0.from <= spot + play }
    }

    static let play: Double = 0.001
}
