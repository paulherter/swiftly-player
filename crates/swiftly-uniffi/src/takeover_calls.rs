//! The server calls of "continue here" and "play on" for the Android app, with the JSON answers the
//! old Swift `Kern` gave (`takeoverOfferings`, `handedOver`, `playTargets`, `playOn`, `playHandOver`).
//! The rules are the ones of `swiftly_playback::takeover`; the order of the hand-over steps is
//! the one of `handoff_flow` (plan, hint, stop, up to 15 reads of the saved position).

use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use serde_json::{Value, json};
use swiftly_jellyfin::{ForeignCommand, RemoteSession};
use swiftly_l10n::Translator;
use swiftly_net::ErrorKind;
use swiftly_playback::handoff_flow::{SETTLE_STEP_MS, SETTLE_TRIES};
use swiftly_playback::takeover::{self, DevicesKind, RemoteSessionExt};
use swiftly_vm::{Host, account_client};

use crate::play_start::PlanOnly;
use crate::transport::CoreTransport;
use swiftly_vm::AccountRef;

const TICKS: f64 = 10_000_000.0;

/// The calls of one signed-in Jellyfin account on this device.
#[derive(uniffi::Object)]
pub struct TakeoverCalls {
    transport: CoreTransport,
    host: Host,
    account: AccountRef,
    targets: Mutex<Vec<RemoteSession>>,
}

impl TakeoverCalls {
    pub(crate) fn build(transport: CoreTransport, host: Host, account: AccountRef) -> Arc<Self> {
        Arc::new(Self {
            transport,
            host,
            account,
            targets: Mutex::new(vec![]),
        })
    }

    fn client(
        &self,
    ) -> Result<swiftly_jellyfin::JellyfinClient<swiftly_vm::Shared<CoreTransport>>, ErrorKind>
    {
        account_client(&Arc::new(self.transport.clone()), &self.host, &self.account)
    }

    fn text(&self, e: &ErrorKind) -> String {
        swiftly_l10n::error_text::readable_error(&Translator::new(self.host.locale.clone()), e)
    }

    fn now() -> f64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64())
    }

    fn set_targets(&self, all: &[RemoteSession]) {
        let t = takeover::play_targets(
            all,
            &self.account.device_id,
            &self.account.user_id,
            Self::now(),
        );
        *self.targets.lock().unwrap_or_else(PoisonError::into_inner) = t;
    }

    /// The current session of the chosen device from a fresh list, or the reason (`weg`, an error text).
    async fn target(&self, device_id: &str) -> Result<RemoteSession, String> {
        let c = self.client().map_err(|e| self.text(&e))?;
        let all = c.remote_sessions().await.map_err(|e| self.text(&e))?;
        self.set_targets(&all);
        self.targets
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .find(|s| s.device_id.as_deref() == Some(device_id))
            .cloned()
            .ok_or_else(|| "weg".to_owned())
    }

    async fn deliver(
        &self,
        session: &RemoteSession,
        item_ids: Vec<String>,
        start: f64,
        source: Option<String>,
        audio: Option<i64>,
        subtitle: Option<i64>,
    ) -> String {
        let name = takeover::target_name(session);
        let sent = match self.client() {
            Ok(c) => {
                c.play_now(
                    &session.id,
                    &item_ids,
                    0,
                    start,
                    source.as_deref(),
                    audio,
                    subtitle,
                )
                .await
            }
            Err(e) => Err(e),
        };
        match sent {
            Ok(()) => json!({"grund": "", "name": name}).to_string(),
            Err(e) => json!({"grund": self.text(&e), "name": name}).to_string(),
        }
    }
}

fn kind_name(k: DevicesKind) -> &'static str {
    match k {
        DevicesKind::Phone => "telefon",
        DevicesKind::Tablet => "tablet",
        DevicesKind::Computer => "rechner",
        DevicesKind::Tv => "fernseher",
        DevicesKind::Unknown => "unbekannt",
    }
}

fn handed(reason: &str, since: f64) -> String {
    json!({"grund": reason, "ab": since}).to_string()
}

#[uniffi::export]
impl TakeoverCalls {
    /// What runs on another device of the account and can be taken over, as the old
    /// `[{"id","itemID","geraet","art","titelzeile","stelle","stelleText","bild","name","serie","staffelNr","folgeNr"}]`.
    /// An error is no error here: there is simply no offer (`[]`).
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn offerings(&self) -> String {
        let Ok(c) = self.client() else {
            return "[]".into();
        };
        let Ok(all) = c.remote_sessions().await else {
            return "[]".into();
        };
        if takeover::must_report(&all, &self.account.device_id) {
            let _ = c.report_capabilities().await;
        }
        let now = Self::now();
        self.set_targets(&all);
        let addresses = c.current_session().map(|s| {
            swiftly_images::ImageAddress::new(
                c.base_url().clone(),
                Some(s.access_token),
                c.server_kind(),
            )
        });
        let list: Vec<Value> = takeover::offerings(&all, &self.account.device_id, &self.account.user_id, now)
            .into_iter()
            .filter_map(|f| {
                let title = f.running.as_ref().filter(|t| !t.id.is_empty())?;
                let spot = f.state.as_ref().map_or(0.0, |s| s.spot());
                Some(json!({
                    "id": f.id, "itemID": title.id, "geraet": f.device_name, "art": kind_name(f.devices_kind()),
                    "titelzeile": f.title_line(), "stelle": spot,
                    "stelleText": swiftly_vm::minutes_text(self.host.locale.clone(), spot),
                    "bild": addresses.as_ref().and_then(|a| swiftly_vm::card_image(title, a)),
                    "name": title.name, "serie": title.series_name,
                    "staffelNr": title.parent_index_number, "folgeNr": title.index_number,
                }))
            })
            .collect();
        Value::Array(list).to_string()
    }

