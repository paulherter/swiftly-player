import JellyfinKit
import SwiftUI

/// App settings.
///
/// Holds what concerns the app. Everything about playback lives on a page of its
/// own, otherwise the same thing would appear in two places. This split matches
/// the iPhone version and stays the same on all platforms.
struct SettingsView: View {
    let model: AppModel
    let back: () -> Void

    @Environment(Navigator.self) private var navigator
    @Environment(\.section) private var section
    @State private var verification: String?
    @State private var examine = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SubpageHeader(title: "Einstellungen", back: back)

                // **Two columns, left-aligned, as on iPad.**
                //
                // The page used to sit in a 560 pt column in the middle of the window: sidebar on
                // the left, nothing on the right, and content starting at no edge that exists
                // elsewhere on the page. Every other page starts at the left edge of its area.
                //
                // The split follows the iPad version: everything about this device in the left
                // column, the server alone in the right. It is the only group not about this
                // device, and it is short; stacked, two thirds of the page would stay empty next
                // to it.
                //
                // The gap is a double side margin, so the two cards relate to each other like
                // they do to the window edge. **Each column ends at `formWidth`.** At
                // `maxWidth: .infinity` in a 1366 frame each column was 659 pt wide, holding a row
                // of icon, one word and a switch: stretched and flat, as on the profile page. A
                // list of rows is a form, not running text.
                HStack(alignment: .top, spacing: Theme.edgeSpacing * 2) {
                    VStack(alignment: .leading, spacing: 0) {
                        offline
                        integration
                    }
                    .frame(maxWidth: Theme.formWidth, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        server
                        // Custom headers for a service in front of the server (issue #4), collapsed under
                        // the group.
                        MacOwnHeaders(model: model)
                    }
                    .frame(maxWidth: Theme.formWidth, alignment: .leading)
                    Spacer(minLength: 0)
                }

