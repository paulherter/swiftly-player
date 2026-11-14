//! Other sessions of the account and the WebSocket channel: `GET Sessions`, playback commands
//! to another session, the handover notice, the capabilities report (JellyfinClient.swift
//! :1145-1190, RemoteControl.swift:461) and the messages that arrive on `/socket`
//! (RemoteControl.swift:389-455).

use serde::Deserialize;
use serde_json::{Value, json};
use swiftly_model::Item;
use swiftly_net::{ErrorKind, Method, TransportReason};
use url::Url;

use crate::client::{JellyfinClient, Query};

/// Ticks per second.
const TICKS: f64 = 10_000_000.0;

/// What a session plays right now (`RemoteSession.PlayState`).
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct RemoteSessionPlayState {
    /// Paused?
    #[serde(rename = "IsPaused")]
    pub halted: Option<bool>,
    #[serde(rename = "PositionTicks")]
    point_ticks: Option<i64>,
}

impl RemoteSessionPlayState {
    /// Position in seconds.
    pub fn spot(&self) -> f64 {
        self.point_ticks.unwrap_or(0) as f64 / TICKS
    }
}

/// Another session of the account (`RemoteSession`, Takeover.swift:8).
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct RemoteSession {
    /// Session id.
    #[serde(rename = "Id")]
    pub id: String,
    /// The user it belongs to.
    #[serde(rename = "UserId", default)]
    pub user_id: Option<String>,
    /// The device id.
    #[serde(rename = "DeviceId", default)]
    pub device_id: Option<String>,
    /// The device name.
    #[serde(rename = "DeviceName", default)]
    pub device_name: Option<String>,
    /// The program (`Client`).
    #[serde(rename = "Client", default)]
    pub program: Option<String>,
    /// Takes commands?
    #[serde(rename = "SupportsRemoteControl", default)]
    pub takes_commands: bool,
    /// What it plays.
    #[serde(rename = "NowPlayingItem", default)]
    pub running: Option<Item>,
    /// Its play state.
    #[serde(rename = "PlayState", default)]
    pub state: Option<RemoteSessionPlayState>,
    /// Last activity, ISO 8601 as the server wrote it.
    #[serde(rename = "LastActivityDate", default)]
    pub last_activity: Option<String>,
    /// Media types it plays; a malformed value counts as empty.
    #[serde(
        rename = "PlayableMediaTypes",
        default,
        deserialize_with = "lenient_strings"
    )]
    pub playable_media_types: Vec<String>,
}

fn lenient_strings<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Vec<String>, D::Error> {
    Ok(Vec::<String>::deserialize(Value::deserialize(d)?).unwrap_or_default())
}

/// A command to another session (`ForeignCommand`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ForeignCommand {
    /// Pause.
    Halt,
    /// Unpause.
    Proceed,
    /// Stop.
    Finish,
}

impl ForeignCommand {
    /// The path part (`Pause`, `Unpause`, `Stop`).
    pub fn raw(self) -> &'static str {
        match self {
            Self::Halt => "Pause",
            Self::Proceed => "Unpause",
            Self::Finish => "Stop",
        }
    }
}

/// A playback command that arrived on the socket (`RemoteCommand`).
#[derive(Debug, Clone, PartialEq)]
pub enum RemoteCommand {
    /// Pause.
    Pause,
    /// Continue.
    Proceed,
    /// Toggle.
    Toggle,
    /// Stop.
    Stop,
    /// Seek to seconds.
    JumpOn(f64),
    /// Skip forward.
    Forward,
    /// Skip back.
    Back,
    /// Next track.
    Next,
    /// Previous track.
    Previous,
}

impl RemoteCommand {
    /// A `Playstate` command name (`translate`); a seek needs its ticks.
    pub fn translate(command: &str, target_ticks: Option<i64>) -> Option<Self> {
        Some(match command {
            "Pause" => Self::Pause,
            "Unpause" => Self::Proceed,
            "PlayPause" => Self::Toggle,
            "Stop" => Self::Stop,
            "Seek" => Self::JumpOn(target_ticks? as f64 / TICKS),
            "FastForward" => Self::Forward,
            "Rewind" => Self::Back,
            "NextTrack" => Self::Next,
            "PreviousTrack" => Self::Previous,
            _ => return None,
        })
    }
}