    /// Take over as on Apple: check a plan exists, hint to the giver, stop it, then read the saved position
    /// up to 15 times. Answer `{"grund": "", "ab": seconds}`; a non-empty reason (`keinPlan`, `nichtVerbunden`,
    /// an error text) means: do not start here.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn handed_over(
        &self,
        session: String,
        item_id: String,
        spot: f64,
        own_name: String,
        max_bitrate: i64,
    ) -> String {
        let Ok(c) = self.client() else {
            return handed("nichtVerbunden", spot);
        };
        match crate::play_start::play_plan_only(
            self.transport.foreign(),
            &self.host,
            &self.account,
            &item_id,
            None,
            false,
            max_bitrate,
            None,
        )
        .await
        {
            Ok(PlanOnly::Ready { .. }) => {}
            Ok(PlanOnly::NoSource) => return handed("keinPlan", spot),
            Ok(PlanOnly::Failed { message, .. }) => return handed(&message, spot),
            Err(e) => return handed(&e.to_string(), spot),
        }
        let (saved, fresh) = tokio::join!(c.item(&item_id), c.remote_sessions());
        let before = saved
            .ok()
            .and_then(|i| i.user_data)
            .and_then(|d| d.playback_position_ticks);
        let fresh = fresh
            .ok()
            .and_then(|all| all.into_iter().find(|s| s.id == session));
        let session_point = fresh
            .as_ref()
            .and_then(|s| s.state.as_ref())
            .map_or(spot, |s| s.spot());
        if let Some(f) = &fresh
            && takeover::takes_hint(f)
        {
            let _ = c.handoff_hint(&session, &own_name).await;
        }
        if let Err(e) = c.foreign_command(ForeignCommand::Finish, &session).await {
            return handed(&self.text(&e), spot);
        }
        let mut afterwards = None;
        for _ in 0..SETTLE_TRIES {
            tokio::time::sleep(Duration::from_millis(u64::from(SETTLE_STEP_MS))).await;
            let now = c
                .item(&item_id)
                .await
                .ok()
                .and_then(|i| i.user_data)
                .and_then(|d| d.playback_position_ticks);
            if now != before {
                afterwards = now;
                break;
            }
        }
        handed("", takeover::start_point(session_point, before, afterwards))
    }

    /// Where a film can be handed over, from the last offerings answer: `[{"deviceId","name"}]`.
    pub fn play_targets(&self) -> String {
        let list: Vec<Value> = self
            .targets
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .filter_map(|s| {
                let id = s.device_id.as_deref().filter(|d| !d.is_empty())?;
                Some(json!({"deviceId": id, "name": takeover::target_name(s)}))
            })
            .collect();
        Value::Array(list).to_string()
    }

    /// A title started on the TV from a page or a menu: only the id and the resume position go out
    /// (`position` < 0: from where the server last saw the viewer). Answer `{"grund","name"}`.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn play_on(
        &self,
        item_id: String,
        device_id: String,
        name: String,
        position: f64,
    ) -> String {
        let session = match self.target(&device_id).await {
            Ok(s) => s,
            Err(reason) => return json!({"grund": reason, "name": name}).to_string(),
        };
        let start = if position >= 0.0 {
            position
        } else {
            match self.client() {
                Ok(c) => c
                    .item(&item_id)
                    .await
                    .ok()
                    .and_then(|i| i.user_data)
                    .and_then(|d| d.playback_position_ticks)
                    .map_or(0.0, |t| t as f64 / TICKS),
                Err(_) => 0.0,
            }
        };
        self.deliver(&session, vec![item_id], start, None, None, None)
            .await
    }

    /// The running title handed over from the player: same position, version and the tracks that play now
    /// (read from `playback`; the TV builds its own plan). Answer `{"grund","name"}`; `nichtVerbunden`
    /// when nothing is open.
    #[uniffi::method(async_runtime = "tokio")]
    pub async fn play_hand_over(
        &self,
        playback: Arc<crate::legacy_playback::LegacyPlayback>,
        device_id: String,
        name: String,
        position: f64,
    ) -> String {
        let Some((item_id, source, audio, subtitle)) = playback.hand_over_order() else {
            return json!({"grund": "nichtVerbunden", "name": name}).to_string();
        };
        let session = match self.target(&device_id).await {
            Ok(s) => s,
            Err(reason) => return json!({"grund": reason, "name": name}).to_string(),
        };
        self.deliver(
            &session,
            vec![item_id],
            position,
            source,
            audio,
            Some(subtitle),
        )
        .await
    }
}
