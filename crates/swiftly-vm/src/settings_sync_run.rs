//! One run of the settings sync, for every host that is written in Rust: the Mac and the phones reach it through the
//! uniffi model (`SettingsSyncModel`), the Linux and Windows app calls it directly. The server's own display
//! preferences under the client name "Swiftly" carry the settings; the newer side wins as a whole set.
//!
//! * [`SettingsSyncCore::round`] is the exchange with the server (fetch, decide, write), over plain text values.
//! * [`StoreSync::run`] is the host side for a [`KeyValueStore`]: it reads the synced keys of the store, runs a round
//!   and writes what the server sent back into the store, with the same bookkeeping keys as `SettingsSyncRun.swift`.

use std::collections::BTreeMap;
use std::sync::Arc;

use swiftly_jellyfin::OwnHeaders;
use swiftly_net::{ErrorKind, HttpRequest, HttpTransport, Method, Url};
use swiftly_settings::KeyValueStore;
use swiftly_sync::{Decision, DisplayPreferencesCopy, SettingsSync, Value};

use crate::{AccountRef, Host};

/// What the settings part of a round did.
#[derive(Debug, Clone, PartialEq)]
pub enum SyncOutcome {
    /// The server's values are newer (or this is another account): write them locally and remember `changed`
    /// (seconds since 1970) as the local change time. Values are `(synced name, stored text)`.
    Apply {
        /// The values to write.
        values: Vec<(String, String)>,
        /// The server's change time.
        changed: f64,
    },
    /// The local values were written to the server; remember `changed` as the change time.
    Pushed {
        /// The change time that was written.
        changed: f64,
    },
    /// Both sides agree.
    Nothing,
    /// The server did not answer; try again later.
    Unreachable,
}

/// What the Seerr part of a round did.
#[derive(Debug, Clone, PartialEq)]
pub enum SeerrOutcome {
    /// Nothing to do.
    Nothing,
    /// Take the server's connection (JSON, empty text = disconnected).
    Adopt {
        /// The connection.
        access: String,
        /// Its change time (seconds since 1970).
        changed: f64,
    },
    /// The device's connection was written.
    Pushed {
        /// Its change time.
        changed: f64,
    },
}

/// A round: the settings, the server's change time and the Seerr part.
#[derive(Debug, Clone, PartialEq)]
pub struct SyncRound {
    /// The settings part.
    pub settings: SyncOutcome,
    /// The change time of the server's copy (seconds since 1970, `0` = none).
    pub remote_changed: f64,
    /// The Seerr part.
    pub seerr: SeerrOutcome,
}

/// The exchange with one account's server.
pub struct SettingsSyncCore<T: HttpTransport> {
    transport: Arc<T>,
    base: String,
    user_id: String,
    headers: Vec<(String, String)>,
}