/// The header of a handover notice (`Takeover.hintHeader`).
pub const HINT_HEADER: &str = "Swiftly-Uebernahme";

/// A message from the server's `/socket` (`RemoteControl.process`).
#[derive(Debug, Clone, PartialEq)]
pub enum SocketMessage {
    /// Answer with `{"MessageType":"KeepAlive"}`.
    ForceKeepAlive,
    /// `SyncPlayCommand` or `SyncPlayGroupUpdate`; the raw text goes to the SyncPlay reader.
    SyncPlay(String),
    /// A handover notice: the name of the device taking over.
    Handoff(String),
    /// A playback command.
    Command(RemoteCommand),
    /// `Play`: the raw text goes to the play-order reader.
    Play(String),
}

impl SocketMessage {
    /// The reply to a `ForceKeepAlive` and the periodic heartbeat.
    pub const KEEP_ALIVE: &'static str = r#"{"MessageType":"KeepAlive"}"#;

    /// Reads one text message; `None` for unknown or unreadable ones.
    pub fn parse(text: &str) -> Option<Self> {
        let raw: Value = serde_json::from_str(text).ok()?;
        match raw.get("MessageType")?.as_str()? {
            "ForceKeepAlive" => Some(Self::ForceKeepAlive),
            "SyncPlayCommand" | "SyncPlayGroupUpdate" => Some(Self::SyncPlay(text.into())),
            "GeneralCommand" => Self::handoff_hint(&raw).map(Self::Handoff),
            "Playstate" => {
                let data = raw.get("Data")?;
                let command = data.get("Command")?.as_str()?;
                let ticks = data.get("SeekPositionTicks").and_then(Value::as_i64);
                RemoteCommand::translate(command, ticks).map(Self::Command)
            }
            "Play" => Some(Self::Play(text.into())),
            _ => None,
        }
    }

    /// The device name from a handover notice, `None` for any other `DisplayMessage`.
    fn handoff_hint(raw: &Value) -> Option<String> {
        let data = raw.get("Data")?;
        if data.get("Name")?.as_str()? != "DisplayMessage" {
            return None;
        }
        let args = data.get("Arguments")?;
        if args.get("Header")?.as_str()? != HINT_HEADER {
            return None;
        }
        let text = args.get("Text")?.as_str()?;
        (!text.is_empty()).then(|| text.to_owned())
    }
}

/// `PlayableMediaTypes` and the commands this device announces (RemoteControl.swift:485).
/// Every name must match the server's `GeneralCommandType`; one typo discards the whole report.
pub const SUPPORTED_COMMANDS: [&str; 11] = [
    "Play",
    "PlayState",
    "PlayNext",
    "PlayMediaSource",
    "DisplayMessage",
    "SetAudioStreamIndex",
    "SetSubtitleStreamIndex",
    "Mute",
    "Unmute",
    "ToggleMute",
    "SetVolume",
];

impl<T: swiftly_net::HttpTransport> JellyfinClient<T> {
    /// `GET Sessions?controllableByUserId&activeWithinSeconds=120` (:1145).
    pub async fn remote_sessions(&self) -> Result<Vec<RemoteSession>, ErrorKind> {
        let s = self.require_session()?;
        let q = Query::new()
            .add("controllableByUserId", &s.user_id)
            .add("activeWithinSeconds", 120);
        self.send(self.get("Sessions", &q)?).await
    }

    /// `POST Sessions/{id}/Playing/{Pause|Unpause|Stop}` (:1158).
    pub async fn foreign_command(
        &self,
        command: ForeignCommand,
        session: &str,
    ) -> Result<(), ErrorKind> {
        let path = format!("Sessions/{session}/Playing/{}", command.raw());
        self.expect_success(self.request(&path, Method::Post, &Query::new(), None)?)
            .await
    }

    /// `POST Sessions/{id}/Message`: tells the one handing over who takes over (:1174).
    pub async fn handoff_hint(&self, session: &str, device: &str) -> Result<(), ErrorKind> {
        let body =
            Self::json_body(&json!({"Header": HINT_HEADER, "Text": device, "TimeoutMs": 1000}))?;
        let req = self.request(
            &format!("Sessions/{session}/Message"),
            Method::Post,
            &Query::new(),
            Some(body),
        )?;
        self.expect_success(req).await
    }

