//! Play on the real app: the plan from the server, the player spec, the engine (libmpv, feature `mpv`) and the
//! reports (`ClientReporter`: start, progress every ~10 s, stop).

use crate::live::{Client, Core};
use crate::live_server::Server;
use crate::login_screen::Pending;
use crate::player_host::{PlanAsk, Planner, Switched};
use crate::player_screen::{LiveEngine, PlayerScreen};
use std::sync::{Arc, Mutex, PoisonError};
use swiftly_jellyfin::{PendingReport, PlayMethod, ReportPlan};
use swiftly_model::DeliveryMethod;
use swiftly_playback::device_profile::DeviceProfile;
use swiftly_playback::endpoints::PlaybackEndpoints;
use swiftly_playback::engine::PlaybackEngine;
use swiftly_playback::media_server::MediaServer;
use swiftly_playback::player_state::EngineRequest;
use swiftly_playback::sections::{Art, Segment};
use swiftly_playback::track_rule;
use swiftly_playback::trickplay::Trickplay;
use swiftly_rules::buffer_level::BufferLevel;
use swiftly_rules::chapter::Chapter;
use swiftly_settings::{KeyValueStore, Value};
use swiftly_ui::{Cx, Env};
use swiftly_vm::{
    ClientReporter, NextEpisode, PendingSink, PlayerSpec, PlexReporter, Quality, TrackMemoryStore,
};

/// What a switch adds to a plan request: the quality's bitrate and the subtitle picked on a transcode.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Extras {
    /// The bitrate the profile reports (`BitratesLimit.of`).
    pub max_bitrate: i64,
    /// Server subtitle index to start on (`-1` off); `None`: the track rules decide.
    pub subtitle: Option<i64>,
}

impl Default for Extras {
    fn default() -> Self {
        Extras {
            max_bitrate: swiftly_playback::device_profile::DEFAULT_MAX_BITRATE,
            subtitle: None,
        }
    }
}

/// What a press on Play asks for.
#[derive(Debug, Clone, PartialEq)]
pub struct PlayRequest {
    /// The title.
    pub item_id: String,
    /// Second to start at (resume position).
    pub since: f64,
    /// The picked version.
    pub source_id: Option<String>,
}

/// A title with several versions and no pick: the host asks, then starts again with the chosen `source_id`.
#[derive(Debug, Clone)]
pub struct VersionAsk {
    /// The title.
    pub item_id: String,
    /// The start meant for the pick.
    pub since: f64,
    /// The versions to choose from.
    pub versions: Vec<swiftly_vm::VersionOption>,
}

/// What a start comes to: a title ready for the engine, or a question about its versions.
pub enum Prepared {
    /// Everything fetched, the engine can start.
    Ready(Box<Ready>),
    /// Several versions (Plex): ask first.
    Choose(VersionAsk),
}

impl Prepared {
    /// The ready title, `None` while a version is asked for.
    pub fn ready(&self) -> Option<&Ready> {
        match self {
            Prepared::Ready(r) => Some(r),
            Prepared::Choose(_) => None,
        }
    }

    /// The question about the versions, `None` for a ready title.
    pub fn ask(&self) -> Option<&VersionAsk> {
        match self {
            Prepared::Choose(a) => Some(a),
            Prepared::Ready(_) => None,
        }
    }
}

/// Everything fetched before the engine starts.
pub struct Ready {
    spec: PlayerSpec,
    head: (String, String),
    sections: Vec<Segment>,
    chapters: Vec<Chapter>,
    trickplay: Option<Trickplay>,
    request: PlayRequest,
    server: Server,
    /// Length of the title in ms for the Plex timeline report.
    duration_ms: Option<i64>,
    account: String,
    memory: Arc<SettingsMemory>,
}

/// The track memory (`utJeTitel` / `tonJeTitel`) as JSON texts in settings.json.
pub struct SettingsMemory(Arc<swiftly_settings::JsonFileStore>);

impl TrackMemoryStore for SettingsMemory {
    fn load(&self, key: &str) -> std::collections::HashMap<String, String> {
        match self.0.get(key) {
            Some(Value::Str(s)) => serde_json::from_str(&s).unwrap_or_default(),
            _ => std::collections::HashMap::new(),
        }
    }
    fn save(&self, key: &str, all: &std::collections::HashMap<String, String>) {
        if let Ok(text) = serde_json::to_string(all) {
            let _ = self.0.set(key, Value::Str(text));
        }
    }
}

fn text(store: &swiftly_settings::JsonFileStore, key: &str) -> String {
    match store.get(key) {
        Some(Value::Str(s)) => s,
        _ => String::new(),
    }
}

impl Ready {
    /// The address the engine opens.
    pub fn url(&self) -> &str {
        &self.spec.request.url
    }

    /// The server the reports go to.
    pub fn server(&self) -> &Server {
        &self.server
    }

    /// The preview offer of the title (Plex: the BIF behind the part).
    pub fn trickplay(&self) -> Option<Trickplay> {
        self.trickplay
    }
}

impl Prepared {
    /// A title that plays from a file on the device: no network plan, the reports queue up as pending ones.
    pub(crate) fn offline(
        core: &Core,
        spec: PlayerSpec,
        head: (String, String),
        server: Server,
        account: String,
    ) -> Prepared {
        let request = PlayRequest {
            item_id: spec.item_id.clone(),
            since: spec.start_at,
            source_id: None,
        };
        let memory = Arc::new(SettingsMemory(Arc::clone(&core.settings)));
        // The Plex timeline report wants the length of the title.
        let duration_ms =
            (spec.request.runtime > 0.0).then_some((spec.request.runtime * 1000.0) as i64);
        Prepared::Ready(Box::new(Ready {
            spec,
            head,
            sections: Vec::new(),
            chapters: Vec::new(),
            trickplay: None,
            request,
            server,
            duration_ms,
            account,
            memory,
        }))
    }
}

/// Stops that did not get through are kept in the settings file (`pending.reports`).
struct SettingsPending(Arc<swiftly_settings::JsonFileStore>, Mutex<()>);

impl PendingSink for SettingsPending {
    fn record(&self, report: PendingReport) {
        let _g = self.1.lock().unwrap_or_else(PoisonError::into_inner);
        let mut all: Vec<PendingReport> = match self.0.get("pending.reports") {
            Some(Value::Str(s)) => serde_json::from_str(&s).unwrap_or_default(),
            _ => Vec::new(),
        };
        all.push(report);
        if let Ok(text) = serde_json::to_string(&all) {
            let _ = self.0.set("pending.reports", Value::Str(text));
        }
    }
}

fn method(m: DeliveryMethod) -> PlayMethod {
    match m {
        DeliveryMethod::DirectPlay => PlayMethod::DirectPlay,
        DeliveryMethod::DirectStream => PlayMethod::DirectStream,
        DeliveryMethod::Transcode => PlayMethod::Transcode,
    }
}

/// `MediaSegments/{id}` -> skip sections (empty on any failure, like the Swift app).
async fn sections(client: &Client, id: &str) -> Vec<Segment> {
    #[derive(serde::Deserialize)]
    struct Row {
        #[serde(rename = "Type")]
        kind: Option<String>,
        #[serde(rename = "StartTicks")]
        start: Option<i64>,
        #[serde(rename = "EndTicks")]
        end: Option<i64>,
    }
    #[derive(serde::Deserialize)]
    struct Rows {
        #[serde(rename = "Items", default)]
        items: Vec<Row>,
    }
    let Ok(rows) = client
        .get_json::<Rows>(&format!("MediaSegments/{id}"), &[])
        .await
    else {
        return Vec::new();
    };
    rows.items
        .into_iter()
        .filter_map(|r| {
            let art = Art::from_raw(r.kind.as_deref()?)?;
            Some(Segment::new(
                art,
                r.start? as f64 / 1e7,
                r.end? as f64 / 1e7,
            ))
        })
        .collect()
}

/// The episode after this one: the next in its season, else the first of the next season (specials, season 0, are
/// skipped unless the title itself is one). `None` for a film or the last episode of the series.
async fn next_episode(client: &Client, item: &swiftly_model::Item) -> Option<NextEpisode> {
    let series = item.series_id.as_deref()?;
    let here = (item.parent_index_number?, item.index_number?);
    let all = client.episodes(series, None).await.ok()?;
    next_after(&all, here).map(|e| NextEpisode {
        id: e.id.clone(),
        title: e.name.clone(),
    })
}

/// The smallest (season, number) after `here`; season 0 only when `here` is in it.
fn next_after(all: &[swiftly_model::Item], here: (i64, i64)) -> Option<&swiftly_model::Item> {
    all.iter()
        .filter_map(|e| Some(((e.parent_index_number?, e.index_number?), e)))
        .filter(|(k, _)| *k > here && (k.0 > 0 || here.0 == 0))
        .min_by_key(|(k, _)| *k)
        .map(|(_, e)| e)
}

/// Fetches the plan and the extras and builds the spec. Runs on the network runtime.
async fn prepare(
    client: Arc<Client>,
    account: String,
    req: PlayRequest,
    store: Arc<swiftly_settings::JsonFileStore>,
    extras: Extras,
) -> Result<Prepared, String> {
    let profile = DeviceProfile::for_flavour(flavour(), extras.max_bitrate);
    // AV1 Dolby Vision 10.0 does not render right through mpv: the server transcodes it (shared rule).
    let plan = swiftly_vm::fetch_plan_for(
        &*client,
        &req.item_id,
        profile,
        req.source_id.as_deref(),
        Some((
            flavour(),
            swiftly_playback::dolby_vision::HostDecoders::default(),
        )),
    )
    .await
    .map_err(|e| format!("{e:?}"))?
    .ok_or("Der Server nennt keine Datei zu diesem Titel.")?;
    let item = client
        .item(&req.item_id)
        .await
        .map_err(|e| format!("{e:?}"))?;
    let sections = sections(&client, &req.item_id).await;
    let streams = plan
        .source
        .as_ref()
        .and_then(|s| s.media_streams.clone())
        .unwrap_or_default();
    // The Swift track rules: remembered choice of this series/film, then the language wishes, then the server default.
    let memory = Arc::new(SettingsMemory(Arc::clone(&store)));
    let track_title =
        track_rule::title_key(item.series_id.as_deref(), &req.item_id, Some(&account));
    let source = plan.source.as_ref();
    let subs = memory.load(track_rule::SUBTITLE_KEY);
    let auds = memory.load(track_rule::AUDIO_KEY);
    let truthy = |k: &str| matches!(store.get(k), Some(Value::Bool(true)));
    let picked = track_rule::start_indices(
        &streams,
        &track_rule::StartInput {
            remembered_audio: track_rule::read_audio(&auds, &track_title),
            remembered_subtitle: track_rule::read_choice(&subs, &track_title),
            server_audio: source.and_then(|s| s.default_audio_stream_index),
            server_subtitle: source.and_then(|s| s.default_subtitle_stream_index),
            automatic: truthy("utAuto"),
            audio_language: &text(&store, "tonSprache"),
            subtitle_language: &text(&store, "utSprache"),
        },
    );
    let audio = picked
        .audio
        .or_else(|| source.and_then(|s| s.default_audio_stream_index))
        .or_else(|| {
            streams
                .iter()
                .find(|m| m.type_.as_deref() == Some("Audio"))
                .and_then(|m| m.index)
        });
    // A transcode carries no bitmap subtitle unless the request names it: ask again with the chosen track (shared rule).
    let plan = match swiftly_vm::replan_for_subtitle(
        &*client,
        &req.item_id,
        &DeviceProfile::for_flavour(flavour(), extras.max_bitrate),
        &plan,
        &streams,
        extras.subtitle.or(picked.subtitle).unwrap_or(-1),
    )
    .await
    {
        Some(again) => again,
        None => plan,
    };
    // A transcode (HLS) carries no text track: the server delivers it as a file, which the player loads as one.
    let mut streams = streams;
    if plan.method == DeliveryMethod::Transcode {
        swiftly_playback::track_mapping::mark_delivered_files(&mut streams);
    }
    let source_id = plan.media_source_id.clone();
    let chapters = client.chapters(&req.item_id, source_id.as_deref()).await;
    let trickplay = client
        .trickplay(
            &req.item_id,
            source_id.as_deref(),
            swiftly_playback::trickplay::DEFAULT_TARGET,
        )
        .await;
    let next = next_episode(&client, &item).await;
    let runtime = plan
        .source
        .as_ref()
        .and_then(|s| s.run_time_ticks)
        .or(item.run_time_ticks)
        .map_or(0.0, |t| t as f64 / 1e7);
    let second = match (item.parent_index_number, item.index_number) {
        (Some(s), Some(e)) => format!("S{s} · F{e}"),
        _ => String::new(),
    };
    let spec = PlayerSpec {
        item_id: req.item_id.clone(),
        title: item.name.clone(),
        plan: ReportPlan {
            play_session_id: plan.play_session_id.clone(),
            media_source_id: plan.media_source_id.clone(),
            method: method(plan.method),
        },
        request: EngineRequest {
            item_id: req.item_id.clone(),
            streams: streams.clone(),
            runtime,
            subtitle_files: swiftly_playback::track_mapping::SubtitleFile::from_streams(
                &streams,
                client.base_url().as_str(),
                client.current_session().map(|s| s.access_token).as_deref(),
                "api_key",
                &|_| None,
            ),
            url: plan.url.clone(),
            headers: Vec::new(),
            software_decode: plan.software_decoder(),
            buffer_level: BufferLevel::Normal,
            frame_rate_match: false,
            external_track_id_base: 1000,
        },
        // A negative second asks for the server's own resume position (the Continue rail plays without a detail page).
        start_at: if req.since < 0.0 {
            item.user_data
                .as_ref()
                .and_then(|u| u.playback_position_ticks)
                .map_or(0.0, |t| t as f64 / 1e7)
        } else {
            req.since
        },
        audio_index: audio,
        subtitle_index: extras.subtitle.or(picked.subtitle).unwrap_or(-1),
        next,
        series_id: item.series_id.clone(),
        track_title: Some(track_title),
        downloaded: false,
    };
    Ok(Prepared::Ready(Box::new(Ready {
        spec,
        head: (item.name, second),
        sections,
        chapters,
        trickplay,
        request: req,
        server: Server::Jellyfin(client),
        duration_ms: None,
        account,
        memory,
    })))
}

