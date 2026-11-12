import Foundation
import JellyfinKit

// Domains image_address, image_store_key, image_selection (ImageAddress, ImageKey, ImageStoreKey,
// ImageSelection). Generator: crates/swiftly-hardening/src/inputs/images.rs.

private func imKind(_ x: Any?) -> ServerKind { ServerKind(rawValue: srStr(x) ?? "") ?? .jellyfin }

private func imAddress(_ c: [String: Any]) -> ImageAddress? {
    guard let b = srStr(c["base"]), let base = URL(string: b) else { return nil }
    return ImageAddress(base: base, token: srStr(c["token"]), kind: imKind(c["kind"]))
}

private func imMass(_ x: Any?) -> ImageMetric {
    let a = x as? [Any] ?? []
    switch srStr(a.first) ?? "" {
    case "high": return .atMostHigh(srInt(a[1]) ?? 0)
    case "wide": return .atMostWide(srInt(a[1]) ?? 0)
    default: return .filling(wide: srInt(a[1]) ?? 0, up: srInt(a[2]) ?? 0)
    }
}

private func imArt(_ x: Any?) -> ImageKind {
    switch srStr(x) ?? "" {
    case "background": .background
    case "preview": .preview
    case "logo": .logo
    default: .poster
    }
}

private func imUrlResult(_ url: URL?) -> [String: Any] {
    ["url": nsnull(url?.absoluteString),
     "key": nsnull(url.map { ImageKey.of($0) }),
     "store": nsnull(url.flatMap { ImageStoreKey.of($0) })]
}

let domainImageAddress = Domain("image_address") { raw in
    let c = try srDict(raw)
    guard let address = imAddress(c) else { return ["base": false] as [String: Any] }
    let url: URL?
    if srStr(c["op"]) == "user" {
        url = address.user(srStr(c["id"]) ?? "", mark: srStr(c["mark"]), border: srInt(c["border"]) ?? 0)
    } else {
        url = address.construct(itemID: srStr(c["id"]) ?? "", art: imArt(c["art"]), mark: srStr(c["mark"]),
                                mass: imMass(c["mass"]), index: srInt(c["index"]), guete: srInt(c["q"]) ?? 90)
    }
    var out = imUrlResult(url)
    out["base"] = true
    return out
}

let domainImageStoreKey = Domain("image_store_key") { raw in
    let c = try srDict(raw)
    guard let text = srStr(c["url"]), let url = URL(string: text) else { return ["parsed": false] as [String: Any] }
    var out = imUrlResult(url)
    out["parsed"] = true
    out["abs"] = url.absoluteString
    return out
}

let domainImageSelection = Domain("image_selection") { raw in
    let c = try srDict(raw)
    guard let address = imAddress(c) else { return ["base": false] as [String: Any] }
    func item(_ x: Any?) -> Item? {
        guard let x, !(x is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: x) else { return nil }
        return try? JSONDecoder().decode(Item.self, from: data)
    }
    guard let it = item(c["item"]) else { return ["decoded": false] as [String: Any] }
    let width = srInt(c["width"]) ?? 0
    var out: [String: Any]
    switch srStr(c["op"]) ?? "" {
    case "landscape":
        let hit = ImageSelection.landscape(it, addresses: address, width: width)
        out = imUrlResult(hit?.url)
        out["source"] = nsnull(hit?.source)
    case "header": out = imUrlResult(ImageSelection.header(it, addresses: address, width: width))
    case "header_fb":
        out = imUrlResult(ImageSelection.headerWithFallback(it, episode: item(c["episode"]), addresses: address, width: width))
    case "logo": out = imUrlResult(ImageSelection.logo(it, addresses: address, maxHeight: width))
    default: out = imUrlResult(ImageSelection.portrait(it, addresses: address, maxHeight: width))
    }
    out["decoded"] = true
    return out
}
