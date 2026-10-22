import JellyfinKit
import SwiftUI

/// Playback: quality, language, behavior.
///
/// Groups, order and texts match the iPhone version. The values come from
/// `Wiedergabewahlen` and `SpeedLevels`, not from separate lists here.
///
/// Only difference: the value list expands **below the row** instead of as a
/// bottom sheet (selection stays in place).
struct PlaybackSettingsView: View {
    let model: AppModel
    let back: () -> Void

    @State private var openList: ListKind?

    enum ListKind { case bitrate, audio, subtitle, back, forward, buffer }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SubpageHeader(title: "Wiedergabe", back: back)

                // **Two columns, left-aligned, as on iPad.** Left: everything audio-related
                // (quality and language). Right: behavior alone. The gap is twice the page margin
                // so the cards sit apart the same way they sit from the window edge.
                HStack(alignment: .top, spacing: Theme.edgeSpacing * 2) {
                    VStack(alignment: .leading, spacing: 0) {
                        quality
                        language
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    behavior
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: Theme.settingWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        // **The milky bar at the top edge.** macOS 26 adds it over every scroll view by
        // itself; it is not in our code. Over the image it was barely visible, on a plain
        // background to the left it showed as a bar. Anything the framework adds unasked
        // has to be switched off just like anything we add ourselves.
        .pagesScroll()
    }

    // MARK: Groups

    private var quality: some View {
        // If the server does not transcode, there is nothing to choose: Direct Play is
        // fixed on and the bitrate is locked.
        let free = model.convertAllowed
        let directPlay = model.alwaysDirectPlay || !free

        return SettingGroup(title: "Qualität") {
            ToggleRow(symbol: "play.fill", title: Text("Immer Direct Play"),
                          under: Text("Der Server wandelt nie um, es läuft immer die Originaldatei"),
                          an: Binding(get: { directPlay },
                                      set: { model.alwaysDirectPlay = $0 }))
                .disabled(!free)
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            ValuesRow(symbol: "chart.bar", title: Text("Höchste Bitrate"),
                       value: Bitrate.text(model.bitratesLimit),
                       arrow: true, action: { toggle(.bitrate) })
                .disabled(directPlay)
                .opacity(directPlay ? 0.4 : 1)
            if openList == .bitrate {
                ValuesList(entries: Bitrate.levels,
                           label: { Bitrate.text($0.value) },
                           isSelected: { $0.value == model.bitratesLimit },
                           select: { model.bitratesLimit = $0.value; close() })
            }
        }
    }

    private var language: some View {
        SettingGroup(title: "Sprache") {
            ValuesRow(symbol: "speaker.wave.2", title: Text("Ton"),
                       value: model.audioLanguage, arrow: true, action: { toggle(.audio) })
            if openList == .audio {
                ValuesList(entries: LanguageSelection.all, label: { $0.name },
                           isSelected: { $0.name == model.audioLanguage },
                           select: { model.audioLanguage = $0.value; close() })
            }
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            ValuesRow(symbol: "captions.bubble", title: Text("Untertitel"),
                       value: model.subtitleLanguage, arrow: true,
                       action: { toggle(.subtitle) })
            if openList == .subtitle {
                ValuesList(entries: LanguageSelection.all(from: String(localized: "Aus")),
                           label: { $0.name },
                           isSelected: { $0.name == model.subtitleLanguage },
                           select: { model.subtitleLanguage = $0.value; close() })
            }
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            ToggleRow(symbol: "text.alignleft", title: Text("Untertitel automatisch"),
                          under: Text("Nur wenn der Ton nicht in der gewählten Sprache läuft"),
                          an: Binding(get: { model.subtitleAutomatic },
                                      set: { model.subtitleAutomatic = $0 }))
        }
    }

    @AppStorage("technikschild") private var techBadge = false
    @AppStorage("introAbspannAuto") private var skipAutomatic = false

    private var behavior: some View {
        SettingGroup(title: "Verhalten") {
            ToggleRow(symbol: "forward.end.fill",
                          title: Text("Nächste Folge automatisch"),
                          an: Binding(get: { model.nextAutomatic },
                                      set: { model.nextAutomatic = $0 }))
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            ToggleRow(symbol: "forward.fill",
                          title: Text("Intro und Abspann automatisch überspringen"),
                          an: $skipAutomatic)
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            // **The switch for the technical badge.**
            //
            // It lives under "Verhalten" rather than with the picture options: it changes
            // nothing about playback, it only shows what playback does. Off by default, like
            // downloads and Seerr.
            ToggleRow(symbol: "waveform.badge.magnifyingglass",
                          title: Text("Technische Daten im Player"),
                          an: $techBadge)
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            ValuesRow(symbol: "gobackward", title: Text("Zurückspulen"),
                       value: "\(model.backSeconds) s", arrow: true,
                       action: { toggle(.back) })
            if openList == .back {
                ValuesList(entries: Span.levels, label: { "\($0.value) s" },
                           isSelected: { $0.value == model.backSeconds },
                           select: { model.backSeconds = $0.value; close() })
            }
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            ValuesRow(symbol: "goforward", title: Text("Vorspulen"),
                       value: "\(model.forwardSeconds) s", arrow: true,
                       action: { toggle(.forward) })
            if openList == .forward {
                ValuesList(entries: Span.levels, label: { "\($0.value) s" },
                           isSelected: { $0.value == model.forwardSeconds },
                           select: { model.forwardSeconds = $0.value; close() })
            }
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            // **Lives under "Verhalten", not under quality.** It does not change the picture,
            // only how much buffer the player keeps before a flaky connection shows through.
            // Same place as on iPhone.
            ValuesRow(symbol: "wifi.exclamationmark", title: Text("Puffer"),
                       value: model.bufferLevel.name, arrow: true,
                       action: { toggle(.buffer) })
            if openList == .buffer {
                ValuesList(entries: BufferLevel.allCases,
                           label: { $0.name },
                           isSelected: { $0 == model.bufferLevel },
                           select: { model.bufferLevel = $0; close() })
            }
        }
    }


    private func toggle(_ list: ListKind) {
        withAnimation(Theme.leap) {
            openList = openList == list ? nil : list
        }
    }

    private func close() {
        withAnimation(Theme.leap) { openList = nil }
    }
}
