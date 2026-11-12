//! Settings that follow the account (`SettingsSync.swift`): the server's own display
//! preferences under the client name "Swiftly" carry them. One run reads the server copy,
//! decides by the change times (the newer side wins) and either hands the server's values to
//! the host or writes the local ones to the server. The host keeps its values in its own store
//! (UserDefaults, SharedPreferences) and passes them by name, encoded as text (`true`, `5`,
//! `["a","b"]`, JSON).

use std::collections::BTreeMap;
use std::sync::Arc;

use swiftly_jellyfin::OwnHeaders;
use swiftly_net::{HttpRequest, HttpTransport, Method, Url};
use swiftly_sync::{Decision, DisplayPreferencesCopy, SettingsSync, Value};
use swiftly_vm::{AccountRef, Host};

use crate::error::CoreError;
use crate::transport::CoreTransport;

/// One synced setting: its name (`utSprache`, `startReihen`, ...) and its value as text.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncSetting {
    /// The synced name, without a server suffix.
    pub name: String,
    /// The value in the stored text form.
    pub value: String,
}

/// A synced name and whether its value belongs to one server only.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SyncEntry {
    /// The name.
    pub name: String,
    /// The local key carries a server suffix (`startBibliotheken|<server>`).
    pub per_server: bool,
}

/// What one run did.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum SettingsSyncOutcome {
    /// The server's values are newer (or this is another account): write them locally and
    /// remember `changed` (seconds since 1970) as the local change time.
    Apply {
        /// The values to write.
        values: Vec<SyncSetting>,
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

/// Every setting that is synced.
#[uniffi::export]
pub fn settings_sync_entries() -> Vec<SyncEntry> {
    SettingsSync::ENTRIES
        .iter()
        .map(|e| SyncEntry {
            name: e.name.to_owned(),
            per_server: e.per_server,
        })
        .collect()
}

/// The synced settings of one account.
#[derive(uniffi::Object)]
pub struct SettingsSyncModel {
    transport: CoreTransport,
    base: String,
    user_id: String,
    headers: Vec<(String, String)>,
}

impl SettingsSyncModel {
    async fn run_once(
        &self,
        local: Vec<SyncSetting>,
        local_changed: Option<f64>,
        other_account: bool,
        now: f64,
    ) -> SettingsSyncOutcome {
        let Some(get) = self.request(Method::Get, None) else {
            return SettingsSyncOutcome::Unreachable;
        };
        let copy = match self.transport.send(get).await {
            Ok(a) if a.is_success() => DisplayPreferencesCopy::from_body(&a.body),
            _ => None,
        };
        let Some(copy) = copy else {
            return SettingsSyncOutcome::Unreachable;
        };
        let remote = SettingsSync::remote(&copy.custom_prefs());
        match SettingsSync::decide(&remote, local_changed, other_account) {
            Decision::Nothing => SettingsSyncOutcome::Nothing,
            Decision::Apply => SettingsSyncOutcome::Apply {
                values: remote
                    .values
                    .iter()
                    .map(|(name, v)| SyncSetting {
                        name: name.clone(),
                        value: v.encoded(),
                    })
                    .collect(),
                changed: remote.changed.unwrap_or(now),
            },
            Decision::Push => {
                let values: BTreeMap<String, Value> = local
                    .iter()
                    .filter_map(|s| {
                        let entry = SettingsSync::ENTRIES.iter().find(|e| e.name == s.name)?;
                        Some((s.name.clone(), Value::decode(&s.value, entry.kind)?))
                    })
                    .collect();
                let changed = SettingsSync::change_time(now, remote.changed);
                let body = copy.merged(&SettingsSync::fields(&values, changed));
                let Some(post) = self.request(Method::Post, Some(body)) else {
                    return SettingsSyncOutcome::Unreachable;
                };
                match self.transport.send(post).await {
                    Ok(a) if a.is_success() => SettingsSyncOutcome::Pushed { changed },
                    _ => SettingsSyncOutcome::Unreachable,
                }
            }
        }
    }

    pub(crate) fn build(
        transport: CoreTransport,
        host: &Host,
        account: &AccountRef,
    ) -> Result<Arc<Self>, CoreError> {
        let client = swiftly_vm::account_client(&Arc::new(transport.clone()), host, account)?;
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
        Ok(Arc::new(Self {
            transport,
            base: account.base_url.trim_end_matches('/').to_owned(),
            user_id: account.user_id.clone(),
            headers,
        }))
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
}

#[uniffi::export]
impl SettingsSyncModel {
    /// One run. `local` are the current local values by synced name, `local_changed` the time
    /// the local values last changed (`None` = never synced), `other_account` whether the last
    /// sync was for another account, `now` seconds since 1970.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn run(
        &self,
        local: Vec<SyncSetting>,
        local_changed: Option<f64>,
        other_account: bool,
        now: f64,
    ) -> Result<SettingsSyncOutcome, CoreError> {
        Ok(self
            .run_once(local, local_changed, other_account, now)
            .await)
    }

    /// One run that also carries the Seerr connection, like the old Android facade
    /// (`settingsSyncRun`): `seerr` is this server's connection as stored (JSON, `None` = none),
    /// `seerr_changed` when it last changed on this device (seconds since 1970, `None` = never).
    /// The connection travels in the same write as the settings when those are pushed, alone
    /// otherwise.
    // The argument list is the Swift/Kotlin API of the old facade (`settingsSyncRun`): a parameter struct would change
    // `Generated.swift` and the Kotlin bindings, so the lint is allowed here and nowhere else.
    #[allow(clippy::too_many_arguments)]
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn run_with_seerr(
        &self,
        local: Vec<SyncSetting>,
        local_changed: Option<f64>,
        remote_seen: Option<f64>,
        other_account: bool,
        now: f64,
        seerr: Option<String>,
        seerr_changed: Option<f64>,
    ) -> Result<SettingsSyncRound, CoreError> {
        Ok(self
            .round(
                local,
                local_changed,
                remote_seen,
                other_account,
                now,
                seerr,
                seerr_changed,
            )
            .await)
    }
}

/// What the Seerr part of a run did.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum SeerrSyncOutcome {
    /// Nothing to do.
    Nothing,
    /// Take the server's connection (`access` is the JSON, empty text = disconnected) and
    /// remember `changed` (seconds since 1970) as its change time.
    Adopt { access: String, changed: f64 },
    /// The device's connection was written; remember `changed`.
    Pushed { changed: f64 },
}

