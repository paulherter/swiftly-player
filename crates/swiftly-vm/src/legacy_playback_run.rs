#![allow(missing_docs)]
//! The running part of the old Android playback (`Kern`'s `playbackTick`, offer card, resume after a pause,
//! prebuffering, the report queue, episode and quality switch): the glue between the packages' rules, in the same
//! order and with the same answers and log rows as the Swift code. See `legacy_playback` for the open title.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::json;
use swiftly_jellyfin::{PendingReport, PlayMethod, ReportPlan, TrackIndices};
use swiftly_l10n::Translator;
use swiftly_model::{DeliveryMethod, ticks_from_seconds};
use swiftly_net::{HttpRequest, HttpTransport, Method};
use swiftly_playback::offering_layer::{OfferingLayer, OfferingPresentation, Opening};
use swiftly_playback::pause_jump_back;
use swiftly_playback::prebuffer;
use swiftly_playback::sections::{ButtonOffering, SectionLogic, Segment};
use swiftly_rules::episodes_card::REMAINING_WINDOW;
use swiftly_rules::episodes_end;
use swiftly_rules::episodes_switch::{EpisodeSwitch, Outcome, Phase, Steps, StopLock};
use swiftly_rules::playback_tick::{self, Reading, Snapshot, TICK_LENGTH};

use crate::legacy_playback::{LegacyPlayback, State};
use crate::play_display::PlayDisplay;
use crate::player_report::{ReportDesk, ReportKind, ReportMessage, ReportOutcome};
use crate::player_start::ReadyStart;

/// What the open title keeps while it runs (`Playback` of the Swift core besides the plan).
pub(crate) struct Live {
    pub(crate) snap: Snapshot,
    pub(crate) layer: OfferingLayer,
    /// Since when it has been paused, seconds on the core's clock (`pausedSince`).
    pub(crate) paused_since: Option<f64>,
    /// Sections already skipped on their own, by start second (bits).
    /// When it opened, seconds on the core's clock.
    pub(crate) start: f64,
}

impl Live {
    pub(crate) fn new() -> Self {
        let mut layer = OfferingLayer::new();
        // The card waits while the controls are open: it goes away, the countdown pauses, and returns when they close.
        layer.card_waits_controls = true;
        Self {
            snap: Snapshot::default(),
            layer,
            paused_since: None,
            start: 0.0,
        }
    }
}

struct Prepared {
    ready: ReadyStart,
    display: PlayDisplay,
    moment: f64,
}

struct RunState {
    next_automatic: bool,
    reported_paused: bool,
    prepared: Option<Prepared>,
    preparation: Option<String>,
    rows: Vec<String>,
    stops: Vec<Stop>,
}

/// A stop, for the download's watch state and the pending catch-up report of the same title (`StopRemember`).
#[derive(Clone)]
pub struct Stop {
    pub item_id: String,
    pub account: String,
    pub ticks: i64,
    pub moment: f64,
    pub sent: bool,
}

/// The parts of one playback that live next to the plan: the report queue, the clock, the switch latch.
pub(crate) struct Run {
    desk: Arc<ReportDesk>,
    epoch: Instant,
    switch: Mutex<Arc<EpisodeSwitch>>,
    inner: Mutex<RunState>,
}

impl Run {
    pub(crate) fn new(desk: Arc<ReportDesk>) -> Self {
        Self {
            desk,
            epoch: Instant::now(),
            switch: Mutex::new(Arc::new(EpisodeSwitch::new())),
            inner: Mutex::new(RunState {
                next_automatic: true,
                reported_paused: false,
                prepared: None,
                preparation: None,
                rows: Vec::new(),
                stops: Vec::new(),
            }),
        }
    }

    fn now(&self) -> f64 {
        self.epoch.elapsed().as_secs_f64() + 1.0
    }

    fn with<R>(&self, f: impl FnOnce(&mut RunState) -> R) -> R {
        f(&mut self.inner.lock().unwrap_or_else(PoisonError::into_inner))
    }