/// The Plex start: the core's `play_start` (plan, tracks, sections, chapters, next episode) over the Plex client, turned
/// into the player spec. Runs on the network runtime.
async fn prepare_plex(
    net: Arc<crate::net::AppTransport>,
    host: swiftly_vm::Host,
    account: swiftly_vm::AccountRef,
    req: PlayRequest,
    store: Arc<swiftly_settings::JsonFileStore>,
    extras: Extras,
) -> Result<Prepared, String> {
    use swiftly_vm::{NextSource, StartAnswer, StartRequest, StartSettings};
    let memory = Arc::new(SettingsMemory(Arc::clone(&store)));
    let truthy = |k: &str| matches!(store.get(k), Some(Value::Bool(true)));
    let key = account.key();
    let request = StartRequest {
        item_id: req.item_id.clone(),
        source_id: req.source_id.clone(),
        since: (req.since >= 0.0).then_some(req.since),
        flavour: flavour(),
        hardware_av1: false,
        no_dolby_vision_decoder: false,
        // No pick yet: a title with several versions comes back as `Choose` (the detail page asks before it gets here).
        ask_versions: req.source_id.is_none(),
        downloaded: None,
        ordered: None,
        account_key: Some(key.clone()),
        settings: StartSettings {
            audio_language: text(&store, "tonSprache"),
            subtitle_language: text(&store, "utSprache"),
            automatic_subtitles: truthy("utAuto"),
            max_bitrate: extras.max_bitrate,
            buffer_level: BufferLevel::Normal,
            frame_rate_match: false,
            server_extracts_text: false,
        },
        next: NextSource::Rule {
            downloads: Vec::new(),
            without_network: false,
        },
    };
    let answer =
        swiftly_vm::play_start(Arc::clone(&net), &host, &account, &request, Some(&*memory))
            .await
            .map_err(|e| format!("{e:?}"))?;
    let ready = match answer {
        StartAnswer::Ready(r) => r,
        StartAnswer::NoSource => return Err("Der Server nennt keine Datei zu diesem Titel.".into()),
        StartAnswer::Choose {
            item,
            versions,
            since,
        } => {
            return Ok(Prepared::Choose(VersionAsk {
                item_id: item.id,
                since,
                versions,
            }));
        }
        StartAnswer::VersionsFailed => {
            return Err("Die Fassungen des Titels lassen sich nicht laden.".into());
        }
        StartAnswer::Failed(e) => return Err(format!("{e:?}")),
    };
    let mut r = *ready;
    // A subtitle picked while a transcode runs: the same plan again, asking for the track (Plex burns it in).
    if let Some(subtitle) = extras.subtitle
        && let Ok(Some(again)) = swiftly_vm::play_plan_only(
            Arc::clone(&net),
            &host,
            &account,
            &req.item_id,
            flavour(),
            false,
            extras.max_bitrate,
            req.source_id
                .as_deref()
                .or(r.plan.media_source_id.as_deref()),
            Some(subtitle),
        )
        .await
    {
        r.plan = again;
        r.subtitle = subtitle;
    }
    let runtime = r
        .plan
        .source
        .as_ref()
        .and_then(|s| s.run_time_ticks)
        .or(r.item.run_time_ticks)
        .map_or(0.0, |t| t as f64 / 1e7);
    let second = match (r.item.parent_index_number, r.item.index_number) {
        (Some(s), Some(e)) => format!("S{s} · F{e}"),
        _ => String::new(),
    };
    let spec = PlayerSpec {
        item_id: req.item_id.clone(),
        title: r.item.name.clone(),
        plan: ReportPlan {
            play_session_id: r.plan.play_session_id.clone(),
            media_source_id: r.plan.media_source_id.clone(),
            method: method(r.plan.method),
        },
        request: EngineRequest {
            item_id: req.item_id.clone(),
            streams: r.streams.clone(),
            runtime,
            subtitle_files: r.subtitle_files.clone(),
            url: r.plan.url.clone(),
            headers: Vec::new(),
            software_decode: r.plan.software_decoder(),
            buffer_level: BufferLevel::Normal,
            frame_rate_match: false,
            external_track_id_base: 1000,
        },
        start_at: r.start_at,
        audio_index: r.audio,
        subtitle_index: r.subtitle,
        next: r.next.as_ref().map(|n| NextEpisode {
            id: n.id.clone(),
            title: n.name.clone(),
        }),
        series_id: r.item.series_id.clone(),
        track_title: Some(r.track_title.clone()),
        downloaded: false,
    };
    let server =
        match swiftly_vm::make_client(&net, &host, &account).map_err(|e| format!("{e:?}"))? {
            s @ Server::Plex(_) => s,
            Server::Jellyfin(_) => return Err("Kein Plex-Konto.".into()),
        };
    // The preview pictures (BIF of the part): `None` when the server made none; the sheets are fetched while scrubbing.
    let trickplay = match &server {
        Server::Plex(c) => {
            MediaServer::trickplay(
                &**c,
                &req.item_id,
                spec.plan.media_source_id.as_deref(),
                swiftly_playback::trickplay::DEFAULT_TARGET,
            )
            .await
        }
        Server::Jellyfin(_) => None,
    };
    Ok(Prepared::Ready(Box::new(Ready {
        spec,
        head: (r.item.name.clone(), second),
        sections: r.sections,
        chapters: r.chapters,
        trickplay,
        request: req,
        server,
        duration_ms: (runtime > 0.0).then_some((runtime * 1000.0) as i64),
        account: key,
        memory,
    })))
}

impl Core {
    /// Starts fetching what a title needs to play.
    pub fn prepare_play(
        &self,
        account: &swiftly_vm::AccountRef,
        req: PlayRequest,
    ) -> Pending<Result<Prepared, String>> {
        let (tx, rx) = Pending::channel();
        match self.server_for(account) {
            Ok(Server::Jellyfin(client)) => {
                let key = account.key();
                let store = Arc::clone(&self.settings);
                self.spawn(async move {
                    let _ = tx.send(prepare(client, key, req, store, Extras::default()).await);
                });
            }
            Ok(Server::Plex(_)) => {
                let (net, host, account, store) = (
                    Arc::clone(&self.net),
                    self.host(),
                    account.clone(),
                    Arc::clone(&self.settings),
                );
                self.spawn(async move {
                    let _ = tx.send(
                        prepare_plex(net, host, account, req, store, Extras::default()).await,
                    );
                });
            }
            Err(e) => {
                let _ = tx.send(Err(format!("{e:?}")));
            }
        }
        rx
    }

    /// The preview offer of a ready title and how to fetch one sheet (blocks; for a worker thread). Jellyfin: the tile
    /// sheets of the trickplay; Plex: one picture of the BIF per "sheet".
    pub fn preview_source(
        &self,
        p: &Ready,
    ) -> Option<(Trickplay, crate::trick_preview::SheetSource)> {
        preview_with(self.runtime_handle(), p)
    }

    /// The picture of the next episode `next_id` for the card (see [`card_still_with`]).
    pub fn card_still_source(
        &self,
        server: &Server,
        next_id: &str,
    ) -> crate::player_card::StillSource {
        card_still_with(
            self.runtime_handle(),
            Arc::clone(&self.net),
            server,
            next_id,
        )
    }
}

/// The preview offer of a ready title and how to fetch one sheet.
fn preview_with(
    handle: tokio::runtime::Handle,
    p: &Ready,
) -> Option<(Trickplay, crate::trick_preview::SheetSource)> {
    {
        let tp = p.trickplay?;
        let (item, source) = (
            p.request.item_id.clone(),
            p.spec.plan.media_source_id.clone(),
        );
        let fetch: crate::trick_preview::SheetSource = match &p.server {
            Server::Jellyfin(client) => {
                let client = Arc::clone(client);
                Arc::new(move |sheet| {
                    let (c, i, s) = (Arc::clone(&client), item.clone(), source.clone());
                    handle.block_on(async move {
                        c.trickplay_sheet(&i, s.as_deref(), tp.width, sheet).await
                    })
                })
            }
            Server::Plex(client) => {
                let client = Arc::clone(client);
                Arc::new(move |sheet| {
                    let (c, i, s) = (Arc::clone(&client), item.clone(), source.clone());
                    handle.block_on(async move {
                        MediaServer::trickplay_sheet(&*c, &i, s.as_deref(), tp.width, sheet).await
                    })
                })
            }
        };
        Some((tp, fetch))
    }
}

