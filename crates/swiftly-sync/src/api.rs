//! The SyncPlay HTTP calls (`extension JellyfinClient` in SyncPlay.swift), built as plain
//! requests and executed through an injected transport and clock.

use serde_json::{Value, json};
use swiftly_net::{ErrorKind, HttpRequest, HttpTransport, Method, Url};

use crate::syncplay::{Reading, SyncPlay, SyncPlayGroup, SyncPlayRight};
use crate::time::{parse_timestamp, time_text};

/// The clock seam: seconds since 1970.
pub trait Clock: Send + Sync {
    /// Now.
    fn now(&self) -> f64;
}

/// What the calls need to know about the signed-in server. `headers` carries the complete
/// authorization (and own) headers every raw request of the jellyfin client sends.
#[derive(Debug, Clone)]
pub struct ServerCtx {
    /// Server base address.
    pub base: String,
    /// Signed-in user id.
    pub user_id: String,
    /// Headers for every request.
    pub headers: Vec<(String, String)>,
}

/// One server call.
#[derive(Debug, Clone, PartialEq)]
pub enum SyncPlayCall {
    /// `GET Users/{id}`: the account's right.
    Right,
    /// `GET SyncPlay/List`.
    List,
    /// `POST SyncPlay/New`.
    Create {
        /// Group name.
        name: String,
    },
    /// `POST SyncPlay/Join`; `rejoin` marks the retry after a dropped channel.
    Join {
        /// Group id.
        group: String,
        /// Rejoin after a drop.
        rejoin: bool,
    },
    /// `POST SyncPlay/Leave`.
    Leave,
    /// `POST SyncPlay/SetNewQueue`.
    SetNewQueue {
        /// Item ids.
        titles: Vec<String>,
        /// Start position in seconds.
        since: f64,
    },
    /// `POST SyncPlay/Unpause`.
    Unpause,
    /// `POST SyncPlay/Pause`.
    Pause,
    /// `POST SyncPlay/Seek`.
    Seek {
        /// Target seconds.
        seconds: f64,
    },
    /// `POST SyncPlay/Ready` or `Buffering`; `moment` is server time.
    State {
        /// Ready or buffering.
        ready: bool,
        /// Server time.
        moment: f64,
        /// Position in seconds.
        spot: f64,
        /// Is the player running.
        running: bool,
        /// `PlaylistItemId`.
        entry_record: String,
    },
    /// `POST SyncPlay/Ping`.
    Ping {
        /// One-way milliseconds.
        milliseconds: i64,
    },
    /// `GET GetUtcTime`.
    ServerTime,
}

impl SyncPlayCall {
    /// A short name for logs and failure routing.
    pub fn name(&self) -> &'static str {
        match self {
            Self::Right => "Right",
            Self::List => "List",
            Self::Create { .. } => "New",
            Self::Join { .. } => "Join",
            Self::Leave => "Leave",
            Self::SetNewQueue { .. } => "SetNewQueue",
            Self::Unpause => "Unpause",
            Self::Pause => "Pause",
            Self::Seek { .. } => "Seek",
            Self::State { ready: true, .. } => "Ready",
            Self::State { ready: false, .. } => "Buffering",
            Self::Ping { .. } => "Ping",
            Self::ServerTime => "GetUtcTime",
        }
    }

    fn path(&self, ctx: &ServerCtx) -> String {
        match self {
            Self::Right => format!("Users/{}", ctx.user_id),
            Self::List => "SyncPlay/List".into(),
            Self::ServerTime => "GetUtcTime".into(),
            other => format!("SyncPlay/{}", other.name()),
        }
    }

    fn method(&self) -> Method {
        if matches!(self, Self::Right | Self::List | Self::ServerTime) {
            Method::Get
        } else {
            Method::Post
        }
    }

    /// The JSON body, if the call has one.
    pub fn body(&self) -> Option<Value> {
        Some(match self {
            Self::Create { name } => json!({ "GroupName": name }),
            Self::Join { group, .. } => json!({ "GroupId": group }),
            Self::SetNewQueue { titles, since } => json!({
                "PlayingQueue": titles, "PlayingItemPosition": 0,
                "StartPositionTicks": SyncPlay::ticks(*since),
            }),
            Self::Seek { seconds } => json!({ "PositionTicks": SyncPlay::ticks(seconds.max(0.0)) }),
            Self::State {
                moment,
                spot,
                running,
                entry_record,
                ..
            } => json!({
                "When": time_text(*moment),
                "PositionTicks": SyncPlay::ticks(spot.max(0.0)),
                "IsPlaying": running,
                "PlaylistItemId": entry_record,
            }),
            Self::Ping { milliseconds } => json!({ "Ping": milliseconds }),
            _ => return None,
        })
    }

    /// Builds the request.
    pub fn to_request(&self, ctx: &ServerCtx) -> Result<HttpRequest, ErrorKind> {
        let url = Url::parse(&format!(
            "{}/{}",
            ctx.base.trim_end_matches('/'),
            self.path(ctx)
        ))
        .map_err(|_| ErrorKind::InvalidServerUrl)?;
        let mut req = HttpRequest::new(self.method(), url);
        for (n, v) in &ctx.headers {
            req.set_header(n, v);
        }
        if let Some(body) = self.body() {
            req.set_header("Content-Type", "application/json");
            req.body =
                Some(serde_json::to_vec(&body).map_err(|e| ErrorKind::Decoding(e.to_string()))?);
        }
        Ok(req)
    }
}

