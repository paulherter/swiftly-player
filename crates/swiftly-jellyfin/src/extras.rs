//! The last single calls of `JellyfinClient.swift`: raw user data (measurement runs), the
//! Jelly Twiggy watcher list, the download permission the client remembers, and the download
//! addresses (:840-895, :1195, :1413-1500).

use serde_json::Value;
use swiftly_net::{ErrorKind, HttpTransport, Method, Url};

use crate::client::{JellyfinClient, Query};
use crate::query::build_url;
use crate::session::ServerKind;

/// One person who watched a title (Watchers.swift). Every field but the user id is read
/// leniently, like the Swift decoder.
#[derive(Debug, Clone, PartialEq)]
pub struct Watcher {
    /// `UserId`.
    pub user_id: String,
    /// `UserName`, empty when missing.
    pub name: String,
    /// `ImageTag`.
    pub image_tag: Option<String>,
    /// `PlayCount`, 0 when missing.
    pub play_count: i64,
    /// `LastWatched` as the server's text (the date parser lives with the callers).
    pub last_watched: Option<String>,
    /// 0...100 for a film that was started.
    pub progress_percent: Option<f64>,
    /// Series and seasons: "7 of 10 episodes".
    pub watched_count: Option<i64>,
    /// See `watched_count`.
    pub total_count: Option<i64>,
}

/// Swift's `JSONDecoder` reads `3.0` and `1e2` as the whole numbers 3 and 100 (F-oracle-H02).
fn whole(v: Option<&Value>) -> Option<i64> {
    let Value::Number(n) = v? else { return None };
    if let Some(i) = n.as_i64() {
        return Some(i);
    }
    let f = n.as_f64().filter(|f| n.is_f64() && f.fract() == 0.0)?;
    // i64::MIN is exactly -2^63 as a double; -2^63 negated is the first value that no longer fits.
    (i64::MIN as f64..-(i64::MIN as f64))
        .contains(&f)
        .then_some(f as i64)
}

impl Watcher {
    /// Reads one entry of the `Watchers` answer; `None` without a `UserId`.
    pub fn read(v: &Value) -> Option<Self> {
        let text = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned);
        Some(Self {
            user_id: text("UserId")?,
            name: text("UserName").unwrap_or_default(),
            image_tag: text("ImageTag"),
            play_count: whole(v.get("PlayCount")).unwrap_or(0),
            last_watched: text("LastWatched"),
            progress_percent: v.get("ProgressPercent").and_then(Value::as_f64),
            watched_count: whole(v.get("WatchedCount")),
            total_count: whole(v.get("TotalCount")),
        })
    }

    /// How much of the ring is drawn, 0...1 (Watchers.swift `ring`).
    pub fn ring(&self) -> f64 {
        if let (Some(w), Some(t)) = (self.watched_count, self.total_count)
            && t > 0
        {
            return (w as f64 / t as f64).clamp(0.0, 1.0);
        }
        if let Some(p) = self.progress_percent {
            return (p / 100.0).clamp(0.0, 1.0);
        }
        if self.play_count > 0 { 1.0 } else { 0.0 }
    }
}

/// What a lower-quality download asks the server to convert to (the `converting` tuple in
/// `downloadURL(…quality:…)`, :1438).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DownloadConversion {
    /// `videoBitRate`.
    pub video_bitrate: i64,
    /// `audioBitRate`.
    pub audio_bitrate: i64,
    /// `maxHeight`.
    pub height: i64,
    /// `maxWidth`.
    pub width: i64,
    /// `maxAudioChannels`.
    pub channels: i64,
}

/// The container of a converted download (`DownloadQuality.container`).
const DOWNLOAD_CONTAINER: &str = "mkv";

impl<T: HttpTransport> JellyfinClient<T> {
    /// `GET UserItems/{id}/UserData`, the raw bytes, so a measurement run can restore the state
    /// exactly (:840). Any status is passed through like `urlSession.data(for:)`.
    pub async fn user_data_raw(&self, item_id: &str) -> Result<Vec<u8>, ErrorKind> {
        let s = self.require_session()?;
        let q = Query::new().add("userId", &s.user_id);
        let req = self.get(&format!("UserItems/{item_id}/UserData"), &q)?;
        Ok(self.execute(req).await?.body)
    }