/// The picture of the next episode `next_id` for the card. The closure blocks on a worker thread
/// (the screen polls it only while the card is up). Jellyfin builds the address from the id; Plex reads the episode
/// first (the picture path is in the entry; the address carries the token), like the Mac's `imageURL(for:)`.
pub fn card_still_with(
    handle: tokio::runtime::Handle,
    net: Arc<crate::net::AppTransport>,
    server: &Server,
    next_id: &str,
) -> crate::player_card::StillSource {
    let id = next_id.to_owned();
    {
        match server {
            Server::Jellyfin(client) => {
                let client = Arc::clone(client);
                Arc::new(move || {
                    let url = client.image_url_by_id(&id, 360)?;
                    handle.block_on(client.get_bytes(url))
                })
            }
            Server::Plex(client) => {
                let (client, net) = (Arc::clone(client), net);
                Arc::new(move || {
                    handle.block_on(async {
                        let item = MediaServer::item(&*client, &id).await.ok()?;
                        let url = match MediaServer::image_url(&*client, &item, 360).await {
                            Some(u) => u,
                            None => client
                                .image_url_for(
                                    &item,
                                    swiftly_plex::ImageKind::Preview,
                                    Some(360),
                                    None,
                                )?
                                .to_string(),
                        };
                        let request = swiftly_net::HttpRequest::new(
                            swiftly_net::Method::Get,
                            url.parse().ok()?,
                        );
                        let response = swiftly_net::HttpTransport::send(&*net, request)
                            .await
                            .ok()?;
                        (response.status == 200 && !response.body.is_empty())
                            .then_some(response.body)
                    })
                })
            }
        }
    }
}

impl Core {
    /// The player screen for a prepared title, over libmpv. `Err` names why the engine could not start.
    pub fn open_player(
        &self,
        env: Env,
        cx: Cx,
        now: f64,
        p: Prepared,
    ) -> Result<PlayerScreen, String> {
        let Prepared::Ready(p) = p else {
            return Err("Die Fassung muss erst gewählt werden.".into());
        };
        let p = *p;
        let (engine, feed) = match FACTORY.get() {
            Some(f) => f()?,
            None => {
                let (engine, feed) = engine()?;
                ContainerIds::wrap(engine, feed, &p.spec.request.streams, &p.spec.request.url)
            }
        };
        let pending = Arc::new(SettingsPending(Arc::clone(&self.settings), Mutex::new(())));
        let (spawner, clock) = (self.host().spawner, self.host().clock);
        let reporter: Arc<dyn swiftly_vm::Reporter> = match &p.server {
            Server::Jellyfin(c) => Arc::new(ClientReporter::new(
                Arc::clone(c),
                &p.account,
                spawner,
                clock,
                pending,
            )),
            Server::Plex(c) => Arc::new(PlexReporter::new(
                Arc::clone(c),
                &p.account,
                p.duration_ms,
                spawner,
                clock,
                pending,
            )),
        };
        let preview = self.preview_source(&p);
        let spec_item_id_value = p.spec.item_id.clone();
        let still = p
            .spec
            .next
            .as_ref()
            .map(|n| self.card_still_source(&p.server, &n.id));
        let mut screen =
            PlayerScreen::live(env, cx, now, p.spec, p.head, engine, feed, reporter, |_| {});
        screen.set_marks(p.chapters, p.sections);
        screen.set_store(Arc::clone(&self.settings), now);
        screen
            .vm()
            .set_memory(Some(p.memory as Arc<dyn TrackMemoryStore>));
        if let Some((tp, fetch)) = preview {
            screen.set_trickplay(Some(tp), fetch);
        }
        if let Some(still) = still {
            screen.set_card_still(still);
        }
        // The title's own picture for the system's media widgets (volume flyout, lock screen, MPRIS).
        let id = spec_item_id_value;
        screen.set_poster(
            self.card_still_source(&p.server, &id),
            crate::store::cache_dir().join("nowplaying"),
            &format!(
                "nowplaying-{}.img",
                id.replace(|c: char| !c.is_ascii_alphanumeric(), "_")
            ),
        );
        Ok(screen)
    }
}

// ---- the host of the player's switches (next episode, quality, subtitle on a transcode) -----------------------------

impl Ready {
    /// The title with everything around it, for [`PlayerScreen::set_planner`]'s switch.
    fn into_switched(
        self,
        handle: &tokio::runtime::Handle,
        net: &Arc<crate::net::AppTransport>,
    ) -> Switched {
        let preview = preview_with(handle.clone(), &self);
        let still = self
            .spec
            .next
            .as_ref()
            .map(|n| card_still_with(handle.clone(), Arc::clone(net), &self.server, &n.id));
        let id = self.spec.item_id.clone();
        let poster = (
            card_still_with(handle.clone(), Arc::clone(net), &self.server, &id),
            crate::store::cache_dir().join("nowplaying"),
            format!(
                "nowplaying-{}.img",
                id.replace(|c: char| !c.is_ascii_alphanumeric(), "_")
            ),
        );
        remember_streams(&self.spec.request.url, &self.spec.request.streams);
        Switched {
            spec: self.spec,
            head: self.head,
            sections: self.sections,
            chapters: self.chapters,
            trickplay: preview,
            still,
            poster: Some(poster),
        }
    }
}

/// A plan asked ahead: the request and its answer on the way.
type Warm = (PlanAsk, Pending<Result<Switched, String>>);

/// Plans titles for a running player: the network plan (or the file of a download), the settings' quality, and one warm
/// plan of the next episode.
pub struct CorePlanner {
    handle: tokio::runtime::Handle,
    net: Arc<crate::net::AppTransport>,
    host: swiftly_vm::Host,
    settings: Arc<swiftly_settings::JsonFileStore>,
    account: swiftly_vm::AccountRef,
    warm: Mutex<Option<Warm>>,
}

impl CorePlanner {
    fn server_key(&self) -> String {
        match (&self.account.plex_machine_id, self.account.server_kind) {
            (Some(machine), swiftly_jellyfin::ServerKind::Plex) => {
                swiftly_settings::plex_server(machine)
            }
            _ => swiftly_settings::jellyfin_server(&self.account.base_url),
        }
    }

    fn start(&self, ask: &PlanAsk) -> Pending<Result<Switched, String>> {
        let (tx, rx) = Pending::channel();
        let key = self.account.key();
        // A copy on the device wins: no server needed.
        if let Some((item, file)) =
            crate::live_downloads::finished(&crate::live_downloads::downloads_dir(), &key, &ask.id)
        {
            let second = match (item.season, item.episode) {
                (Some(s), Some(e)) => format!("S{s} · F{e}"),
                _ => String::new(),
            };
            let _ = tx.send(
                crate::live_offline::offline_spec(&item, &file, ask.since)
                    .map(|spec| Switched::bare(spec, (item.title.clone(), second))),
            );
            return rx;
        }
        let (handle, net, host, settings, account, ask) = (
            self.handle.clone(),
            Arc::clone(&self.net),
            self.host.clone(),
            Arc::clone(&self.settings),
            self.account.clone(),
            ask.clone(),
        );
        self.handle.spawn(async move {
            let extras = Extras {
                max_bitrate: swiftly_rules::playback_levels::bitrate_limit_of(
                    ask.quality.direct_play,
                    ask.quality.limit,
                ),
                subtitle: ask.subtitle,
            };
            let mut req = PlayRequest {
                item_id: ask.id.clone(),
                since: ask.since,
                source_id: ask.source_id.clone(),
            };
            let answer = async {
                let server =
                    swiftly_vm::make_client(&net, &host, &account).map_err(|e| format!("{e:?}"))?;
                let mut prepared = match &server {
                    Server::Jellyfin(c) => {
                        prepare(
                            Arc::clone(c),
                            account.key(),
                            req.clone(),
                            Arc::clone(&settings),
                            extras,
                        )
                        .await?
                    }
                    Server::Plex(_) => {
                        prepare_plex(
                            Arc::clone(&net),
                            host.clone(),
                            account.clone(),
                            req.clone(),
                            Arc::clone(&settings),
                            extras,
                        )
                        .await?
                    }
                };
                // Several versions and none kept (a next episode): the first one plays, like the title page's fallback.
                if let Some(first) = prepared.ask().and_then(|a| a.versions.first()) {
                    req.source_id = Some(first.id.clone());
                    prepared = prepare_plex(
                        Arc::clone(&net),
                        host.clone(),
                        account.clone(),
                        req,
                        Arc::clone(&settings),
                        extras,
                    )
                    .await?;
                }
                match prepared {
                    Prepared::Ready(r) => Ok(r.into_switched(&handle, &net)),
                    Prepared::Choose(_) => Err("Die Fassung muss erst gewählt werden.".to_owned()),
                }
            }
            .await;
            let _ = tx.send(answer);
        });
        rx
    }
}

impl Planner for CorePlanner {
    fn plan(&self, ask: PlanAsk) -> Pending<Result<Switched, String>> {
        let warm = self
            .warm
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        match warm {
            Some((w, pending))
                if w.id == ask.id
                    && w.quality == ask.quality
                    && !ask.reload
                    && ask.subtitle.is_none() =>
            {
                pending
            }
            _ => self.start(&ask),
        }
    }

    fn quality(&self) -> Quality {
        let key = self.server_key();
        let read = |name: &str| {
            self.settings
                .get(&swiftly_settings::server_key(name, &key))
                .or_else(|| self.settings.get(name))
        };
        Quality {
            direct_play: !matches!(read("immerDirectPlay"), Some(Value::Bool(false))),
            limit: if let Some(Value::Int(n)) = read("bitratenGrenze") {
                n
            } else {
                0
            },
        }
    }

    fn save_quality(&self, quality: Quality) {
        let key = self.server_key();
        let _ = self.settings.set(
            &swiftly_settings::server_key("immerDirectPlay", &key),
            Value::Bool(quality.direct_play),
        );
        let _ = self.settings.set(
            &swiftly_settings::server_key("bitratenGrenze", &key),
            Value::Int(quality.limit),
        );
    }

    fn prepare_next(&self, ask: PlanAsk) {
        let pending = self.start(&ask);
        *self.warm.lock().unwrap_or_else(PoisonError::into_inner) = Some((ask, pending));
    }

    fn forget_prepared(&self) {
        *self.warm.lock().unwrap_or_else(PoisonError::into_inner) = None;
    }
}

/// The rows of the core's `download_subtitle_files` as (index, address, extension).
fn parse_subtitle_rows(
    json: &str,
) -> Vec<(
    i64,
    String,
    String,
    swiftly_vm::subtitle_sidecar::SubtitleMeta,
)> {
    swiftly_vm::subtitle_sidecar::parse_rows(json)
        .into_iter()
        .map(|r| (r.index, r.address, r.ending, r.meta))
        .collect()
}

impl Core {
    /// What a finished download asks the server to take along: the external subtitle files of its title (Jellyfin/Emby:
    /// the playback info's files, for a server-built copy also the embedded text tracks as extracted files; Plex: the
    /// start answer's files). `None` when the account has no client.
    pub fn subtitle_lister(
        &self,
        account: &swiftly_vm::AccountRef,
    ) -> Option<crate::live_downloads::SubtitleLister> {
        let (net, host, account) = (Arc::clone(&self.net), self.host(), account.clone());
        let jellyfin = matches!(self.server_for(&account).ok()?, Server::Jellyfin(_));
        Some(Arc::new(
            move |id: String, source: Option<String>, converted: bool| {
                let (net, host, account) = (Arc::clone(&net), host.clone(), account.clone());
                Box::pin(async move {
                    // One implementation for every platform: the core's `download_subtitle_files`.
                    let rows = if jellyfin {
                        match swiftly_vm::LegacyDetail::new(&net, &host, &account) {
                            Ok(d) => {
                                d.download_subtitle_files(&id, source.as_deref(), converted)
                                    .await
                            }
                            Err(_) => return Vec::new(),
                        }
                    } else {
                        match swiftly_vm::LegacyPlexDetail::new(&net, &host, &account) {
                            Ok(d) => {
                                d.download_subtitle_files(&id, source.as_deref(), converted)
                                    .await
                            }
                            Err(_) => return Vec::new(),
                        }
                    };
                    parse_subtitle_rows(&rows)
                })
                    as std::pin::Pin<
                        Box<
                            dyn std::future::Future<
                                    Output = Vec<(
                                        i64,
                                        String,
                                        String,
                                        swiftly_vm::subtitle_sidecar::SubtitleMeta,
                                    )>,
                                > + Send,
                        >,
                    >
            },
        ))
    }

