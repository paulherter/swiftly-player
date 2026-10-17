import Foundation

/// May this account download titles to the device? On the server the right is
/// `Policy.EnableContentDownloading`, in the dashboard "Allow media downloading".
///
/// **Measured against Jellyfin 12.0.0:** of 409 operations in the server's
/// OpenAPI document, exactly **one** carries the `Download` permission:
/// `GET /Items/{itemId}/Download`, with a 403 among its responses.
/// `GET /Videos/{itemId}/stream` carries **none**. And that is exactly
/// Swiftly's download address
/// (``JellyfinClient/downloadURL(itemID:mediaSourceID:)``), whose comment even
/// justifies it by this route not needing the right. It really did not need it:
/// the checkbox was off, the button was there, and the file came anyway. No
/// code read the right.
///
/// **The decision lives here and only here.** Six surfaces ask
/// ``anbieten(rights:functionOn:)``, so that none of them answers differently;
/// a second list in Kotlin or a copy in GTK would be exactly the mistake
/// `loadMore()` made once before.
public enum DownloadPermission: String, Sendable, Equatable, CaseIterable {

    /// The server said nothing: old Jellyfin, no `Policy` block, or the request
    /// did not get through.
    case unknown = "unbekannt"
    /// `EnableContentDownloading: true`.
    case allowed = "erlaubt"
    /// `EnableContentDownloading: false`.
    case forbidden = "verboten"

    /// From the field as `GET /Users/{id}` returns it; `nil` means "was not
    /// there".
    public static func fromServer(_ value: Bool?) -> DownloadPermission {
        guard let value else { return .unknown }
        return value ? .allowed : .forbidden
    }

    /// **`unknown` counts as allowed**, and that is intentional.
    ///
    /// A network error, an older server or a missing field must not take away
    /// anything a person is allowed to do. Only an explicit `false` blocks, the
    /// same direction as ``Weiterschalten``, where a silent server leaves the
    /// app's default in place.
    public var mayLoad: Bool { self != .forbidden }

    /// Whether a surface shows a download button.
    ///
    /// Two conditions, one answer: the switch in the settings (without it the
    /// feature does not exist at all) **and** the right on the account. If either
    /// is missing, the button is **not there**, rather than there and throwing an
    /// error. A button that is only pressed to fail is worse than none.
    ///
    /// What is already on disk does not depend on this: the "Downloads" tab and
    /// the row in the settings stay tied to the switch, otherwise nobody could
    /// reach their downloaded files to delete them.
    public static func offer(rights: DownloadPermission, functionOn: Bool) -> Bool {
        functionOn && rights.mayLoad
    }
}