                // The version is a minor detail: 12 pt in `schriftSehrLeise`. White at 30 % has a
                // computed contrast of 2.67:1 and is explicitly among the forbidden values.
                Text(verbatim: Version.withBase)
                    .font(Theme.small)
                    .foregroundStyle(Theme.fontVeryQuiet)
                    .padding(.top, 26)
            }
            .frame(maxWidth: Theme.settingWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.edgeSpacing)
            .padding(.top, Theme.contentTop)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        // **The milky bar at the top edge.** macOS 26 places it over every scroll area by
        // itself. It was never in our code, which is why searching our code found nothing.
        // Over an image it blended in; on plain background on the left it showed as a bar.
        //
        // What the framework adds unasked has to be switched off just like what we write.
        .pagesScroll()
    }

    // **`playback` and `presentation` do not belong here.** They go in the profile,
    // next to Quick Connect, as on iPhone, iPad and TV. Promising *all* settings in one
    // place via Command-comma shrank the profile to one row and buried appearance two
    // levels deep. What stays here concerns the device: offline, integration, server.

    /// **A group of its own, before integration.**
    ///
    /// Not under *Appearance*: downloads are not a matter of taste but a feature that
    /// takes up space. Not under *Integration*: that is for third-party services.
    /// Off by default, so exactly one row appears here.
    private var offline: some View {
        SettingGroup(title: "Offline") {
            ToggleRow(symbol: "arrow.down.circle",
                          title: Text("Downloads"),
                          under: Text("Titel auf diesen Mac laden und offline schauen"),
                          an: Binding(get: { model.downloadsAn },
                                      set: { an in
                                          if an || model.downloads.entries.isEmpty {
                                              model.downloadsAn = an
                                          } else {
                                              disablePrompt = true
                                          }
                                      }))
            if model.downloadsAn {
                ToggleRow(symbol: "wifi",
                              title: Text("Nur über WLAN"),
                              under: Text("Downloads warten, bis du im WLAN bist"),
                              an: Binding(get: { model.onlyOverWLAN },
                                          set: { model.onlyOverWLAN = $0 }))
                ValuesRow(symbol: "internaldrive",
                           title: Text("Speicher"),
                           under: Text("\(model.downloads.entries.count) Titel auf diesem Mac"),
                           value: DownloadRules.size(
                               DownloadRules.allocation(model.downloads.entries).bytes))
            }
        }
        // **Switching off never deletes anything unasked.** On the Mac the confirmation is
        // a system dialog instead of a sheet: the question belongs to the window, not to a
        // row in it.
        .confirmationDialog(Text("Downloads ausschalten?"),
                            isPresented: $disablePrompt) {
            Button("Behalten") { model.downloadsAn = false }
            Button("Alles entfernen", role: .destructive) {
                model.downloads.allRemove()
                model.downloadsAn = false
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(verbatim: disableText)
        }
    }

    @State private var disablePrompt = false

    private var disableText: String {
        let b = DownloadRules.allocation(model.downloads.entries)
        return String(localized: "\(b.count) Titel bleiben auf diesem Mac")
            + " · " + DownloadRules.size(b.bytes)
    }

    /// **Between Offline and Server, deliberately.** It is a second service, not a
    /// second server, and an add-on: anyone who connects nothing sees nothing of it
    /// apart from this one row.
    private var integration: some View {
        SettingGroup(title: "Integration") {
            ValuesRow(symbol: "sparkle.magnifyingglass", title: Text("Seerr"),
                       under: Text("Anfragen, was noch nicht da ist"),
                       value: model.seerr.connected ? String(localized: "Verbunden") : nil,
                       action: { navigator.openIt(.seerr, in: section) })
            // **Next to Seerr, and only with credentials in the build** (`TraktAccess`);
            // without them there would be a button that is guaranteed to fail.
            if model.trakt.available {
                SheetLine().padding(.leading, Theme.separatorInsetCard)
                ValuesRow(symbol: "checkmark.circle", title: Text(verbatim: "Trakt"),
                           under: Text("Trägt ein, was du schaust"),
                           value: model.trakt.connected ? String(localized: "Verbunden") : nil,
                           action: { navigator.openIt(.trakt, in: section) })
            }
            // **Here and not under "Playback".** The rows there say *how* something runs.
            // This is the only one in the app that gives something **to the outside**: setting
            // it up tells everyone on one's Discord servers what is being watched. It is a
            // second service like Seerr and, as there, off until someone looks for it.
            //
            // **In the sandbox it is not shown at all**, which is not hiding but the opposite
            // of a half promise. All three ways to Discord were tested on a device:
            //
            // - The socket lives at `/var/folders/.../T/discord-ipc-0`. The sandbox gives the
            // app its **own** `TMPDIR` with none in it. The path has a random part and cannot
            // even be named as an exception.
            // - WebSocket on 6463 **without** an Origin header is the usual workaround on the
            // web: `101 Switching Protocols`, then immediately a close frame "Invalid Origin".
            // An RPC origin can no longer be registered in the portal since its deprecation.
            // - HTTP transport: here the origin check really does not apply, the answer comes
            // with 200 and reads `command not available from "http" transport` (4002).
            //
            // A greyed-out switch raises the question every time; one that is absent raises it
            // once. It is reversible: a build without the sandbox brings the row back with it,
            // without anyone having to remember.
            if !inSandbox {
                SheetLine().padding(.leading, Theme.separatorInsetCard)
                ToggleRow(symbol: "bubble.left.and.text.bubble.right",
                              title: Text(verbatim: "Discord"),
                              under: Text("Zeigt im Profil, was gerade läuft"),
                              an: Binding(get: { model.discordShow },
                                          set: { model.discordShow = $0 }))
            }
        }
    }

    /// Is the app running in the sandbox? In the Store it is mandatory.
    ///
    /// Read from the home directory rather than an environment variable: a sandboxed
    /// app gets its container as home, and that is also why it cannot see Discord's
    /// socket. The check measures the same thing that is the obstacle.
    private var inSandbox: Bool {
        NSHomeDirectory().contains("/Library/Containers/")
    }

    private var server: some View {
        SettingGroup(title: "Server") {
            ValuesRow(symbol: "externaldrive.connected.to.line.below",
                       title: Text(verbatim: model.serverName ?? String(localized: "Server")),
                       value: model.serverVersion ?? "?")
            SheetLine().padding(.leading, Theme.separatorInsetCard)
            ValuesRow(symbol: "wifi", title: Text("Verbindung prüfen"),
                       under: verification.map { Text(verbatim: $0) },
                       value: examine ? String(localized: "Moment…") : nil,
                       action: examine ? nil : { check() })
        }
    }

    // **Rate, Discord and Report a problem are now in the profile**, at the very
    // bottom under Server/Sign out; here they were rarely noticed.

    @Environment(\.openURL) private var open

    private func check() {
        examine = true
        Task {
            verification = await model.connectionCheck(deadline: .seconds(12))
            examine = false
        }
    }
}