    /// The host the player screen asks for its switches.
    pub fn planner(&self, account: &swiftly_vm::AccountRef) -> Arc<dyn Planner> {
        Arc::new(CorePlanner {
            handle: self.runtime_handle(),
            net: Arc::clone(&self.net),
            host: self.host(),
            settings: Arc::clone(&self.settings),
            account: account.clone(),
            warm: Mutex::new(None),
        })
    }
}

/// The engine for commands and the same engine as event and frame source.
pub type Engines = (Arc<dyn PlaybackEngine>, Arc<dyn LiveEngine>);

/// Makes the engine of a platform that brings its own (Android: Media3 over JNI).
pub type EngineFactory = Box<dyn Fn() -> Result<Engines, String> + Send + Sync>;

static FACTORY: std::sync::OnceLock<EngineFactory> = std::sync::OnceLock::new();

static FLAVOUR: std::sync::OnceLock<swiftly_playback::device_profile::Flavour> =
    std::sync::OnceLock::new();

/// Sets which device profile the plan asks for (the engine decides what it can play: AVPlayer on Apple needs the narrow
/// `AirPlay` profile, libmpv and Media3 the wide one). Default `Mpv`, the wide profile. Called once by a platform shell.
pub fn set_flavour(f: swiftly_playback::device_profile::Flavour) {
    let _ = FLAVOUR.set(f);
}

fn flavour() -> swiftly_playback::device_profile::Flavour {
    FLAVOUR
        .get()
        .copied()
        .unwrap_or(swiftly_playback::device_profile::Flavour::Mpv)
}

/// Registers the platform engine; `open_player` prefers it over libmpv.
pub fn set_engine_factory(f: EngineFactory) {
    let _ = FACTORY.set(f);
}

/// libmpv as the screen's event and frame source (what `engine()` hands to the player screen).
#[cfg(feature = "mpv")]
pub struct MpvFeed(
    Arc<swiftly_player_surface::mpv::MpvEngine>,
    Mutex<swiftly_player_surface::FrameBuffer>,
);

#[cfg(feature = "mpv")]
impl MpvFeed {
    /// A feed over `engine`.
    pub fn new(engine: Arc<swiftly_player_surface::mpv::MpvEngine>) -> MpvFeed {
        MpvFeed(
            engine,
            Mutex::new(swiftly_player_surface::FrameBuffer::default()),
        )
    }
}

/// The subtitle probe of `--smoke-play`: while on, every frame the engine hands over is measured (share of near-white
/// pixels in the bottom band, where libass and the PGS renderer put the cues) and the newest value waits here.
static PROBE_ON: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// (white share, ink share) of the last frame.
static PROBE_LAST: Mutex<Option<(f32, f32)>> = Mutex::new(None);

/// Switches the subtitle probe on or off (tests that measure a cue on the live player's frames).
#[doc(hidden)]
pub fn probe_arm(on: bool) {
    PROBE_ON.store(on, std::sync::atomic::Ordering::Relaxed);
}

/// (white share, ink share) of the newest probed frame, once.
#[doc(hidden)]
pub fn probe_take() -> Option<(f32, f32)> {
    PROBE_LAST
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .take()
}

/// Share of near-white pixels (all channels at least 235) in the bottom 40 % of an RGBA frame.
#[cfg_attr(not(feature = "mpv"), allow(dead_code))]
fn white_band_share(rgba: &[u8], w: u32, h: u32) -> f32 {
    let (w, h) = (w as usize, h as usize);
    let from = h - h * 2 / 5;
    let band = rgba.get(from * w * 4..h * w * 4).unwrap_or_default();
    let white = band
        .as_chunks::<4>()
        .0
        .iter()
        .filter(|p| p[0] >= 235 && p[1] >= 235 && p[2] >= 235)
        .count();
    if band.is_empty() {
        0.0
    } else {
        white as f32 / (band.len() / 4) as f32
    }
}

/// Share of "ink" pixels in the bottom 40 %: near-white or strongly coloured (spread of at least 110 between the channels).
/// A styled ASS cue (yellow fill, red outline) has no white in it, so the judge counts this and compares it with the
/// subtitle-off pass, where whatever the picture holds of its own cancels out.
#[cfg_attr(not(feature = "mpv"), allow(dead_code))]
fn ink_band_share(rgba: &[u8], w: u32, h: u32) -> f32 {
    let (w, h) = (w as usize, h as usize);
    let from = h - h * 2 / 5;
    let band = rgba.get(from * w * 4..h * w * 4).unwrap_or_default();
    let ink = band
        .as_chunks::<4>()
        .0
        .iter()
        .filter(|p| {
            let (hi, lo) = (p[0].max(p[1]).max(p[2]), p[0].min(p[1]).min(p[2]));
            lo >= 235 || hi - lo >= 110
        })
        .count();
    if band.is_empty() {
        0.0
    } else {
        ink as f32 / (band.len() / 4) as f32
    }
}

#[cfg_attr(not(feature = "mpv"), allow(dead_code))]
fn probe(w: u32, h: u32, rgba: &[u8]) {
    if PROBE_ON.load(std::sync::atomic::Ordering::Relaxed) {
        *PROBE_LAST.lock().unwrap_or_else(PoisonError::into_inner) =
            Some((white_band_share(rgba, w, h), ink_band_share(rgba, w, h)));
    }
}

#[cfg(feature = "mpv")]
impl LiveEngine for MpvFeed {
    fn events(&self) -> Vec<swiftly_playback::engine::EngineEvent> {
        use swiftly_player_surface::SurfaceEngine;
        self.0.poll_events()
    }
    fn frame(&self, max_w: u32, max_h: u32, sink: &mut dyn FnMut(u32, u32, &[u8])) {
        use swiftly_player_surface::{FrameStatus, VideoSurface};
        let mut buf = self.1.lock().unwrap_or_else(PoisonError::into_inner);
        self.0.set_skip_alpha(false);
        if self.0.acquire_frame(max_w, max_h, &mut buf) == FrameStatus::New {
            probe(buf.width, buf.height, &buf.rgba);
            sink(buf.width, buf.height, &buf.rgba);
        }
    }
    fn source_size(&self) -> Option<(u32, u32)> {
        use swiftly_player_surface::VideoSurface;
        self.0.display_hints().size
    }
    fn frame_swap(&self, max_w: u32, max_h: u32, out: &mut swiftly_ui::VideoFrame) -> bool {
        use swiftly_player_surface::{FrameStatus, VideoSurface};
        let mut buf = self.1.lock().unwrap_or_else(PoisonError::into_inner);
        // The host's shader ignores alpha, so libmpv's fourth byte is left alone (saves a pass over the whole frame).
        self.0.set_skip_alpha(true);
        if self.0.acquire_frame(max_w, max_h, &mut buf) != FrameStatus::New {
            return false;
        }
        probe(buf.width, buf.height, &buf.rgba);
        // The finished frame moves to the host without a copy; the host's old buffer becomes the next target.
        (out.w, out.h) = (buf.width, buf.height);
        std::mem::swap(&mut out.rgba, &mut buf.rgba);
        true
    }
}

#[cfg(feature = "mpv")]
fn engine() -> Result<Engines, String> {
    use swiftly_player_surface::mpv::MpvEngine;
    let mpv = Arc::new(MpvEngine::new()?);
    Ok((
        Arc::clone(&mpv) as Arc<dyn PlaybackEngine>,
        Arc::new(MpvFeed::new(mpv)),
    ))
}

#[cfg(not(feature = "mpv"))]
fn engine() -> Result<Engines, String> {
    Err("Dieser Bau hat keine Video-Engine (Feature mpv).".into())
}

/// Plex numbers a stream by its stream id (`MediaStream::index`) and the place in the file is `container_index`, while
/// libmpv numbers the file's own tracks by that place. The core talks in server indexes, so this sits between the core and
/// libmpv: commands go in as the file's number, the track lists and the active track come back as the server's index.
/// Streams without a `container_index` (Jellyfin, Emby, files next to the film) pass through unchanged.
///
/// The table belongs to the title that is loaded: every `load` swaps it for the table of that address (a next episode
/// has other stream ids), see [`remember_streams`].
struct ContainerIds {
    /// `(server index, place in the file)` of the streams where the two differ.
    pairs: std::sync::RwLock<Vec<(i64, i64)>>,
}

type IdPairs = Vec<(i64, i64)>;

fn pairs_of(streams: &[swiftly_model::MediaStream]) -> IdPairs {
    streams
        .iter()
        .filter_map(|s| Some((s.index?, s.container_index?)))
        .filter(|(a, b)| a != b)
        .collect()
}

/// The id tables of the titles planned lately, by the address the engine will open.
static STREAMS_BY_URL: Mutex<Vec<(String, IdPairs)>> = Mutex::new(Vec::new());

/// Notes the stream ids of a planned title under its address, for the load that follows.
fn remember_streams(url: &str, streams: &[swiftly_model::MediaStream]) {
    let mut all = STREAMS_BY_URL
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    all.retain(|(u, _)| u != url);
    all.push((url.to_owned(), pairs_of(streams)));
    if all.len() > 8 {
        all.remove(0);
    }
}

impl ContainerIds {
    fn of(streams: &[swiftly_model::MediaStream]) -> ContainerIds {
        ContainerIds {
            pairs: std::sync::RwLock::new(pairs_of(streams)),
        }
    }

    fn to_file(&self, server: i64) -> i64 {
        self.pairs
            .read()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .find(|(s, _)| *s == server)
            .map_or(server, |(_, f)| *f)
    }

    fn to_server(&self, file: i64) -> i64 {
        self.pairs
            .read()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .find(|(_, f)| *f == file)
            .map_or(file, |(s, _)| *s)
    }

    /// A load of `url`: the table of that title replaces the old one (no note: no pairs, ids pass through).
    fn switch_to(&self, url: &str) {
        let found = STREAMS_BY_URL
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .find(|(u, _)| u == url)
            .map(|(_, p)| p.clone());
        *self.pairs.write().unwrap_or_else(PoisonError::into_inner) = found.unwrap_or_default();
    }

    /// The engine pair translating by the table of the loaded title.
    fn wrap(
        engine: Arc<dyn PlaybackEngine>,
        feed: Arc<dyn LiveEngine>,
        streams: &[swiftly_model::MediaStream],
        url: &str,
    ) -> Engines {
        remember_streams(url, streams);
        let ids = Arc::new(ContainerIds::of(streams));
        (
            Arc::new(IdsEngine(engine, Arc::clone(&ids))),
            Arc::new(IdsFeed(feed, ids)),
        )
    }

    fn event(
        &self,
        e: swiftly_playback::engine::EngineEvent,
    ) -> swiftly_playback::engine::EngineEvent {
        use swiftly_playback::engine::EngineEvent;
        let EngineEvent::Tracks {
            mut audio,
            mut subtitles,
            active_audio,
            active_subtitle,
        } = e
        else {
            return e;
        };
        for t in audio.iter_mut().chain(subtitles.iter_mut()) {
            t.id = self.to_server(t.id);
        }
        EngineEvent::Tracks {
            audio,
            subtitles,
            active_audio: active_audio.map(|i| self.to_server(i)),
            active_subtitle: active_subtitle.map(|i| self.to_server(i)),
        }
    }
}

