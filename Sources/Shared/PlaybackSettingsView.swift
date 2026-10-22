import JellyfinKit
import SwiftUI

/// Everything about playback.
///
/// Deliberately separate from Settings: that holds what concerns the app,
/// appearance and server. If quality were in both places, you would have to guess
/// which one applies.
struct PlaybackSettingsView: View {
    let model: AppModel

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var openList: ListKind?
    /// Which list is **shown**; stays after closing.
    ///
    /// **Without this nothing slides out.** If the content hangs on `openList`, it
    /// disappears at the very moment the motion should start. SwiftUI then has
    /// nothing left to move and fades.
    ///
    /// **Set from the start, not on first open.** Otherwise the card would be inserted
    /// and opened in the same pass the first time, and something that is just being
    /// created cannot slide in from below. With an initial value it hangs there from
    /// the beginning, off screen, and only `openList` changes.
    @State private var shownList: ListKind? = .audio

    private enum ListKind: String, Identifiable {
        case bitrate, audio = "ton", subtitle = "untertitel", back = "zurueck", forward = "vor", buffer = "puffer"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // The same background as every other page. It was briefly its own
            // (`gruppengrund`) because pure black under a card made the whole travel
            // distance at once; since the background is #101010 the jump is a fifth of that
            // and needs no exception.
            Theme.reason.ignoresSafeArea()
            VStack(spacing: 0) {
                // Title beside the arrow, not below it; see `SettingsView`.
                SubpageHeader(title: String(localized: "Wiedergabe")) { back() }
                ScrollView { content }
                    .scrollIndicators(.hidden)
            }
            sheet
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if wide {
                // **Zero, since the groups are cards.** Each card already carries `Theme.rand` on
                // left and right; with 56 in between there were 112 pt between two cards, and
                // they are too narrow for that. The cards carry the spacing themselves now.
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        quality
                        language
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    behavior.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                quality
                language
                behavior
            }

        }
        .padding(.bottom, 40)
    }

    private var quality: some View {
        // If the server does not convert, there is nothing to choose: Direct Play is
        // fixed on, the bitrate is locked.
        let free = model.convertAllowed
        let directPlay = model.alwaysDirectPlay || !free
        let select: (() -> Void)? = directPlay ? nil : { openIt(.bitrate) }

        return SettingGroup(title: "Qualität") {
            ChoiceRow(symbol: "play.fill", title: Text("Immer Direct Play"),
                      under: Text("Der Server wandelt nie um, es läuft immer die Originaldatei"),
                      an: Binding(get: { directPlay },
                                  set: { model.alwaysDirectPlay = $0 }))
                .disabled(!free)
            SheetLine()
            ValueRow(symbol: "chart.bar", title: Text("Höchste Bitrate"),
                      value: Bitrate.text(model.bitratesLimit),
                      dimmedDown: directPlay, action: select)
        }
    }

    private var language: some View {
        SettingGroup(title: "Sprache") {
            ValueRow(symbol: "speaker.wave.2", title: Text("Ton"),
                      value: model.audioLanguage.isEmpty ? String(localized: "Wie die Datei") : model.audioLanguage,
                      action: { openIt(.audio) })
            SheetLine()
            ValueRow(symbol: "captions.bubble", title: Text("Untertitel"),
                      value: model.subtitleLanguage.isEmpty ? String(localized: "Aus") : model.subtitleLanguage,
                      action: { openIt(.subtitle) })
            SheetLine()
            ChoiceRow(symbol: "text.alignleft", title: Text("Untertitel automatisch"),
                      under: Text("Nur wenn der Ton nicht in der gewählten Sprache läuft"),
                      an: Binding(get: { model.subtitleAutomatic },
                                  set: { model.subtitleAutomatic = $0 }))
        }
    }

    @AppStorage("technikschild") private var techBadge = false
    @AppStorage("introAbspannAuto") private var skipAutomatic = false

    private var behavior: some View {
        SettingGroup(title: "Verhalten") {
            ChoiceRow(symbol: "forward.end.fill", title: Text("Nächste Folge automatisch"),
                      an: Binding(get: { model.nextAutomatic },
                                  set: { model.nextAutomatic = $0 }))
            SheetLine()
            ChoiceRow(symbol: "forward.fill", title: Text("Intro und Abspann automatisch überspringen"),
                      an: $skipAutomatic)
            SheetLine()
            // **The switch for the tech badge.**
            //
            // It sits under "Behavior" and not with the picture rules: it changes nothing
            // about playback, it only shows what playback does. Off until someone looks for
            // it, like Downloads and Seerr.
            ChoiceRow(symbol: "waveform.badge.magnifyingglass",
                      title: Text("Technische Daten im Player"),
                      an: $techBadge)
            SheetLine()
            ValueRow(symbol: "gobackward", title: Text("Zurückspulen"),
                      value: "\(model.backSeconds) s",
                      action: { openIt(.back) })
            SheetLine()
            ValueRow(symbol: "goforward", title: Text("Vorspulen"),
                      value: "\(model.forwardSeconds) s",
                      action: { openIt(.forward) })
            SheetLine()
            // **Under "Behavior", not under quality.** It changes nothing about the picture,
            // only how much buffer the player holds before a shaky connection breaks
            // through.
            ValueRow(symbol: "wifi.exclamationmark", title: Text("Puffer"),
                      value: model.bufferLevel.name,
                      action: { openIt(.buffer) })
        }
    }

    /// Open the sheet: set the content first, **then** show it, in two passes, not
    /// one.
    ///
    /// **Otherwise the card measures itself while it is already moving.** Both lines
    /// used to stand one after the other and landed in the same update: the card got
    /// its content and its motion at once. But its height is what the motion depends
    /// on. On the **first** open it was zero (there was no content yet), so the
    /// section was already in place while the rest slid in.
    ///
    /// After that it was no longer noticeable because the previous content stays and
    /// the height was roughly right. Switching from a long to a short list would have
    /// brought it back.
    ///
    /// The `Task` delays showing by one pass: in between, the card is measured once
    /// with its new content, closed and invisible. That costs one frame build and
    /// nothing else.
    private func openIt(_ list: ListKind) {
        shownList = list
        Task { @MainActor in openList = list }
    }

    /// Close, and the content stays, permanently.
    ///
    /// **No timer anymore.** `shownList` used to be cleared after 400 ms; until
    /// then a piece of the card stayed visible at the bottom and then vanished
    /// abruptly. The card is now only moved, so it is outside as soon as the motion
    /// is over and there is nothing to clean up. What remains is a list in memory,
    /// which costs nothing.
    private func closeSheet() {
        openList = nil
    }

    /// **One sheet, not five.**
    ///
    /// There was a `switch` over `shownList`, and each case built its own
    /// `SelectionSheet` with its own generic type (`Bitrate`, `LanguageSelection`, `Span`).
    /// To SwiftUI those are **different views**: on a switch the old one is removed
    /// and a new one inserted, and it is born with `opened == true`. The card then
    /// sits in place immediately and the slide-up is skipped.
    ///
    /// It was visible exactly when you were fast enough: close, immediately tap the
    /// next, and nothing slid up. If you were slow it happened to be right, because
    /// the old view was already gone and the difference went unnoticed.
    ///
    /// The same rule as "never in an `if opened`", only as a `switch`. Hence **one**
    /// sheet over a common row: the identity stays, only the content changes.
    private var sheet: some View {
        SelectionSheet(opened: Binding(get: { openList != nil },
                                    set: { if !$0 { closeSheet() } }),
                     title: sheetTitle,
                     entries: sheetEntries,
                     label: { $0.text },
                     isSelected: { $0.selected },
                     select: { $0.perform() })
    }

    private var sheetTitle: LocalizedStringKey {
        switch shownList {
        case .bitrate:    "Höchste Bitrate"
        case .audio:        "Ton"
        case .subtitle: "Untertitel"
        case .back:    "Zurückspulen"
        case .forward:        "Vorspulen"
        case .buffer:     "Puffer"
        case nil:         ""
        }
    }

    private var sheetEntries: [SelectionEntry] {
        switch shownList {
        case .bitrate:
            Bitrate.levels.map { rung in
                SelectionEntry(id: "b\(rung.value)", text: Bitrate.text(rung.value),
                               selected: rung.value == model.bitratesLimit) {
                    model.bitratesLimit = rung.value
                }
            }
        case .buffer:
            BufferLevel.allCases.map { rung in
                SelectionEntry(id: rung.rawValue, text: rung.name,
                               selected: rung == model.bufferLevel) {
                    model.bufferLevel = rung
                }
            }
        case .audio:
            LanguageSelection.all.map { choice in
                SelectionEntry(id: "t\(choice.value)", text: choice.name,
                               selected: choice.name == model.audioLanguage) {
                    model.audioLanguage = choice.value
                }
            }
        case .subtitle:
            LanguageSelection.all(from: String(localized: "Aus")).map { choice in
                SelectionEntry(id: "u\(choice.value)", text: choice.name,
                               selected: choice.name == model.subtitleLanguage) {
                    model.subtitleLanguage = choice.value
                }
            }
        case .back:
            Span.levels.map { rung in
                SelectionEntry(id: "z\(rung.value)", text: "\(rung.value) s",
                               selected: rung.value == model.backSeconds) {
                    model.backSeconds = rung.value
                }
            }
        case .forward:
            Span.levels.map { rung in
                SelectionEntry(id: "v\(rung.value)", text: "\(rung.value) s",
                               selected: rung.value == model.forwardSeconds) {
                    model.forwardSeconds = rung.value
                }
            }
        case nil:
            []
        }
    }



}


