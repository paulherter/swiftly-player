import CoreGraphics
import SwiftUI
import struct SwiftlyCore.PlayerChapterRow

/// **The chapter list's rows, once for iPhone, iPad, Mac and Apple TV.**
///
/// The core owns the list (`VLCPlayerView.coreChapters`: name or "Kapitel n", start, preview tile, the running one marked)
/// and the jump (`coreJump(toChapter:)`). What stays on a platform is the layer around it (header, columns, focus) and the
/// row's button style; the row's text and picture come from here, so the three layers cannot drift apart.
extension PlayerChapterRow {
    /// The start as "m:ss", or "h:mm:ss" from one hour on.
    var startText: String {
        let total = Int(start.rounded(.down))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The file's own name, verbatim; only the numbered fallback ("Kapitel 3") is looked up in the catalog.
    func title(numberTitle: String) -> String {
        name ?? String(format: String(localized: String.LocalizationValue(numberTitle)), number)
    }
}

/// The sizes of one chapter row on a platform.
struct ChapterRowLook {
    var tile: CGSize
    var tileRadius: CGFloat
    var name: CGFloat
    var time: CGFloat
    var check: CGFloat
    var checkWidth: CGFloat
    var spacing: CGFloat
    var textSpacing: CGFloat
    var vertical: CGFloat

    /// iPhone and iPad (`pad`).
    static func phone(pad: Bool) -> ChapterRowLook {
        ChapterRowLook(tile: CGSize(width: 64, height: 36), tileRadius: 4, name: pad ? 16 : 15, time: 12,
                       check: pad ? 15 : 14, checkWidth: 18, spacing: 8, textSpacing: 2, vertical: 4)
    }

    /// Mac: the row sits in the same column rhythm as the track rows.
    static let mac = ChapterRowLook(tile: CGSize(width: 80, height: 45), tileRadius: 4, name: 15, time: 12,
                                    check: 15, checkWidth: 17, spacing: 9, textSpacing: 2, vertical: 5)

    /// Apple TV: read from three metres, so the tile and the type are larger.
    static let tv = ChapterRowLook(tile: CGSize(width: 160, height: 90), tileRadius: 8, name: 30, time: 24,
                                   check: 30, checkWidth: 32, spacing: 20, textSpacing: 4, vertical: 12)
}

/// Check mark for the running chapter, preview tile, name and start. The colour comes from the surrounding style, so a
/// platform's button (white on iPhone, hover on Mac, focus on TV) decides it; the tile keeps its final size whether or not
/// its image is there yet.
struct ChapterRowContent: View {
    let row: PlayerChapterRow
    let numberTitle: String
    let image: CGImage?
    let look: ChapterRowLook

    var body: some View {
        HStack(spacing: look.spacing) {
            Image(icon: "checkmark", size: look.check)
                .font(.app(size: look.check, weight: .semibold))
                .opacity(row.current ? 1 : 0)
                .frame(width: look.checkWidth)
                .accessibilityHidden(true)
            Group {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() } else { Color.white.opacity(0.08) }
            }
            .frame(width: look.tile.width, height: look.tile.height)
            .clipShape(RoundedRectangle(cornerRadius: look.tileRadius, style: .continuous))
            VStack(alignment: .leading, spacing: look.textSpacing) {
                Text(verbatim: row.title(numberTitle: numberTitle))
                    .font(.app(size: look.name, weight: row.current ? .semibold : .regular))
                    .lineLimit(2)
                Text(verbatim: row.startText)
                    .font(.app(size: look.time))
                    .opacity(0.7)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, look.vertical)
        .contentShape(Rectangle())
    }
}
