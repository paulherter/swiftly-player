import AppKit
import SwiftUI

/// Entry point of the Mac version.
///
/// `hiddenTitleBar` lets content run up under the window buttons; the sidebar keeps
/// `Theme.titleHeight` free at the top so the wordmark does not sit under the three
/// dots. Without that, a grey bar would sit over everything, which does not fit a
/// flat, dark design.
@main
struct SwiftlyApp: App {

    /// Identifier of the one window. A constant so it is the same when opening from
    /// the menu and when explaining.
    static let mainWindow = "hauptfenster"

    /// **So that closing the window does not quit the app.**
    ///
    /// A `Window` without this delegate terminates the program as soon as its only
    /// window closes. That would be Apple's second permitted behaviour, but it is
    /// unusual for a player: Music, TV, VLC and IINA all stay running. With `false`
    /// the app stays in the Dock, and SwiftUI lists the closed window in the "Window"
    /// menu.
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegateObj

    init() {
        #if DEBUG
        // A look at the app's own work, see `WindowOffPull`. Development builds only, and
        // only a tick that watches one file.
        WindowOffPull.eavesdrop()
        // A measured scroll run when the environment requests it, see `ScrollProbe`.
        // Without the variable nothing happens.
        ScrollProbe.start()
        #endif
    }

    var body: some Scene {
        // **`Window`, not `WindowGroup`.** Two reasons, the second more important.
        //
        // 1. App Review rejected the app under guideline 4: "when the user closes the main
        // application window there is no menu item to re-open it." A `Window` is a single
        // named window; SwiftUI keeps it in the "Window" menu permanently, even when it is
        // closed. With `WindowGroup` that menu only listed the currently open windows.
        // 2. **This app cannot have two windows.** `AppModel` is `@State` in `RootView`;
        // every further window would get its own, i.e. a second, signed-out app inside the
        // same process. The "New Window" item was therefore already removed, and with it
        // the only way back. That is exactly the gap App Review saw.
        Window(Text(verbatim: "Swiftly"), id: Self.mainWindow) {
            RootView()
                .frame(minWidth: Theme.windowMinWidth, minHeight: Theme.windowMinHeight)
                // There is no light theme; the design is built for dark. Verbatim from the iPhone
                // version.
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands { MenuBar() }
    }
}

/// The menu bar belongs to the Mac, but it offers **nothing** the UI does not also
/// show. It is a second route to the same actions, not a store of its own.
///
/// Commands therefore go through `AppCommand` as a message to the view instead of
/// carrying logic here.
/// What the frontmost window tells the menu bar: is a film playing, are downloads
/// available?
extension FocusedValues {
    @Entry var playerOpen: Bool?
    @Entry var downloadsAn: Bool?
    @Entry var watchlistShown: Bool?
}

struct MenuBar: Commands {
    @FocusedValue(\.playerOpen) private var playerOpen
    @FocusedValue(\.downloadsAn) private var downloadsAn
    @FocusedValue(\.watchlistShown) private var watchlistShown