/// A row in a selection sheet, regardless of what it selects.
///
/// **So that there is only one sheet.** The five lists carry different generic
/// types; without a common row they would be five different views, and every
/// switch would remove one and insert the other; see `sheet`.
struct SelectionEntry: Identifiable {
    let id: String
    let text: String
    let selected: Bool
    let perform: () -> Void
}

// MARK: - Zeilen

/// Row with a switch.
struct ChoiceRow: View {
    /// **Locked means dimmed.** `ValueRow` takes `dimmedDown` from outside; here the
    /// lock was hard-coded to `false`, and "Always Direct Play" looked operable even
    /// though `.disabled` was attached. The state comes from the environment so the
    /// call site's `.disabled` is enough and no second value has to sit beside it
    /// that can drift apart.
    @Environment(\.isEnabled) private var operable
    let symbol: String
    /// Deliberately `Text` and not `String` or `LocalizedStringKey`: the rows carry
    /// either a fixed label (`Text("Sprache")`, translated) or a value from the
    /// server such as the server name, which must stay unchanged
    /// (`Text(verbatim:)`). `Text` can do both; two builders per row type would be
    /// the more roundabout way to the same thing.
    let title: Text
    var under: Text?
    @Binding var an: Bool

    var body: some View {
        RowsLayout(symbol: symbol, title: title, under: under,
                     dimmedDown: !operable) {
            ToggleSwitch(an: $an)
        }
        // Not only the capsule: tapping the title toggles too. The capsule stays a
        // button of its own and catches its tap itself.
        .contentShape(Rectangle())
        .onTapGesture {
            Theme.jerk(.lightweight)
            an.toggle()
        }
        // **The whole row is the switch.** VoiceOver used to read the title, the
        // subtitle and then a switch named "On": three stops, and the last lacked what
        // it switches.
        .accessibilityRepresentation { Toggle(isOn: $an) { title } }
        .accessibilityHint(under ?? Text(verbatim: ""))
    }
}