    fn switch(&self) -> Arc<EpisodeSwitch> {
        Arc::clone(&self.switch.lock().unwrap_or_else(PoisonError::into_inner))
    }

    /// A new player: its own latch, nothing prepared (`_episodesSwitch = EpisodeSwitch()`).
    pub(crate) fn reset_switch(&self) {
        *self.switch.lock().unwrap_or_else(PoisonError::into_inner) =
            Arc::new(EpisodeSwitch::new());
        self.with(|r| {
            r.prepared = None;
            r.preparation = None;
        });
    }

    pub(crate) fn row(&self, text: String) {
        self.with(|r| {
            r.rows.push(text);
            if r.rows.len() > 50 {
                let extra = r.rows.len() - 50;
                r.rows.drain(..extra);
            }
        });
    }

    /// The stop of a playback, awaited; empty if reported, otherwise the catch-up report as JSON (`stopReport`).
    pub(crate) async fn stop_report(
        self: Arc<Self>,
        message: ReportMessage,
        user: String,
    ) -> String {
        let seconds = message.seconds;
        let item = message.item_id.clone();
        let session = message.plan.play_session_id.clone();
        let moment = wall();
        let result = self.desk.report_and_wait(message).await;
        if !user.is_empty() {
            self.with(|r| {
                r.stops.push(Stop {
                    item_id: item.clone(),
                    account: user.clone(),
                    ticks: ticks_from_seconds(seconds),
                    moment,
                    sent: result == ReportOutcome::Sent,
                });
            });
        }
        let session_text = session.as_deref().unwrap_or("nil");
        match result {
            ReportOutcome::Sent => {
                self.row(format!(
                    "Stopped {} s {item} session {session_text}",
                    whole(seconds)
                ));
                String::new()
            }
            ReportOutcome::Discarded => {
                self.row(format!(
                    "Stopped doppelt verworfen {item} session {session_text}"
                ));
                String::new()
            }
            ReportOutcome::Failed | ReportOutcome::TimedOut => {
                self.row(format!("Stopped {result:?} \u{2192} Nachmeldung {item}"));
                if user.is_empty() {
                    return String::new();
                }
                serde_json::to_string(&PendingReport {
                    item_id: item,
                    account: user.clone(),
                    ticks: ticks_from_seconds(seconds),
                    moment,
                })
                .unwrap_or_default()
            }
        }
    }
}

#[derive(Serialize)]
struct TickOut {
    #[serde(rename = "ladeschirmWeg")]
    loading_screen_gone: bool,
    #[serde(rename = "spurenAnwenden")]
    tracks_apply: bool,
    position: f64,
    #[serde(rename = "angebot")]
    offering: &'static str,
    #[serde(rename = "nach", skip_serializing_if = "Option::is_none")]
    to: Option<f64>,
    #[serde(rename = "angebotstext")]
    offering_text: String,
    #[serde(rename = "einblendung")]
    overlay: &'static str,
    countdown: f64,
    #[serde(rename = "countdownRest")]
    countdown_rest: i64,
    #[serde(rename = "countdownLaenge")]
    countdown_length: f64,
    #[serde(rename = "weiterschalten")]
    advance: bool,
    #[serde(rename = "autoUeberspringen")]
    auto_skip: bool,
    /// Fill of the skip button's countdown (0..1); only present with auto-skip on and a skip button showing.
    #[serde(rename = "knopfCountdown", skip_serializing_if = "Option::is_none")]
    button_countdown: Option<f64>,
}

struct Status {
    art: &'static str,
    to: Option<f64>,
    text: &'static str,
    overlay: &'static str,
    share: f64,
}

fn status(live: &Live, sections: &[Segment], has_next: bool) -> Status {
    let offering =
        SectionLogic::offering(live.snap.position, live.snap.duration, sections, has_next);
    let (art, to) = match offering {
        ButtonOffering::Nobody => ("keiner", None),
        ButtonOffering::Skip { to, .. } => ("ueberspringen", Some(to)),
        ButtonOffering::NextEpisode => ("naechste", None),
    };
    let (overlay, share) = match live.layer.display() {
        OfferingPresentation::Nothing => ("nichts", 0.0),
        OfferingPresentation::Button(_) => ("knopf", 0.0),
        OfferingPresentation::Card { share } => ("karte", share),
    };
    Status {
        art,
        to,
        text: offering.label(),
        overlay,
        share,
    }
}