    var body: some Commands {
        // Apple's defaults that are not needed: no filler items such as "Print" or "New".
        // **There is no new window**, see the reasoning at the scene: this app cannot have
        // two windows.
        CommandGroup(replacing: .newItem) {}

        // **The way back to the window.** App Review rejected the app exactly here: "when
        // the user closes the main application window there is no menu item to re-open it."
        //
        // Verified, not assumed: neither `WindowGroup` nor `Window` provides an item that
        // brings back a **closed** window by itself. `WindowGroup` only listed the open
        // windows, so the item vanished while the window was open. With `Window` the
        // "Window" menu was empty even with the window open, apart from "Minimize", "Zoom"
        // and "Bring All to Front". So it is provided here.
        CommandGroup(after: .singleWindowList) { WindowOpener() }

        // **Command-comma. Every Mac app has it.**
        //
        // Anyone looking for settings looks in the app menu first, under this shortcut,
        // as natural on the Mac as Command-W to close. Before this, the only route was the
        // profile page at the bottom of the sidebar. `.appSettings` is where AppKit expects
        // the item, so it appears where everyone looks.
        CommandGroup(replacing: .appSettings) {
            CommandButton("Einstellungen…", .settings, ",")
        }

        // **All sections, not three of six.** The sidebar has six; the menu offered Home,
        // Movies, Series and Search. Watchlist and Downloads could only be reached by
        // tabbing without a mouse, and there was no visible focus either.
        CommandMenu(Text("Gehe zu")) {
            CommandButton("Start",     .start,     "1")
            CommandButton("Filme",     .movies,     "2")
            CommandButton("Serien",    .seriesList,    "3")
            CommandButton("Merkliste", .watchlist, "4")
                .disabled(watchlistShown == false)
            CommandButton("Downloads", .downloads, "5")
                .disabled(downloadsAn == false)
            Divider()
            CommandButton("Suchen", .search,  "f")
            Divider()
            CommandButton("Zurück", .back, "[")
        }

        // **What already has keys in the player**, also available in the menu bar. No
        // shortcuts here: Space, arrows and F belong to the player itself (`PlayerScreen`),
        // and a second shortcut on the same key would only reach one of the two.
        CommandMenu(Text("Wiedergabe")) {
            Button("Abspielen") { CommandPost.dispatch(.playToggle) }.disabled(playerOpen != true)
            Button("Zurückspulen") { CommandPost.dispatch(.playBack) }.disabled(playerOpen != true)
            Button("Vorspulen") { CommandPost.dispatch(.playForward) }.disabled(playerOpen != true)
            Button("Pause") { CommandPost.dispatch(.playPause) }.disabled(playerOpen != true)
            Divider()
            Button("Lauter") { CommandPost.dispatch(.louder) }.disabled(playerOpen != true)
            Button("Leiser") { CommandPost.dispatch(.quieter) }.disabled(playerOpen != true)
            Button("Ton aus") { CommandPost.dispatch(.muted) }.disabled(playerOpen != true)
            Divider()
            Button("Vollbild") { CommandPost.dispatch(.playFullscreen) }.disabled(playerOpen != true)
        }
    }
}

/// What the menu bar can trigger. Deliberately small: every case has a visible
/// counterpart in the UI.
enum AppCommand: String {
    case start, movies = "filme", seriesList = "serien", watchlist = "merkliste", downloads, search = "suche", back = "zurueck", settings = "einstellungen"
    /// Player only (the "Playback" menu).
    case playToggle = "spielUmschalten", playPause = "spielPause", playBack = "spielZurueck", playForward = "spielVor", playFullscreen = "spielVollbild", louder = "lauter", quieter = "leiser", muted = "stumm"
}

/// A menu item that sends its command as a message.
///
/// Via `NotificationCenter` rather than a shared state holder: the menu bar lives
/// outside any view, and with several windows there would be no way to decide which
/// one is meant. The frontmost listens, the others do not.
struct CommandButton: View {
    let label: LocalizedStringKey
    let command: AppCommand
    let keyButton: KeyEquivalent

    init(_ label: LocalizedStringKey, _ command: AppCommand, _ keyButton: KeyEquivalent) {
        self.label = label
        self.command = command
        self.keyButton = keyButton
    }

    var body: some View {
        Button(label) { CommandPost.dispatch(command) }
            .keyboardShortcut(keyButton, modifiers: .command)
    }
}

/// The wire between menu bar and view.
enum CommandPost {
    static let name = Notification.Name("de.paulherter.swiftly.kommando")

    static func dispatch(_ command: AppCommand) {
        NotificationCenter.default.post(name: name, object: nil,
                                        userInfo: ["k": command.rawValue])
    }

    static func receive(_ postDirection: Notification) -> AppCommand? {
        guard let raw = postDirection.userInfo?["k"] as? String else { return nil }
        return AppCommand(rawValue: raw)
    }
}

/// This delegate answers one question only, which AppKit asks by itself.
@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}

/// "Window > Swiftly": brings the main window back when closed and to the front
/// when open. `openWindow` does both by itself.
///
/// A view of its own rather than a button in the `Commands` body: `openWindow` comes
/// from the environment, which only exists in a `View`.
struct WindowOpener: View {
    @Environment(\.openWindow) private var openIt

    var body: some View {
        Button { openIt(id: SwiftlyApp.mainWindow) } label: {
            Text(verbatim: "Swiftly")
        }
        .keyboardShortcut("0", modifiers: .command)
    }
}
