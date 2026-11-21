import JellyfinKit
import SwiftUI
import struct SwiftlyCore.PlayerChapterRow
import struct SwiftlyCore.PlayerPreview
import enum SwiftlyCore.PlayerMenuPanelTab

/// Player dimensions on the TV, in one place so the title of the episode layer
/// sits exactly where it sat on the picture. Rounded to the TV type steps; the
/// margins are the app-wide title-safe ones (`Theme.edgePage`, `Theme.edgeTop`).
enum PlayerMetric {
    /// Uses the app's type ladder, not its own. The title over the picture is the
    /// page title (56 bold), the info line is a detail (24), and the runtime sits on
    /// the tile title (26), the smallest step still readable from three metres.
    static let title = Theme.titleLarge
    static let meta = Theme.small
    static let time: CGFloat = 26
    /// Target time under the preview image while scrubbing.
    static let previewTime: CGFloat = 30
    /// Bar background, as in the design and the iPhone `Zeitregler`.
    static let barReason = Color.white.opacity(0.25)
    /// Buffered stretch of the bar (design: white at 40 %).
    static let barBuffered = Color.white.opacity(0.4)
    /// Between title and meta line or season pill.
    static let titleSpacing: CGFloat = 10
    /// Line boxes of the head: 56 x 1.1 and 24 x 1.3 as in the design CSS, so title and meta line sit on the same y.
    static let titleLine: CGFloat = 61.6
    static let metaLine: CGFloat = 31.2
    /// Title tracking (design: -1.2 px).
    static let titleTracking: CGFloat = -1.2
    /// The icon buttons at top right: 88 x 88, glyph 44, gap 8.
    static let button: CGFloat = 88
    static let symbol: CGFloat = 44
    static let buttonSpacing: CGFloat = 8
    /// Gap of the skip pill above the bar.
    static let overBar: CGFloat = 28
    /// Height of the time row (one 26 pt line).
    static let bar: CGFloat = 32
    /// Distance of the time row from the bottom edge.
    static let bottom: CGFloat = 90
    /// Column heading (36 / 700) and the gap below it.
    static let heading: CGFloat = 36
    static let headingGap: CGFloat = 16
    static let rowHeight: CGFloat = 72
    /// Space between the last row and the "Verzögerung" block.
    static let delayTop: CGFloat = 28
    /// Columns of the audio & subtitles and settings layers.
    static let column: CGFloat = 500
    static let columnSpacing: CGFloat = 114
    static let columnsTop: CGFloat = 212
    /// Row inset on the layers, so column title, choice row and delay share one text edge.
    static let inset: CGFloat = 20
    /// Width between the margins (80 pt) at 1920 pt.
    static let safeWidth: CGFloat = 1760

    /// Column width for `count` columns side by side. Up to three keep the design
    /// size; four or five (quality, group) move closer instead of running off screen.
    static func columnsWidth(count: Int) -> CGFloat {
        guard count > 3 else { return column }
        return min(column, (safeWidth - CGFloat(count - 1) * tighter) / CGFloat(count))
    }
    static func columnGap(count: Int) -> CGFloat { count > 3 ? tighter : columnSpacing }
    private static let tighter: CGFloat = 48

    /// Width of the icon row; the resting title keeps that space free.
    static func iconRail(count: Int) -> CGFloat {
        CGFloat(count) * button + CGFloat(max(count - 1, 0)) * buttonSpacing
    }
}

/// The layers over the picture.
enum PlayerLayer: Equatable {
    case episodes, chapters
}

/// Shoot path for screenshots without a working stream. DEBUG only; in release every flag is `false`.
///
///     -zeige player -ohneBild [-ebene]
///
/// `-ohneBild` shows the control layer as if playing (see `PlayerScreen`); `-ebene` opens the Ton & Untertitel menu.
enum PlayerShoot {
    #if DEBUG
    static let withoutImage = ProcessInfo.processInfo.arguments.contains("-ohneBild")
    static let layer = withoutImage && ProcessInfo.processInfo.arguments.contains("-ebene")
    #else
    static let withoutImage = false
    static let layer = false
    #endif
    static let position: Double = 1781
    static let duration: Double = 2880
    /// Buffered up to here (seconds): about nine percent of the film ahead of the position.
    static let buffered: Double = 2045
    /// Share of the "Nächste Folge" underline.
    static let countdown: Double = 0.7

}

// MARK: - Quality

/// Quality choice in the player: Direct Play or a cap in Mbit/s. `select(nil)` means Direct Play.
struct QualitySelection {
    let directPlay: Bool
    let limit: Int
    let select: (Int?) -> Void
}

/// Focus does not enter a layer on its own: the first assignment falls into the
/// pass in which the layer is inserted, and SwiftUI drops it. So set it at once
/// and again one tick later.
enum LayersFocus {
    @MainActor
    static func put(_ setDown: () -> Void) async {
        setDown()
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return }
        setDown()
    }
}