/// What a call brings back.
#[derive(Debug, Clone, PartialEq)]
pub enum CallResult {
    /// Nothing to read.
    Done,
    /// `Right`; `None` if the server says nothing.
    Right(Option<SyncPlayRight>),
    /// `List`.
    Groups(Vec<SyncPlayGroup>),
    /// `ServerTime`.
    Time(Reading),
}

/// Executes calls over a transport and a clock.
pub struct SyncPlayClient<T: HttpTransport, C: Clock> {
    transport: T,
    clock: C,
    ctx: ServerCtx,
}

impl<T: HttpTransport, C: Clock> SyncPlayClient<T, C> {
    /// A client.
    pub fn new(transport: T, clock: C, ctx: ServerCtx) -> Self {
        Self {
            transport,
            clock,
            ctx,
        }
    }

    /// Executes one call. Non-2xx is [`ErrorKind::Http`] (first 300 bytes) except for `Right`,
    /// which swallows every failure into `Right(None)`.
    pub async fn execute(&self, call: &SyncPlayCall) -> Result<CallResult, ErrorKind> {
        let req = call.to_request(&self.ctx)?;
        let sent = self.clock.now();
        let answer = match self.transport.send(req).await {
            Ok(a) => a,
            Err(_) if matches!(call, SyncPlayCall::Right) => return Ok(CallResult::Right(None)),
            Err(e) => return Err(e),
        };
        let receive = self.clock.now();
        if matches!(call, SyncPlayCall::Right) {
            let right = answer
                .is_success()
                .then(|| serde_json::from_slice::<Value>(&answer.body).ok())
                .flatten()
                .and_then(|v| {
                    v["Policy"]["SyncPlayAccess"]
                        .as_str()
                        .and_then(SyncPlayRight::from_raw)
                });
            return Ok(CallResult::Right(right));
        }
        if !answer.is_success() {
            return Err(ErrorKind::Http {
                status: answer.status,
                body: answer.text_prefix(300),
            });
        }
        match call {
            SyncPlayCall::List => SyncPlayGroup::list_from_json(&answer.body)
                .map(CallResult::Groups)
                .ok_or_else(|| ErrorKind::Decoding("SyncPlay/List".into())),
            SyncPlayCall::ServerTime => {
                let v: Value = serde_json::from_slice(&answer.body)
                    .map_err(|_| ErrorKind::Decoding("GetUtcTime".into()))?;
                let read = |k: &str| v[k].as_str().and_then(parse_timestamp);
                match (
                    read("RequestReceptionTime"),
                    read("ResponseTransmissionTime"),
                ) {
                    (Some(a), Some(b)) => Ok(CallResult::Time(Reading {
                        sent,
                        server_receive: a,
                        server_sent: b,
                        receive,
                    })),
                    _ => Err(ErrorKind::Decoding("GetUtcTime".into())),
                }
            }
            _ => Ok(CallResult::Done),
        }
    }
}
