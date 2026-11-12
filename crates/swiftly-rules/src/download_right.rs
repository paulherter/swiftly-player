//! Port of DownloadRight.swift.
//!
//! May this account download titles to the device? On the server the right is
//! `Policy.EnableContentDownloading`. The decision lives here and only here. (Reading the
//! right from `/Users/{id}` and the 403 on the download address are networking/model code and
//! not ported.)

/// The download right of an account. Raw values are the Swift strings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DownloadPermission {
    /// The server said nothing (`unbekannt`).
    Unknown,
    /// `EnableContentDownloading: true` (`erlaubt`).
    Allowed,
    /// `EnableContentDownloading: false` (`verboten`).
    Forbidden,
}

impl DownloadPermission {
    /// The Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Unknown => "unbekannt",
            Self::Allowed => "erlaubt",
            Self::Forbidden => "verboten",
        }
    }

    /// From the field as `GET /Users/{id}` returns it; `None` means "was not there".
    pub fn from_server(value: Option<bool>) -> Self {
        match value {
            None => Self::Unknown,
            Some(true) => Self::Allowed,
            Some(false) => Self::Forbidden,
        }
    }

    /// `Unknown` counts as allowed, intentionally: only an explicit `false` blocks.
    pub fn may_load(self) -> bool {
        self != Self::Forbidden
    }

    /// Whether a surface shows a download button: the settings switch **and** the right.
    pub fn offer(rights: DownloadPermission, function_on: bool) -> bool {
        function_on && rights.may_load()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Swift: fromServer()
    #[test]
    fn from_server() {
        assert_eq!(
            DownloadPermission::from_server(None),
            DownloadPermission::Unknown
        );
        assert_eq!(
            DownloadPermission::from_server(Some(true)),
            DownloadPermission::Allowed
        );
        assert_eq!(
            DownloadPermission::from_server(Some(false)),
            DownloadPermission::Forbidden
        );
    }

    // Swift: unknownAllowed()
    #[test]
    fn unknown_allowed() {
        assert!(DownloadPermission::Unknown.may_load());
        assert!(DownloadPermission::Allowed.may_load());
        assert!(!DownloadPermission::Forbidden.may_load());
    }

    // Swift: offer()
    #[test]
    fn offer() {
        use DownloadPermission::*;
        assert!(DownloadPermission::offer(Allowed, true));
        assert!(DownloadPermission::offer(Unknown, true));
        assert!(!DownloadPermission::offer(Forbidden, true));
        // Without the switch the feature does not exist at all.
        assert!(!DownloadPermission::offer(Allowed, false));
        assert!(!DownloadPermission::offer(Unknown, false));
        assert!(!DownloadPermission::offer(Forbidden, false));
    }

    #[test]
    fn raw_values_are_the_persisted_strings() {
        assert_eq!(DownloadPermission::Unknown.raw_value(), "unbekannt");
        assert_eq!(DownloadPermission::Allowed.raw_value(), "erlaubt");
        assert_eq!(DownloadPermission::Forbidden.raw_value(), "verboten");
    }
}