struct IdsEngine(Arc<dyn PlaybackEngine>, Arc<ContainerIds>);

impl PlaybackEngine for IdsEngine {
    fn load(&self, mut r: swiftly_playback::engine::EngineLoad) {
        self.1.switch_to(&r.url);
        r.audio_server_index = r.audio_server_index.map(|i| self.1.to_file(i));
        r.subtitle_server_index = self.1.to_file(r.subtitle_server_index);
        self.0.load(r);
    }
    fn play(&self) {
        self.0.play();
    }
    fn pause(&self) {
        self.0.pause();
    }
    fn seek(&self, seconds: f64) {
        self.0.seek(seconds);
    }
    fn set_rate(&self, tempo: f32) {
        self.0.set_rate(tempo);
    }
    fn set_volume(&self, percent: u8) {
        self.0.set_volume(percent);
    }
    fn set_audio_delay(&self, milliseconds: i32) {
        self.0.set_audio_delay(milliseconds);
    }
    fn set_subtitle_delay(&self, milliseconds: i32) {
        self.0.set_subtitle_delay(milliseconds);
    }
    fn set_subtitle_style(&self, style: &swiftly_playback::engine::SubtitleTextStyle) {
        self.0.set_subtitle_style(style);
    }
    fn select_audio(&self, server_index: i32) -> bool {
        self.0.select_audio(
            i32::try_from(self.1.to_file(i64::from(server_index))).unwrap_or(server_index),
        )
    }
    fn select_subtitle(&self, server_index: i32) -> swiftly_playback::engine::SubtitleRoute {
        self.0.select_subtitle(
            i32::try_from(self.1.to_file(i64::from(server_index))).unwrap_or(server_index),
        )
    }
    fn set_fill(&self, on: bool) {
        self.0.set_fill(on);
    }
    fn place(&self, rect: swiftly_playback::engine::Rect) {
        self.0.place(rect);
    }
    fn stop(&self, reset_display: bool) {
        self.0.stop(reset_display);
    }
    fn pip(&self, command: swiftly_playback::engine::PipCmd) {
        self.0.pip(command);
    }
    fn set_audio_output(&self, mode: &swiftly_playback::decoder_choice::AudioOutputMode) {
        self.0.set_audio_output(mode);
    }
}

struct IdsFeed(Arc<dyn LiveEngine>, Arc<ContainerIds>);

impl LiveEngine for IdsFeed {
    fn events(&self) -> Vec<swiftly_playback::engine::EngineEvent> {
        self.0
            .events()
            .into_iter()
            .map(|e| self.1.event(e))
            .collect()
    }
    fn frame(&self, max_w: u32, max_h: u32, sink: &mut dyn FnMut(u32, u32, &[u8])) {
        self.0.frame(max_w, max_h, sink);
    }
    fn source_size(&self) -> Option<(u32, u32)> {
        self.0.source_size()
    }
    fn frame_swap(&self, max_w: u32, max_h: u32, out: &mut swiftly_ui::VideoFrame) -> bool {
        self.0.frame_swap(max_w, max_h, out)
    }
}

/// The request behind a play action; `None` while the action only waits or asks.
pub fn request_of(a: &swiftly_vm::PlayAction) -> Option<PlayRequest> {
    use swiftly_vm::PlayAction as A;
    match a {
        A::Start {
            item_id,
            since,
            source_id,
        } => Some(PlayRequest {
            item_id: item_id.clone(),
            since: *since,
            source_id: source_id.clone(),
        }),
        A::Resolve { item_id, since } | A::Choose { item_id, since, .. } => Some(PlayRequest {
            item_id: item_id.clone(),
            since: *since,
            source_id: None,
        }),
        A::Wait => None,
    }
}

/// Reads a path of a plain-http server (the fixture's `/fixture/reports`).
fn http_get(address: &str, path: &str) -> Option<String> {
    use std::io::{Read, Write};
    let host = address.strip_prefix("http://")?.trim_end_matches('/');
    let mut s = std::net::TcpStream::connect(host).ok()?;
    write!(
        s,
        "GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"
    )
    .ok()?;
    let mut out = String::new();
    s.read_to_string(&mut out).ok()?;
    out.split_once("\r\n\r\n").map(|(_, b)| b.to_owned())
}

/// True for the local fixture server: loopback, the Android emulator host, or the one host named in
/// `SWIFTLY_SMOKE_FIXTURE_HOST` (the VM reaches the fixture through the hypervisor bridge, e.g. `192.168.122.1`).
fn is_fixture_address(found: &str, extra_host: Option<&str>) -> bool {
    found.starts_with("http://127.0.0.1")
        || found.starts_with("http://10.0.2.2")
        || extra_host.is_some_and(|h| {
            !h.is_empty()
                && found
                    .strip_prefix("http://")
                    .is_some_and(|r| r.split(['/', ':']).next() == Some(h))
        })
}

/// The cue windows asked for with `SWIFTLY_SMOKE_CUES="1-3,4-6"` (seconds of the title's own clock).
fn parse_cues(text: &str) -> Vec<(f64, f64)> {
    text.split(',')
        .filter_map(|w| w.split_once('-'))
        .filter_map(|(a, b)| Some((a.trim().parse().ok()?, b.trim().parse().ok()?)))
        .collect()
}

/// Judges the subtitle against the same frame times with the subtitle off (`base`, a second pass): what a cue changes is the
/// difference (absolute: text over a white bar only adds its dark outline) of the white share of the band at the same position, so a bitmap burned into the picture (white in both
/// passes) is neither mistaken for a cue nor hides one. Inside a cue window (half a second in from both ends) the median
/// difference must be clearly above zero (the same frame without the subtitle is the reference); the median between the windows is only reported, because its few frames sit at the edges of the run.
fn judge_cues(
    samples: &[(f64, f32)],
    base: &[(f64, f32)],
    windows: &[(f64, f64)],
) -> Result<String, String> {
    const EDGE: f64 = 0.5;
    // The position of a frame is only known to about half a second, so a frame is compared with every baseline frame
    // within that reach and gets the closest one (a frame on a bar's edge then still finds its own partner; a cue can only
    // shrink by this, never appear).
    const NEAR: f64 = 0.75;
    let delta = |(t, w): &(f64, f32)| -> Option<f32> {
        base.iter()
            .filter(|b| (b.0 - t).abs() <= NEAR)
            .map(|b| (w - b.1).abs())
            .min_by(f32::total_cmp)
    };
    let mut inside: Vec<f32> = samples
        .iter()
        .filter(|(t, _)| {
            windows
                .iter()
                .any(|(a, b)| *t >= a + EDGE && *t <= b - EDGE)
        })
        .filter_map(delta)
        .collect();
    let mut outside: Vec<f32> = samples
        .iter()
        .filter(|(t, _)| windows.iter().all(|(a, b)| *t < a - EDGE || *t > b + EDGE))
        .filter_map(delta)
        .collect();
    if inside.len() < 3 {
        return Err(format!(
            "too few frames to judge the cues against the subtitle-off pass: {} inside a cue have a baseline frame ({} baseline frames)",
            inside.len(),
            base.len()
        ));
    }
    inside.sort_by(f32::total_cmp);
    outside.sort_by(f32::total_cmp);
    let cue_median = inside[inside.len() / 2];
    let noise = if outside.len() >= 3 {
        outside[outside.len() / 2]
    } else {
        0.0
    };
    let line = format!(
        "subtitle pixels against the subtitle-off pass: {} frames inside cues, band share changed median {:.2} %, {} frames between cues, median {:.2} %",
        inside.len(),
        cue_median * 100.0,
        outside.len(),
        noise * 100.0
    );
    if cue_median >= 0.002 {
        Ok(line)
    } else {
        Err(format!("{line}\nno subtitle pixels at the cue times"))
    }
}

/// White text over saturated colour bars adds white but takes coloured pixels away, so the combined ink share can cancel
/// out; a styled cue has no white. A cue counts when the white share OR the ink share changed against the subtitle-off pass.
fn judge_cues_either(
    white: &[(f64, f32)],
    white_base: &[(f64, f32)],
    ink: &[(f64, f32)],
    ink_base: &[(f64, f32)],
    windows: &[(f64, f64)],
) -> Result<String, String> {
    judge_cues(white, white_base, windows).or_else(|w| {
        judge_cues(ink, ink_base, windows).map_err(|i| format!("{w}\n(ink share: {i})"))
    })
}

/// The judge without a baseline (no second pass possible): inside a cue window the band must hold clearly more white than
/// outside every window. A bitmap burned into the picture fools it; `judge_cues` is the verdict where a baseline exists.
fn judge_cues_plain(samples: &[(f64, f32)], windows: &[(f64, f64)]) -> Result<String, String> {
    const EDGE: f64 = 0.5;
    let inside: Vec<f32> = samples
        .iter()
        .filter(|(t, _)| {
            windows
                .iter()
                .any(|(a, b)| *t >= a + EDGE && *t <= b - EDGE)
        })
        .map(|s| s.1)
        .collect();
    let mut outside: Vec<f32> = samples
        .iter()
        .filter(|(t, _)| windows.iter().all(|(a, b)| *t < a - EDGE || *t > b + EDGE))
        .map(|s| s.1)
        .collect();
    if inside.len() < 3 || outside.len() < 3 {
        return Err(format!(
            "too few frames to judge the cues: {} inside a cue, {} outside (positions {:.1}..{:.1} s)",
            inside.len(),
            outside.len(),
            samples.first().map_or(0.0, |s| s.0),
            samples.last().map_or(0.0, |s| s.0)
        ));
    }
    outside.sort_by(f32::total_cmp);
    let quiet_peak = outside[outside.len() * 9 / 10];
    let mut sorted = inside.clone();
    sorted.sort_by(f32::total_cmp);
    let cue_median = sorted[sorted.len() / 2];
    // The share a cue adds: PGS bar of the bench ~ 5 % of the band, a short text line ~ 0.5-1 %.
    let line = format!(
        "subtitle pixels: {} frames inside cues, white share median {:.2} %, {} frames between cues, median {:.2} %",
        inside.len(),
        cue_median * 100.0,
        outside.len(),
        quiet_peak * 100.0
    );
    if cue_median >= quiet_peak + 0.002 {
        Ok(line)
    } else {
        Err(format!("{line}\nno subtitle pixels at the cue times"))
    }
}

/// The subtitle rows that are on (`None`: the list has not arrived yet). The "off" row, when the screen has one, does not count.
fn selected_subtitles(screen: &crate::player_screen::PlayerScreen) -> Option<Vec<String>> {
    let rows = screen.vm().tracks().subtitles;
    (!rows.is_empty()).then(|| {
        rows.iter()
            .filter(|r| r.selected && r.index >= 0)
            .map(|r| r.label.clone())
            .collect()
    })
}