    /// `POST Sessions/{id}/Playing?playCommand=PlayNow&itemIds=…`: asks another session to play a title
    /// (`playOn` of PlayOn.swift). Only IDs, position and track indices go out; the receiver builds
    /// its own plan. `subtitle` is Jellyfin's `Index`, `-1` for off.
    #[allow(clippy::too_many_arguments)] // mirrors PlayOn.swift's parameter list
    pub async fn play_now(
        &self,
        session: &str,
        item_ids: &[String],
        start_index: usize,
        start_seconds: f64,
        media_source_id: Option<&str>,
        audio: Option<i64>,
        subtitle: Option<i64>,
    ) -> Result<(), ErrorKind> {
        let ticks = if start_seconds.is_finite() && start_seconds > 0.0 {
            (start_seconds * TICKS).round() as i64
        } else {
            0
        };
        let mut q = Query::new()
            .add("playCommand", "PlayNow")
            .add("itemIds", item_ids.join(","))
            .add("startPositionTicks", ticks);
        if start_index != 0 {
            q = q.add("startIndex", start_index);
        }
        if let Some(m) = media_source_id {
            q = q.add("mediaSourceId", m);
        }
        if let Some(a) = audio {
            q = q.add("audioStreamIndex", a);
        }
        if let Some(s) = subtitle {
            q = q.add("subtitleStreamIndex", s);
        }
        let req = self.request(
            &format!("Sessions/{session}/Playing"),
            Method::Post,
            &q,
            None,
        )?;
        self.expect_success(req).await
    }

    /// `POST Sessions/Capabilities/Full`: without it the session shows up in the dashboard
    /// but cannot be controlled (RemoteControl.swift:461).
    pub async fn report_capabilities(&self) -> Result<(), ErrorKind> {
        let body = Self::json_body(&json!({
            "PlayableMediaTypes": ["Video", "Audio"],
            "SupportedCommands": SUPPORTED_COMMANDS,
            "SupportsMediaControl": true,
            "SupportsPersistentIdentifier": true,
        }))?;
        let req = self.request(
            "Sessions/Capabilities/Full",
            Method::Post,
            &Query::new(),
            Some(body),
        )?;
        let response = self.execute(req).await?;
        if response.is_success() {
            Ok(())
        } else {
            Err(ErrorKind::Transport(TransportReason::Other(
                "Fähigkeiten konnten nicht gemeldet werden.".into(),
            )))
        }
    }

    /// The WebSocket address: `ws`/`wss://host/socket?ApiKey=<token>&deviceId=<id>`. `ApiKey`,
    /// not `api_key`: it carries Jellyfin 10.8 to 12 (RemoteControl.swift:122-140).
    pub fn socket_url(&self, device_id: &str) -> Result<Url, ErrorKind> {
        let s = self.require_session()?;
        let mut url = self
            .base_url()
            .join("socket")
            .map_err(|_| ErrorKind::InvalidServerUrl)?;
        let scheme = if self.base_url().scheme() == "http" {
            "ws"
        } else {
            "wss"
        };
        url.set_scheme(scheme)
            .map_err(|()| ErrorKind::InvalidServerUrl)?;
        url.query_pairs_mut()
            .append_pair("ApiKey", &s.access_token)
            .append_pair("deviceId", device_id);
        Ok(url)
    }

    /// Success or "the other device did not react".
    async fn expect_success(&self, req: swiftly_net::HttpRequest) -> Result<(), ErrorKind> {
        if self.execute(req).await?.is_success() {
            Ok(())
        } else {
            Err(ErrorKind::Transport(TransportReason::RemoteDeviceSilent))
        }
    }
}

