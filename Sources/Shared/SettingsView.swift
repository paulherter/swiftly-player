import JellyfinKit
import SwiftUI

/// App settings.
///
/// Same structure as the profile page: flat rows with hairlines, groups
/// separated only by whitespace and a small spaced-out title.
///
/// This covers what concerns the app. Everything about playback (quality,
/// language, behavior) lives on its own page; otherwise the same thing would
/// appear in two places.
struct SettingsView: View {
    let model: AppModel

    @Environment(\.dismiss) private var back
    @Environment(\.wide) private var wide
    @State private var verification: String?
    @State private var examine = false

    var body: some View {
        ZStack(alignment: .top) {
            // The same background as every other page. It was briefly its own
            // (`gruppengrund`), because pure black under a card was the whole jump at once;
            // since the background is #101010 the jump is a fifth of that and needs no
            // exception.
            Theme.reason.ignoresSafeArea()
            VStack(spacing: 0) {
                // **The title sits next to the arrow, not below it.**
                //
                // It used to be its own line under a floating arrow: two lines for one piece
                // of information, and the arrow belonged to nothing. `SubpageHeader` puts
                // both in one line, the same one that the watchlist and downloaded series
                // already use.
                SubpageHeader(title: String(localized: "Einstellungen")) { back() }
                ScrollView { content }
                    .scrollIndicators(.hidden)
            }
        }
        .overlay(alignment: .topTrailing) {
            // **turning it off deletes nothing unasked.** Silently deleting forty
            // gigabytes someone downloaded over a week would be the worst variant. Kept
            // files reappear as soon as the switch is flipped again.
            ActionSheet(opened: $disableSheet, title: disableTitle, actions: [
                TitleAction(symbol: "tray.and.arrow.down", text: "Behalten") {
                    model.downloadsAn = false
                },
                TitleAction(symbol: "trash", text: "Alles entfernen", cautionary: true) {
                    model.downloads.allRemove()
                    model.downloadsAn = false
                },
            ])
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .background(SwipeBack())
        #endif
    }

    @State private var disableSheet = false

    private var disableTitle: String {
        let b = DownloadRules.allocation(model.downloads.entries)
        return String(localized: "\(b.count) Titel bleiben auf dem Gerät")
            + " · " + DownloadRules.size(b.bytes)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Side by side. Both groups are short; stacked in one column they would leave
            // two thirds of the page empty.
            //
            // Explicitly **not** merged with playback and profile into one page, as the TV
            // does. There the reason is the remote: every saved hop is a saved trip. A tap
            // on the iPad costs nothing.
            if wide {
                // **Zero, since the groups are cards.** Each card already carries
                // `Theme.rand` left and right; with 56 in between, 112 points stood between two
                // cards, which is too narrow for them. The cards carry the spacing themselves
                // now.
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) { offline; integration }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) { server; sync }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                offline
                integration
                server
                sync
            }
            // **Support, always reachable.** Below the device settings, before the
            // version line: it concerns the app, not this device or the server.
            SupportSettingsGroup()

