import Foundation
import JellyfinKit
import class SwiftlyCore.Core
import enum SwiftlyCore.PlayerSectionKind
import struct SwiftlyCore.AccountRef

/// **Skip sections, trickplay sheets and chapters of a title, asked through the core** (`playSections`,
/// `playTrickplay`, `playChapters`: the Rust port of `JellyfinClient.sections` / `trickplay` / `chapter` and the
/// Plex ones), turned back into the models the screens already read (`Segment`, `Trickplay`, `Chapter`).
///
/// Like the old calls they never fail: a server that does not answer, an old version or a missing plugin is an
/// empty list (`nil` for trickplay), and the screen simply shows no button, no thumbnails, one piece of bar.
enum PlayExtras {
    static func sections(core: Core, account: AccountRef, itemID: String, locale: String) async -> [JellyfinKit.Segment] {
        let list = (try? await core.playSections(account: account, locale: locale, itemId: itemID)) ?? []
        return list.map { section in
            let art: JellyfinKit.Segment.Art
            switch section.kind {
            case .unknown: art = .unknown
            case .ads: art = .ads
            case .preview: art = .preview
            case .lookBack: art = .lookBack
            case .credits: art = .credits
            case .intro: art = .introSegment
            }
            return JellyfinKit.Segment(art: art, from: section.from, until: section.until)
        }
    }

    static func trickplay(
        core: Core, account: AccountRef, itemID: String, source: String?, locale: String
    ) async -> Trickplay? {
        guard let found = (try? await core.playTrickplay(
            account: account, locale: locale, itemId: itemID, source: source)) ?? nil
        else { return nil }
        return Trickplay(
            width: Int(found.width), height: Int(found.height), tilesWide: Int(found.tilesWide),
            tilesUp: Int(found.tilesUp), count: Int(found.count), interval: Int(found.interval))
    }

    static func chapters(
        core: Core, account: AccountRef, itemID: String, source: String?, locale: String
    ) async -> [Chapter] {
        let list = (try? await core.playChapters(account: account, locale: locale, itemId: itemID, source: source)) ?? []
        return list.map { Chapter(name: $0.name, from: $0.from) }
    }
}
