import JellyfinKit
import SwiftUI

/// The tech badge over the running picture: **the info that makes a bug
/// report usable.**
///
/// **Why a badge and not a tab.** The same numbers used to be a "Tech" tab
/// in the playback sheet. That is the wrong form for the question they
/// answer: "is it running smoothly right now?" is not asked once but
/// watched while playing. A sheet covers the picture and closes again; you
/// read a number, close it, see stutter again and do not know whether the
/// number belonged to it. Streamyfin solves it as a persistent badge, for
/// the same reason.
///
/// **It takes no input.** `allowsHitTesting(false)` is set at the call
/// site, not here: the badge is information, not a control, and must not
/// take anything from the controls beneath. On tvOS the same holds for
/// focus.
///
/// **Top left, always.** The controls and the scrubber sit at the bottom
/// everywhere, and the close button at the top right on iPhone and iPad.
/// Top left is the only corner free in all four players, and a badge that
/// sits somewhere else on each device has to be hunted for.
///
/// **What it shows and what not anymore.** The badge had grown a line with
/// every measurement until it covered almost the whole picture on a phone
/// in landscape. Now only what a viewer wants to know stays visible: how
/// the server delivers and why, what video, audio and subtitles, how large
/// and dense the file is, and whether the buffer suffices. Everything that
/// only helps when hunting a bug (clock, position, the Matroska trick,
/// decoder and display counters, screen rate) shows only in measure mode
/// (`techBadgeMeasure`, see there).
///
/// **The core lines always show; only the rest is capped.** Header, reason,
/// video, audio, subtitles, file and buffer carry `kern()` and show no
/// matter how tall they get: a long reason is shortened, not dropped.
/// Whatever goes beyond (lost frames) is taken by `TruncatedList` only while
/// `maxShare` of the offered height suffices. Before, the cap applied
/// to all lines, and on iPhone in landscape audio and buffer dropped out
/// after a re-layout. No scrolling: the badge takes no input, so nobody
/// could scroll anyway.
struct TechBadge: View {
    /// What the server delivers and why: the most important line.
    let plan: PlaybackPlan
    /// What VLC counts while playing. `nil` until something is measured.
    let values: PlayValues?
    /// The playback surface, for runtime, position and the Matroska trick:
    /// everything only the player knows and the server does not.
    var area: VLCPlayerView?
    /// How large the badge turns out overall. The TV is read from three
    /// meters, the iPhone from thirty centimeters.
    var far = false
    /// Measured refresh rate of the screen, filled on iOS only.
    var screenHertz: Double?

    /// **Measure mode: all lines, no maximum height.**
    ///
    /// Not a setting in the preferences: it is a tool for hunting a bug, not
    /// for viewers. It is set as a launch argument (`-technikschildMessen YES`),
    /// on the Mac also with `defaults write`. `#if DEBUG` alone was not enough:
    /// test devices get debug builds, and there the badge should be as slim as
    /// for everyone else.
    @AppStorage("technikschildMessen") private var measure = false

    /// Up to here extra lines may lengthen the badge; the core lines count
    /// toward it but also show beyond it.
    ///
    /// **Calculated, not estimated** (iPhone landscape, 390 pt tall): under the
    /// title line the badge has a good 275 pt, 55 % of which is 152. The seven
    /// core lines need 120 pt at 12 pt type and 4 pt spacing, and 154 with a
    /// two-line reason and a wrapping video line; then the loss line drops,
    /// not the core lines. With 0.4 (110 pt) even the normal case was too long
    /// without the loss line. On tvOS (1080, 24 pt, 7 pt spacing) a good 740 pt
    /// remain; the core lines need at most 305.
    static let maxShare: CGFloat = 0.55

    private var source: MediaSource? { plan.source }
    private var video: MediaStream? { source.flatMap(FileDetails.videoTrack) }
    private var audio: MediaStream? { source.flatMap(FileDetails.audioTracks)?.first }
    private var subtitle: MediaStream? {
        source.flatMap(FileDetails.subtitleTracks)?.first
    }

    private var spacing: CGFloat { far ? 7 : 4 }