            // **Not typed.** This used to say "Swiftly 1.0", a number that became wrong
            // long ago and that nobody updates. The Mac already read it from the bundle;
            // this was the last copy. Use the component, not a third copy: degree, color
            // and scaling live in `Footer`.
            HStack(spacing: 8) {
                Footer(Text(verbatim: Version.withBase))
                SupporterMark()
            }
                .padding(.horizontal, Theme.margin(wide: wide))
                .padding(.top, 26)
        }
        .padding(.bottom, 40)
    }

    // MARK: Gruppen

    // **Appearance is no longer here**, but its own page in the profile next to
    // "Playback", together with the home page, without a submenu inside a submenu.

    /// **A group of its own, placed before integration.**
    ///
    /// Not under *Appearance*: downloads are not a matter of taste but a function
    /// that occupies space on the device. Not under *Integration*: that is for
    /// third-party services. And before *Server*, because it concerns this device,
    /// not that one.
    ///
    /// **** off by default, and then exactly one row appears here.
    private var offline: some View {
        SettingGroup(title: "Offline") {
            ChoiceRow(symbol: "arrow.down.circle",
                      title: Text("Downloads"),
                      under: Text("Titel aufs Gerät laden und offline schauen"),
                      an: Binding(get: { model.downloadsAn },
                                  set: { an in
                                      if an { model.downloadsAn = true }
                                      // turning it off deletes nothing unasked. If nothing is stored, there
                                      // is nothing to ask.
                                      else if model.downloads.entries.isEmpty { model.downloadsAn = false }
                                      else { disableSheet = true }
                                  }))
            if model.downloadsAn {
                SheetLine()
                ChoiceRow(symbol: "wifi",
                          title: Text("Nur über WLAN"),
                          under: Text("Downloads warten, bis du im WLAN bist"),
                          an: Binding(get: { model.onlyOverWLAN },
                                      set: { model.onlyOverWLAN = $0 }))
                SheetLine()
                ChoiceRow(symbol: "play.square.stack",
                          title: Text("Nächste Folge laden"),
                          under: Text("Lädt die nächste, löscht die gesehene"),
                          an: Binding(get: { model.downloads.nextAuto },
                                      set: { model.downloads.nextAuto = $0 }))
                SheetLine()
                // **The number is in the row, not behind it.** Anyone who wants to know how
                // much is used should not have to tap; it is the only piece of information
                // here.
                ValueRow(symbol: "internaldrive",
                          title: Text("Speicher"),
                          under: Text("\(model.downloads.entries.count) Titel auf diesem Gerät"),
                          value: DownloadRules.size(
                              DownloadRules.allocation(model.downloads.entries).bytes))
            }
        }
    }

    /// **Sits between Offline and Server, on purpose.** It is a second service,
    /// not a second server, and it is an extra: whoever connects nothing sees
    /// nothing of it except this one row.
    private var integration: some View {
        SettingGroup(title: "Integration") {
            NavigationLink(value: SeerrRoute()) {
                ValueRow(symbol: "sparkle.magnifyingglass", title: Text("Seerr"),
                          under: Text("Anfragen, was noch nicht da ist"),
                          value: model.seerr.connected ? String(localized: "Verbunden") : nil)
            }
            // **`PressRow`, not `PressButton`.** The row is edge to edge and as wide as
            // the card; shrinking it by 0.97 visibly detaches it from the rows above. A row
            // acknowledges with area, a compact control with scale.
            .buttonStyle(Theme.PressRow())
            // **Only if the build has the Trakt application's credentials**
            // (`TraktAccess`). Without them there would be a button that is guaranteed to
            // fail.
            if model.trakt.available {
                SheetLine()
                NavigationLink(value: TraktRoute()) {
                    ValueRow(symbol: "checkmark.circle", title: Text(verbatim: "Trakt"),
                              under: Text("Trägt ein, was du schaust"),
                              value: model.trakt.connected ? String(localized: "Verbunden") : nil)
                }
                .buttonStyle(Theme.PressRow())
            }
        }
    }

    private var server: some View {
        let trigger: (() -> Void)? = examine ? nil : { check() }

        return SettingGroup(title: "Server") {
            ValueRow(symbol: "externaldrive.connected.to.line.below",
                      title: Text(verbatim: model.serverName ?? "Server"),
                      value: model.serverVersion ?? "?")
            SheetLine()
            ValueRow(symbol: "wifi", title: Text("Verbindung prüfen"),
                      under: verification.map { Text(verbatim: $0) },
                      value: examine ? String(localized: "Moment…") : nil,
                      action: trigger)
            SheetLine()
            // **Custom headers, issue #4.** Only for servers behind a service like
            // Cloudflare Access; everyone else never enters.
            NavigationLink {
                OwnHeadersPage(model: model)
            } label: {
                ValueRow(symbol: "key", title: Text("Eigene Header"),
                          under: Text("Für einen Dienst vor dem Server"),
                          value: model.ownHeaders(for: model.session?.serverURL).isEmpty
                              ? nil : String(model.ownHeaders(for: model.session?.serverURL).count))
            }
            .buttonStyle(Theme.PressRow())
        }
    }

    /// **Settings follow the account to every device** (`SettingsSyncRun`). On by default.
    private var sync: some View {
        SettingGroup(title: "Konto") {
            ChoiceRow(symbol: "arrow.triangle.2.circlepath",
                      title: Text("Einstellungen auf allen Geräten gleich halten"),
                      under: Text("Sprachen, Überspringen und Startseite liegen auf deinem Server"),
                      an: Binding(get: { model.settingsSync.on },
                                  set: { model.settingsSync.on = $0 }))
        }
    }

    // MARK: Kleinkram

    @Environment(\.openURL) private var open



    private func check() {
        examine = true
        Task {
            verification = await model.connectionCheck(deadline: .seconds(12))
            examine = false
        }
    }
}