/// Opens `id` again through the planner path (the start rule reads the track memory), reports which subtitles were on at the
/// first picture, optionally picks "off" (a hand choice, remembered too) and closes.
fn reopen_selected(
    core: &Core,
    account: &swiftly_vm::AccountRef,
    id: &str,
    then_off: bool,
) -> Result<Vec<String>, String> {
    use std::time::{Duration, Instant};
    let wait = Duration::from_secs(30);
    let prepared = core
        .prepare_play(
            account,
            PlayRequest {
                item_id: id.to_owned(),
                since: -1.0,
                source_id: None,
            },
        )
        .0
        .recv_timeout(wait)
        .map_err(|_| "plan timed out")??;
    let env = Env::new(
        swiftly_layout::Size::new(960.0, 540.0),
        1.0,
        swiftly_ui::Idiom::Desktop,
    );
    let mut screen = core.open_player(env, Cx::deterministic(), 0.0, prepared)?;
    screen.set_planner(core.planner(account));
    let t0 = Instant::now();
    let mut on = None;
    while t0.elapsed().as_secs_f64() < 20.0 && on.is_none() {
        let _ = screen.frame(t0.elapsed().as_secs_f64() * 1000.0);
        if screen.video_frames() > 0 {
            on = selected_subtitles(&screen);
        }
        std::thread::sleep(Duration::from_millis(16));
    }
    let on = on.ok_or("the reopened player never showed a subtitle list")?;
    if then_off {
        screen.send_intent(
            swiftly_vm::PlayerIntent::SelectSubtitle(-1),
            t0.elapsed().as_secs_f64() * 1000.0,
        );
        let until = t0.elapsed().as_secs_f64() + 0.8;
        while t0.elapsed().as_secs_f64() < until {
            let _ = screen.frame(t0.elapsed().as_secs_f64() * 1000.0);
            std::thread::sleep(Duration::from_millis(16));
        }
    }
    screen.send_intent(
        swiftly_vm::PlayerIntent::Close,
        t0.elapsed().as_secs_f64() * 1000.0,
    );
    std::thread::sleep(Duration::from_millis(1000));
    Ok(on)
}

/// The headless play test: sign in, take the first movie of Home, play it for `seconds` through the real player
/// screen, close, and (local fixture only) read back which reports the server got. On any other server only the
/// plan is fetched: nothing is played and nothing is reported, so a public server's data stays untouched.
///
/// Environment: `SWIFTLY_SMOKE_SERVER=plex` signs in with a token instead of a password (the Plex fixture takes any;
/// the title is then `SWIFTLY_SMOKE_ITEM`, a rating key such as `9002`, default `9001`); `SWIFTLY_SMOKE_ITEM` plays that
/// title; `SWIFTLY_SMOKE_SUBTITLE=<text>` picks the subtitle track whose label holds the text (case blind) and
/// `SWIFTLY_SMOKE_CUES="124-126,134-136"` (seconds on the title's clock) then asserts subtitle pixels in the played frames.
///
/// # Errors
/// The step that failed, as text.
pub fn smoke_play(
    address: &str,
    user: &str,
    password: &str,
    seconds: f64,
) -> Result<String, String> {
    smoke_play_on(address, user, password, seconds, false)
}

/// `smoke_play`; `native_video` = the engine draws into its own surface (Android Media3), so no frames reach the app
/// and the frame count is not asserted. The fixture is recognised by loopback or the emulator host address.
pub fn smoke_play_on(
    address: &str,
    user: &str,
    password: &str,
    seconds: f64,
    native_video: bool,
) -> Result<String, String> {
    use std::time::{Duration, Instant};
    let core = Arc::new(Core::open()?);
    let wait = Duration::from_secs(30);
    let plex = std::env::var("SWIFTLY_SMOKE_SERVER").is_ok_and(|v| v.eq_ignore_ascii_case("plex"));
    let item_env = std::env::var("SWIFTLY_SMOKE_ITEM").ok();
    // `SWIFTLY_SMOKE_DOWNLOAD=1`: download the title through the app's path (core download item, downloads view model,
    // subtitle files) and print what lies on disk; `SWIFTLY_SMOKE_OFFLINE=1`: play the downloaded copy with no server.
    let (download, offline) = (
        std::env::var_os("SWIFTLY_SMOKE_DOWNLOAD").is_some(),
        std::env::var_os("SWIFTLY_SMOKE_OFFLINE").is_some(),
    );
    let (found, account, id) = if plex {
        // Plex signs in through plex.tv (PIN), which the fixture does not play: the account is built from a token, the
        // same record the sign-in stores (`server_kind` Plex, the server's token, the profile id).
        let backend = core.sign_in_backend();
        let _ = &backend;
        let found = address.trim_end_matches('/').to_owned();
        let account = swiftly_vm::AccountRef {
            base_url: found.clone(),
            user_id: user.to_owned(),
            token: password.to_owned(),
            server_kind: swiftly_jellyfin::ServerKind::Plex,
            device_id: "smoke-play".into(),
            plex_machine_id: None,
            plex_account_token: None,
        };
        (
            found,
            account,
            item_env.clone().unwrap_or_else(|| "9001".into()),
        )
    } else if offline {
        // The server is gone: the account the download run stored, the title from `SWIFTLY_SMOKE_ITEM`.
        let account = core
            .account()
            .ok_or("no stored account: run the download step first")?;
        (
            address.trim_end_matches('/').to_owned(),
            account,
            item_env
                .clone()
                .ok_or("SWIFTLY_SMOKE_OFFLINE needs SWIFTLY_SMOKE_ITEM")?,
        )
    } else {
        let backend = core.sign_in_backend();
        let found = backend
            .connect(address)
            .0
            .recv_timeout(wait)
            .map_err(|_| "address check timed out")??;
        backend
            .password(user, password)
            .0
            .recv_timeout(wait)
            .map_err(|_| "sign-in timed out")??;
        let account = core.account().ok_or("account not stored")?;
        let client = core.client_for(&account).map_err(|e| format!("{e:?}"))?;
        let (tx, rx) = Pending::channel();
        {
            let c = Arc::new(client);
            let pick = item_env.clone();
            core.spawn(async move {
                // `SWIFTLY_SMOKE_ITEM=<id>` plays that title (the bench matrix runs every `bm-*` title this way).
                if let Some(id) = pick {
                    let _ = tx.send(Ok(Some(id)));
                    return;
                }
                let q = swiftly_jellyfin::ItemsQuery::default();
                let _ = tx.send(c.items(&q).await.map(|r| {
                    r.items
                        .into_iter()
                        .find(|i| i.type_.as_deref() == Some("Movie"))
                        .map(|i| i.id)
                }));
            });
        }
        let id =
            rx.0.recv_timeout(wait)
                .map_err(|_| "item list timed out")?
                .map_err(|e| format!("{e:?}"))?
                .ok_or("server has no movie")?;
        (found, account, id)
    };
    let mut out = vec![format!(
        "server {found}{}, title {id}",
        if plex { " (Plex)" } else { "" }
    )];
    if download {
        out.push(smoke_download(&core, &account, &id)?);
        return Ok(out.join("\n"));
    }
    let t = Instant::now();
    let prepared = if offline {
        crate::live_offline::prepare_offline(&core, &account, &id).map_err(|e| {
            format!(
                "{e} (account key {}, folder {})",
                account.key(),
                crate::live_downloads::downloads_dir().display()
            )
        })?
    } else {
        core.prepare_play(
            &account,
            PlayRequest {
                item_id: id.clone(),
                since: -1.0,
                source_id: None,
            },
        )
        .0
        .recv_timeout(wait)
        .map_err(|_| "plan timed out")??
    };
    let Some(ready) = prepared.ready() else {
        return Err("the server asks for a version".into());
    };
    out.push(format!(
        "plan {} ms: {:?} {} sections, url {}",
        t.elapsed().as_millis(),
        ready.spec.plan.method,
        ready.sections.len(),
        ready.url().split('?').next().unwrap_or("")
    ));
    if !is_fixture_address(
        &found,
        std::env::var("SWIFTLY_SMOKE_FIXTURE_HOST").ok().as_deref(),
    ) {
        out.push("not the local fixture: plan only, nothing played or reported".into());
        return Ok(out.join("\n"));
    }
    let env = Env::new(
        swiftly_layout::Size::new(960.0, 540.0),
        1.0,
        swiftly_ui::Idiom::Desktop,
    );
    let mut screen = core.open_player(env, Cx::deterministic(), 0.0, prepared)?;
    screen.set_planner(core.planner(&account));
    let mut cues = std::env::var("SWIFTLY_SMOKE_CUES")
        .map(|c| parse_cues(&c))
        .unwrap_or_default();
    let mut want_subtitle = std::env::var("SWIFTLY_SMOKE_SUBTITLE")
        .ok()
        .filter(|s| !s.is_empty());
    // `SWIFTLY_SMOKE_NEXT_AT=<s>` (and `SWIFTLY_SMOKE_SEEK2=<s>` to jump in the second title): that many seconds in, the player moves to the next episode; the subtitle pick and the cue
    // check then belong to the second title (the first one only has to play).
    let next_at = std::env::var("SWIFTLY_SMOKE_NEXT_AT")
        .ok()
        .and_then(|v| v.parse::<f64>().ok());
    let mut moved = false;
    if next_at.is_some() {
        out.push(format!("first title {}", screen.vm().spec().item_id));
    }
    let (second_cues, second_subtitle) = if next_at.is_some() {
        (std::mem::take(&mut cues), want_subtitle.take())
    } else {
        (Vec::new(), None)
    };
    PROBE_ON.store(!cues.is_empty(), std::sync::atomic::Ordering::Relaxed);
    let first_id = screen.vm().spec().item_id.clone();
    let mut samples: Vec<(f64, f32)> = Vec::new();
    let mut ink_samples: Vec<(f64, f32)> = Vec::new();
    let mut chosen = want_subtitle.is_none();
    // `SWIFTLY_SMOKE_EXPECT_START=<text|off>`: what the start rule must have selected before any hand pick (a forced track,
    // a remembered one); `SWIFTLY_SMOKE_REOPEN=1`: after the run the title is opened again through the planner path and
    // must start with the hand-picked track, then "off" is picked and the next open must start with nothing.
    let expect_start = std::env::var("SWIFTLY_SMOKE_EXPECT_START")
        .ok()
        .filter(|s| !s.is_empty());
    let reopen = std::env::var_os("SWIFTLY_SMOKE_REOPEN").is_some();
    let mut start_checked = expect_start.is_none();
    let mut picked_label: Option<String> = None;
    let mut first_frames = 0u64;
    let t0 = Instant::now();
    while t0.elapsed().as_secs_f64() < seconds {
        let now = t0.elapsed().as_secs_f64() * 1000.0;
        let _ = screen.frame(now);
        if let Some(at) = next_at.filter(|at| !moved && now >= at * 1000.0) {
            screen.send_intent(swiftly_vm::PlayerIntent::NextEpisode, now);
            moved = true;
            let _ = at;
        }
        if moved && cues.is_empty() && screen.vm().spec().item_id != first_id {
            // The switch landed: judge the second title from its own start.
            out.push(format!("moved to {}", screen.vm().spec().item_id));
            (cues, want_subtitle) = (second_cues.clone(), second_subtitle.clone());
            chosen = want_subtitle.is_none();
            samples.clear();
            ink_samples.clear();
            PROBE_ON.store(!cues.is_empty(), std::sync::atomic::Ordering::Relaxed);
            first_frames = screen.video_frames();
        }
        if !start_checked && screen.video_frames() > first_frames && screen.video_frames() > 0 {
            let on = selected_subtitles(&screen);
            if let Some(on) = on {
                start_checked = true;
                let text = if on.is_empty() {
                    "off".to_owned()
                } else {
                    on.join(", ")
                };
                out.push(format!("subtitle at start: {text}"));
                let want = expect_start.clone().unwrap_or_default().to_lowercase();
                let ok = if want == "off" {
                    on.is_empty()
                } else {
                    on.iter().any(|l| l.to_lowercase().contains(&want))
                };
                if !ok {
                    return Err(format!(
                        "{}\nstart rule: expected '{want}' selected at the start, got {text}",
                        out.join("\n")
                    ));
                }
            }
        }
        if !chosen && screen.video_frames() > first_frames && screen.video_frames() > 0 {
            // The picks wait for the first picture: the panel rows exist once the engine is up.
            chosen = true;
            if moved
                && let Some(to) = std::env::var("SWIFTLY_SMOKE_SEEK2")
                    .ok()
                    .and_then(|v| v.parse::<f64>().ok())
            {
                // A long title: jump to where its cues are (once its picture is up).
                screen.send_intent(swiftly_vm::PlayerIntent::SeekTo(to), now);
            }
            let (needle, rows) = (
                want_subtitle.clone().unwrap_or_default().to_lowercase(),
                screen.vm().tracks().subtitles,
            );
            out.push(format!(
                "subtitle rows: {}",
                rows.iter()
                    .map(|r| format!(
                        "{}={}{}",
                        r.index,
                        r.label,
                        if r.selected { " (on)" } else { "" }
                    ))
                    .collect::<Vec<_>>()
                    .join(" | ")
            ));
            // `#<index>` picks by the server's track number (a downloaded copy does not keep the language, so its labels are alike).
            let pick = rows.iter().rev().find(|r| {
                !r.forced
                    && match needle.strip_prefix('#') {
                        Some(n) => r.index.to_string() == n,
                        None => r.label.to_lowercase().contains(&needle),
                    }
            });
            let Some(row) = pick else {
                return Err(format!(
                    "{}\nno subtitle track matches '{needle}'",
                    out.join("\n")
                ));
            };
            screen.send_intent(swiftly_vm::PlayerIntent::SelectSubtitle(row.index), now);
            out.push(format!("subtitle picked: {} ({})", row.index, row.label));
            picked_label = Some(row.label.clone());
        }
        if let Some(w) = PROBE_LAST
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
        {
            samples.push((screen.vm().transport().position, w.0));
            ink_samples.push((screen.vm().transport().position, w.1));
        }
        std::thread::sleep(Duration::from_millis(16));
    }
    // The baseline: the same positions with the subtitle off, so a bitmap burned into the picture cancels out.
    let mut base: Vec<(f64, f32)> = Vec::new();
    let mut ink_base: Vec<(f64, f32)> = Vec::new();
    if !cues.is_empty() && !native_video {
        let from = (cues.iter().map(|w| w.0).fold(f64::MAX, f64::min) - 1.0).max(0.0);
        let to = cues.iter().map(|w| w.1).fold(0.0, f64::max) + 1.0;
        let start = t0.elapsed().as_secs_f64() * 1000.0;
        screen.send_intent(swiftly_vm::PlayerIntent::SelectSubtitle(-1), start);
        screen.send_intent(swiftly_vm::PlayerIntent::SeekTo(from), start);
        let pass = Instant::now();
        let mut landed = false;
        while pass.elapsed().as_secs_f64() < 25.0 {
            let _ = screen.frame(t0.elapsed().as_secs_f64() * 1000.0);
            let pos = screen.vm().transport().position;
            // Frames before the seek landed still belong to the subtitle-on pass.
            landed = landed
                || (pass.elapsed().as_secs_f64() > 0.4 && (from - 0.5..=from + 3.0).contains(&pos));
            if let Some(w) = PROBE_LAST
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .take()
                && landed
            {
                base.push((pos, w.0));
                ink_base.push((pos, w.1));
            }
            if landed && pos > to {
                break;
            }
            std::thread::sleep(Duration::from_millis(16));
        }
        out.push(format!("subtitle-off pass: {} frames from {from:.1} s to {to:.1} s (got {:.2}..{:.2} s, {:.1} s wall)", base.len(), base.first().map_or(0.0, |b| b.0), base.last().map_or(0.0, |b| b.0), pass.elapsed().as_secs_f64()));
    }
    PROBE_ON.store(false, std::sync::atomic::Ordering::Relaxed);
    out.push(format!("player log: {:?}", screen.log()));
    out.push(format!(
        "played {seconds:.0} s, video frames delivered {}",
        screen.video_frames()
    ));
    let picture = screen.picture_stats();
    if let Some(p) = &picture {
        out.push(format!(
            "picture: mean rgb {:.0}/{:.0}/{:.0}, black {:.0} %, green {:.0} %",
            p.mean[0],
            p.mean[1],
            p.mean[2],
            p.black * 100.0,
            p.green * 100.0
        ));
    }
    if std::env::var_os("SWIFTLY_SMOKE_SAMPLES").is_some() {
        // For a title whose picture has white of its own (a burned-in bitmap): the raw band shares, one per 0.25 s.
        let mut last = f64::NEG_INFINITY;
        let list: Vec<String> = samples
            .iter()
            .filter(|(t, _)| {
                let keep = *t >= last + 0.25;
                if keep {
                    last = *t;
                }
                keep
            })
            .map(|(t, w)| format!("{t:.2}:{:.2}", w * 100.0))
            .collect();
        out.push(format!("subtitle samples (s:% white): {}", list.join(" ")));
    }
    if std::env::var_os("SWIFTLY_SMOKE_SAMPLES").is_some() && !base.is_empty() {
        let mut last = f64::NEG_INFINITY;
        let list: Vec<String> = base
            .iter()
            .filter(|(t, _)| {
                let keep = *t >= last + 0.25;
                if keep {
                    last = *t;
                }
                keep
            })
            .map(|(t, w)| format!("{t:.2}:{:.2}", w * 100.0))
            .collect();
        out.push(format!(
            "subtitle-off samples (s:% white): {}",
            list.join(" ")
        ));
    }
    let cue_verdict = (!cues.is_empty() && !native_video).then(|| {
        match judge_cues_either(&samples, &base, &ink_samples, &ink_base, &cues) {
            // No usable baseline (the position did not advance after the seek back): the plain judge, which a burned-in bitmap can fool.
            Err(e) if e.starts_with("too few") => {
                out.push(format!("{e}; falling back to the judge without a baseline"));
                judge_cues_plain(&samples, &cues)
            }
            other => other,
        }
    });
    match &cue_verdict {
        Some(Ok(line)) => out.push(line.clone()),
        Some(Err(e)) => out.push(e.clone()),
        None => {}
    }
    screen.send_intent(swiftly_vm::PlayerIntent::Close, seconds * 1000.0);
    std::thread::sleep(Duration::from_millis(1200));
    if reopen {
        let want = picked_label
            .ok_or_else(|| format!("{}\nreopen needs SWIFTLY_SMOKE_SUBTITLE", out.join("\n")))?;
        let again = reopen_selected(&core, &account, &id, true)?;
        out.push(format!("reopen: selected {again:?} (picked '{want}')"));
        if !again.contains(&want) {
            return Err(format!(
                "{}\nthe choice is not remembered per title: reopened with {again:?}",
                out.join("\n")
            ));
        }
        let off = reopen_selected(&core, &account, &id, false)?;
        out.push(format!("reopen after off: selected {off:?}"));
        if !off.is_empty() {
            return Err(format!(
                "{}\n'off' is not remembered per title: reopened with {off:?}",
                out.join("\n")
            ));
        }
    }
    if offline {
        out.push("offline: the server is gone, no reports expected".into());
        if picture.is_some_and(|p| !p.looks_fine()) {
            return Err(format!("{}\nthe picture is black or green", out.join("\n")));
        }
        if screen.video_frames() == 0 && !native_video {
            return Err(format!("{}\nno video frames arrived", out.join("\n")));
        }
        if let Some(Err(_)) = cue_verdict {
            return Err(out.join("\n"));
        }
        return Ok(out.join("\n"));
    }
    let reports = http_get(found.as_str(), "/fixture/reports").unwrap_or_default();
    out.push(format!("reports at the server: {reports}"));
    // Jellyfin posts `/Sessions/Playing`, `/Sessions/Playing/Progress`, `/Sessions/Playing/Stopped`; Plex `/:/timeline/<state>`.
    let timeline = reports.matches("/:/timeline/").count();
    let plex_stops = reports.matches("timeline/stopped").count();
    let plex_starts = usize::from(reports.contains("timeline/playing"));
    let (starts, progress, stops) = (
        reports.matches("Playing\"").count() + plex_starts,
        reports.matches("Progress").count() + timeline.saturating_sub(plex_starts + plex_stops),
        reports.matches("Stopped").count() + plex_stops,
    );
    if picture.is_some_and(|p| !p.looks_fine()) {
        return Err(format!("{}\nthe picture is black or green", out.join("\n")));
    }
    if screen.video_frames() == 0 && !native_video {
        return Err(format!("{}\nno video frames arrived", out.join("\n")));
    }
    if let Some(Err(_)) = cue_verdict {
        return Err(out.join("\n"));
    }
    // A progress report goes out every 10 s, so short runs only need start and stop.
    if starts == 0 || (progress == 0 && seconds > 10.5) || stops == 0 {
        return Err(format!(
            "{}\nreports missing: start {starts}, progress {progress}, stop {stops}",
            out.join("\n")
        ));
    }
    Ok(out.join("\n"))
}