impl<T: swiftly_net::HttpTransport> JellyfinClient<T> {
    /// A signed-in `GET` decoded as JSON, for crates that add typed endpoints on top of this
    /// client (`swiftly-playback`: segments, trickplay, chapters). Same error rules as every
    /// other call.
    pub async fn get_json<D: serde::de::DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, &str)],
    ) -> Result<D, ErrorKind> {
        let mut q = Query::new();
        for (k, v) in query {
            q.push(k, v);
        }
        self.send(self.get(path, &q)?).await
    }

    /// The body of a `GET` on a full address with the account's own headers; `None` on any
    /// failure or non-2xx (trickplay sheets: "only the time is shown").
    pub async fn get_bytes(&self, url: Url) -> Option<Vec<u8>> {
        let mut req = swiftly_net::HttpRequest::new(Method::Get, url);
        crate::own_headers::OwnHeaders::apply(&mut req);
        let response = self.execute(req).await.ok()?;
        response.is_success().then_some(response.body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ClientConfig, ServerKind, Session};
    use futures_executor::block_on;
    use swiftly_net::MockTransport;

    fn client(mock: MockTransport) -> JellyfinClient<MockTransport> {
        let c = JellyfinClient::new(
            mock,
            "https://tv.example.de",
            ClientConfig::new("dev", "Test", "1.0"),
        )
        .expect("client");
        c.set_session(Some(Session {
            access_token: "TOKEN".into(),
            user_id: "u1".into(),
            user_name: "n".into(),
            server_url: "https://tv.example.de".into(),
            kind: ServerKind::Jellyfin,
        }));
        c
    }

    /// A playing session as Jellyfin 10.10 writes it: the item carries streams, chapters, blur hashes
    /// and more than the library lists ever ask for. The whole answer must still decode.
    #[test]
    fn a_playing_session_in_the_servers_own_shape_decodes() {
        let body = r#"[{"PlayState":{"PositionTicks":1234567890,"CanSeek":true,"IsPaused":false,"IsMuted":false,
            "RepeatMode":"RepeatNone","PlaybackOrder":"Default","PlayMethod":"DirectPlay","MediaSourceId":"abc"},
          "AdditionalUsers":[],"Capabilities":{"PlayableMediaTypes":["Audio","Video"],"SupportedCommands":["Play"],
            "SupportsMediaControl":true,"SupportsPersistentIdentifier":true},
          "RemoteEndPoint":"192.168.1.20","PlayableMediaTypes":["Audio","Video"],"Id":"3a1b5c","UserId":"9f8e7d",
          "UserName":"paul","Client":"Swiftly Player","LastActivityDate":"2026-11-14T10:00:00.1234567Z",
          "LastPlaybackCheckIn":"0001-01-01T00:00:00.0000000Z","DeviceName":"Mac","DeviceId":"MAC-1",
          "ApplicationVersion":"1.1.0","IsActive":true,"SupportsMediaControl":true,"SupportsRemoteControl":true,
          "NowPlayingItem":{"Name":"Pilot","OriginalTitle":"Pilot","ServerId":"srv","Id":"e1",
            "DateCreated":"2025-01-01T00:00:00.0000000Z","Container":"mkv","PremiereDate":"2008-01-20T00:00:00.0000000Z",
            "ChannelId":null,"CommunityRating":8.9,"RunTimeTicks":29000000000,"ProductionYear":2008,"IndexNumber":1,
            "ParentIndexNumber":1,"IsFolder":false,"Type":"Episode","ParentBackdropItemId":"s1",
            "ParentBackdropImageTags":["t"],"UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false,"Key":"x"},
            "SeriesName":"Show","SeriesId":"s1","SeasonId":"se1","PrimaryImageAspectRatio":1.7777777777777777,
            "SeriesPrimaryImageTag":"p","SeasonName":"Season 1","MediaStreams":[
              {"Codec":"h264","TimeBase":"1/1000","VideoRange":"SDR","DisplayTitle":"1080p H264","IsInterlaced":false,
               "BitRate":8000000,"BitDepth":8,"RefFrames":4,"IsDefault":true,"IsForced":false,"Height":1080,"Width":1920,
               "AverageFrameRate":23.976025,"RealFrameRate":23.976025,"Profile":"High","Type":"Video","AspectRatio":"16:9",
               "Index":0,"IsExternal":false,"IsTextSubtitleStream":false,"SupportsExternalStream":false,"PixelFormat":"yuv420p","Level":41},
              {"Codec":"ac3","Language":"ger","ChannelLayout":"5.1","Channels":6,"SampleRate":48000,"IsDefault":true,
               "Type":"Audio","Index":1,"IsExternal":false}],
            "ImageTags":{"Primary":"tag"},"BackdropImageTags":[],"ImageBlurHashes":{"Primary":{"tag":"LKO2"}},
            "Chapters":[],"MediaType":"Video","Width":1920,"Height":1080}}]"#;
        let c = client(MockTransport::new().route("/Sessions", 200, body));
        let list = block_on(c.remote_sessions()).expect("sessions");
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].running.as_ref().map(|i| i.id.as_str()), Some("e1"));
        assert!(list[0].takes_commands);
    }

    // JellyfinClient.swift:1145
    #[test]
    fn remote_sessions_asks_for_controllable_active_ones_and_reads_leniently() {
        let body = r#"[{"Id":"s1","UserId":"u1","DeviceId":"d","DeviceName":"TV","Client":"Swiftly",
            "SupportsRemoteControl":true,"PlayableMediaTypes":"kaputt",
            "PlayState":{"IsPaused":true,"PositionTicks":900000000},
            "NowPlayingItem":{"Id":"i1","Name":"Film","Type":"Movie"}},{"Id":"s2"}]"#;
        let c = client(MockTransport::new().route("/Sessions", 200, body));
        let list = block_on(c.remote_sessions()).expect("sessions");
        let url = c.transport().last_request().expect("req").url;
        assert_eq!(
            url.as_str(),
            "https://tv.example.de/Sessions?controllableByUserId=u1&activeWithinSeconds=120"
        );
        assert_eq!(list.len(), 2);
        assert!(list[0].takes_commands && list[0].playable_media_types.is_empty());
        assert_eq!(list[0].state.as_ref().map(|s| s.spot()), Some(90.0));
        assert_eq!(list[0].running.as_ref().map(|i| i.id.as_str()), Some("i1"));
        assert!(!list[1].takes_commands && list[1].running.is_none());
    }

    // :1158
    #[test]
    fn foreign_command_posts_to_playing_and_fails_with_the_silent_device_text() {
        let c = client(MockTransport::new().route("/Playing/Unpause", 204, ""));
        block_on(c.foreign_command(ForeignCommand::Proceed, "s1")).expect("ok");
        let r = c.transport().last_request().expect("req");
        assert_eq!(r.method, Method::Post);
        assert_eq!(r.url.path(), "/Sessions/s1/Playing/Unpause");
        let c = client(MockTransport::new().route("/Playing/Stop", 500, ""));
        assert_eq!(
            block_on(c.foreign_command(ForeignCommand::Finish, "s1")),
            Err(ErrorKind::Transport(TransportReason::RemoteDeviceSilent))
        );
    }

    // :1174
    #[test]
    fn handoff_hint_body() {
        let c = client(MockTransport::new().route("/Message", 204, ""));
        block_on(c.handoff_hint("s1", "Wohnzimmer")).expect("ok");
        let r = c.transport().last_request().expect("req");
        assert_eq!(r.url.path(), "/Sessions/s1/Message");
        let body: Value = serde_json::from_slice(&r.body.expect("body")).expect("json");
        assert_eq!(
            body,
            json!({"Header": HINT_HEADER, "Text": "Wohnzimmer", "TimeoutMs": 1000})
        );
    }

    // PlayOn.swift: PlayOrder.query
    #[test]
    fn play_now_sends_ids_ticks_and_tracks() {
        let c = client(MockTransport::new().route("/Playing", 204, ""));
        block_on(c.play_now(
            "s1",
            &["i1".into()],
            0,
            12.5,
            Some("src"),
            Some(2),
            Some(-1),
        ))
        .expect("ok");
        let r = c.transport().last_request().expect("req");
        assert_eq!(r.url.path(), "/Sessions/s1/Playing");
        let q = r.url.query().unwrap_or_default().to_owned();
        for part in [
            "playCommand=PlayNow",
            "itemIds=i1",
            "startPositionTicks=125000000",
            "mediaSourceId=src",
            "audioStreamIndex=2",
            "subtitleStreamIndex=-1",
        ] {
            assert!(q.contains(part), "{part} in {q}");
        }
        assert!(!q.contains("startIndex"));
    }

    // RemoteControl.swift:461-499
    #[test]
    fn capabilities_report_uses_the_exact_server_names() {
        let c = client(MockTransport::new().route("/Capabilities/Full", 204, ""));
        block_on(c.report_capabilities()).expect("ok");
        let r = c.transport().last_request().expect("req");
        assert_eq!(r.url.path(), "/Sessions/Capabilities/Full");
        let body: Value = serde_json::from_slice(&r.body.expect("body")).expect("json");
        // `PlayState` with a capital S: the old `Playstate` made the server drop the report.
        assert!(
            body["SupportedCommands"]
                .as_array()
                .expect("list")
                .contains(&json!("PlayState"))
        );
        assert!(
            !body["SupportedCommands"]
                .as_array()
                .expect("list")
                .contains(&json!("Playstate"))
        );
        assert_eq!(body["PlayableMediaTypes"], json!(["Video", "Audio"]));
        assert_eq!(body["SupportsMediaControl"], json!(true));
        assert_eq!(body["SupportsPersistentIdentifier"], json!(true));
    }

    // :122-140
    #[test]
    fn socket_url_uses_wss_and_apikey() {
        let c = client(MockTransport::new());
        assert_eq!(
            c.socket_url("dev-1").expect("url").as_str(),
            "wss://tv.example.de/socket?ApiKey=TOKEN&deviceId=dev-1"
        );
    }

    // :389-455
    #[test]
    fn socket_messages_are_sorted() {
        use SocketMessage::*;
        let p = SocketMessage::parse;
        assert_eq!(
            p(r#"{"MessageType":"ForceKeepAlive"}"#),
            Some(ForceKeepAlive)
        );
        assert!(matches!(
            p(r#"{"MessageType":"SyncPlayCommand","Data":{}}"#),
            Some(SyncPlay(_))
        ));
        assert!(matches!(
            p(r#"{"MessageType":"SyncPlayGroupUpdate","Data":{}}"#),
            Some(SyncPlay(_))
        ));
        assert!(matches!(
            p(r#"{"MessageType":"Play","Data":{}}"#),
            Some(Play(_))
        ));
        assert_eq!(
            p(
                r#"{"MessageType":"Playstate","Data":{"Command":"Seek","SeekPositionTicks":600000000}}"#
            ),
            Some(Command(RemoteCommand::JumpOn(60.0)))
        );
        assert_eq!(
            p(r#"{"MessageType":"Playstate","Data":{"Command":"Seek"}}"#),
            None
        );
        assert_eq!(
            p(r#"{"MessageType":"Playstate","Data":{"Command":"PlayPause"}}"#),
            Some(Command(RemoteCommand::Toggle))
        );
        assert_eq!(
            p(r#"{"MessageType":"Playstate","Data":{"Command":"Bogus"}}"#),
            None
        );
        assert_eq!(p(r#"{"MessageType":"Other"}"#), None);
        assert_eq!(p("kein JSON"), None);
        assert_eq!(SocketMessage::KEEP_ALIVE, r#"{"MessageType":"KeepAlive"}"#);
    }

    #[test]
    fn only_our_display_message_is_a_handoff() {
        let ours = format!(
            r#"{{"MessageType":"GeneralCommand","Data":{{"Name":"DisplayMessage","Arguments":{{"Header":"{HINT_HEADER}","Text":"iPhone"}}}}}}"#
        );
        assert_eq!(
            SocketMessage::parse(&ours),
            Some(SocketMessage::Handoff("iPhone".into()))
        );
        let foreign = r#"{"MessageType":"GeneralCommand","Data":{"Name":"DisplayMessage","Arguments":{"Header":"Hallo","Text":"x"}}}"#;
        assert_eq!(SocketMessage::parse(foreign), None);
        let other = r#"{"MessageType":"GeneralCommand","Data":{"Name":"Mute"}}"#;
        assert_eq!(SocketMessage::parse(other), None);
    }

    #[test]
    fn get_json_and_bytes_pass_through() {
        let c = client(
            MockTransport::new()
                .route("/Things", 200, r#"{"a":1}"#)
                .route("/pic.jpg", 200, "JPG"),
        );
        let v: Value = block_on(c.get_json("Things", &[("x", "y z")])).expect("json");
        assert_eq!(v["a"], 1);
        assert_eq!(
            c.transport().last_request().expect("req").url.query(),
            Some("x=y%20z")
        );
        let url = Url::parse("https://tv.example.de/pic.jpg").expect("url");
        assert_eq!(block_on(c.get_bytes(url)), Some(b"JPG".to_vec()));
    }
}