fn catch_up(
    live: &mut Live,
    sections: &[Segment],
    has_next: bool,
    automatic: bool,
    running: bool,
    elapsed: f64,
    at_end: bool,
) -> bool {
    let (spot, duration) = (live.snap.position, live.snap.duration);
    let offering = SectionLogic::offering(spot, duration, sections, has_next);
    // "Skip intro and outro automatically" lets the outro's card count down and advance as well.
    let auto_next = live.layer.auto_skip
        && SectionLogic::automatic(spot, duration, sections, has_next).is_some();
    let due = (automatic || auto_next)
        && SectionLogic::card_due(spot, duration, sections, has_next, Some(REMAINING_WINDOW));
    let countdown =
        SectionLogic::countdown_with_sections(spot, duration, sections, Some(REMAINING_WINDOW));
    live.layer
        .tick(offering, due, running, elapsed, countdown, at_end)
}

fn play_method(m: DeliveryMethod) -> PlayMethod {
    match m {
        DeliveryMethod::DirectPlay => PlayMethod::DirectPlay,
        DeliveryMethod::DirectStream => PlayMethod::DirectStream,
        DeliveryMethod::Transcode => PlayMethod::Transcode,
    }
}

fn track_text(t: &TrackIndices) -> String {
    let one = |v: Option<i64>| v.map_or("\u{2014}".to_owned(), |n| n.to_string());
    format!("{}/{}", one(t.audio), one(t.subtitle))
}

/// Whole seconds as the old log wrote them (`Int(capped:)`).
fn whole(seconds: f64) -> i64 {
    if seconds.is_finite() {
        seconds as i64
    } else {
        0
    }
}

fn wall() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

