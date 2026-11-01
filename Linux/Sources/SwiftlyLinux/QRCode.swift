import Foundation

/// Minimal QR code encoder: byte mode, EC level M, versions 1...10.
enum QRCode {
    /// Square module matrix, true = dark. Quiet zone NOT included. nil if the text does not fit.
    static func modules(for text: String) -> [[Bool]]? {
        let bytes = Array(text.utf8)
        guard let version = pickVersion(byteCount: bytes.count) else { return nil }
        let codewords = interleaved(encode(bytes, version: version), version: version)
        return build(codewords: codewords, version: version)
    }

    // MARK: - Tables (level M)

    /// (ecc codewords per block, blocks in group 1, data per block g1, blocks in group 2, data per block g2)
    private static let blockTable: [(ecc: Int, n1: Int, d1: Int, n2: Int, d2: Int)] = [
        (10, 1, 16, 0, 0),   // v1
        (16, 1, 28, 0, 0),   // v2
        (26, 1, 44, 0, 0),   // v3
        (18, 2, 32, 0, 0),   // v4
        (24, 2, 43, 0, 0),   // v5
        (16, 4, 27, 0, 0),   // v6
        (18, 4, 31, 0, 0),   // v7
        (22, 2, 38, 2, 39),  // v8
        (22, 3, 36, 2, 37),  // v9
        (26, 4, 43, 1, 44),  // v10
    ]

    private static let alignment: [[Int]] = [
        [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34],
        [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50],
    ]

    private static func dataCapacity(_ version: Int) -> Int {
        let t = blockTable[version - 1]
        return t.n1 * t.d1 + t.n2 * t.d2
    }

    private static func pickVersion(byteCount: Int) -> Int? {
        for v in 1...10 {
            let countBits = v < 10 ? 8 : 16
            let bits = 4 + countBits + byteCount * 8
            if bits <= dataCapacity(v) * 8 { return v }
        }
        return nil
    }

    // MARK: - Data encoding

    private static func encode(_ bytes: [UInt8], version: Int) -> [UInt8] {
        var bits: [Bool] = []
        func put(_ value: Int, _ count: Int) {
            for i in stride(from: count - 1, through: 0, by: -1) { bits.append((value >> i) & 1 == 1) }
        }
        put(0b0100, 4)
        put(bytes.count, version < 10 ? 8 : 16)
        for b in bytes { put(Int(b), 8) }
        let capBits = dataCapacity(version) * 8
        put(0, min(4, capBits - bits.count))
        while bits.count % 8 != 0 { bits.append(false) }
        var out = [UInt8](repeating: 0, count: bits.count / 8)
        for (i, bit) in bits.enumerated() where bit { out[i / 8] |= UInt8(0x80 >> (i % 8)) }
        var pad: UInt8 = 0xEC
        while out.count < dataCapacity(version) {
            out.append(pad)
            pad = pad == 0xEC ? 0x11 : 0xEC
        }
        return out
    }

    // MARK: - Reed-Solomon