impl<T: HttpTransport + 'static> SettingsSyncCore<T> {
    /// The exchange for `account` over `transport`.
    ///
    /// # Errors
    /// The client for the account could not be built.
    pub fn new(transport: &Arc<T>, host: &Host, account: &AccountRef) -> Result<Self, ErrorKind> {
        let client = crate::account_client(transport, host, account)?;
        let mut headers: Vec<(String, String)> = Url::parse(&account.base_url)
            .ok()
            .map(|u| {
                OwnHeaders::of(&u)
                    .into_iter()
                    .map(|h| (h.name, h.value))
                    .collect()
            })
            .unwrap_or_default();
        headers.push(("Authorization".into(), client.authorization_header()));
        headers.push(("Accept".into(), "application/json".into()));
        Ok(Self {
            transport: Arc::clone(transport),
            base: account.base_url.trim_end_matches('/').to_owned(),
            user_id: account.user_id.clone(),
            headers,
        })
    }

    fn request(&self, method: Method, body: Option<Vec<u8>>) -> Option<HttpRequest> {
        let url = Url::parse(&format!(
            "{}/DisplayPreferences/{}?userId={}&client={}",
            self.base,
            SettingsSync::DISPLAY_ID,
            self.user_id,
            SettingsSync::CLIENT_NAME
        ))
        .ok()?;
        let mut req = HttpRequest::new(method, url);
        for (n, v) in &self.headers {
            req.set_header(n, v);
        }
        if let Some(b) = body {
            req.set_header("Content-Type", "application/json");
            req.body = Some(b);
        }
        Some(req)
    }

    async fn post(&self, body: Vec<u8>) -> bool {
        let Some(post) = self.request(Method::Post, Some(body)) else {
            return false;
        };
        matches!(self.transport.send(post).await, Ok(a) if a.is_success())
    }

    /// One run that also carries the Seerr connection: `local` are the current local values (synced name, text),
    /// `local_changed` when they last changed (`None` = never synced), `remote_seen` the server's change time at the
    /// last run, `other_account` whether the last sync was for another account, `now` seconds since 1970, `seerr`
    /// this server's connection as stored (JSON, `None` = none) and `seerr_changed` when it last changed here.
    #[allow(clippy::too_many_arguments)]
    pub async fn round(
        &self,
        local: &[(String, String)],
        local_changed: Option<f64>,
        remote_seen: Option<f64>,
        other_account: bool,
        now: f64,
        seerr: Option<&str>,
        seerr_changed: Option<f64>,
    ) -> SyncRound {
        use swiftly_seerr::SeerrAccess;
        use swiftly_sync::settings::SeerrStep;
        let unreachable = || SyncRound {
            settings: SyncOutcome::Unreachable,
            remote_changed: 0.0,
            seerr: SeerrOutcome::Nothing,
        };
        let Some(get) = self.request(Method::Get, None) else {
            return unreachable();
        };
        let copy = match self.transport.send(get).await {
            Ok(a) if a.is_success() => DisplayPreferencesCopy::from_body(&a.body),
            _ => None,
        };
        let Some(copy) = copy else {
            return unreachable();
        };
        let prefs = copy.custom_prefs();
        let access: Option<SeerrAccess> = seerr
            .filter(|t| !t.is_empty())
            .and_then(|t| serde_json::from_str(t).ok());
        let mut seerr_out = SeerrOutcome::Nothing;
        let mut seerr_fields = BTreeMap::new();
        match SettingsSync::seerr_step(&prefs, seerr_changed, access.is_some()) {
            SeerrStep::Adopt(theirs, changed) => {
                seerr_out = SeerrOutcome::Adopt {
                    access: theirs
                        .and_then(|a| serde_json::to_string(&a).ok())
                        .unwrap_or_default(),
                    changed,
                };
            }
            SeerrStep::Push => {
                let stamp = seerr_changed.unwrap_or(now);
                seerr_out = SeerrOutcome::Pushed { changed: stamp };
                seerr_fields = SettingsSync::seerr_fields(access.as_ref(), stamp);
            }
            SeerrStep::Nothing => {}
        }
        let remote = SettingsSync::remote(&prefs);
        let remote_changed = remote.changed.unwrap_or(0.0);
        let decision = SettingsSync::decide(&remote, local_changed, other_account);
        let done = |settings| SyncRound {
            settings,
            remote_changed,
            seerr: seerr_out.clone(),
        };
        // Each write replaces all of CustomPrefs from the copy: Seerr goes alone only without a push.
        if decision != Decision::Push
            && !seerr_fields.is_empty()
            && !self.post(copy.merged(&seerr_fields)).await
        {
            return unreachable();
        }
        match decision {
            Decision::Apply => done(SyncOutcome::Apply {
                values: remote
                    .values
                    .iter()
                    .map(|(name, v)| (name.clone(), v.encoded()))
                    .collect(),
                changed: remote_changed,
            }),
            Decision::Nothing => done(SyncOutcome::Nothing),
            Decision::Push => {
                let values: BTreeMap<String, Value> = local
                    .iter()
                    .filter_map(|(name, text)| {
                        let entry = SettingsSync::ENTRIES.iter().find(|e| e.name == name)?;
                        Some((name.clone(), Value::decode(text, entry.kind)?))
                    })
                    .collect();
                // Nothing of the device's own to write: only the connection travels, if there is one.
                if values.is_empty() {
                    if !seerr_fields.is_empty() && !self.post(copy.merged(&seerr_fields)).await {
                        return unreachable();
                    }
                    return done(SyncOutcome::Nothing);
                }
                let stamp =
                    local_changed.unwrap_or_else(|| SettingsSync::change_time(now, remote_seen));
                let mut fields = SettingsSync::fields(&values, stamp);
                fields.extend(seerr_fields);
                if self.post(copy.merged(&fields)).await {
                    done(SyncOutcome::Pushed { changed: stamp })
                } else {
                    unreachable()
                }
            }
        }
    }
}