impl<T: HttpTransport + 'static> LegacyPlayback<T> {
    fn message(&self, kind: ReportKind, s: &State, seconds: f64) -> Option<ReportMessage> {
        let ready = s.ready.as_ref()?;
        Some(ReportMessage {
            kind,
            item_id: ready.item.id.clone(),
            plan: ReportPlan {
                play_session_id: ready.plan.play_session_id.clone(),
                media_source_id: ready.plan.media_source_id.clone(),
                method: play_method(ready.plan.method),
            },
            seconds,
            tracks: TrackIndices {
                audio: s.chosen.audio,
                subtitle: s.chosen.subtitle,
            },
            runtime_ms: None,
        })
    }

    fn start_report(&self, s: &State, seconds: f64) {
        self.run.with(|r| r.reported_paused = false);
        if let Some(m) = self.message(ReportKind::Start, s, seconds) {
            self.run.row(format!(
                "Start {} s {} session {} Spuren {}",
                whole(seconds),
                m.item_id,
                m.plan.play_session_id.as_deref().unwrap_or("nil"),
                track_text(&m.tracks)
            ));
            self.run.desk.enqueue(m);
        }
    }

    fn progress_report(&self, s: &State, seconds: f64, paused: bool) {
        let Some(m) = self.message(ReportKind::Progress { paused }, s, seconds) else {
            return;
        };
        let item = m.item_id.clone();
        let text = format!(
            "Progress {} s pausiert {} {} Spuren {}",
            whole(seconds),
            paused,
            item,
            track_text(&m.tracks)
        );
        if self.run.desk.enqueue(m) {
            self.run.row(text);
            self.run.with(|r| r.reported_paused = paused);
        } else {
            self.run
                .row(format!("Fortschritt nach Stopp verworfen {item}"));
        }
    }

    /// The running playback when reporting out of turn is allowed (`reportable()`): the start went out, no switch runs.
    fn reportable(&self, s: &State) -> bool {
        s.ready.is_some() && self.run.switch().messages_allowed() && s.live.snap.start_reported
    }

    /// `Kern.playbackPoint`.
    pub fn playback_point(&self, since: f64) {
        self.locked(|s| s.live.snap.position = since);
    }

    /// `Kern.displayTime`: the time between two ticks; -1 if nothing plays or a switch is in progress.
    pub fn display_time(&self, position: f64, at_push: bool) -> f64 {
        let now = self.run.now();
        if !self.run.switch().messages_allowed() {
            return -1.0;
        }
        self.locked(|s| {
            if s.ready.is_none() {
                return -1.0;
            }
            let since = now - s.live.start;
            playback_tick::time_adopt(&mut s.live.snap, position, at_push, since, now);
            s.live.snap.position
        })
    }

    /// `Kern.controlsChanged`: the overlay after the controls opened or closed (`nichts`, `knopf`, `karte`).
    pub fn controls_changed(&self, opened: bool) -> String {
        self.locked(|s| {
            let Some(ready) = s.ready.as_ref() else {
                return "nichts".to_owned();
            };
            let (sections, has_next) = (ready.sections.clone(), ready.next.is_some());
            s.live.layer.controls(opened, Opening::Deliberate);
            status(&s.live, &sections, has_next).overlay.to_owned()
        })
    }

    /// `Kern.offeringClose`: true if something was closed; then Back must not leave the player.
    pub fn offering_close(&self) -> bool {
        let closed = self.locked(|s| s.ready.is_some() && s.live.layer.close());
        if closed {
            self.run.row("Angebot: geschlossen".to_owned());
        }
        closed
    }

    /// `Kern.offeringPressed`.
    pub fn offering_pressed(&self) {
        self.locked(|s| s.live.layer.pressed());
    }

    /// `Kern.nextAutomaticSet`.
    pub fn next_automatic_set(&self, on: bool) {
        self.run.with(|r| r.next_automatic = on);
    }

    /// `Kern.resumeTarget`: a bit back after a long pause, -1 for none.
    pub fn resume_target(&self, position: f64, in_group: bool) -> f64 {
        let now = self.run.now();
        let since = self.locked(|s| s.live.paused_since.take());
        match pause_jump_back::target(position, since, now, in_group) {
            Some(z) => {
                self.run.row(format!(
                    "Fortsetzen nach {} s Pause \u{2014} vorher auf {} s",
                    whole(now - since.unwrap_or(now)),
                    whole(z)
                ));
                z
            }
            None => -1.0,
        }
    }

    fn slab_known(s: &State, id: &str) -> bool {
        serde_json::from_str::<Vec<serde_json::Value>>(&s.downloads)
            .is_ok_and(|list| list.iter().any(|e| e["id"] == id && e["stand"] == "fertig"))
    }

    /// `Kern.prebufferDue`: whether the next episode is prepared now.
    pub fn prebuffer_due(&self, position: f64, duration: f64, network_favorable: bool) -> bool {
        if !self.run.switch().messages_allowed() {
            return false;
        }
        let preparation = self.run.with(|r| r.preparation.clone());
        self.locked(|s| {
            let Some(ready) = s.ready.as_ref() else {
                return false;
            };
            let Some(next) = ready.next.as_ref() else {
                return false;
            };
            if s.without_next
                || preparation.as_deref() == Some(next.id.as_str())
                || Self::slab_known(s, &next.id)
            {
                return false;
            }
            let credits = ready
                .sections
                .iter()
                .find(|x| x.art == swiftly_playback::sections::Art::Credits)
                .map(|x| x.from);
            prebuffer::now(position, duration, credits, network_favorable)
        })
    }

    /// `Kern.episodePrepare`: the plan of the next episode and the start of its file, once per episode.
    pub async fn episode_prepare(&self) {
        let next = self.locked(|s| {
            s.ready
                .as_ref()
                .and_then(|r| r.next.as_ref())
                .map(|n| n.id.clone())
        });
        let Some(next) = next else { return };
        let begin = self.run.now();
        let first = self.run.with(|r| {
            if r.preparation.as_deref() == Some(next.as_str()) {
                return false;
            }
            r.preparation = Some(next.clone());
            r.prepared = None;
            true
        });
        if !first {
            return;
        }
        let ms = |now: f64| whole((now - begin) * 1000.0);
        let Ok((ready, display)) = self.fetch(&next, "").await else {
            self.run
                .row(format!("Vorpuffer: Plan fuer {next} nicht geholt"));
            return;
        };
        let applies = self.locked(|s| {
            s.ready
                .as_ref()
                .and_then(|r| r.next.as_ref())
                .is_some_and(|n| n.id == next)
        }) && self
            .run
            .with(|r| r.preparation.as_deref() == Some(next.as_str()));
        if !applies {
            return;
        }
        let (address, method) = (ready.plan.url.clone(), ready.plan.method);
        let moment = self.run.now();
        self.run.row(format!(
            "Vorpuffer: Plan bereit nach {} ms \u{b7} {}",
            ms(moment),
            method.raw_value()
        ));
        self.run.with(|r| {
            r.prepared = Some(Prepared {
                ready,
                display,
                moment,
            })
        });
        if !prebuffer::start_load(&address, method) {
            return;
        }
        let Ok(url) = address.parse() else { return };
        let request = HttpRequest {
            method: Method::Get,
            url,
            headers: vec![("Range".to_owned(), prebuffer::range_header())],
            body: None,
            timeout: None,
            keep_method: false,
        };
        match self.transport.send(request).await {
            Ok(answer) => self.run.row(format!(
                "Vorpuffer: Anfang vorgeladen {} KB nach {} ms",
                answer.body.len() / 1024,
                ms(self.run.now())
            )),
            Err(_) => self
                .run
                .row("Vorpuffer: Anfang nicht geladen (Fehler)".to_owned()),
        }
    }

    fn tick_out(
        &self,
        job: playback_tick::WorkItem,
        live: &Live,
        ready: &ReadyStart,
        advance: bool,
        auto_skip: bool,
    ) -> String {
        let st = status(live, &ready.sections, ready.next.is_some());
        serde_json::to_string(&TickOut {
            loading_screen_gone: job.loading_screen_gone,
            tracks_apply: job.tracks_apply,
            position: live.snap.position,
            offering: st.art,
            to: st.to,
            offering_text: if st.text.is_empty() {
                String::new()
            } else {
                Translator::new(self.host.locale.clone()).t(st.text)
            },
            overlay: st.overlay,
            countdown: st.share,
            countdown_rest: live.layer.countdown_rest(),
            countdown_length: live.layer.countdown_length(),
            advance,
            auto_skip,
            button_countdown: live.layer.skip_share(),
        })
        .unwrap_or_else(|_| "{}".to_owned())
    }

    /// `Kern.playbackTick`: every 500 ms. Start and progress go to the server from here; what the UI does comes back.
    #[allow(clippy::too_many_arguments)]
    pub fn playback_tick(
        &self,
        duration: f64,
        position: f64,
        shows_image: bool,
        running: bool,
        has_audio_tracks: bool,
        at_push: bool,
        auto_skip: bool,
    ) -> String {
        if !self.run.switch().messages_allowed() {
            return "{}".to_owned();
        }
        let now = self.run.now();
        let automatic = self.run.with(|r| r.next_automatic);
        let mut report: Option<(bool, f64, bool)> = None;
        let text = self.locked(|s| {
            let Some(ready) = s.ready.clone() else {
                return "{}".to_owned();
            };
            let reading = Reading {
                duration,
                position,
                good_point: position,
                shows_image,
                seeks_to_start: false,
                running,
                has_audio_tracks,
            };
            let live = &mut s.live;
            live.layer.auto_skip = auto_skip;
            let job = playback_tick::compute(
                &mut live.snap,
                &reading,
                false,
                at_push,
                now - live.start,
                now,
            );
            let spot = live.snap.position;
            let sections = &ready.sections;
            let has_next = ready.next.is_some() && !s.without_next;
            let ready_countdown = catch_up(
                live,
                sections,
                has_next,
                automatic,
                running && shows_image && !at_push,
                TICK_LENGTH.as_secs_f64(),
                episodes_end::at_end(spot, live.snap.duration) && !at_push,
            );
            // Auto-skip: the offer was shown and its countdown ran out; the UI now presses the button.
            let auto_step = live.layer.take_auto_skip();
            if ready_countdown {
                self.run.row("Angebot: Countdown abgelaufen".to_owned());
            }
            let proceed = has_next
                && (ready_countdown
                    || (live.layer.next_at_end()
                        && episodes_end::advance(
                            spot,
                            live.snap.duration,
                            now - live.start,
                            live.layer.card_counts(),
                        )));
            if job.start_report {
                report = Some((true, spot, false));
            } else if job.progress_report {
                report = Some((false, spot, !live.snap.running));
            }
            let mut ready_view = ready;
            if s.without_next {
                ready_view.next = None;
            }
            self.tick_out(job, &s.live, &ready_view, proceed, auto_step)
        });
        if let Some((start, spot, paused)) = report {
            self.locked(|s| {
                if start {
                    self.start_report(s, spot);
                } else {
                    self.progress_report(s, spot, paused);
                }
            });
        }
        text
    }

    /// `Kern.runStateReported`: paused or resumed, reported at once; once per change.
    pub fn run_state_reported(&self, running: bool, position: f64) {
        let now = self.run.now();
        self.locked(|s| {
            if s.ready.is_some() {
                if running {
                    s.live.paused_since = None;
                } else if s.live.paused_since.is_none() {
                    s.live.paused_since = Some(now);
                }
            }
            if !self.reportable(s) || self.run.with(|r| r.reported_paused) != running {
                return;
            }
            self.run.row(format!(
                "sofort: {} bei {} s",
                if running { "weiter" } else { "Pause" },
                whole(position)
            ));
            self.progress_report(s, position, !running);
        });
    }

    /// `Kern.jumpReported`: a seek, reported and shown at once.
    pub fn jump_reported(&self, target: f64) -> String {
        let now = self.run.now();
        let automatic = self.run.with(|r| r.next_automatic);
        self.locked(|s| {
            let Some(ready) = s.ready.clone() else {
                return "{}".to_owned();
            };
            playback_tick::jumped(&mut s.live.snap, target, now);
            s.live.layer.jumped();
            let has_next = ready.next.is_some() && !s.without_next;
            let _ = catch_up(
                &mut s.live,
                &ready.sections,
                has_next,
                automatic,
                false,
                0.0,
                false,
            );
            if self.reportable(s) {
                let paused = self.run.with(|r| r.reported_paused);
                self.progress_report(s, s.live.snap.position.max(0.0), paused);
            }
            self.tick_out(
                playback_tick::WorkItem::default(),
                &s.live,
                &ready,
                false,
                false,
            )
        })
    }

    /// `Kern.backgroundReport`: the activity goes to the background, report now.
    pub fn background_report(&self, position: f64, paused: bool) {
        self.locked(|s| {
            if !self.reportable(s) {
                return;
            }
            self.run.row(format!(
                "Hintergrund: {} s pausiert {paused}",
                whole(position)
            ));
            self.progress_report(s, position, paused);
        });
    }

    fn stop_message(&self, s: &State, seconds: f64) -> Option<ReportMessage> {
        self.message(ReportKind::Stop, s, seconds)
    }

    /// `Kern.playbackEnd`: stopped on close; empty if reported, otherwise the catch-up report as JSON.
    pub async fn playback_end(&self, position: f64) -> String {
        let change = self.run.switch();
        self.locked(|s| {
            if s.ordered.as_ref().is_some_and(|(id, _)| {
                Some(id.as_str()) == s.ready.as_ref().map(|r| r.item.id.as_str())
            }) {
                s.ordered = None;
            }
        });
        if change.phase() == Phase::Closed {
            return String::new();
        }
        // The latch closes (`EpisodeSwitch.close`); a start still on its way goes first, the stop after it.
        let spot_key = self.locked(|s| {
            s.ready
                .as_ref()
                .map(|r| StopLock::key(&r.item.id, r.plan.play_session_id.as_deref()))
        });
        let message = self.locked(|s| {
            let live_spot = s.live.snap.position;
            let same = spot_key
                == s.ready
                    .as_ref()
                    .map(|r| StopLock::key(&r.item.id, r.plan.play_session_id.as_deref()));
            let spot = if same { position } else { live_spot };
            self.stop_message(s, spot)
        });
        let user = self.account.user_id.clone();
        let out = Arc::new(Mutex::new(String::new()));
        let cell = Arc::clone(&out);
        let run = Arc::clone(&self.run);
        let deferred = change.close(Box::new(move || {
            Box::pin(async move {
                if let Some(m) = message {
                    *cell.lock().unwrap_or_else(PoisonError::into_inner) =
                        run.stop_report(m, user).await;
                }
            })
        }));
        if let Some(stop) = deferred {
            stop().await;
        }
        self.locked(|s| {
            s.ready = None;
            s.display = None;
        });
        out.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// The stops since the last pickup (for `stoppsProcess`): item, account, ticks, moment, whether the server took it.
    pub fn stops_take(&self) -> Vec<Stop> {
        self.run.with(|r| std::mem::take(&mut r.stops))
    }

    /// The rows for logcat since the last pickup (`logFetch`).
    pub fn log_fetch(&self) -> String {
        self.run.with(|r| std::mem::take(&mut r.rows)).join("\n")
    }

    fn switch_answer(
        result: &str,
        plan: Option<String>,
        error: Option<String>,
        pending: Option<String>,
    ) -> String {
        let mut o = serde_json::Map::new();
        o.insert("ergebnis".into(), json!(result));
        if let Some(p) = plan {
            o.insert("spielplan".into(), json!(p));
        }
        if let Some(e) = error {
            o.insert("fehler".into(), json!(e));
        }
        if let Some(p) = pending {
            o.insert("nachmeldung".into(), json!(p));
        }
        serde_json::Value::Object(o).to_string()
    }

    fn outcome_word(o: Outcome) -> &'static str {
        match o {
            Outcome::Switched => "gewechselt",
            Outcome::Locked => "gesperrt",
            Outcome::Cancelled => "abgebrochen",
            Outcome::Failed => "gescheitert",
        }
    }

    /// The same flow for episode and quality switch (`EpisodeSwitch.execute`): the old playback stays until the plan is there.
    async fn switch_to(
        &self,
        target: &str,
        position: f64,
        prepared: Option<(ReadyStart, PlayDisplay)>,
        quality: bool,
    ) -> String {
        let change = self.run.switch();
        let Some((old, old_display)) = self.locked(|s| s.ready.clone().zip(s.display.clone()))
        else {
            return Self::switch_answer("gescheitert", None, None, None);
        };
        let _ = old_display;
        let user = self.account.user_id.clone();
        let pending = Arc::new(Mutex::new(String::new()));
        let error = Arc::new(Mutex::new(None::<String>));
        let plan_text = Arc::new(Mutex::new(None::<String>));
        let fetched = Arc::new(Mutex::new(None::<(ReadyStart, PlayDisplay)>));
        let stop_msg = self.locked(|s| self.stop_message(s, position));
        let me: &Self = self;
        let steps = Steps {
            stop_now: Box::new({
                let pending = Arc::clone(&pending);
                let user = user.clone();
                move || {
                    Box::pin(async move {
                        if let Some(m) = stop_msg {
                            *pending.lock().unwrap_or_else(PoisonError::into_inner) =
                                Arc::clone(&me.run).stop_report(m, user).await;
                        }
                    })
                }
            }),
            plan_out: Box::new({
                let error = Arc::clone(&error);
                let fetched = Arc::clone(&fetched);
                let target = target.to_owned();
                move || {
                    Box::pin(async move {
                        let result = match prepared {
                            Some(p) => Ok(p),
                            None => me.fetch(&target, "").await,
                        };
                        match result {
                            Ok(p) => {
                                *fetched.lock().unwrap_or_else(PoisonError::into_inner) =
                                    Some(p.clone());
                                Some(p)
                            }
                            Err(e) => {
                                *error.lock().unwrap_or_else(PoisonError::into_inner) =
                                    Some(crate::tile::Words::new(me.host.locale.clone()).error(&e));
                                None
                            }
                        }
                    })
                }
            }),
            apply: Box::new({
                let plan_text = Arc::clone(&plan_text);
                move |p: &(ReadyStart, PlayDisplay)| {
                    let text = me.plan_json(&p.0, &p.1).ok();
                    me.install(p.0.clone(), p.1.clone());
                    let now = me.run.now();
                    me.locked(|s| {
                        playback_tick::new_title(&mut s.live.snap, true);
                        s.live.start = now;
                        if quality && position > 0.0 {
                            playback_tick::jumped(&mut s.live.snap, position, now);
                        }
                    });
                    *plan_text.lock().unwrap_or_else(PoisonError::into_inner) = text;
                }
            }),
            start: Box::new(move |_p: (ReadyStart, PlayDisplay)| {
                Box::pin(async move {
                    me.locked(|s| me.start_report(s, if quality { position } else { 0.0 }));
                })
            }),
            failed: Box::new({
                let old_key = StopLock::key(&old.item.id, old.plan.play_session_id.as_deref());
                move || {
                    me.locked(|s| {
                        if s.ready
                            .as_ref()
                            .map(|r| StopLock::key(&r.item.id, r.plan.play_session_id.as_deref()))
                            == Some(old_key)
                        {
                            s.live.snap.start_reported = false;
                        }
                    });
                }
            }),
        };
        let outcome = change.execute(steps).await;
        let _ = fetched;
        self.run.row(if quality {
            format!(
                "Qualit\u{e4}t {} \u{2192} {} bei {} s",
                Self::outcome_word(outcome),
                old.item.id,
                whole(position)
            )
        } else {
            format!("Wechsel {} \u{2192} {target}", Self::outcome_word(outcome))
        });
        let pending = pending
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        let pending = (!pending.is_empty()).then_some(pending);
        match outcome {
            Outcome::Switched => {
                let plan = plan_text
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                Self::switch_answer("gewechselt", plan, None, pending)
            }
            Outcome::Failed => {
                let e = error.lock().unwrap_or_else(PoisonError::into_inner).clone();
                Self::switch_answer(
                    "gescheitert",
                    None,
                    Some(e.unwrap_or_else(|| "Nicht verf\u{fc}gbar".to_owned())),
                    pending,
                )
            }
            other => Self::switch_answer(Self::outcome_word(other), None, None, pending),
        }
    }

    /// `Kern.qualitySwitch`: same title, replanned at the same position (the bitrate limit was set beforehand).
    pub async fn quality_switch(&self, position: f64) -> String {
        self.run.with(|r| {
            r.prepared = None;
            r.preparation = None;
        });
        let Some(id) = self.locked(|s| s.ready.as_ref().map(|r| r.item.id.clone())) else {
            return Self::switch_answer("gescheitert", None, None, None);
        };
        self.switch_to(&id, position, None, true).await
    }

    /// `Kern.episodeSwitch`: `id` empty means the queued next episode.
    pub async fn episode_switch(&self, id: &str, position: f64) -> String {
        let target = if id.is_empty() {
            self.locked(|s| {
                s.ready
                    .as_ref()
                    .and_then(|r| r.next.as_ref())
                    .map(|n| n.id.clone())
            })
        } else {
            Some(id.to_owned())
        };
        let Some(target) = target else {
            return Self::switch_answer("gescheitert", None, None, None);
        };
        let now = self.run.now();
        let prepared = self.run.with(|r| {
            let p = r.prepared.take();
            p.filter(|p| p.ready.item.id == target && prebuffer::fresh_value(p.moment, now))
                .map(|p| (p.ready, p.display))
        });
        self.run.row(format!(
            "Wechsel Beginn \u{2192} {target} \u{b7} Plan vorbereitet: {}",
            if prepared.is_some() { "ja" } else { "nein" }
        ));
        self.switch_to(&target, position, prepared, false).await
    }
}
