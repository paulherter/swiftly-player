import Foundation
import JellyfinKit

/// The catalog of this UI, read once at startup.
///
/// **Why not `NSLocalizedString`.** On Linux the
/// call uses the bundle's **development language**, here
/// `defaultLocalization: "de"`, although the bundle reports `en` as the
/// preferred language. Linux has no Apple language setting for CFBundle to pick
/// from, so the UI was German for every user regardless of system language. The
/// catalogs were fine; only the lookup path was not.
///
/// ``TextCatalog`` does the lookup itself: language from the environment, file
/// via `url(…, localization:)`, read with `NSDictionary(contentsOf:)`, the way
/// that demonstrably works. It lives in the package because both targets need
/// it; the method is shared, not the content.
let upperAreasCatalog = TextCatalog(bundle: .module)

/// Short path to a translated text from this app's catalog.
///
/// **Why this exists again.** ``JellyfinKit`` has its own catalog and bundle,
/// and a bundle only finds what is inside it. This app's UI ships its own
/// texts, so it needs its own lookup. The two look and are named alike on
/// purpose, so a reader need not wonder which one applies.
///
/// **The key stays a plain `String` here**, unlike in the package, where
/// ``Textschluessel`` catches interpolation. The UI inserts its placeholders
/// itself (`String(format: translated("%@ als gesehen"), name)`), so the
/// placeholder is already in the literal and must not be touched.
///
/// **The German wording is also the key**, the same decision as everywhere in
/// the project. If the catalog is missing, the result is the correct German
/// sentence, not `player.error.42`.
///
/// **Server data never passes through here.** Only literals in the source are
/// translated; a movie title that happens to be "Aus" would otherwise become
/// "Off".
func translated(_ key: String) -> String {
    upperAreasCatalog.text(TextKey(key))
}