/// Bookkeeping keys of the device (the names of `SettingsSyncRun.swift`).
pub mod keys {
    /// The switch ("Auf allen Geräten gleich"), on by default.
    pub const ON: &str = "einstellungenSync";
    /// When the synced values last changed here or were taken from the server (milliseconds).
    pub const TIME: &str = "einstellungenSyncZeit";
    /// The account key of the last sync.
    pub const ACCOUNT: &str = "einstellungenSyncKonto";
    /// The server's change time at the last run (milliseconds).
    pub const REMOTE: &str = "einstellungenSyncServer";
}

/// What a store run did (for the log and the tests).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ran {
    /// The switch is off.
    Off,
    /// The server did not answer.
    Unreachable,
    /// The server's values went into the store.
    Applied,
    /// The device's values went to the server.
    Pushed,
    /// Both sides agree.
    Nothing,
}

/// The synced values of the store by synced name, as stored text.
pub fn synced_values(store: &dyn KeyValueStore, suffix: &str) -> Vec<(String, String)> {
    swiftly_settings::sync::collect(suffix, |key, kind| {
        swiftly_settings::sync::read_from_store(store, key, kind)
    })
    .into_iter()
    .map(|(n, v)| (n, v.encoded()))
    .collect()
}

/// Notes that the user changed a synced value now: the time every run compares. Never earlier than the server's.
pub fn stamp_change(store: &dyn KeyValueStore, now_seconds: f64) {
    let remote = millis(store, keys::REMOTE).map(|ms| ms / 1000.0);
    let stamp = SettingsSync::change_time(now_seconds, remote);
    let _ = store.set(keys::TIME, swiftly_settings::Value::Double(stamp * 1000.0));
}

/// The settings sync of one account over a [`KeyValueStore`].
pub struct StoreSync<T: HttpTransport> {
    core: SettingsSyncCore<T>,
    store: Arc<dyn KeyValueStore>,
    suffix: String,
    account_key: String,
}

fn millis(store: &dyn KeyValueStore, key: &str) -> Option<f64> {
    match store.get(key)? {
        swiftly_settings::Value::Double(d) => Some(d),
        #[allow(clippy::cast_precision_loss)]
        swiftly_settings::Value::Int(i) => Some(i as f64),
        _ => None,
    }
}