/// The download step of the smoke: the app's own path (`download_item` of the core, the shared downloads view model, the
/// subtitle files that travel along) up to the finished copy and its `.untertitel` folder.
fn smoke_download(
    core: &Core,
    account: &swiftly_vm::AccountRef,
    id: &str,
) -> Result<String, String> {
    use std::time::{Duration, Instant};
    let (net, host) = (Arc::clone(&core.net), core.host());
    let ids = [id.to_owned()];
    let rows = if matches!(account.server_kind, swiftly_jellyfin::ServerKind::Plex) {
        let d = swiftly_vm::LegacyPlexDetail::new(&net, &host, account)
            .map_err(|e| format!("{e:?}"))?;
        core.handle().block_on(d.download_item(&ids))
    } else {
        let d =
            swiftly_vm::LegacyDetail::new(&net, &host, account).map_err(|e| format!("{e:?}"))?;
        core.handle().block_on(d.download_item(&ids))
    };
    let rows: serde_json::Value = serde_json::from_str(&rows).map_err(|e| e.to_string())?;
    let item: swiftly_downloads::DownloadItem = serde_json::from_value(
        rows.get(0)
            .and_then(|r| r.get("posten"))
            .cloned()
            .ok_or("no download item for the title")?,
    )
    .map_err(|e| e.to_string())?;
    let (key, dir) = (account.key(), crate::live_downloads::downloads_dir());
    // The list keeps the account's key (the load sheet stamps it the same way), not the core's bare user id.
    let mut item = item;
    item.account.clone_from(&key);
    let vm = crate::live_downloads::shared(core, account);
    vm.send(swiftly_vm::DownloadsIntent::Start {
        items: vec![item.clone()],
        images: std::collections::HashMap::new(),
        check_space: false,
    })
    .map_err(|e| format!("{e:?}"))?;
    let t = Instant::now();
    let (item, file) = loop {
        if let Some(done) = crate::live_downloads::finished(&dir, &key, id) {
            break done;
        }
        if t.elapsed() > Duration::from_secs(120) {
            return Err("the download did not finish".into());
        }
        std::thread::sleep(Duration::from_millis(200));
    };
    let folder = dir.join(item.subtitle_folder_name());
    let t = Instant::now();
    let mut files: Vec<String> = Vec::new();
    while t.elapsed() < Duration::from_secs(15) {
        files = std::fs::read_dir(&folder)
            .map(|d| {
                d.flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default();
        if !files.is_empty() {
            break;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    files.sort();
    Ok(format!(
        "downloaded {} ({} bytes), subtitle folder {}: {files:?}",
        file.display(),
        std::fs::metadata(&file).map_or(0, |m| m.len()),
        folder.display()
    ))
}

#[cfg(test)]
mod container_id_tests {
    use super::ContainerIds;
    use swiftly_playback::engine::{EngineEvent, EngineTrack};

    fn stream(index: i64, container: Option<i64>) -> swiftly_model::MediaStream {
        swiftly_model::MediaStream {
            index: Some(index),
            container_index: container,
            ..Default::default()
        }
    }

    fn track(id: i64) -> EngineTrack {
        EngineTrack {
            id,
            codec: String::new(),
            language: None,
            name: String::new(),
            channels: 0,
            is_default: false,
            is_forced: false,
        }
    }

    #[test]
    fn plex_stream_ids_and_file_places_translate_both_ways() {
        let ids = ContainerIds::of(&[
            stream(413105, Some(0)),
            stream(413114, Some(3)),
            stream(413117, None),
            stream(2, Some(2)),
        ]);
        assert_eq!(ids.to_file(413114), 3);
        assert_eq!(
            ids.to_file(1000),
            1000,
            "an external file keeps its engine id"
        );
        assert_eq!(ids.to_file(2), 2, "equal numbers need no pair");
        assert_eq!(ids.to_server(3), 413114);
        let EngineEvent::Tracks {
            subtitles,
            active_subtitle,
            ..
        } = ids.event(EngineEvent::Tracks {
            audio: vec![],
            subtitles: vec![track(3), track(1000)],
            active_audio: None,
            active_subtitle: Some(3),
        })
        else {
            panic!("tracks")
        };
        assert_eq!(
            (subtitles[0].id, subtitles[1].id, active_subtitle),
            (413114, 1000, Some(413114))
        );
        assert!(
            ContainerIds::of(&[stream(1, None), stream(2, Some(2))])
                .pairs
                .read()
                .unwrap()
                .is_empty(),
            "Jellyfin streams pass through"
        );
    }
}

#[cfg(test)]
mod next_episode_id_tests {
    use super::{ContainerIds, remember_streams};

    fn stream(index: i64, container: i64) -> swiftly_model::MediaStream {
        swiftly_model::MediaStream {
            index: Some(index),
            container_index: Some(container),
            ..Default::default()
        }
    }

    #[test]
    fn a_next_episode_gets_its_own_id_table() {
        remember_streams("http://x/ep1", &[stream(100, 0), stream(101, 3)]);
        remember_streams("http://x/ep2", &[stream(200, 0), stream(201, 3)]);
        let ids = ContainerIds::of(&[stream(100, 0), stream(101, 3)]);
        ids.switch_to("http://x/ep2");
        assert_eq!(
            ids.to_file(201),
            3,
            "episode 2 stream id maps to its file place"
        );
        assert_eq!(ids.to_server(3), 201);
        assert_eq!(ids.to_file(101), 101, "episode 1 ids are gone");
        ids.switch_to("http://x/unknown");
        assert_eq!(
            ids.to_file(201),
            201,
            "a title without a note passes through"
        );
    }
}

#[cfg(test)]
mod cue_tests {
    use super::{
        ink_band_share, judge_cues, judge_cues_either, judge_cues_plain, parse_cues,
        white_band_share,
    };

    #[test]
    fn cue_windows_are_read_from_the_text() {
        assert_eq!(parse_cues("1-3, 4-6"), vec![(1.0, 3.0), (4.0, 6.0)]);
        assert!(parse_cues("").is_empty());
    }

    #[test]
    fn the_cores_subtitle_rows_become_index_address_ending() {
        let rows = r#"[{"index":3,"adresse":"http://h/a.ass?k=1","endung":"ass"},{"index":-1}]"#;
        assert_eq!(
            super::parse_subtitle_rows(rows),
            vec![(
                3,
                "http://h/a.ass?k=1".to_owned(),
                "ass".to_owned(),
                swiftly_vm::subtitle_sidecar::SubtitleMeta {
                    index: 3,
                    ..Default::default()
                }
            )]
        );
        assert!(super::parse_subtitle_rows("[]").is_empty());
    }

    #[test]
    fn a_cue_is_found_only_where_the_band_gets_whiter() {
        let frames = |cue_white: f32| -> Vec<(f64, f32)> {
            (0..120)
                .map(|i| {
                    let t = f64::from(i) / 12.0;
                    (
                        t,
                        if (2.0..4.0).contains(&t) {
                            cue_white
                        } else {
                            0.01
                        },
                    )
                })
                .collect()
        };
        assert!(judge_cues_plain(&frames(0.06), &[(2.0, 4.0)]).is_ok());
        assert!(
            judge_cues_plain(&frames(0.01), &[(2.0, 4.0)]).is_err(),
            "no cue drawn: must fail"
        );
        assert!(
            judge_cues_plain(&frames(0.06)[..20], &[(2.0, 4.0)]).is_err(),
            "too few frames: must fail"
        );
    }

    /// 12 frames a second for 10 s; `bar` is a bitmap burned into the picture (white share of the band) at the given seconds.
    fn burned(bar: &[(f64, f64)], cue_white: f32, windows: &[(f64, f64)]) -> Vec<(f64, f32)> {
        (0..120)
            .map(|i| {
                let t = f64::from(i) / 12.0;
                let mut w = 0.01_f32;
                if bar.iter().any(|(a, b)| t >= *a && t < *b) {
                    w += 0.20;
                }
                if windows.iter().any(|(a, b)| t >= *a && t <= *b) {
                    w += cue_white;
                }
                (t, w)
            })
            .collect()
    }

    #[test]
    fn a_burned_in_bitmap_is_not_taken_for_a_cue_and_does_not_hide_one() {
        let windows = [(1.0, 3.0), (4.0, 6.0)];
        let bar = [(0.0, 2.0), (4.0, 6.0)];
        let base = burned(&bar, 0.0, &windows);
        // The text is really drawn on top of the burned bar: green although the bar is in the quiet frames too.
        let on = burned(&bar, 0.006, &windows);
        assert!(
            judge_cues(&on, &base, &windows).is_ok(),
            "a drawn cue next to a burned bar must pass"
        );
        // Nothing drawn, the bar alone sits in a cue window: red.
        let windows = [(4.0, 6.0), (7.0, 9.0)];
        let bar = [(4.0, 6.0)];
        let both = burned(&bar, 0.0, &windows);
        assert!(
            judge_cues(&both, &both, &windows).is_err(),
            "a burned bar alone is no subtitle"
        );
        // The same frame times with no subtitle are the baseline: identical frames mean no cue.
        assert!(
            judge_cues(&both, &[], &windows).is_err(),
            "no baseline frames: no verdict"
        );
        // No baseline frames near the cue: the verdict says so instead of guessing.
    }

    /// A yellow cue with a red outline has no white pixel: the white share misses it, the ink share (and the judge) finds it.
    #[test]
    fn a_coloured_cue_without_any_white_is_found() {
        let (w, h) = (20u32, 10u32);
        let mut frame = vec![0u8; (w * h * 4) as usize];
        for p in frame.as_chunks_mut::<4>().0 {
            p.copy_from_slice(&[96, 96, 96, 255]);
        }
        let plain = frame.clone();
        for (i, p) in frame
            .as_chunks_mut::<4>()
            .0
            .iter_mut()
            .enumerate()
            .skip(150)
            .take(30)
        {
            p.copy_from_slice(if i % 2 == 0 {
                &[255, 220, 20, 255]
            } else {
                &[200, 20, 20, 255]
            });
        }
        assert_eq!(
            white_band_share(&frame, w, h),
            0.0,
            "no white in a yellow cue"
        );
        let cue = ink_band_share(&frame, w, h);
        assert!(cue > 0.1 && ink_band_share(&plain, w, h) == 0.0);
        let windows = [(1.0, 5.0)];
        let on: Vec<(f64, f32)> = (0..60)
            .map(|i| {
                (
                    f64::from(i) / 12.0,
                    if (1.0..=5.0).contains(&(f64::from(i) / 12.0)) {
                        cue
                    } else {
                        0.0
                    },
                )
            })
            .collect();
        let off: Vec<(f64, f32)> = on.iter().map(|(t, _)| (*t, 0.0)).collect();
        assert!(
            judge_cues(&on, &off, &windows).is_ok(),
            "a styled cue must pass against the subtitle-off pass"
        );
        assert!(judge_cues(&off, &off, &windows).is_err());
    }

    /// White text over saturated bars: the white share rises, the ink share stays flat (bars are covered). Found on the
    /// colour-bar bench media, where the ink-only judge failed every plain white cue.
    #[test]
    fn a_white_cue_over_colour_bars_passes_when_ink_stays_flat() {
        let windows = [(1.0, 5.0)];
        let t = |v: f32| -> Vec<(f64, f32)> {
            (0..60)
                .map(|i| {
                    (
                        f64::from(i) / 12.0,
                        if (1.0..=5.0).contains(&(f64::from(i) / 12.0)) {
                            v
                        } else {
                            0.0
                        },
                    )
                })
                .collect()
        };
        let flat = t(0.0);
        let white_on = t(0.004);
        assert!(
            judge_cues(&flat, &flat, &windows).is_err(),
            "ink alone sees nothing"
        );
        assert!(judge_cues_either(&white_on, &flat, &flat, &flat, &windows).is_ok());
        assert!(judge_cues_either(&flat, &flat, &flat, &flat, &windows).is_err());
    }

    #[test]
    fn white_share_counts_only_the_bottom_band() {
        let (w, h) = (10u32, 10u32);
        let mut rgba = vec![0u8; (w * h * 4) as usize];
        for p in rgba.as_chunks_mut::<4>().0.iter_mut().take(30) {
            p.copy_from_slice(&[255, 255, 255, 255]);
        }
        assert_eq!(
            white_band_share(&rgba, w, h),
            0.0,
            "white in the top rows is not a cue"
        );
        for p in rgba.as_chunks_mut::<4>().0.iter_mut().skip(70) {
            p.copy_from_slice(&[240, 250, 255, 255]);
        }
        assert!((white_band_share(&rgba, w, h) - 0.75).abs() < 1e-6);
    }
}

#[cfg(test)]
mod next_tests {
    use super::next_after;

    fn ep(id: &str, season: i64, number: i64) -> swiftly_model::Item {
        serde_json::from_value(serde_json::json!({ "Id": id, "Name": id, "Type": "Episode", "ParentIndexNumber": season, "IndexNumber": number })).expect("item")
    }

    #[test]
    fn next_crosses_the_season_border_and_skips_specials() {
        let all = vec![
            ep("s0e1", 0, 1),
            ep("s1e1", 1, 1),
            ep("s1e2", 1, 2),
            ep("s2e1", 2, 1),
        ];
        assert_eq!(
            next_after(&all, (1, 1)).map(|e| e.id.as_str()),
            Some("s1e2")
        );
        assert_eq!(
            next_after(&all, (1, 2)).map(|e| e.id.as_str()),
            Some("s2e1")
        );
        assert_eq!(next_after(&all, (2, 1)).map(|e| e.id.as_str()), None);
        assert_eq!(
            next_after(&all, (0, 1)).map(|e| e.id.as_str()),
            Some("s1e1")
        );
    }
}

#[cfg(test)]
mod fixture_address_tests {
    use super::is_fixture_address;

    #[test]
    fn only_loopback_emulator_and_the_named_host_count_as_the_fixture() {
        assert!(is_fixture_address("http://127.0.0.1:18197", None));
        assert!(is_fixture_address("http://10.0.2.2:18197", None));
        assert!(!is_fixture_address("http://192.168.122.1:18198", None));
        assert!(is_fixture_address(
            "http://192.168.122.1:18198",
            Some("192.168.122.1")
        ));
        assert!(!is_fixture_address(
            "http://192.168.122.10:18198",
            Some("192.168.122.1")
        ));
        assert!(!is_fixture_address(
            "https://jellyfin.example.org",
            Some("")
        ));
    }
}