    /// `POST UserItems/{id}/UserData` with the bytes `user_data_raw` returned (:848).
    pub async fn user_data_back_put(&self, item_id: &str, raw: Vec<u8>) -> Result<(), ErrorKind> {
        let s = self.require_session()?;
        let q = Query::new().add("userId", &s.user_id);
        let req = self.request(
            &format!("UserItems/{item_id}/UserData"),
            Method::Post,
            &q,
            Some(raw),
        )?;
        self.send_ignoring_body(req).await
    }

    /// Jelly Twiggy: who watched a title. `None` when the server has no such plugin; once the
    /// plugin has answered "not here" the client does not ask again (:876).
    pub async fn watchers(&self, item_id: &str) -> Option<Vec<Watcher>> {
        if self.config.kind != ServerKind::Jellyfin || self.current_session().is_none() {
            return None;
        }
        if self.state().watchers_absent {
            return None;
        }
        let req = self
            .get(
                &format!("JellyTwiggy/Items/{item_id}/Watchers"),
                &Query::new(),
            )
            .ok()?;
        match self.send::<Vec<Value>>(req).await {
            // The Swift decoder fails the whole list on a broken entry.
            Ok(list) => list.iter().map(Watcher::read).collect(),
            Err(ErrorKind::Http { status, .. }) if status == 404 || status == 405 => {
                // The route itself is missing on a server without the plugin; one unknown
                // title alone (404) does not prove that, two different ones do.
                let mut state = self.state();
                state.watchers_not_found.insert(item_id.to_owned());
                if status == 405 || state.watchers_not_found.len() >= 2 {
                    state.watchers_absent = true;
                }
                None
            }
            Err(_) => None,
        }
    }

    /// `true` once the server has said it has no Jelly Twiggy plugin (:895).
    pub fn watchers_plugin_missing(&self) -> bool {
        self.state().watchers_absent
    }

    /// Remembers `Policy.EnableContentDownloading` from an `accountDefaults` answer (:1199).
    /// Only on a response, never on a failure.
    pub fn remember_download_allowed(&self, allowed: Option<bool>) {
        self.state().download_allowed = allowed;
    }

    /// The remembered permission; `None` = unknown = allowed.
    pub fn download_allowed(&self) -> Option<bool> {
        self.state().download_allowed
    }

    /// The address a title is downloaded from (:1413, :1438).
    ///
    /// Plain (`conversion` and `audio_stream_index` both `None`): the stream address without a
    /// `playSessionId`. Otherwise `Videos/{id}/stream.mkv` with `static=false`: converted, or
    /// only cut down to one audio track (`videoCodec=copy`). **The bolt sits here**: an
    /// explicit "not allowed" gives the same 403 the server would.
    pub fn download_url(
        &self,
        item_id: &str,
        media_source_id: Option<&str>,
        conversion: Option<DownloadConversion>,
        audio_stream_index: Option<i64>,
    ) -> Result<Url, ErrorKind> {
        if self.download_allowed() == Some(false) {
            return Err(ErrorKind::Http {
                status: 403,
                body: Some("EnableContentDownloading".into()),
            });
        }
        if conversion.is_none() && audio_stream_index.is_none() {
            return self.stream_url(item_id, media_source_id, None);
        }
        let s = self.require_session()?;
        let mut q = Query::new()
            .add("static", "false")
            .add("container", DOWNLOAD_CONTAINER);
        if let Some(c) = conversion {
            q.push("videoCodec", "h264");
            q.push("audioCodec", "aac");
            q.push("videoBitRate", c.video_bitrate);
            q.push("audioBitRate", c.audio_bitrate);
            q.push("maxAudioChannels", c.channels);
            q.push("maxHeight", c.height);
            q.push("maxWidth", c.width);
        } else {
            q.push("videoCodec", "copy");
            q.push("audioCodec", "copy");
            q.push("allowVideoStreamCopy", "true");
            q.push("allowAudioStreamCopy", "true");
        }
        if let Some(a) = audio_stream_index {
            q.push("AudioStreamIndex", a);
        }
        q.push("deviceId", &self.config.device_id);
        q.push(self.token_name(), &s.access_token);
        if let Some(m) = media_source_id {
            q.push("mediaSourceId", m);
        }
        build_url(
            &self.base_url,
            &format!("Videos/{item_id}/stream.{DOWNLOAD_CONTAINER}"),
            &q.0,
        )
        .ok_or(ErrorKind::InvalidServerUrl)
    }
}
