//! Plex sign-in as the old Android facade answered it (`Kern.plexStart/plexStartTv/plexPoll/plexPickProfile/plexServers/
//! plexPickServer/plexReset`): one JSON step per call over [`PlexSignIn`]. Kotlin asks `plexPoll` about once a second.

use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use serde_json::{Value, json};
use swiftly_net::ErrorKind;
use swiftly_plex::PlexError;

use super::{PlexAccountEnd, PlexProfileEnd, PlexSignIn};
use crate::accounts::AccountsModel;
use swiftly_plex::PlexIdentity;

/// What the flow holds besides the sign-in itself.
#[derive(Default)]
struct Flow {
    /// The token was seen once; the timer and a closing browser window can both see it, one wins.
    handled: AtomicBool,
    /// Answers that failed in a row; five end the wait.
    failures: AtomicU32,
    /// A server is being connected right now.
    connecting: AtomicBool,
    /// The Plex Home profile picked from a choice (absent for a single profile).
    chosen: Mutex<Option<String>>,
}

/// The Plex sign-in of one screen, in the old JSON.
#[derive(uniffi::Object)]
pub struct LegacyPlexSignIn {
    inner: Arc<PlexSignIn>,
    flow: Flow,
}

#[uniffi::export]
impl AccountsModel {
    /// The old `Kern.plex…` steps. `base_url` stands in for plex.tv (tests and debug builds only); `None` is the real one.
    pub fn legacy_plex_sign_in(
        self: Arc<Self>,
        client_id: String,
        app_version: String,
        platform: String,
        device: String,
        device_name: String,
        base_url: Option<String>,
    ) -> Arc<LegacyPlexSignIn> {
        let identity =
            PlexIdentity::new(&client_id, &app_version, &platform, &device, &device_name);
        let transport = self.transport();
        let inner = PlexSignIn::build(self, transport, identity, base_url.as_deref());
        Arc::new(LegacyPlexSignIn {
            inner,
            flow: Flow::default(),
        })
    }
}

impl LegacyPlexSignIn {
    #[cfg(test)]
    pub(super) fn over(inner: Arc<PlexSignIn>) -> Arc<Self> {
        Arc::new(Self {
            inner,
            flow: Flow::default(),
        })
    }
}

fn text(v: Value) -> String {
    v.to_string()
}

fn step(name: &str) -> String {
    text(json!({ "step": name }))
}

impl LegacyPlexSignIn {
    /// `plexFail`: a network failure is its own page, anything else carries the sentence.
    fn fail_text(&self, message: String) -> String {
        if self.inner.last_failure_unreachable() {
            step("plexUnreachable")
        } else {
            text(json!({ "step": "failed", "message": message }))
        }
    }

    fn fail(&self, error: &PlexError) -> String {
        match error {
            PlexError::PinExpired => step("expired"),
            PlexError::NoServer => text(json!({ "step": "servers", "servers": [] })),
            other => {
                let message = self.inner.readable(other);
                self.fail_text(message)
            }
        }
    }

    fn core_fail(&self, e: crate::error::CoreError) -> String {
        match e {
            crate::error::CoreError::Failed { message } => self.fail_text(message),
            other => text(json!({ "step": "failed", "message": other.to_string() })),
        }
    }

    async fn begin(&self, strong: bool) -> String {
        self.reset_flow();
        match self.inner.start(strong).await {
            Ok(pin) => {
                let (url, code) = if strong {
                    (pin.plain_auth_url, None)
                } else {
                    (pin.link_url.unwrap_or_default(), Some(pin.code))
                };
                text(without_nulls(
                    json!({ "step": "waiting", "secondsLeft": pin.seconds, "url": url, "code": code }),
                ))
            }
            Err(e) => self.core_fail(e),
        }
    }

    fn reset_flow(&self) {
        self.inner.reset();
        self.flow.handled.store(false, Ordering::SeqCst);
        self.flow.failures.store(0, Ordering::SeqCst);
        self.flow.connecting.store(false, Ordering::SeqCst);
        *self
            .flow
            .chosen
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
    }

    async fn signed_in(&self) -> String {
        if self.flow.handled.swap(true, Ordering::SeqCst) {
            return text(json!({ "step": "waiting" }));
        }
        match self.inner.load_account().await {
            Ok(PlexAccountEnd::Expired) => step("expired"),
            Ok(PlexAccountEnd::Ready { info }) => {
                if info.profiles.is_empty() {
                    self.servers_step().await
                } else {
                    let profiles: Vec<Value> = info
                        .profiles
                        .iter()
                        .map(|p| json!({ "id": p.id, "name": p.name, "image": p.image, "protected": p.protected }))
                        .collect();
                    text(without_nulls(
                        json!({ "step": "profiles", "account": info.name, "profiles": profiles }),
                    ))
                }
            }
            Err(e) => self.core_fail(e),
        }
    }