/// A run of the settings and the Seerr connection together.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SettingsSyncRound {
    /// The settings part.
    pub settings: SettingsSyncOutcome,
    /// The change time of the server's copy (seconds since 1970, `0` = none), to remember.
    pub remote_changed: f64,
    /// The Seerr part.
    pub seerr: SeerrSyncOutcome,
}

impl SettingsSyncModel {
    #[allow(clippy::too_many_arguments)]
    async fn round(
        &self,
        local: Vec<SyncSetting>,
        local_changed: Option<f64>,
        remote_seen: Option<f64>,
        other_account: bool,
        now: f64,
        seerr: Option<String>,
        seerr_changed: Option<f64>,
    ) -> SettingsSyncRound {
        use swiftly_seerr::SeerrAccess;
        use swiftly_sync::settings::SeerrStep;
        let unreachable = || SettingsSyncRound {
            settings: SettingsSyncOutcome::Unreachable,
            remote_changed: 0.0,
            seerr: SeerrSyncOutcome::Nothing,
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
            .as_deref()
            .filter(|t| !t.is_empty())
            .and_then(|t| serde_json::from_str(t).ok());
        let mut seerr_out = SeerrSyncOutcome::Nothing;
        let mut seerr_fields = BTreeMap::new();
        match SettingsSync::seerr_step(&prefs, seerr_changed, access.is_some()) {
            SeerrStep::Adopt(theirs, changed) => {
                seerr_out = SeerrSyncOutcome::Adopt {
                    access: theirs
                        .and_then(|a| serde_json::to_string(&a).ok())
                        .unwrap_or_default(),
                    changed,
                };
            }
            SeerrStep::Push => {
                let stamp = seerr_changed.unwrap_or(now);
                seerr_out = SeerrSyncOutcome::Pushed { changed: stamp };
                seerr_fields = SettingsSync::seerr_fields(access.as_ref(), stamp);
            }
            SeerrStep::Nothing => {}
        }
        let remote = SettingsSync::remote(&prefs);
        let remote_changed = remote.changed.unwrap_or(0.0);
        let decision = SettingsSync::decide(&remote, local_changed, other_account);
        let done = |settings| SettingsSyncRound {
            settings,
            remote_changed,
            seerr: seerr_out.clone(),
        };
        // Each write replaces all of CustomPrefs from the copy: Seerr goes alone only without a push.
        if decision != Decision::Push && !seerr_fields.is_empty() {
            let Some(post) = self.request(Method::Post, Some(copy.merged(&seerr_fields))) else {
                return unreachable();
            };
            if !matches!(self.transport.send(post).await, Ok(a) if a.is_success()) {
                return unreachable();
            }
        }
        match decision {
            Decision::Apply => done(SettingsSyncOutcome::Apply {
                values: remote
                    .values
                    .iter()
                    .map(|(name, v)| SyncSetting {
                        name: name.clone(),
                        value: v.encoded(),
                    })
                    .collect(),
                changed: remote_changed,
            }),
            Decision::Nothing => done(SettingsSyncOutcome::Nothing),
            Decision::Push => {
                let values: BTreeMap<String, Value> = local
                    .iter()
                    .filter_map(|s| {
                        let entry = SettingsSync::ENTRIES.iter().find(|e| e.name == s.name)?;
                        Some((s.name.clone(), Value::decode(&s.value, entry.kind)?))
                    })
                    .collect();
                // Nothing of the device's own to write: only the connection travels, if there is one.
                if values.is_empty() {
                    if !seerr_fields.is_empty() {
                        let Some(post) =
                            self.request(Method::Post, Some(copy.merged(&seerr_fields)))
                        else {
                            return unreachable();
                        };
                        if !matches!(self.transport.send(post).await, Ok(a) if a.is_success()) {
                            return unreachable();
                        }
                    }
                    return done(SettingsSyncOutcome::Nothing);
                }
                let stamp =
                    local_changed.unwrap_or_else(|| SettingsSync::change_time(now, remote_seen));
                let mut fields = SettingsSync::fields(&values, stamp);
                fields.extend(seerr_fields);
                let Some(post) = self.request(Method::Post, Some(copy.merged(&fields))) else {
                    return unreachable();
                };
                match self.transport.send(post).await {
                    Ok(a) if a.is_success() => done(SettingsSyncOutcome::Pushed { changed: stamp }),
                    _ => unreachable(),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::{HttpClient, HttpFailure, NetRequest, NetResponse};
    use std::sync::Mutex;
    use swiftly_jellyfin::ServerKind;
    use swiftly_l10n::Locale;
    use swiftly_vm::{Spawner, SystemClock};

    struct Spawn;
    impl Spawner for Spawn {
        fn spawn(&self, task: std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>) {
            drop(tokio::spawn(task));
        }
    }
    struct NoStore;
    impl swiftly_library::Store for NoStore {
        fn read(&self, _: &str) -> Option<Vec<u8>> {
            None
        }
        fn write(&self, _: &str, _: &[u8]) {}
        fn remove(&self, _: &str) {}
    }

    /// A server holding one display-preferences document.
    struct Server {
        doc: Mutex<String>,
        posts: Mutex<Vec<String>>,
    }
    #[async_trait::async_trait]
    impl HttpClient for Server {
        async fn send(&self, r: NetRequest) -> Result<NetResponse, HttpFailure> {
            assert!(
                r.url
                    .contains("DisplayPreferences/swiftly?userId=u1&client=Swiftly"),
                "{}",
                r.url
            );
            let body = if let Some(raw) = r.body {
                let b = String::from_utf8(raw).unwrap();
                self.posts.lock().unwrap().push(b);
                String::new()
            } else {
                self.doc.lock().unwrap().clone()
            };
            Ok(NetResponse {
                status: 200,
                headers: vec![],
                body: body.into_bytes(),
                url: None,
            })
        }
    }

    fn model(doc: &str) -> (Arc<SettingsSyncModel>, Arc<Server>) {
        let server = Arc::new(Server {
            doc: Mutex::new(doc.into()),
            posts: Mutex::default(),
        });
        let host = Host {
            spawner: Arc::new(Spawn),
            clock: Arc::new(SystemClock),
            store: Arc::new(NoStore),
            locale: Locale::parse("en"),
            device_name: "t".into(),
            client_version: "1".into(),
            cache: None,
        };
        let account = AccountRef {
            base_url: "https://s.example".into(),
            user_id: "u1".into(),
            token: "t".into(),
            server_kind: ServerKind::Jellyfin,
            device_id: "d".into(),
            plex_machine_id: None,
            plex_account_token: None,
        };
        let t = CoreTransport::new(Arc::clone(&server) as Arc<dyn HttpClient>);
        (
            SettingsSyncModel::build(t, &host, &account).unwrap(),
            server,
        )
    }

    fn local() -> Vec<SyncSetting> {
        vec![
            SyncSetting {
                name: "tonSprache".into(),
                value: "de".into(),
            },
            SyncSetting {
                name: "vorSek".into(),
                value: "30".into(),
            },
        ]
    }

    #[tokio::test]
    async fn an_empty_server_gets_the_local_values_and_keeps_the_rest_of_its_document() {
        let (m, server) = model(r#"{"Id":"x","CustomPrefs":{"other":"keep"}}"#);
        let out = m.run(local(), None, false, 1000.0).await.unwrap();
        assert!(matches!(out, SettingsSyncOutcome::Pushed { .. }), "{out:?}");
        let post = server.posts.lock().unwrap()[0].clone();
        assert!(
            post.contains("\"swiftly.tonSprache\":\"de\"")
                && post.contains("\"swiftly.vorSek\":\"30\"")
                && post.contains("\"other\":\"keep\""),
            "{post}"
        );
    }

    #[tokio::test]
    async fn newer_server_values_come_back_older_ones_are_overwritten() {
        let doc = r#"{"CustomPrefs":{"swiftly.tonSprache":"fr","swiftly.changed":"5000000"}}"#;
        let (m, server) = model(doc);
        match m.run(local(), Some(1000.0), false, 9000.0).await.unwrap() {
            SettingsSyncOutcome::Apply { values, changed } => {
                assert_eq!(
                    values,
                    vec![SyncSetting {
                        name: "tonSprache".into(),
                        value: "fr".into()
                    }]
                );
                assert!((changed - 5000.0).abs() < 1e-9);
            }
            other => panic!("{other:?}"),
        }
        assert!(server.posts.lock().unwrap().is_empty());
        let out = m.run(local(), Some(6000.0), false, 9000.0).await.unwrap();
        assert!(matches!(out, SettingsSyncOutcome::Pushed { .. }), "{out:?}");
        assert_eq!(
            m.run(local(), Some(5000.0), false, 9000.0).await.unwrap(),
            SettingsSyncOutcome::Nothing
        );
    }

    const ACCESS: &str = r#"{"adresse":"https://seerr.example","keks":"connect.sid=abc"}"#;

    #[tokio::test]
    async fn the_connection_travels_in_the_same_write_as_pushed_settings() {
        let (m, server) = model(r#"{"CustomPrefs":{}}"#);
        let r = m
            .run_with_seerr(
                local(),
                None,
                None,
                false,
                1000.0,
                Some(ACCESS.into()),
                None,
            )
            .await
            .unwrap();
        assert!(
            matches!(r.settings, SettingsSyncOutcome::Pushed { .. }),
            "{r:?}"
        );
        assert_eq!(r.seerr, SeerrSyncOutcome::Pushed { changed: 1000.0 });
        let posts = server.posts.lock().unwrap().clone();
        assert_eq!(posts.len(), 1, "{posts:?}");
        assert!(
            posts[0].contains("swiftly.seerrChanged")
                && posts[0].contains("connect.sid=abc")
                && posts[0].contains("swiftly.tonSprache"),
            "{}",
            posts[0]
        );
    }

    #[tokio::test]
    async fn a_newer_server_connection_is_adopted_and_nothing_is_written() {
        let doc = r#"{"CustomPrefs":{"swiftly.seerr":"{\"adresse\":\"https://seerr.example\",\"keks\":\"connect.sid=abc\"}","swiftly.seerrChanged":"9000000","swiftly.tonSprache":"fr","swiftly.changed":"5000000"}}"#;
        let (m, server) = model(doc);
        let r = m
            .run_with_seerr(
                local(),
                Some(5000.0),
                Some(5000.0),
                false,
                9999.0,
                None,
                Some(1000.0),
            )
            .await
            .unwrap();
        match r.seerr {
            SeerrSyncOutcome::Adopt { access, changed } => {
                assert!(access.contains("connect.sid=abc"), "{access}");
                assert!((changed - 9000.0).abs() < 1e-9);
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(r.settings, SettingsSyncOutcome::Nothing);
        assert!((r.remote_changed - 5000.0).abs() < 1e-9);
        assert!(server.posts.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn the_connection_goes_alone_when_the_settings_agree() {
        let doc = r#"{"CustomPrefs":{"swiftly.tonSprache":"de","swiftly.changed":"5000000","swiftly.seerr":"","swiftly.seerrChanged":"1000000"}}"#;
        let (m, server) = model(doc);
        let r = m
            .run_with_seerr(
                local(),
                Some(5000.0),
                Some(5000.0),
                false,
                9999.0,
                Some(ACCESS.into()),
                Some(2000.0),
            )
            .await
            .unwrap();
        assert_eq!(r.settings, SettingsSyncOutcome::Nothing);
        assert_eq!(r.seerr, SeerrSyncOutcome::Pushed { changed: 2000.0 });
        let posts = server.posts.lock().unwrap().clone();
        assert_eq!(posts.len(), 1);
        assert!(
            posts[0].contains("connect.sid=abc")
                && posts[0].contains("\"swiftly.tonSprache\":\"de\""),
            "{}",
            posts[0]
        );
    }
}