    private static let gfTables: (exp: [Int], log: [Int]) = {
        var exp = [Int](repeating: 0, count: 512)
        var log = [Int](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            exp[i] = x
            log[x] = i
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11D }
        }
        for i in 255..<512 { exp[i] = exp[i - 255] }
        return (exp, log)
    }()

    private static func gfMul(_ a: Int, _ b: Int) -> Int {
        if a == 0 || b == 0 { return 0 }
        return gfTables.exp[gfTables.log[a] + gfTables.log[b]]
    }

    private static func rsRemainder(_ data: [UInt8], eccCount: Int) -> [UInt8] {
        // Generator polynomial (without leading 1), highest degree first.
        var gen = [Int](repeating: 0, count: eccCount)
        gen[eccCount - 1] = 1
        var root = 1
        for _ in 0..<eccCount {
            for j in 0..<eccCount {
                gen[j] = gfMul(gen[j], root)
                if j + 1 < eccCount { gen[j] ^= gen[j + 1] }
            }
            root = gfMul(root, 2)
        }
        var rem = [Int](repeating: 0, count: eccCount)
        for b in data {
            let factor = Int(b) ^ rem[0]
            rem.removeFirst()
            rem.append(0)
            for j in 0..<eccCount { rem[j] ^= gfMul(gen[j], factor) }
        }
        return rem.map { UInt8($0) }
    }

    private static func interleaved(_ data: [UInt8], version: Int) -> [UInt8] {
        let t = blockTable[version - 1]
        var dataBlocks: [[UInt8]] = []
        var pos = 0
        for i in 0..<(t.n1 + t.n2) {
            let len = i < t.n1 ? t.d1 : t.d2
            dataBlocks.append(Array(data[pos..<pos + len]))
            pos += len
        }
        let eccBlocks = dataBlocks.map { rsRemainder($0, eccCount: t.ecc) }
        var out: [UInt8] = []
        for i in 0..<max(t.d1, t.d2) {
            for block in dataBlocks where i < block.count { out.append(block[i]) }
        }
        for i in 0..<t.ecc {
            for block in eccBlocks { out.append(block[i]) }
        }
        return out
    }

    // MARK: - Matrix construction

    private static func build(codewords: [UInt8], version: Int) -> [[Bool]] {
        let size = version * 4 + 17
        var grid = [[Bool]](repeating: [Bool](repeating: false, count: size), count: size)
        var reserved = [[Bool]](repeating: [Bool](repeating: false, count: size), count: size)

        func set(_ x: Int, _ y: Int, _ dark: Bool) {
            grid[y][x] = dark
            reserved[y][x] = true
        }

        // Timing patterns.
        for i in 0..<size {
            set(6, i, i % 2 == 0)
            set(i, 6, i % 2 == 0)
        }
        // Finder patterns with separators.
        for (cx, cy) in [(3, 3), (size - 4, 3), (3, size - 4)] {
            for dy in -4...4 {
                for dx in -4...4 {
                    let x = cx + dx, y = cy + dy
                    guard x >= 0, x < size, y >= 0, y < size else { continue }
                    let dist = max(abs(dx), abs(dy))
                    set(x, y, dist != 2 && dist != 4)
                }
            }
        }
        // Alignment patterns.
        let pos = alignment[version - 1]
        for (i, cy) in pos.enumerated() {
            for (j, cx) in pos.enumerated() {
                if (i == 0 && j == 0) || (i == 0 && j == pos.count - 1) || (i == pos.count - 1 && j == 0) { continue }
                for dy in -2...2 {
                    for dx in -2...2 { set(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1) }
                }
            }
        }
        // Reserve format and version areas (drawn properly below).
        for i in 0..<9 { reserved[8][i] = true; reserved[i][8] = true }
        for i in 0..<8 { reserved[8][size - 1 - i] = true; reserved[size - 1 - i][8] = true }
        if version >= 7 {
            for i in 0..<6 { for j in 0..<3 { reserved[i][size - 11 + j] = true; reserved[size - 11 + j][i] = true } }
        }

        // Zigzag data placement.
        var bitIndex = 0
        let totalBits = codewords.count * 8
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vert in 0..<size {
                for j in 0..<2 {
                    let x = right - j
                    let upward = ((right + 1) & 2) == 0
                    let y = upward ? size - 1 - vert : vert
                    if !reserved[y][x], bitIndex < totalBits {
                        grid[y][x] = (codewords[bitIndex >> 3] >> UInt8(7 - (bitIndex & 7))) & 1 == 1
                        bitIndex += 1
                    }
                }
            }
            right -= 2
        }

        // Try all masks, keep the lowest penalty.
        var best: [[Bool]] = []
        var bestScore = Int.max
        var bestMask = 0
        for mask in 0..<8 {
            var g = grid
            for y in 0..<size {
                for x in 0..<size where !reserved[y][x] && maskBit(mask, x, y) { g[y][x].toggle() }
            }
            drawFormat(&g, mask: mask, size: size)
            if version >= 7 { drawVersion(&g, version: version, size: size) }
            let score = penalty(g)
            if score < bestScore {
                bestScore = score
                best = g
                bestMask = mask
            }
        }
        _ = bestMask
        return best
    }

    private static func maskBit(_ mask: Int, _ x: Int, _ y: Int) -> Bool {
        switch mask {
        case 0: return (x + y) % 2 == 0
        case 1: return y % 2 == 0
        case 2: return x % 3 == 0
        case 3: return (x + y) % 3 == 0
        case 4: return (x / 3 + y / 2) % 2 == 0
        case 5: return x * y % 2 + x * y % 3 == 0
        case 6: return (x * y % 2 + x * y % 3) % 2 == 0
        default: return ((x + y) % 2 + x * y % 3) % 2 == 0
        }
    }

    private static func drawFormat(_ g: inout [[Bool]], mask: Int, size: Int) {
        // EC level M = 00, then 3 mask bits, BCH(15,5) and XOR mask.
        let data = mask
        var rem = data
        for _ in 0..<10 { rem = (rem << 1) ^ ((rem >> 9) * 0x537) }
        let bits = ((data << 10) | rem) ^ 0x5412
        func bit(_ i: Int) -> Bool { (bits >> i) & 1 == 1 }
        for i in 0...5 { g[i][8] = bit(i) }
        g[7][8] = bit(6)
        g[8][8] = bit(7)
        g[8][7] = bit(8)
        for i in 9..<15 { g[8][14 - i] = bit(i) }
        for i in 0..<8 { g[8][size - 1 - i] = bit(i) }
        for i in 8..<15 { g[size - 15 + i][8] = bit(i) }
        g[size - 8][8] = true  // dark module
    }

    private static func drawVersion(_ g: inout [[Bool]], version: Int, size: Int) {
        var rem = version
        for _ in 0..<12 { rem = (rem << 1) ^ ((rem >> 11) * 0x1F25) }
        let bits = (version << 12) | rem
        for i in 0..<18 {
            let dark = (bits >> i) & 1 == 1
            let a = size - 11 + i % 3
            let b = i / 3
            g[a][b] = dark
            g[b][a] = dark
        }
    }

    // MARK: - Penalty (ISO 18004 rules 1-4)

    private static func penalty(_ g: [[Bool]]) -> Int {
        let size = g.count
        var total = 0

        func lineScore(_ line: [Bool]) -> Int {
            var score = 0
            var run = 1
            for i in 1..<line.count {
                if line[i] == line[i - 1] {
                    run += 1
                } else {
                    if run >= 5 { score += 3 + run - 5 }
                    run = 1
                }
            }
            if run >= 5 { score += 3 + run - 5 }
            // Rule 3: 1011101 with 4 light modules on either side.
            let p1: [Bool] = [true, false, true, true, true, false, true, false, false, false, false]
            let p2: [Bool] = Array(p1.reversed())
            if line.count >= 11 {
                for i in 0...(line.count - 11) {
                    let w = line[i..<i + 11]
                    if w.elementsEqual(p1) { score += 40 }
                    if w.elementsEqual(p2) { score += 40 }
                }
            }
            return score
        }

        for y in 0..<size { total += lineScore(g[y]) }
        for x in 0..<size { total += lineScore((0..<size).map { g[$0][x] }) }

        // Rule 2: 2x2 blocks of one colour.
        for y in 0..<(size - 1) {
            for x in 0..<(size - 1) {
                let c = g[y][x]
                if g[y][x + 1] == c, g[y + 1][x] == c, g[y + 1][x + 1] == c { total += 3 }
            }
        }
        // Rule 4: dark/light balance.
        var dark = 0
        for row in g { for m in row where m { dark += 1 } }
        let all = size * size
        let k = (abs(dark * 20 - all * 10) + all - 1) / all - 1
        total += max(k, 0) * 10
        return total
    }
}