    var body: some View {
        TruncatedList(spacing: spacing, share: measure ? nil : Self.maxShare) {
            headerLine.kern()

            // The reason sits directly under the word, not at the end: whoever reads
            // "Transcoding" wants to know next what caused it. Two lines suffice for
            // kind and codec; the rest of the parenthesis may be shortened outside
            // measure mode.
            if plan.method == .transcode, let reason = plan.reasons.first {
                Text(verbatim: reason.text).foregroundStyle(Theme.warning)
                    .lineLimit(measure ? nil : 2)
                    .kern()
            }

            // **If no picture ever arrived, it says so here**, and what the player
            // did about it, see ``FirstFrame``. Without this line, a black picture with
            // sound would look like a healthy stream in the badge.
            if let hint = area?.firstFrameHint {
                Text(verbatim: hint).foregroundStyle(Theme.warning)
                    .lineLimit(measure ? nil : 2)
                    .kern()
            }

            if let b = imageRow { detail(String(localized: "Bild"), b).kern() }
            if let t = audioRow { detail(String(localized: "Ton"), t).kern() }
            if let u = underTitleRow { detail(String(localized: "Untertitel"), u).kern() }
            if let d = fileRow { detail(String(localized: "Datei"), d).kern() }

            if let values {
                bufferRow(values).kern()
                // Outside measure mode only if something was lost, in which case it is
                // the answer to "why does this stutter?".
                if measure || loss(values) { lossRow(values) }
            }

            if measure {
                if let m = matroskaRow { measureRow(m, conspicuous: false) }
                if let z = timeRow { measureRow(z, conspicuous: false) }
                #if os(tvOS)
                tickRow
                #endif
                if let values {
                    // **A hairline, no spacing.** What is above describes the file; what is
                    // below counts up while playing.
                    Rectangle().fill(Theme.margin)
                        .frame(width: far ? 260 : 150, height: 1)
                        .padding(.vertical, spacing / 2)

                    measureRow("\(String(localized: "Demuxer")) \(values.demuxer)", conspicuous: false)
                    showsRow(values)
                    runRow(values)
                    screenRow()
                    decodeRow(values)
                    streamRow(values)
                }
            }
        }
        .clipped()
        // **The scale instead of own grades, and digits instead of monospace.**
        // The whole badge used to be in a monospace face with its own sizes
        // (12/24). That face makes every line a fifth wider, and with a fixed
        // width wider means more two-line entries. Equal-width digits are enough
        // to keep the counters from jittering as they count up.
        .font(Theme.small.monospacedDigit())
        .foregroundStyle(Theme.font)
        // **A fixed width, otherwise the longest line runs out.**
        //
        // A `VStack` in an overlay gets as much room as it wants, and the line
        // with the three counters is the longest. On tvOS it sat half outside the
        // badge. With a width it wraps instead of escaping. `TruncatedList` passes
        // the height through: it needs the offered one to derive the maximum
        // height from it.
        .frame(width: far ? 420 : 260, alignment: .leading)
        .padding(.horizontal, far ? 20 : 12)
        .padding(.vertical, far ? 16 : 10)
        .background {
            // Opaque, not translucent: the badge lies over a moving picture, and over
            // a moving picture any transparency is sometimes readable and sometimes
            // not. The same decision as for the bars.
            // **0.88 instead of 0.82.** The most critical color on the badge is
            // `warning` (#E8833A), and at 0.82 over a white picture it reached only
            // 4.38:1, below the 4.5 limit. At 0.88 it is 5.40:1.
            RoundedRectangle(cornerRadius: far ? Theme.cornerSmall : Theme.corner, style: .continuous)
                // 0.78 like the tile badge and the checkmark on the episode row: the same
                // job, the same number.
                .fill(Theme.reason.opacity(0.78))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Zeilen

    /// The delivery mode, and it is the only colored line.
    ///
    /// Direct Play and Direct Stream look the same: both are lossless, and the
    /// distinction only matters to someone looking for it. Only transcoding
    /// stands out because it is the one thing this app promises to avoid.
    private var headerLine: some View {
        Text(verbatim: TechDetails.delivery(plan.method))
            // One step above the lines, semibold: bold appears exactly once, at the
            // page title.
            .font(Theme.tile.weight(.semibold))
            .foregroundStyle(TechDetails.weight(plan.method) == .good
                             ? Theme.accent : Theme.warning)
    }

    /// Codec, resolution and HDR kind in one line.
    ///
    /// **Which HDR kind the file carries** (user request): HDR10, HDR10+,
    /// Dolby Vision with profile, HLG or SDR. This is the file's format, not
    /// the output: whether the device outputs HDR or VLC maps to SDR is not
    /// reliably known here (`TechDetails.dynamics`). The frame rate shows
    /// only in measure mode: it explains stutter at the screen's refresh rate,
    /// which is a question for debugging.
    private var imageRow: String? {
        let parts = [
            TechDetails.codecNameValue(video?.codec),
            TechDetails.imageRow(width: video?.width, height: video?.height,
                                     depth: nil, reach: nil),
            TechDetails.dynamics(video),
            measure ? TechDetails.frameRate(video?.frameRate).map { "\($0) fps" } : nil
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var audioRow: String? {
        guard let name = TechDetails.codecNameValue(audio?.codec) else { return nil }
        var text = name
        if let k = TechDetails.channelWord(audio?.channels) { text += " · \(k)" }
        if let language = TechDetails.language(audio?.language) { text += " · \(language)" }
        return text
    }

    private var underTitleRow: String? {
        guard let name = TechDetails.codecNameValue(subtitle?.codec) else { return nil }
        var text = name
        if let language = TechDetails.language(subtitle?.language) { text += " · \(language)" }
        return text
    }

    /// Container, size and what the file needs on average.
    ///
    /// **`FileDetails.container` already includes the size.** Here
    /// `size(source)` was added as well, and since that one also comes with
    /// its own separator, the badge read "File MP4 · 0.3 GB ·  · 0.3 GB". Two
    /// building blocks that both do more than their name says, and both were
    /// added instead of reading one.
    ///
    /// **The average bitrate sits here and is no longer its own line**
    /// ("File needs"): size divided by runtime. Next to the intake in the
    /// buffer line it says whether the stream keeps up. Peaks lie above the
    /// average; being only slightly above is still a problem.
    private var fileRow: String? {
        guard let source, let c = FileDetails.container(source) else { return nil }
        guard let rate = TechDetails.bitrate(bytesJeSecond.map { $0 * 8 }) else { return c }
        return "\(c) · Ø \(rate)"
    }

    /// Size divided by runtime. `nil` while either is missing.
    private var bytesJeSecond: Double? {
        guard let bytes = source?.size, bytes > 0,
              let duration = area?.durationSeconds, duration > 1 else { return nil }
        return Double(bytes) / duration
    }

    /// **How much reserve lies ahead of the playhead, and what arrives.**
    ///
    /// VLC gives no buffer seconds, but it counts both things needed for it:
    /// what came from the network and what the demuxer has already consumed.
    /// The difference, divided by what the file needs per second, is seconds
    /// (`Counter.reserveSeconds`).
    ///
    /// Another client playing the same file smoothly from the same server
    /// shows exactly this number, at a good eleven seconds. It is the only
    /// one that tells beforehand whether it is about to hang: as it approaches
    /// zero, the picture freezes one to two seconds later. The average as
    /// denominator is coarse but accurate enough for "does the reserve last or
    /// not"; in measure mode the raw bytes are shown next to it.
    private func bufferRow(_ w: PlayValues) -> some View {
        let seconds = bytesJeSecond.flatMap { w.mediaWork.reserveSeconds(bytesJeSecond: $0) }
        var parts: [String] = []
        if let seconds { parts.append(comma(seconds) + " s") }
        if measure { parts.append("\(w.mediaWork.preAdviceBytes / 1024) KiB") }
        parts.append("\(String(localized: "Eingang")) \(w.input)")
        return detail(String(localized: "Puffer"), parts.joined(separator: " · "),
                      conspicuous: (seconds ?? .infinity) < 2)
    }

    private func comma(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    private func loss(_ w: PlayValues) -> Bool {
        w.discarded > 0 || w.tooLate > 0 || w.audioLost > 0
    }

    /// **The line this badge exists for.**
    ///
    /// Dropped and late frames are the difference between "runs" and "just
    /// barely runs": a stalling picture and one that silently drops frames
    /// look the same from three meters. A zero here means it was the network
    /// or the server; a number here means it was the decoder.
    private func lossRow(_ w: PlayValues) -> some View {
        measureRow("\(String(localized: "Verworfen")) \(w.discarded)"
                  + " · \(String(localized: "zu spät")) \(w.tooLate)"
                  + " · \(String(localized: "Ton weg")) \(w.audioLost)",
                  conspicuous: loss(w))
    }

    /// A statement for viewers: name quiet, value bright. When it stands out,
    /// it is entirely in `warning` and with a symbol, like `measureRow`.
    @ViewBuilder
    private func detail(_ name: String, _ value: String, conspicuous: Bool = false) -> some View {
        if conspicuous {
            measureRow("\(name) \(value)", conspicuous: true)
        } else {
            Text(verbatim: name).foregroundStyle(Theme.fontQuiet)
                + Text(verbatim: " \(value)").foregroundStyle(Theme.font)
        }
    }

    /// **Did the Matroska trick take effect?**
    ///
    /// `:demux=mkv_trusted` is the difference between a seek of one second and
    /// one of twenty, and whether it applies is decided by the **extension of
    /// the delivered URL**, not the file's container. The two diverged once
    /// before, which is why both are shown here.
    private var matroskaRow: String? {
        let names = ["mkv", "matroska", "webm", "mka", "mks"]
        let container = (source?.container ?? "").lowercased()
        guard names.contains(where: { container.contains($0) }) else { return nil }
        let suffix = plan.url.pathExtension.lowercased()
        let address = suffix.isEmpty ? String(localized: "ohne Endung") : "." + suffix
        let quirk = (area?.matroskaTrusted ?? false)
            ? String(localized: "vertraut") : String(localized: "MISSTRAUT")
        return "\(String(localized: "Matroska")) \(quirk) · \(address)"
    }

    /// Where in the film we are. **So that a screenshot names a position**
    /// and not only a state: "at 41:12" can be reproduced, "somewhere in the
    /// middle" cannot.
    private var timeRow: String? {
        guard let area, area.durationSeconds > 1 else { return nil }
        return "\(String(localized: "Stelle")) \(clock(area.positionSeconds))"
            + " / \(clock(area.durationSeconds))"
    }

    private func clock(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds))
        let s = whole % 60, m = (whole / 60) % 60, h = whole / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// **The number that clears or convicts the player.**
    ///
    /// What actually lands on screen per second, next to what the file
    /// specifies. If both are equal, every frame arrives on time, and what you
    /// see is produced afterwards: by the screen's refresh rate or in the file
    /// itself. If the first is below without "dropped" rising, the decoder
    /// hangs.
    private func showsRow(_ w: PlayValues) -> some View {
        let should = video?.frameRate
        // The suffix says what is averaged over; otherwise the number looks like
        // an instantaneous value and every fluctuation reads as an event.
        var text = "\(String(localized: "Zeigt Ø")) "
        if let actualValue = w.showsProSecond {
            text += String(format: "%.1f", actualValue).replacingOccurrences(of: ".", with: ",")
        } else {
            text += "—"
        }
        text += " fps · \(String(localized: "Gezeigt")) \(w.shown)"
        // **A short window is noisy.**
        //
        // Two seconds are about forty-eight frames; one frame more or less at the
        // window edge is already 0.5 fps. With a half-frame tolerance the line
        // showed orange even though the eight-second average was exactly the
        // file's rate. Only two frames of difference exceed the edge.
        let lags = if let actualValue = w.showsProSecond, let should { actualValue < should - 2 } else { false }
        return measureRow(text, conspicuous: lags)
    }

    /// **The only number that really measures hanging.**
    ///
    /// A film runs in real time: in one second the position advances one
    /// second. `Run 100 %` means playback keeps pace with the clock; anything
    /// below is lost time, exactly the kind seen as stalling.
    ///
    /// It is here because `Gezeigt` claims the opposite when things get tight:
    /// VLC redraws a standing picture as long as nothing follows, and counts
    /// every repetition as a shown frame. While hanging, that counter thus
    /// runs *faster*. In one measurement 1015 shown frames stood at position
    /// 0:28 where 671 would belong, while the picture visibly stood still.
    private func runRow(_ w: PlayValues) -> some View {
        var text = "\(String(localized: "Lauf")) "
        if let share = w.runShare {
            text += "\(Int((share * 100).rounded())) %"
        } else {
            text += "—"
        }
        // Below 97 percent it is no longer measurement noise: that is more than
        // a second and a half per minute.
        let hanging = (w.runShare ?? 1) < 0.97
        return measureRow(text, conspicuous: hanging)
    }

    /// **At how many Hz the screen serves this app, measured.**
    ///
    /// The number decides whether a file *can* run smoothly at all: 23.976 does
    /// not divide into 60 Hz (2.503) and nearly does into 120 Hz (5.005). If
    /// this shows 60 on a device capable of 120, every pan stutters without a
    /// single frame being lost, which is exactly when every other number on
    /// this badge looks clean.
    @ViewBuilder private func screenRow() -> some View {
        if let hz = screenHertz {
            let tight = hz < 70
            measureRow("\(String(localized: "Schirm")) \(Int(hz.rounded())) Hz",
                      conspicuous: tight)
        }
    }

    /// **The line that separates decoder and output.**
    ///
    /// If the reserve is full and the position still falls behind, the
    /// bottleneck is behind the demuxer, and there are exactly two places for
    /// it. If the file's frame rate shows here, the decoder is fast enough and
    /// the output does not keep pace. If less shows, the decoder itself is too
    /// slow.
    private func decodeRow(_ w: PlayValues) -> some View {
        let should = video?.frameRate
        var text = "\(String(localized: "Dekodiert Ø")) "
        if let actualValue = w.decodedProSecond {
            text += String(format: "%.1f", actualValue).replacingOccurrences(of: ".", with: ",")
        } else {
            text += "—"
        }
        text += " fps"
        // Two frames of difference, as for the shown line: below that it is the
        // window edge and not an event.
        let lags = if let actualValue = w.decodedProSecond, let should { actualValue < should - 2 } else { false }
        return measureRow(text, conspicuous: lags)
    }

    /// **What was broken in the stream itself.**
    ///
    /// Corrupted blocks are the number behind "there were picture errors",
    /// jumps the one behind "the audio drifts away". Both say something the
    /// dropped frames do not: there the decoder is overloaded, here what it
    /// should decode arrived already broken.
    private func streamRow(_ w: PlayValues) -> some View {
        let bad = w.beschaedigt > 0 || w.jumps > 0
        return measureRow("\(String(localized: "Beschädigt")) \(w.beschaedigt)"
                         + " · \(String(localized: "Sprünge")) \(w.jumps)",
                         conspicuous: bad)
    }

    #if os(tvOS)
    /// **The line that explains stutter without loss.**
    ///
    /// Measured on two screenshots 22 seconds apart: 539 shown frames in 22
    /// seconds, exactly the file's rate, with no dropped frame, no late one,
    /// nothing corrupted and no new jump. It still visibly stuttered.
    ///
    /// If every frame arrives and is shown on time and it still stalls, the
    /// cause is no longer playback but the **screen's refresh rate**: 23.976
    /// does not divide into 60 Hz, so every second frame is shown three times
    /// and every other twice. Motion alternates between too fast and too slow,
    /// and **no counter reports anything** because no frame is lost. That is
    /// what `FrameTick` is for, and without this line it could not be seen
    /// whether it takes effect.
    private var tickRow: some View {
        let measured = area.flatMap { FrameTick.rate(from: $0.player) }
        let claims = video?.frameRate
        let rate = TechDetails.frameRate(measured ?? claims)
        let tick = FrameTick.screenTick

        let word: String
        let fits: Bool
        if let target = FrameTick.demanded {
            // **Exact to the decimal, not rounded.** This used `%.0f`, turning 23.976
            // into "24 Hz", exactly the mix-up this line is about. The real value is
            // requested; that the screen reports it as 24 is its rounding, not ours.
            word = String(localized: "angefordert \(TechDetails.frameRate(target) ?? "?") Hz")
            fits = true
        } else {
            switch FrameTick.state {
            case .ready:
                word = String(localized: "ohne Wechsel")
                // Without a switch it only works out if the screen fits anyway.
                fits = (measured ?? claims).map {
                    abs(($0 * 2).rounded() - $0 * 2) < 0.5
                        && Int(($0 * 2).rounded()) % 2 == 0
                        ? Int($0.rounded()) != 0 && tick % Int($0.rounded()) == 0
                        : tick % 24 == 0
                } ?? false
            case .disabled:
                word = String(localized: "Anpassung aus")
                fits = false
            case .inSwiftlyOut:
                // Not a defect but a choice, hence not orange.
                word = String(localized: "in Swiftly aus")
                fits = true
            case .unreachable:
                word = String(localized: "Anzeige stumm")
                fits = false
            }
        }
        return measureRow("\(String(localized: "Takt")) \(rate ?? "?") fps"
                         + " · \(word) · \(String(localized: "Schirm")) \(tick) Hz",
                         conspicuous: !fits)
    }
    #endif

    /// **A measurement line that stands out, and not only through color.**
    ///
    /// At eight places a line was recolored from `schriftLeise` to `warning`
    /// and nothing else changed: same wording, same grade, no symbol. Whoever
    /// cannot tell orange from gray saw eight identical lines, and the badge
    /// said nothing to them, which is exactly its purpose. The rule: status through shape too, not only color.
    ///
    /// The symbol is the same one `ProofRow` in `Style.swift` uses for the
    /// same occasion, `exclamationmark.triangle.fill`. Two symbols for one
    /// meaning would be a second language.
    @ViewBuilder private func measureRow(_ text: String, conspicuous: Bool) -> some View {
        if conspicuous {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Theme.badge)
                Text(verbatim: text)
            }
            // `warning` on the badge surface: 5.40:1 at 0.88 opacity.
            .foregroundStyle(Theme.warning)
        } else {
            Text(verbatim: text).foregroundStyle(Theme.fontQuiet)
        }
    }
}

/// **A column with a maximum height that omits instead of scrolling.**
///
/// Core lines (`kern()`) always show. The rest it takes from the top as
/// long as they fit in `share` of the offered height, and it stops at the
/// first that no longer fits, even if a shorter one after it would still
/// have room. The order is the ranking; a later line overtaking an earlier
/// one would leave a hole in the middle.
///
/// The offered height is that of the overlay above the picture: call sites
/// place the badge in a frame reaching to all edges, which passes its
/// height through. Without an offer (`nil`) or without `share` there is
/// no limit.
private struct TruncatedList: Layout {
    var spacing: CGFloat
    var share: CGFloat?

    /// The size of each line that shows, `nil` for the omitted ones.
    private func metrics(_ offering: ProposedViewSize, _ rows: Subviews) -> [CGSize?] {
        var limit = CGFloat.infinity
        if let share, let height = offering.height, height.isFinite { limit = height * share }
        var sum: CGFloat = 0
        var full = false
        var result: [CGSize?] = []
        for row in rows {
            let size = row.sizeThatFits(ProposedViewSize(width: offering.width, height: nil))
            let new = sum + (sum == 0 ? 0 : spacing) + size.height
            let kern = row[CoreRow.self]
            if !kern && (full || new > limit) {
                full = true
                result.append(nil)
                continue
            }
            sum = new
            result.append(size)
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let state = metrics(proposal, subviews).compactMap { $0 }
        let height = state.map(\.height).reduce(0, +) + spacing * CGFloat(max(state.count - 1, 0))
        return CGSize(width: proposal.width ?? state.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let metrics = metrics(proposal, subviews)
        var y = bounds.minY
        for (row, size) in zip(subviews, metrics) {
            if let size {
                row.place(at: CGPoint(x: bounds.minX, y: y),
                            proposal: ProposedViewSize(width: bounds.width, height: size.height))
                y += size.height + spacing
            } else {
                // Every line must be placed, otherwise SwiftUI puts it in the middle.
                // The rest land below the badge without a size, and `clipped` in the
                // badge cuts them off.
                row.place(at: CGPoint(x: bounds.minX, y: bounds.maxY), proposal: .zero)
            }
        }
    }
}

/// Marks a line that `TruncatedList` never omits.
private struct CoreRow: LayoutValueKey {
    static let defaultValue = false
}

private extension View {
    /// A core line of the tech badge: always shows, see `TruncatedList`.
    func kern() -> some View { layoutValue(key: CoreRow.self, value: true) }
}
