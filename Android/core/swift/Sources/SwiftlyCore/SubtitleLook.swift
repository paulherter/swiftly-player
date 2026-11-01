import Foundation
import JellyfinKit

// MARK: - Subtitle look, the bridge for Kotlin
//
// **Every rule lives in the package** (`SubtitleLook`, `vlcOptions`, `textScalePercent`,
// `SubtitleFile.asPlainText`). Kotlin keeps one text, the look as the package's JSON, under the
// sync key `utAussehen`, and asks here for everything derived from it. Nothing is copied: the
// option table, the steps and the defaults are the ones the Apple apps use and the package tests.

/// What the preview and the Media3 caption view need, as plain numbers.
private struct SubtitleLookFacts: Encodable {
    /// Words as stored, so Kotlin can pick its label and describe the step.
    let size, colour, outline, position: String
    let shadow, background, keepFileStyle, raised, standard: Bool
    /// `--sub-text-scale` for the given base scale (82 on phone, 88 on TV at "Normal").
    let percent: Int
    /// Text colour as `0xRRGGBB`.
    let rgb: Int
    /// Outline thickness in percent of the text height (0, 2, 3).
    let thickness: Int
    /// Media3: `outline`, `shadow` or `none`. Media3 has one edge; the outline wins over the shadow.
    let edge: String
    /// Media3: `setFractionalTextSize`.
    let fraction: Double
    /// Media3: `setBottomPaddingFraction`.
    let bottomPadding: Double
}

extension Kern {

    /// The look read from a stored text; anything unreadable or empty is the default.
    private static func subtitleLook(_ json: String) -> SubtitleLook {
        SubtitleLook.read(json.isEmpty ? nil : Data(json.utf8))
    }

    private static func subtitleLookText(_ look: SubtitleLook) -> String {
        String(decoding: look.encoded(), as: UTF8.self)
    }

    /// The stored text in its stable form (sorted keys, every field present, unknown words as the
    /// default). Kotlin stores this and compares with it.
    public static func subtitleLookNormalise(json: String) -> String {
        subtitleLookText(subtitleLook(json))
    }

    /// The default look as text.
    public static func subtitleLookStandard() -> String {
        subtitleLookText(.standard)
    }

    /// One field changed. `field` is `size`, `colour`, `outline`, `shadow`, `background`,
    /// `position` or `keepFileStyle`; `value` the stored word, or `true`/`false` for the switches.
    /// An unknown field or word leaves the look as it was.
    public static func subtitleLookChange(json: String, field: String, value: String) -> String {
        var look = subtitleLook(json)
        let on = value == "true"
        switch field {
        case "size": if let v = SubtitleLook.Size(rawValue: value) { look.size = v }
        case "colour": if let v = SubtitleLook.Colour(rawValue: value) { look.colour = v }
        case "outline": if let v = SubtitleLook.Outline(rawValue: value) { look.outline = v }
        case "position": if let v = SubtitleLook.Position(rawValue: value) { look.position = v }
        case "shadow": look.shadow = on
        case "background": look.background = on
        case "keepFileStyle": look.keepFileStyle = on
        default: break
        }
        return subtitleLookText(look)
    }

    /// Everything derived from a look as JSON (``SubtitleLookFacts``): the preview draws from it and
    /// Media3 is configured from it. `baseScale` is 0.82 on the phone and 0.88 on TV.
    public static func subtitleLookFacts(json: String, baseScale: Double) -> String {
        let look = subtitleLook(json)
        let percent = SubtitleLook.textScalePercent(look: look, baseScale: baseScale)
        let facts = SubtitleLookFacts(
            size: look.size.rawValue, colour: look.colour.rawValue, outline: look.outline.rawValue,
            position: look.position.rawValue,
            shadow: look.shadow, background: look.background, keepFileStyle: look.keepFileStyle,
            raised: look.position == .raised, standard: look.isStandard,
            percent: percent, rgb: look.colour.rgb, thickness: look.outline.thickness,
            edge: look.outline != .off ? "outline" : (look.shadow ? "shadow" : "none"),
            fraction: 0.0625 * Double(percent) / 100,
            bottomPadding: look.position == .raised ? 0.15 : 0.08)
        return encoded(facts)
    }

    /// The libVLC 3 options for a look as a JSON list, without the font. `outputHeight` is the
    /// picture height in pixels, for the lift of "Higher".
    public static func subtitleLookVlcOptions(json: String, baseScale: Double, outputHeight: Int) -> String {
        encoded(SubtitleLook.vlcOptions(look: subtitleLook(json), baseScale: baseScale,
                                        outputHeight: outputHeight, engine: .vlc3))
    }

    /// Whether the signed-in server can hand out ASS as SRT (Jellyfin, Emby). Plex cannot for
    /// tracks inside the file, so the switch is locked there (`AppModel.fileStyleAdjustable`).
    public func subtitleFileStyleAdjustable() -> Bool {
        kind() != ServerKind.plex.rawValue
    }

    /// From the settings, at start and on every change: whether the file's own ASS style stays.
    /// Applies to the next playback start (``playbackOpen``).
    public func subtitleLookReport(json: String) {
        let keep = Self.subtitleLook(json).keepFileStyle
        barrier.lock(); _subtitleKeepFileStyle = keep; barrier.unlock()
    }

    /// The subtitle files of a plan for the stored look: with "keep the file's style" off, every
    /// ASS and SSA track comes as the server's SRT under the same index.
    func subtitleFilesFor(plan: PlaybackPlan, session: Session) -> [SubtitleFile] {
        let streams = plan.source?.mediaStreams ?? []
        let keep = lockRead { _subtitleKeepFileStyle }
        if !keep, session.kind != .plex, let itemID = plan.itemID {
            return SubtitleFile.asPlainText(streams: streams, itemID: itemID, source: plan.mediaSourceID,
                                            server: session.serverURL, key: session.accessToken,
                                            keyName: EmbyPaths.tokenName(for: session.kind))
        }
        return SubtitleFile.from(streams: streams, server: session.serverURL, key: session.accessToken,
                                 keyName: EmbyPaths.tokenName(for: session.kind))
    }
}