/// Row with a value, optionally tappable.
struct ValueRow: View {
    let symbol: String
    let title: Text
    var under: Text?
    /// The chosen value comes partly from the server (language name), partly from a
    /// list of our own. It therefore stays a string and is translated where it
    /// originates.
    var value: String?
    var dimmedDown = false
    var action: (() -> Void)?

    var body: some View {
        let shell = RowsLayout(symbol: symbol, title: title, under: under,
                                 dimmedDown: dimmedDown) {
            HStack(spacing: 8) {
                if let value {
                    Text(value)
                        // The value grows with it like the title beside it, otherwise half the row would
                        // follow the system font and the other half not.
                        .growing(15)
                        .foregroundStyle(Theme.fontQuiet)
                }
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        // See RootView: 28 percent is 2.50:1.
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .accessibilityHidden(true)
                }
            }
        }
        if let action {
            Button(action: action) { shell }.buttonStyle(Theme.PressButton())
        } else {
            // Title and value as one statement ("Server, 10.9.11").
            shell.accessibilityElement(children: .combine)
        }
    }
}

/// Icon, text, something on the right.
struct RowsLayout<Right: View>: View {
    @Environment(\.wide) private var wide
    let symbol: String
    let title: Text
    var under: Text?
    var dimmedDown: Bool
    @ViewBuilder var right: () -> Right

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: 20)
                // Decorative: without it VoiceOver read symbol names such as
                // "externaldrive.connected.to.line.below".
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // **List row: 15 semibold.** 16 regular was as loud as the explanation below it;
                // the name leads, the value follows.
                title.growing(15, .semibold)
                    // **Dimmed, not translucent**.
                    //
                    // `Theme.font.opacity(0.4)` was on the whole row. Two problems in one value:
                    // computed, that is 3.57:1 on `reason`, below 4.5, and "white 40 %"
                    // is forbidden. And the inner `foregroundStyle` of the subtitle wins over the
                    // outer one, so the subtitle was **not** dimmed and stood at 5.58:1, brighter
                    // than its own title. The ranking flipped exactly in the locked state.
                    .foregroundStyle(dimmedDown ? Theme.fontVeryQuiet : Theme.font)
                if let under {
                    under
                        .growing(12)
                        // When locked, title and subtitle carry the same tone: the distance between them
                        // is kept instead of reversing.
                        .foregroundStyle(Theme.fontVeryQuiet)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
            right()
        }
        // The symbol on the left and everything `right()` returns follow the row's
        // state; the text column sets its own tone.
        .foregroundStyle(dimmedDown ? Theme.fontVeryQuiet : Theme.font)
        .padding(.horizontal, Theme.margin(wide: wide))
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