impl<T: HttpTransport + 'static> StoreSync<T> {
    /// The sync of the account `account_key` (`Session.accountKey`) whose per-server keys carry `suffix`.
    pub fn new(
        core: SettingsSyncCore<T>,
        store: Arc<dyn KeyValueStore>,
        suffix: &str,
        account_key: &str,
    ) -> Self {
        Self {
            core,
            store,
            suffix: suffix.to_owned(),
            account_key: account_key.to_owned(),
        }
    }

    /// One run; `now` is seconds since 1970.
    pub async fn run(&self, now: f64) -> Ran {
        let store = &*self.store;
        if store.get_bool(keys::ON) == Some(false) {
            return Ran::Off;
        }
        let started = millis(store, keys::TIME);
        let other = store.get_string(keys::ACCOUNT).as_deref() != Some(self.account_key.as_str());
        let round = self
            .core
            .round(
                &synced_values(store, &self.suffix),
                started.map(|ms| ms / 1000.0),
                millis(store, keys::REMOTE).map(|ms| ms / 1000.0),
                other,
                now,
                None,
                None,
            )
            .await;
        if round.remote_changed > 0.0 {
            let _ = store.set(
                keys::REMOTE,
                swiftly_settings::Value::Double(round.remote_changed * 1000.0),
            );
        }
        let remember = |changed: f64| {
            let _ = store.set(
                keys::TIME,
                swiftly_settings::Value::Double(changed * 1000.0),
            );
            let _ = store.set(
                keys::ACCOUNT,
                swiftly_settings::Value::Str(self.account_key.clone()),
            );
        };
        match round.settings {
            SyncOutcome::Unreachable => Ran::Unreachable,
            SyncOutcome::Apply { values, changed } => {
                // Changed here while the answer was on its way: that change must not be overwritten.
                if millis(store, keys::TIME) != started {
                    return Ran::Nothing;
                }
                let typed: BTreeMap<String, swiftly_settings::sync::SyncValue> = values
                    .iter()
                    .filter_map(|(name, text)| {
                        let entry = swiftly_settings::sync::ENTRIES
                            .iter()
                            .find(|e| e.name == name)?;
                        Some((
                            name.clone(),
                            swiftly_settings::sync::SyncValue::decode(text, entry.kind)?,
                        ))
                    })
                    .collect();
                let _ = swiftly_settings::sync::apply_to_store(store, &self.suffix, &typed);
                remember(changed);
                Ran::Applied
            }
            SyncOutcome::Pushed { changed } => {
                remember(changed);
                let _ = store.set(
                    keys::REMOTE,
                    swiftly_settings::Value::Double(changed * 1000.0),
                );
                Ran::Pushed
            }
            SyncOutcome::Nothing => {
                let _ = store.set(
                    keys::ACCOUNT,
                    swiftly_settings::Value::Str(self.account_key.clone()),
                );
                Ran::Nothing
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use swiftly_net::HttpResponse;
    use swiftly_settings::{MemoryStore, Value as Stored};

    /// A server that keeps one display-preferences document, like Jellyfin does.
    struct Server(Mutex<Vec<u8>>);

    impl HttpTransport for Server {
        async fn send(&self, r: HttpRequest) -> Result<HttpResponse, ErrorKind> {
            assert!(
                r.url
                    .as_str()
                    .contains("DisplayPreferences/swiftly?userId=u1&client=Swiftly"),
                "{}",
                r.url
            );
            let mut doc = self.0.lock().unwrap();
            if let Some(body) = r.body {
                *doc = body;
                return Ok(HttpResponse::new(204, Vec::new()));
            }
            Ok(HttpResponse::new(200, doc.clone()))
        }
    }

    fn device(server: &Arc<Server>) -> (Arc<MemoryStore>, StoreSync<Server>) {
        let store = Arc::new(MemoryStore::new());
        let core = SettingsSyncCore {
            transport: Arc::clone(server),
            base: "https://server.test".into(),
            user_id: "u1".into(),
            headers: Vec::new(),
        };
        let sync = StoreSync::new(
            core,
            Arc::<MemoryStore>::clone(&store),
            "https://server.test",
            "acct",
        );
        (store, sync)
    }

    #[test]
    fn a_change_on_the_desktop_reaches_the_server_and_comes_back_to_another_device() {
        let server = Arc::new(Server(Mutex::new(br#"{"CustomPrefs":{}}"#.to_vec())));
        let (desktop, desktop_run) = device(&server);
        let (phone, phone_run) = device(&server);

        desktop.set("utSprache", Stored::Str("fr".into())).unwrap();
        desktop.set("zurueckSek", Stored::Int(15)).unwrap();
        stamp_change(&*desktop, 1000.0);
        let ran = futures_executor::block_on(desktop_run.run(1001.0));
        assert_eq!(ran, Ran::Pushed);
        let doc = String::from_utf8(server.0.lock().unwrap().clone()).unwrap();
        assert!(
            doc.contains("swiftly.utSprache") && doc.contains("\"fr\""),
            "{doc}"
        );
        assert!(doc.contains("swiftly.zurueckSek"), "{doc}");

        // The other device has nothing of its own yet and takes the server's set.
        let ran = futures_executor::block_on(phone_run.run(1100.0));
        assert_eq!(ran, Ran::Applied);
        assert_eq!(phone.get_string("utSprache").as_deref(), Some("fr"));
        assert_eq!(phone.get_int("zurueckSek"), Some(15));

        // The phone changes one value later; the desktop takes it on its next run.
        phone.set("zurueckSek", Stored::Int(30)).unwrap();
        stamp_change(&*phone, 2000.0);
        assert_eq!(
            futures_executor::block_on(phone_run.run(2001.0)),
            Ran::Pushed
        );
        assert_eq!(
            futures_executor::block_on(desktop_run.run(2100.0)),
            Ran::Applied
        );
        assert_eq!(desktop.get_int("zurueckSek"), Some(30));
        // Both sides agree now.
        assert_eq!(
            futures_executor::block_on(desktop_run.run(2200.0)),
            Ran::Nothing
        );
    }

    #[test]
    fn the_switch_off_stops_the_run() {
        let server = Arc::new(Server(Mutex::new(br#"{"CustomPrefs":{}}"#.to_vec())));
        let (store, run) = device(&server);
        store.set(keys::ON, Stored::Bool(false)).unwrap();
        assert_eq!(futures_executor::block_on(run.run(1.0)), Ran::Off);
        assert_eq!(
            server.0.lock().unwrap().as_slice(),
            br#"{"CustomPrefs":{}}"#
        );
    }
}
