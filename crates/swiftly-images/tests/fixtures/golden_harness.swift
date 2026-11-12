import Foundation

func out(_ k: String, _ v: String) { print("\(k)|\(v)") }
func d(_ x: Double) -> String { String(format: "%.12f", x) }

// 1. addresses
let jf = ImageAddress(base: URL(string: "https://tv.example.de")!, token: "abc")
let jfSub = ImageAddress(base: URL(string: "https://tv.example.de/jf/")!, token: "a b+c&d")
let jfNo = ImageAddress(base: URL(string: "http://192.168.1.5:8096")!, token: nil)
let em = ImageAddress(base: URL(string: "https://emby.example.de:8920")!, token: "T", kind: .emby)
let px = ImageAddress(base: URL(string: "https://plex.example.de:32400")!, token: "TOK", kind: .plex)
let pxNo = ImageAddress(base: URL(string: "https://plex.example.de:32400")!, token: nil, kind: .plex)
func u(_ x: URL?) -> String { x?.absoluteString ?? "nil" }
var n = 0
func add(_ a: ImageAddress, _ label: String, _ id: String, _ art: ImageKind, _ mark: String?, _ mass: ImageMetric, _ index: Int? = nil, _ q: Int = 90) {
    n += 1
    out("addr\(n)", "\(label) \(id) \(art.rawValue) \(mark ?? "-") \(mass) \(index.map(String.init) ?? "-") \(q)")
    out("addr\(n).url", u(a.construct(itemID: id, art: art, mark: mark, mass: mass, index: index, guete: q)))
}
add(jf, "jf", "abc123", .poster, "t1", .atMostHigh(450))
add(jf, "jf", "abc123", .background, "t1", .atMostWide(1200))
add(jf, "jf", "abc123", .preview, "t1", .atMostWide(600))
add(jf, "jf", "abc123", .logo, "t1", .atMostHigh(240))
add(jf, "jf", "abc123", .poster, nil, .filling(wide: 100, up: 150))
add(jf, "jf", "abc123", .background, "t1", .atMostWide(1200), 2, 85)
add(jfSub, "jfsub", "a b", .poster, "tag é+ü", .atMostHigh(300))
add(jfNo, "jfno", "x", .poster, "t", .atMostHigh(300))
add(em, "emby", "x", .poster, "t", .atMostHigh(300))
add(px, "plex", "5", .poster, "/library/metadata/5/thumb/1700", .atMostHigh(450))
add(px, "plex", "5", .background, "/library/metadata/5/art/9", .atMostWide(1280))
add(px, "plex", "5", .poster, "/library/metadata/5/thumb/1", .filling(wide: 640, up: 360), nil, 80)
add(px, "plex", "5", .poster, nil, .atMostHigh(300))
add(px, "plex", "5", .preview, nil, .atMostHigh(300))
add(px, "plex", "5", .background, nil, .atMostWide(300))
add(px, "plex", "5", .logo, nil, .atMostWide(300))
add(px, "plex", "5", .poster, "https://metadata-static.plex.tv/a.jpg", .atMostHigh(300))
add(px, "plex", "5", .poster, "/a b/c+d?x=1&y=é", .atMostHigh(300))
add(pxNo, "plexno", "5", .poster, "/library/metadata/5/thumb/1", .atMostHigh(300))
out("user1", u(jf.user("u1", mark: "m", border: 64)))
out("user2", u(jfNo.user("u1", border: 64)))
out("user3", u(em.user("u1", mark: "m", border: 64)))
out("user4", u(px.user("u1", border: 64)))

