import Foundation

/// **Plex's preview pictures for scrubbing** (`.bif`, "Base Index Frames"): one JPEG every
/// few seconds in one file. Unlike Jellyfin's tile sheets there is no grid; each picture
/// stands alone.
///
/// Layout, little endian: 8 bytes magic `89 42 49 46 0D 0A 1A 0A`, `version` (u32), number of
/// images (u32), `timestampMultiplier` (u32, milliseconds per timestamp unit; 0 means 1000),
/// 44 bytes reserved; then `count + 1` index entries of (timestamp u32, byte offset u32),
/// the last one a sentinel (`0xFFFFFFFF`) whose offset is the end of the last picture; then
/// the JPEG data.
public struct PlexBIF: Sendable, Equatable {

    public struct Frame: Sendable, Equatable {
        /// Milliseconds from the start of the title.
        public let milliseconds: Int
        let range: Range<Int>
    }

    public let frames: [Frame]
    let data: Data

    /// `nil` for anything that is not a well-formed BIF; a half file must not crash a
    /// player that only wanted a preview.
    public init?(data: Data) {
        let magic: [UInt8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]
        let bytes = [UInt8](data)
        guard bytes.count >= 64, Array(bytes[0..<8]) == magic else { return nil }
        func word(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        let count = word(12)
        let multiplier = word(16) == 0 ? 1000 : word(16)
        let tableEnd = 64 + (count + 1) * 8
        guard count > 0, count < 1_000_000, bytes.count >= tableEnd else { return nil }

        var list: [Frame] = []
        list.reserveCapacity(count)
        for index in 0..<count {
            let entry = 64 + index * 8
            let start = word(entry + 4)
            let end = word(entry + 12)
            guard start >= tableEnd, end >= start, end <= bytes.count else { return nil }
            list.append(Frame(milliseconds: word(entry) * multiplier, range: start..<end))
        }
        frames = list
        self.data = data
    }

    /// The picture for a position: the last one at or before it (the first before the
    /// start, the last after the end, so scrubbing to the edge never shows nothing).
    public func image(atSeconds seconds: Double) -> Data? {
        guard !frames.isEmpty, seconds.isFinite else { return nil }
        let ms = Int(max(seconds, 0) * 1000)
        var low = 0, high = frames.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if frames[mid].milliseconds <= ms { low = mid } else { high = mid - 1 }
        }
        return data.subdata(in: data.startIndex + frames[low].range.lowerBound
                                ..< data.startIndex + frames[low].range.upperBound)
    }

    /// The picture with this number, `nil` outside the file.
    public func image(at index: Int) -> Data? {
        guard frames.indices.contains(index) else { return nil }
        return data.subdata(in: data.startIndex + frames[index].range.lowerBound
                                ..< data.startIndex + frames[index].range.upperBound)
    }

    /// Milliseconds between two pictures (the server writes them at a fixed step).
    public var interval: Int {
        guard frames.count > 1 else { return 0 }
        return max(0, frames[1].milliseconds - frames[0].milliseconds)
    }

    /// Width and height of the pictures, read from the JPEG header of the first one (no
    /// image framework, so it works on every platform). `nil` if it is no JPEG.
    public var pictureSize: (width: Int, height: Int)? {
        guard let first = image(at: 0) else { return nil }
        let b = [UInt8](first)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var at = 2
        while at + 9 < b.count {
            guard b[at] == 0xFF else { at += 1; continue }
            let marker = b[at + 1]
            if marker == 0xFF { at += 1; continue }
            // Start of frame (baseline, extended, progressive), not the tables in between.
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                let height = Int(b[at + 5]) << 8 | Int(b[at + 6])
                let width = Int(b[at + 7]) << 8 | Int(b[at + 8])
                return width > 0 && height > 0 ? (width, height) : nil
            }
            if marker == 0xD8 || (0xD0...0xD7).contains(marker) || marker == 0x01 { at += 2; continue }
            at += 2 + (Int(b[at + 2]) << 8 | Int(b[at + 3]))
        }
        return nil
    }
}
