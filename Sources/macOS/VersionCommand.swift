import Foundation

/// The menu bar's "Fassung wählen…" (Wiedergabe, Option-Return): the keyboard route to the version list
/// that the Play button lists on a right click.
///
/// The rule lives here, free of any view, so a test can pin it (`Tests/MacMenu`, `Werkzeuge/version-command-test.sh`).
enum VersionCommand {
    /// - `offered`: what the page in front published, whether Play has several versions to choose from;
    ///   `nil` when no detail page is in front (a list, the settings).
    /// - `playerOpen`: a film is playing, the page beneath is not in use.
    static func isEnabled(offered: Bool?, playerOpen: Bool?) -> Bool {
        offered == true && playerOpen != true
    }
}
