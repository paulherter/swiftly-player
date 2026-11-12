use swiftly_jellyfin::ServerKind;

use crate::bundle::AccountBundle;
use crate::store::kind_name;

/// Where the pointer to the current kind is kept.
pub const POINTER_KEY: &str = "aktiveArt";

pub(crate) const ALL_KINDS: [ServerKind; 3] =
    [ServerKind::Jellyfin, ServerKind::Emby, ServerKind::Plex];

/// Where the bundle of a kind is kept: `konten` stays the Jellyfin bundle.
pub fn bundle_storage_key(kind: ServerKind) -> &'static str {
    match kind {
        ServerKind::Jellyfin => "konten",
        ServerKind::Emby => "konten.emby",
        ServerKind::Plex => "konten.plex",
    }
}

/// One bundle of accounts per kind of server, and which kind is current (`ServerBundles`).
#[derive(Debug, Clone, PartialEq)]
pub struct ServerBundles {
    bundles: [Option<AccountBundle>; 3],
    active_kind: ServerKind,
}

fn slot(kind: ServerKind) -> usize {
    ALL_KINDS.iter().position(|k| *k == kind).unwrap_or(0)
}

impl Default for ServerBundles {
    fn default() -> Self {
        Self::new(Vec::new(), ServerKind::Jellyfin)
    }
}

impl ServerBundles {
    /// From bundles and the wished current kind; falls back to the first kind that has one.
    pub fn new(found: Vec<(ServerKind, AccountBundle)>, active: ServerKind) -> Self {
        let mut bundles = [None, None, None];
        for (k, b) in found {
            bundles[slot(k)] = Some(b);
        }
        let mut s = Self {
            bundles,
            active_kind: active,
        };
        if s.bundle(active).is_none()
            && let Some(first) = s.first_kind()
        {
            s.active_kind = first;
        }
        s
    }

    fn first_kind(&self) -> Option<ServerKind> {
        ALL_KINDS.into_iter().find(|k| self.bundle(*k).is_some())
    }

    /// True when no kind has a bundle.
    pub fn is_empty(&self) -> bool {
        self.first_kind().is_none()
    }

    /// The current kind.
    pub fn active_kind(&self) -> ServerKind {
        self.active_kind
    }

    /// The bundle of the current kind.
    pub fn active(&self) -> Option<&AccountBundle> {
        self.bundle(self.active_kind)
    }

    /// The bundle of one kind.
    pub fn bundle(&self, kind: ServerKind) -> Option<&AccountBundle> {
        self.bundles[slot(kind)].as_ref()
    }

    /// Kinds that have accounts, in the fixed order.
    pub fn kinds(&self) -> Vec<ServerKind> {
        ALL_KINDS
            .into_iter()
            .filter(|k| self.bundle(*k).is_some())
            .collect()
    }

    /// Replaces (or with `None` removes) one bundle; if the current kind loses its bundle,
    /// another kind with accounts takes over.
    pub fn set(&mut self, bundle: Option<AccountBundle>, kind: ServerKind) {
        self.bundles[slot(kind)] = bundle;
        if self.bundle(self.active_kind).is_none()
            && let Some(other) = self.first_kind()
        {
            self.active_kind = other;
        }
    }

    /// Makes a kind current; ignored when it has no bundle.
    pub fn switch_to(&mut self, kind: ServerKind) {
        if self.bundle(kind).is_some() {
            self.active_kind = kind;
        }
    }

    /// Reads from stored bytes by key. An entry that cannot be decoded counts as missing.
    pub fn load(read: impl Fn(&str) -> Option<Vec<u8>>) -> Self {
        let found = ALL_KINDS
            .into_iter()
            .filter_map(|k| {
                let data = read(bundle_storage_key(k))?;
                Some((k, serde_json::from_slice::<AccountBundle>(&data).ok()?))
            })
            .collect();
        let pointer = read(POINTER_KEY)
            .and_then(|d| String::from_utf8(d).ok())
            .and_then(|t| ALL_KINDS.into_iter().find(|k| kind_name(*k) == t));
        Self::new(found, pointer.unwrap_or(ServerKind::Jellyfin))
    }
}