// 2. keys
let keyUrls = [
  "http://192.168.1.5:8096/Items/abc/Images/Primary?fillHeight=600&tag=f00&ApiKey=geheim",
  "https://tv.example.org/Items/abc/Images/Primary?fillHeight=600&tag=f00&api_key=anders",
  "https://s/Items/abc/Images/Primary?tag=1",
  "https://s/Items/abc/Images/Primary?tag=",
  "https://s/Items/abc/Images/Primary?fillHeight=600",
  "https://x.de/i",
  "https://x.de/i?api_key=G&tag=1",
  "https://x.de/i?ApiKey=A",
  "https://plex.example.de:32400/photo/:/transcode?url=/library/metadata/5/thumb/1&upscale=0&width=4096&height=300&quality=90&X-Plex-Token=TOK",
  "https://u:p@h.de:81/Items/e/Images/Backdrop/2?TAG=abc&maxWidth=1200&quality=85&ApiKey=k#frag",
  "https://s/Items/é/Images/Primary?tag=a%20b&q=x+y",
  "https://s/Items/x/Images/Primary?Tag=UP",
]
for (i, s) in keyUrls.enumerated() {
    let url = URL(string: s)!
    out("key\(i)", s)
    out("key\(i).image", ImageKey.of(url))
    out("key\(i).store", ImageStoreKey.of(url) ?? "nil")
    out("key\(i).name", ImagePlate.name(url) ?? "nil")
}
for (i, s) in ["", "a", "b", "hello", "/Items/abc/Images/Primary?fillHeight=600&tag=f00", "é€😀"].enumerated() {
    out("fnv\(i)", "\(s)")
    out("fnv\(i).name", ImagePlate.fileName(s))
}

// 3. tones
var seed: UInt64 = 0x2545F4914F6CDD1D
func next() -> UInt64 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed }
func area(_ r: UInt8, _ g: UInt8, _ b: UInt8, points: Int) -> [UInt8] { (0 ..< points).flatMap { _ in [r, g, b, 255] } }
var images: [(String, [UInt8])] = []
images.append(("red", area(200, 30, 30, points: 256)))
images.append(("gray", area(120, 120, 120, points: 256)))
images.append(("two", area(20, 60, 200, points: 300) + area(220, 140, 20, points: 100)))
images.append(("five", area(220, 30, 30, points: 100) + area(30, 220, 30, points: 90) + area(30, 30, 220, points: 80) + area(220, 220, 30, points: 70) + area(30, 220, 220, points: 60) + area(220, 30, 220, points: 50)))
var noisy: [UInt8] = []
for _ in 0 ..< 2304 { let v = next(); noisy += [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24), 255] }
images.append(("noise48", noisy))
images.append(("dark", area(20, 10, 5, points: 100)))
images.append(("empty", []))
images.append(("odd", area(200, 30, 30, points: 3) + [1, 2, 3]))
for (name, px) in images {
    let t = AvComputation.tones(rgba: px)
    out("tones.\(name)", t.map(d).joined(separator: ","))
}
let toneSets: [(String, [Double])] = [("one", [200]), ("two", [30, 200]), ("three", [350, 10, 120]), ("none", [])]
for (name, t) in toneSets {
    for (x, y) in [(0.0, 0.0), (1.0, 0.0), (0.5, 0.5), (0.0, 1.0), (0.3, 0.8)] {
        let h = AvComputation.hsb(t, x: x, y: y)
        out("hsb.\(name).\(x).\(y)", [h.audio, h.saturation, h.brightness].map(d).joined(separator: ","))
        for f in [1.0, 0.5, 0.0] {
            let c = AvComputation.color(t, x: x, y: y, decay: f)
            out("color.\(name).\(x).\(y).\(f)", [c.r, c.g, c.b].map(d).joined(separator: ","))
        }
    }
    let p = AvComputation.points(t, columns: 5, rows: 8, height: 1000, colorHeight: 900, since: 300, runOut: 600)
    out("points.\(name)", p.map { String(UInt32(bitPattern: $0), radix: 16) }.joined(separator: ","))
}
for y in [0.0, 100, 300, 301, 600, 900, 1600, 2000] {
    out("decay.\(y)", d(AvComputation.decay(y: y, since: 300, runOut: 1300)))
}
out("decay.zero.a", d(AvComputation.decay(y: 10, since: 300, runOut: 0)))
out("decay.zero.b", d(AvComputation.decay(y: 400, since: 300, runOut: 0)))

