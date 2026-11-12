//! The accounts of the real app: the list for the profile hub, switching, and signing one account out. All of it goes
//! through `swiftly-accounts` bundles in the secret store (the same bytes the Swift app writes).

use crate::live::Core;
use swiftly_accounts::{ServerBundles, load_bundles, save_bundles};
use swiftly_jellyfin::ServerKind;
use swiftly_vm::Capabilities;

/// One stored account as the screens show it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    /// `Account.accountKey`, the identity inside the bundles.
    pub key: String,
    /// The user name.
    pub name: String,
    /// The server address.
    pub server: String,
    /// The kind of server.
    pub kind: ServerKind,
    /// Per-server settings suffix (`Session.serverSuffix`).
    pub suffix: String,
    /// The account in use.
    pub active: bool,
}

/// What a kind of server can do (`ServerCapability` sets: Jellyfin everything, Emby and Plex neither Seerr nor the
/// settings sync).
pub fn capabilities_of(kind: ServerKind) -> Capabilities {
    match kind {
        ServerKind::Jellyfin => Capabilities::ALL,
        ServerKind::Emby | ServerKind::Plex => Capabilities {
            seerr: false,
            settings_sync: false,
            downloads: true,
        },
    }
}

impl Core {
    /// Every stored account of every kind of server, in bundle order.
    pub fn accounts_list(&self) -> Vec<Entry> {
        let all = load_bundles(&*self.secrets);
        let mut out = Vec::new();
        for kind in all.kinds() {
            let Some(bundle) = all.bundle(kind) else {
                continue;
            };
            for a in bundle.accounts() {
                let key = a.account_key();
                let suffix = match (&a.plex, kind) {
                    (Some(p), ServerKind::Plex) => format!("|plex:{}", p.machine_identifier),
                    _ => format!("|{}", a.session.server_url),
                };
                out.push(Entry {
                    active: kind == all.active_kind() && key == bundle.active_id(),
                    name: a.session.user_name.clone(),
                    server: a.session.server_url.clone(),
                    kind,
                    suffix,
                    key,
                });
            }
        }
        out
    }

    /// The active account's entry.
    pub fn active_entry(&self) -> Option<Entry> {
        self.accounts_list().into_iter().find(|e| e.active)
    }

    /// Makes the account `key` the active one. `false` when it is not stored.
    pub fn switch_account(&self, key: &str) -> bool {
        let Some(e) = self.accounts_list().into_iter().find(|e| e.key == key) else {
            return false;
        };
        let mut all = load_bundles(&*self.secrets);
        let Some(mut bundle) = all.bundle(e.kind).cloned() else {
            return false;
        };
        bundle.switch_to(key);
        all.set(Some(bundle), e.kind);
        all.switch_to(e.kind);
        save_bundles(&*self.secrets, &all);
        true
    }

    /// Removes the account `key`; the next account of its server takes over, else another server, else none is left.
    pub fn sign_out_account(&self, key: &str) {
        let Some(e) = self.accounts_list().into_iter().find(|e| e.key == key) else {
            return;
        };
        let mut all: ServerBundles = load_bundles(&*self.secrets);
        let rest = all.bundle(e.kind).and_then(|b| b.removed(key));
        all.set(rest, e.kind);
        save_bundles(&*self.secrets, &all);
    }
}