    async fn servers_step(&self) -> String {
        if self.inner.servers_token().is_err() {
            return step("failed");
        }
        let account = self
            .inner
            .held(|h| h.account.as_ref().map(|a| a.title.clone()));
        let chosen = self
            .flow
            .chosen
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        match self.inner.servers().await {
            Ok(list) => {
                let servers: Vec<Value> = list
                    .iter()
                    .map(|s| json!({ "id": s.id, "name": s.name, "sharedBy": s.shared_by, "local": s.local, "online": s.online }))
                    .collect();
                text(without_nulls(
                    json!({ "step": "servers", "account": account, "profile": chosen, "servers": servers }),
                ))
            }
            Err(e) => self.core_fail(e),
        }
    }
}

/// Swift's `Encodable` leaves a missing optional out instead of writing `null`.
fn without_nulls(v: Value) -> Value {
    match v {
        Value::Object(m) => Value::Object(
            m.into_iter()
                .filter(|(_, v)| !v.is_null())
                .map(|(k, v)| (k, without_nulls(v)))
                .collect(),
        ),
        Value::Array(a) => Value::Array(a.into_iter().map(without_nulls).collect()),
        other => other,
    }
}

#[uniffi::export]
impl LegacyPlexSignIn {
    /// `Kern.plexStart`: the code and the browser page.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn start(&self) -> String {
        self.begin(true).await
    }

    /// `Kern.plexStartTv`: the short code and `plex.tv/link`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn start_tv(&self) -> String {
        self.begin(false).await
    }

    /// `Kern.plexPoll`: one look; once the token is there, the profiles or the servers follow in the same answer.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn poll(&self) -> String {
        let (pin, expires) = self.inner.held(|h| (h.pin.clone(), h.expires));
        let (Some(pin), Some(expires)) = (pin, expires) else {
            return text(json!({ "step": "waiting", "secondsLeft": 0 }));
        };
        if self.flow.handled.load(Ordering::SeqCst) {
            return text(json!({ "step": "waiting", "secondsLeft": 0 }));
        }
        if Instant::now() >= expires {
            return step("expired");
        }
        match self.inner.service.check_pin(&pin).await {
            Ok(checked) => {
                self.flow.failures.store(0, Ordering::SeqCst);
                if self.inner.take_token(checked) {
                    return self.signed_in().await;
                }
            }
            Err(
                PlexError::Request(ErrorKind::Http {
                    status: 404 | 410, ..
                })
                | PlexError::PinExpired,
            ) => return step("expired"),
            Err(error) => {
                if self.flow.failures.fetch_add(1, Ordering::SeqCst) + 1 >= 5 {
                    return self.fail(&error);
                }
            }
        }
        let left = expires
            .saturating_duration_since(Instant::now())
            .as_secs_f64()
            .ceil() as i64;
        text(json!({ "step": "waiting", "secondsLeft": left.max(0) }))
    }

    /// `Kern.plexPickProfile`: `pin` empty for an unprotected profile.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn pick_profile(&self, id: String, pin: String) -> String {
        let known = self
            .inner
            .held(|h| h.account_token.is_some() && h.home_users.iter().any(|u| u.uuid == id));
        if !known {
            return step("failed");
        }
        let name = self.inner.held(|h| {
            h.home_users
                .iter()
                .find(|u| u.uuid == id)
                .map(|u| u.title.clone())
        });
        match self
            .inner
            .pick_profile(id, (!pin.is_empty()).then_some(pin.clone()))
            .await
        {
            Ok(PlexProfileEnd::Accepted) => {
                *self
                    .flow
                    .chosen
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner) = name;
                self.servers_step().await
            }
            Ok(PlexProfileEnd::PinWrong) if pin.is_empty() => {
                self.fail(&PlexError::ProfilePinWrong)
            }
            Ok(PlexProfileEnd::PinWrong) => step("pinWrong"),
            Err(e) => self.core_fail(e),
        }
    }

    /// `Kern.plexServers`: asks plex.tv again on every call.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn servers(&self) -> String {
        self.servers_step().await
    }

    /// `Kern.plexPickServer`: the best address that answers, then the session to store as `done`; nothing answering is `unreachable`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn pick_server(&self, id: String) -> String {
        let known = self.inner.held(|h| {
            h.account_token.is_some() && h.servers.iter().any(|s| s.machine_identifier == id)
        });
        if !known || self.flow.connecting.swap(true, Ordering::SeqCst) {
            return step("failed");
        }
        let result = self.inner.connect_account(&id).await;
        self.flow.connecting.store(false, Ordering::SeqCst);
        match result {
            Ok(Some((account, _, _))) => match serde_json::to_string(&account) {
                Ok(session) => text(json!({ "step": "done", "session": session })),
                Err(_) => step("unreachable"),
            },
            _ => step("unreachable"),
        }
    }

    /// `Kern.plexReset`: forgets everything the flow holds.
    pub fn reset(&self) {
        self.reset_flow();
    }
}