// 4. OKLab
for (r, g, b) in [(0.6, 0.13, 0.11), (16.0/255, 16.0/255, 16.0/255), (0.0, 0.0, 0.0), (1.0, 1.0, 1.0), (0.02, 0.5, 0.9)] {
    let l = ColorSelection.oklab(r, g, b)
    out("oklab.\(r).\(g).\(b)", [l.L, l.a, l.b].map(d).joined(separator: ","))
    if let s = ColorSelection.srgb(L: l.L, a: l.a, b: l.b) { out("srgb.\(r).\(g).\(b)", [s.r, s.g, s.b].map(d).joined(separator: ",")) }
}
out("srgb.out", ColorSelection.srgb(L: 0.25, a: 0.4, b: 0.4) == nil ? "nil" : "some")
for (L, C, h) in [(0.25, 0.4, 29.0), (0.5, 0.1, 200.0), (0.9, 0.3, 120.0), (0.1, 0.0, 0.0)] {
    let f = ColorSelection.srgb(L: L, C: C, h: h)
    out("lch.\(L).\(C).\(h)", [f.r, f.g, f.b].map(d).joined(separator: ","))
}
out("spacing", [ColorSelection.spacing(350, 10), ColorSelection.spacing(10, 350), ColorSelection.spacing(90, 270), ColorSelection.spacing(29, 33)].map(d).joined(separator: ","))
for (h, s, v) in [(0.0, 1.0, 1.0), (60.0, 0.5, 0.5), (200.0, 0.38, 0.2), (359.0, 0.9, 0.9), (120.0, 0.0, 0.5)] {
    let c = AvComputation.hsbPostRGB(h, s, v)
    out("hsbrgb.\(h).\(s).\(v)", [c.r, c.g, c.b].map(d).joined(separator: ","))
}

// 5. mood mesh (ImageTone.network, copied loop)
func mesh(_ tones: [Double], height: Double, colorHeight: Double, since: Double, runOut: Double) {
    let columns = 5
    var rows: [Double] = [0, since * 0.5, since]
    for i in 1 ... 10 { rows.append(since + runOut * Double(i) / 10) }
    rows.append(height)
    var lines: [String] = []
    for y in rows {
        let f = AvComputation.decay(y: y, since: since, runOut: runOut)
        for s in 0 ..< columns {
            let x = Double(s) / Double(columns - 1)
            let c = tones.isEmpty ? (16.0/255, 16.0/255, 16.0/255) : AvComputation.color(tones, x: x, y: min(1, y / colorHeight), decay: f)
            lines.append([x, Float(min(1, y / height)).description.isEmpty ? 0 : Double(Float(min(1, y / height))), c.0, c.1, c.2].map(d).joined(separator: ","))
        }
    }
    out("mesh.\(Int(since)).\(tones.isEmpty ? "empty" : "tones")", "\(rows.count)|" + lines.joined(separator: ";"))
}
mesh([30, 200], height: 2000, colorHeight: 1100, since: 200, runOut: 1300)
mesh([], height: 2000, colorHeight: 1100, since: 200, runOut: 1300)
// 5x5 grid colors
for (name, t) in toneSets {
    var cs: [String] = []
    for row in 0 ..< 5 { for col in 0 ..< 5 {
        let h = AvComputation.hsb(t, x: Double(Float(col) / 4), y: Double(Float(row) / 4))
        cs.append([h.audio, h.saturation, h.brightness].map(d).joined(separator: ","))
    } }
    out("grid.\(name)", cs.joined(separator: ";"))
}

// 6. noise tile
do {
    let border = 96
    var points = [UInt8](repeating: 0, count: border * border * 4)
    var condition: UInt64 = 0x2545F4914F6CDD1D
    for i in stride(from: 0, to: points.count, by: 4) {
        condition ^= condition << 13
        condition ^= condition >> 7
        condition ^= condition << 17
        let bright = (condition & 1) == 1
        let coverage = UInt8(truncatingIfNeeded: condition >> 8)
        let channel: UInt8 = bright ? coverage : 0
        points[i] = channel; points[i + 1] = channel; points[i + 2] = channel
        points[i + 3] = coverage
    }
    out("noise.hash", ImagePlate.fileName(String(decoding: points.map { $0 == 0 ? 48 : ($0 % 26) + 97 }, as: UTF8.self)))
    out("noise.head", points.prefix(32).map(String.init).joined(separator: ","))
    out("noise.sum", String(points.reduce(0) { $0 + Int($1) }))
}
