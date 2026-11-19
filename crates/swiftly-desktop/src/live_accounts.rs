//! The accounts of the real app: the list for the profile hub, switching, and signing one account out. All of it goes
//! through `swiftly-accounts` bundles in the secret store (the same bytes the Swift app writes).

use crate::live::Core;
use swiftly_accounts::{ServerBundles, load_bundles, save_bundles};
use swiftly_jellyfin::ServerKind;
use swiftly_seerr::SeerrAccess;
use swiftly_settings::{KeyValueStore, Value};
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

impl Entry {
    /// The server part of a per-server settings key (`Session.serverSuffix` without the `|` the sync keys carry): the one
    /// every `server_key(name, server)` reader and writer takes. Handing `suffix` itself to the settings page stored its
    /// per-server values under `name||server`, where the Start page (reading `name|server`) never looked.
    pub fn server_part(&self) -> &str {
        self.suffix.trim_start_matches('|')
    }
}

/// The picture address of one account (see [`Core::avatar_address`]); pure, so it is tested without a secret store.
pub fn avatar_address_of(
    kind: ServerKind,
    server_url: &str,
    token: &str,
    user_id: &str,
    plex_picture: Option<&str>,
) -> Option<String> {
    if kind == ServerKind::Plex {
        return plex_picture.map(str::to_owned);
    }
    let base = swiftly_images::Url::parse(server_url).ok()?;
    swiftly_images::ImageAddress::new(base, Some(token.to_owned()), kind)
        .user(user_id, None, i64::from(crate::hub::AVATAR_EDGE))
        .map(|u| u.to_string())
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

    /// The profile picture address of the stored account `key` (`AppModel.userImageURL(for:)`): `Users/{id}/Images/Primary`
    /// of the account's own server at 480 px with its token, built by the core's `ImageAddress`. Plex keeps the plex.tv
    /// address from sign-in. `None` for an unknown account, a Plex account without a picture or an unusable address.
    pub fn avatar_address(&self, key: &str) -> Option<String> {
        let all = load_bundles(&*self.secrets);
        let account = all
            .kinds()
            .into_iter()
            .find_map(|kind| all.bundle(kind).and_then(|b| b.account(key)))?;
        avatar_address_of(
            account.session.kind,
            &account.session.server_url,
            &account.session.access_token,
            &account.session.user_id,
            account.plex.as_ref().and_then(|p| p.user_image.as_deref()),
        )
    }

    /// The per-server suffix of the active account (the Seerr session is kept per server); empty without an account.
    /// Looked up at most once a second: screens ask every frame and the accounts sit in the secret store.
    pub fn seerr_suffix(&self) -> String {
        static CACHE: std::sync::Mutex<Option<(std::time::Instant, String)>> =
            std::sync::Mutex::new(None);
        let mut cache = CACHE
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some((at, suffix)) = &*cache
            && at.elapsed() < std::time::Duration::from_secs(1)
        {
            return suffix.clone();
        }
        let suffix = self.active_entry().map(|e| e.suffix).unwrap_or_default();
        *cache = Some((std::time::Instant::now(), suffix.clone()));
        suffix
    }

    /// The Seerr session of the active account's server (taken over from the server's other devices by the settings
    /// sync, see `swiftly_vm::StoreSync`). A session kept under the old single key is moved to its server once; it
    /// carries no change time, so whatever the server says about Seerr wins over it.
    pub fn seerr_stored(&self) -> Option<SeerrAccess> {
        let suffix = self.seerr_suffix();
        if let Some(access) = swiftly_vm::stored_seerr(&*self.settings, &suffix) {
            return Some(access);
        }
        let legacy = match self.settings.get("seerr") {
            Some(Value::Data(d)) => serde_json::from_slice::<SeerrAccess>(&d).ok()?,
            _ => return None,
        };
        swiftly_vm::store_seerr(&*self.settings, &suffix, Some(&legacy), 0.0);
        let _ = self.settings.remove("seerr");
        Some(legacy)
    }

    /// Keeps (or with `None` drops) the active server's Seerr session; the sync carries it to the other devices.
    pub fn seerr_set(&self, access: Option<&SeerrAccess>) {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        swiftly_vm::store_seerr(&*self.settings, &self.seerr_suffix(), access, now);
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
    /// The server is told as well (`removeAndSignOff`: `POST Sessions/Logout` with the account's own token, best effort,
    /// five seconds at most), so the token stops working there.
    pub fn sign_out_account(&self, key: &str) {
        let Some(e) = self.accounts_list().into_iter().find(|e| e.key == key) else {
            return;
        };
        let mut all: ServerBundles = load_bundles(&*self.secrets);
        let session = all
            .bundle(e.kind)
            .and_then(|b| b.account(key))
            .map(|a| a.session.clone());
        let rest = all.bundle(e.kind).and_then(|b| b.removed(key));
        all.set(rest, e.kind);
        save_bundles(&*self.secrets, &all);
        if let Some(session) = session
            && e.kind != ServerKind::Plex
            && let Ok(client) = self.client(&session.server_url, e.kind)
        {
            client.set_session(Some(session));
            self.spawn(async move {
                let _ = tokio::time::timeout(std::time::Duration::from_secs(5), client.sign_off())
                    .await;
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_user_picture_address_is_the_cores_480_edge_with_the_token() {
        let got = avatar_address_of(
            ServerKind::Jellyfin,
            "https://jf.example.de",
            "TOK",
            "u9",
            None,
        );
        let base = swiftly_images::Url::parse("https://jf.example.de").expect("url");
        let want =
            swiftly_images::ImageAddress::new(base, Some("TOK".into()), ServerKind::Jellyfin)
                .user("u9", None, 480)
                .map(|u| u.to_string());
        assert_eq!(got, want);
        let got = got.expect("address");
        assert!(got.contains("/Users/u9/Images/Primary"), "{got}");
        assert!(
            got.contains("fillWidth=480")
                && got.contains("fillHeight=480")
                && got.contains("quality=90")
        );
        assert!(got.contains("ApiKey=TOK"), "{got}");
    }

    #[test]
    fn plex_keeps_the_plex_tv_address_and_a_bad_server_has_none() {
        assert_eq!(
            avatar_address_of(
                ServerKind::Plex,
                "https://p",
                "t",
                "1",
                Some("https://plex.tv/u/1.png")
            ),
            Some("https://plex.tv/u/1.png".into())
        );
        assert_eq!(
            avatar_address_of(ServerKind::Plex, "https://p", "t", "1", None),
            None
        );
        assert_eq!(
            avatar_address_of(ServerKind::Jellyfin, "not a url", "t", "1", None),
            None
        );
    }
}

#[cfg(test)]
mod server_part_tests {
    use super::*;

    #[test]
    fn the_server_part_has_no_leading_bar() {
        let entry = |suffix: &str| Entry {
            key: "k".into(),
            name: "n".into(),
            server: "http://h:1".into(),
            kind: ServerKind::Jellyfin,
            suffix: suffix.into(),
            active: true,
        };
        assert_eq!(entry("|http://h:1").server_part(), "http://h:1");
        assert_eq!(entry("|plex:abc").server_part(), "plex:abc");
        assert_eq!(
            swiftly_settings::server_key("startReihenfolge", entry("|http://h:1").server_part()),
            "startReihenfolge|http://h:1"
        );
    }
}
