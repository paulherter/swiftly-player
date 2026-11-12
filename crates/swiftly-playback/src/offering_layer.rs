//! Port of `Packages/JellyfinKit/Sources/JellyfinKit/OfferingLayer.swift`: the layer above the
//! picture where "Skip intro" and "Next episode" appear by themselves (`OfferingLayer`), the
//! continuous fill clock (`FillClock`), the auto-advance setting (`Advance`) and the account
//! defaults (`AccountPreGift`).
//!
//! Time comes in as elapsed seconds per tick, not as a clock, so every sequence is testable
//! without waiting. `FillClock` takes `now` as `f64` seconds on any consistent clock (Swift
//! used `Date()`).

use serde::{Deserialize, Deserializer};
use swiftly_rules::download_quality::DownloadQuality;
use swiftly_rules::download_right::DownloadPermission;
use swiftly_rules::whole_number::capped;

use crate::sections::ButtonOffering;

/// The card's "Next episode" fill runs this long at most; shorter if the file ends sooner
/// (OfferingLayer.swift:46).
pub const COUNTDOWN: f64 = 7.0;

/// How long after the calculated end of the fill the switch happens: one animation tick (half
/// a second) plus 0.4 s of rest (OfferingLayer.swift:53).
pub const POST_RUN: f64 = 0.5 + 0.4;

/// How long "Skip intro" (and any other skip) is shown above the picture without controls,
/// counted from the start of the section, only while playing (OfferingLayer.swift:58).
pub const BUTTON_DURATION: f64 = 6.0;

/// What is shown above the picture (OfferingLayer.swift:60-67).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum OfferingPresentation {
    /// Nothing.
    Nothing,
    /// The skip button.
    Button(ButtonOffering),
    /// The "Next episode" card; `share` runs from 0 to 1, how far the countdown is.
    Card {
        /// Fill, 0 to 1.
        share: f64,
    },
}

impl OfferingPresentation {
    /// Whether anything is shown (OfferingLayer.swift:66).
    pub fn visible(&self) -> bool {
        *self != Self::Nothing
    }
}

/// How the controls opened (OfferingLayer.swift:89-96).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Opening {
    /// Tap, click on the picture, key, remote: cancels the card.
    Deliberate,
    /// Pointer movement (or mere sync with the view's state): cancels nothing and does not
    /// turn deliberately opened controls back into "incidental".
    Beside,
}

/// What the remembered state applies to; if it changes, everything starts over
/// (OfferingLayer.swift:70-74).
#[derive(Debug, Clone, Copy, PartialEq)]
enum Occasion {
    Nobody,
    Skip { to: f64 },
    NextEpisode,
}

/// The layer above the picture (OfferingLayer.swift:41-268). A skip button is shown for
/// [`BUTTON_DURATION`] seconds from the start of the section, afterwards only with the
/// controls open. "Next episode" is a card with a countdown that exists only with an outro
/// section (`card_due`).
#[derive(Debug, Clone, PartialEq)]
pub struct OfferingLayer {
    occasion: Occasion,
    offering: ButtonOffering,
    closed: bool,
    run: f64,
    /// How long the skip button has been shown (OfferingLayer.swift:81).
    button_run: f64,
    length: f64,
    triggered: bool,
    controls_open: bool,
    /// Open, but only through pointer movement; the card keeps running.
    only_beside: bool,
    /// The countdown was cancelled; this episode then no longer advances by itself at the end
    /// of the file either (OfferingLayer.swift:104).
    next_cancelled: bool,
    /// The card waits while the controls are open (episode card, iPhone and TV): it goes
    /// away, the countdown pauses, and it comes back when the controls close. Off: the old
    /// behaviour where deliberately opened controls cancel the card (OfferingLayer.swift:114).
    pub card_waits_controls: bool,
    /// "Skip intro and outro automatically": the skip button then runs a countdown (its fill)
    /// over [`BUTTON_DURATION`] and the platform presses it when it ends
    /// ([`Self::take_auto_skip`]). Dismissing ([`Self::close`]) cancels it. Off: the button
    /// waits for the user.
    pub auto_skip: bool,
    /// The skip countdown ran out; waiting for the platform to press the button.
    auto_skip_due: bool,
}

impl Default for OfferingLayer {
    fn default() -> Self {
        Self::new()
    }
}

impl OfferingLayer {
    /// `init()` (OfferingLayer.swift:106).
    pub fn new() -> Self {
        Self {
            occasion: Occasion::Nobody,
            offering: ButtonOffering::Nobody,
            closed: false,
            run: 0.0,
            button_run: 0.0,
            length: COUNTDOWN,
            triggered: false,
            controls_open: false,
            only_beside: false,
            next_cancelled: false,
            card_waits_controls: false,
            auto_skip: false,
            auto_skip_due: false,
        }
    }

    /// The controls cover the card: open, and not only through the pointer
    /// (OfferingLayer.swift:99).
    fn controls_cover(&self) -> bool {
        self.controls_open && !self.only_beside
    }

    /// The countdown was cancelled (OfferingLayer.swift:104).
    pub fn next_cancelled(&self) -> bool {
        self.next_cancelled
    }

    /// The card is currently counting its countdown (visible or covered by the controls); then
    /// advancing belongs to it, not to the end of the file (OfferingLayer.swift:121-123).
    pub fn card_counts(&self) -> bool {
        self.occasion == Occasion::NextEpisode && !self.closed && !self.triggered
    }

    /// After a jump the countdown starts over (OfferingLayer.swift:127-130).
    pub fn jumped(&mut self) {
        if self.occasion != Occasion::NextEpisode || self.closed || self.triggered {
            return;
        }
        self.run = 0.0;
    }

    /// One tick (OfferingLayer.swift:144-177). `true` means: switch to the next episode now,
    /// exactly once per episode. Also call directly after a jump with `elapsed: 0`.
    ///
    /// - `new`: what `SectionLogic` currently offers.
    /// - `card_due`: `SectionLogic::card_due`.
    /// - `running`: no countdown runs while stopped.
    /// - `elapsed`: seconds since the last tick.
    /// - `countdown`: how long the fill lasts if the card opens now (default [`COUNTDOWN`]).
    /// - `at_end`: at the end of the file it keeps counting although nothing plays (default
    ///   `false`).
    pub fn tick(
        &mut self,
        new: ButtonOffering,
        card_due: bool,
        running: bool,
        elapsed: f64,
        countdown: f64,
        at_end: bool,
    ) -> bool {
        let new_occasion = match new {
            ButtonOffering::Skip { to, .. } => Occasion::Skip { to },
            ButtonOffering::NextEpisode => {
                if card_due {
                    Occasion::NextEpisode
                } else {
                    Occasion::Nobody
                }
            }
            ButtonOffering::Nobody => Occasion::Nobody,
        };
        if new_occasion != self.occasion {
            // A skip countdown that fired belongs to its section; a new offer starts clean.
            if matches!(self.occasion, Occasion::Skip { .. }) {
                self.triggered = false;
                self.auto_skip_due = false;
            }
            self.occasion = new_occasion;
            self.run = 0.0;
            self.button_run = 0.0;
            self.length = countdown.max(0.5);
            self.closed = false;
        }
        self.offering = new;

        if matches!(self.occasion, Occasion::Skip { .. })
            && running
            && elapsed > 0.0
            && !self.closed
        {
            self.button_run += elapsed;
            // The skip countdown ran out (fill full plus the rest of the last tick).
            if self.auto_skip && !self.triggered && self.button_run >= BUTTON_DURATION + POST_RUN {
                self.triggered = true;
                self.auto_skip_due = true;
            }
        }

        // At the end of the file it keeps counting although nothing plays, otherwise the card
        // would stay forever after a jump to the end.
        if !(running || at_end)
            || elapsed.is_nan()
            || elapsed <= 0.0
            || self.occasion != Occasion::NextEpisode
            || self.closed
            || self.controls_cover()
            || self.triggered
        {
            return false;
        }
        self.run += elapsed;
        if self.run >= self.length + POST_RUN {
            self.triggered = true;
            return true;
        }
        false
    }

    /// The controls open or close; call immediately, not on the next tick
    /// (OfferingLayer.swift:185-202). A deliberate open cancels a "Next episode" card (unless
    /// [`Self::card_waits_controls`]), even if the controls were already open through the
    /// pointer; `Opening::Beside` lets it run.
    pub fn controls(&mut self, opened: bool, through: Opening) {
        if !opened {
            self.controls_open = false;
            self.only_beside = false;
            return;
        }
        match through {
            Opening::Deliberate => {
                if self.controls_cover() {
                    return;
                }
                if self.occasion == Occasion::NextEpisode && !self.card_waits_controls {
                    self.close();
                }
                self.controls_open = true;
                self.only_beside = false;
            }
            Opening::Beside => {
                if self.controls_open {
                    return;
                }
                self.controls_open = true;
                self.only_beside = true;
            }
        }
    }

    /// What is shown above the picture (OfferingLayer.swift:208-216).
    pub fn display(&self) -> OfferingPresentation {
        if self.occasion == Occasion::Nobody || self.closed || self.triggered {
            return OfferingPresentation::Nothing;
        }
        if self.occasion == Occasion::NextEpisode {
            if self.controls_cover() {
                return OfferingPresentation::Nothing;
            }
            return OfferingPresentation::Card {
                share: (self.run / self.length).min(1.0),
            };
        }
        if self.button_expired() {
            return OfferingPresentation::Nothing;
        }
        OfferingPresentation::Button(self.offering)
    }

    /// The skip button has had its time without controls and the controls are closed
    /// (OfferingLayer.swift:220-222).
    fn button_expired(&self) -> bool {
        // With auto-skip the button stays until its countdown (fill) has run out.
        let shown = if self.auto_skip {
            BUTTON_DURATION + POST_RUN
        } else {
            BUTTON_DURATION
        };
        self.button_run >= shown && !self.controls_open
    }

    /// The fill of the skip button's countdown, 0 to 1: only with auto-skip on and a skip
    /// button showing; `None` otherwise (the button then just waits for the user).
    pub fn skip_share(&self) -> Option<f64> {
        if !self.auto_skip
            || self.closed
            || self.triggered
            || !matches!(self.occasion, Occasion::Skip { .. })
        {
            return None;
        }
        Some((self.button_run / BUTTON_DURATION).min(1.0))
    }

    /// `true` exactly once when the skip countdown has run out: the platform then does what a
    /// press on the button does.
    pub fn take_auto_skip(&mut self) -> bool {
        std::mem::take(&mut self.auto_skip_due)
    }

    /// How long the fill of the currently shown card runs (OfferingLayer.swift:225).
    pub fn countdown_length(&self) -> f64 {
        self.length
    }

    /// Seconds until the switch, for VoiceOver and labels (OfferingLayer.swift:228-230).
    pub fn countdown_rest(&self) -> i64 {
        capped((self.length - self.run.min(self.length)).ceil())
    }

    /// Whether playback advances by itself at the end of the file: only with a card, and only
    /// if it is not cancelled (OfferingLayer.swift:234-236).
    pub fn next_at_end(&self) -> bool {
        self.occasion == Occasion::NextEpisode && !self.next_cancelled
    }

    /// Back, or focus moves elsewhere: the overlay is gone until a new offer arrives; a
    /// running countdown is cancelled (OfferingLayer.swift:244-252). Returns `true` if there
    /// was something to close; Back has then done its job here and must not leave the player.
    pub fn close(&mut self) -> bool {
        if self.occasion == Occasion::Nobody || self.closed || self.triggered {
            return false;
        }
        // A hidden button is already gone: Back then belongs to the player.
        if matches!(self.occasion, Occasion::Skip { .. }) && self.button_expired() {
            return false;
        }
        if self.occasion == Occasion::NextEpisode {
            self.next_cancelled = true;
        }
        self.closed = true;
        true
    }

    /// The button was pressed: the overlay goes, the platform executes
    /// (OfferingLayer.swift:255-257).
    pub fn pressed(&mut self) {
        self.closed = true;
    }

    /// A new episode plays: forget everything, including a cancel. Only whether the controls
    /// are open (and `card_waits_controls`) stays (OfferingLayer.swift:261-267).
    pub fn new_episode(&mut self) {
        let opened = self.controls_open;
        let beside = self.only_beside;
        let waits = self.card_waits_controls;
        let auto = self.auto_skip;
        *self = Self::new();
        self.card_waits_controls = waits;
        self.auto_skip = auto;
        self.controls_open = opened;
        self.only_beside = beside;
    }
}

/// The card's fill as continuous motion (OfferingLayer.swift:277-306). While stopped it holds
/// exactly where it was and continues from there; it never jumps back.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FillClock {
    base: f64,
    since: Option<f64>,
    length: f64,
}

impl Default for FillClock {
    fn default() -> Self {
        Self::new()
    }
}

impl FillClock {
    /// `init()` (OfferingLayer.swift:282).
    pub fn new() -> Self {
        Self {
            base: 0.0,
            since: None,
            length: COUNTDOWN,
        }
    }

    /// Call on every tick and on every change (OfferingLayer.swift:286-299). `share` is the
    /// layer's fraction; `None` means no card, and the clock is reset. `now` is seconds on any
    /// consistent clock.
    pub fn set(&mut self, share: Option<f64>, running: bool, length: f64, now: f64) {
        let Some(share) = share else {
            *self = Self::new();
            return;
        };
        self.length = length.max(0.5);
        if running {
            if self.since.is_none() {
                self.base = self.base.max(share);
                self.since = Some(now);
            }
        } else if self.since.is_some() {
            self.base = self.share(now);
            self.since = None;
        }
    }

    /// The fraction at this moment, 0 to 1 (OfferingLayer.swift:302-305).
    pub fn share(&self, now: f64) -> f64 {
        let run = self.since.map_or(0.0, |s| (now - s).max(0.0));
        (self.base + run / self.length).min(1.0)
    }
}

/// Whether playback switches to the next episode by itself at the end (OfferingLayer.swift:315-319):
/// the own choice, then the Jellyfin account's `EnableNextEpisodeAutoPlay`, then "on".
pub struct Advance;

impl Advance {
    /// `applies(ownSelection:account:)`.
    pub fn applies(own_selection: Option<bool>, account: Option<bool>) -> bool {
        own_selection.or(account).unwrap_or(true)
    }
}

/// What counts from the Jellyfin account: `GET /Users/{id}`, fields `Configuration` and
/// `Policy` (OfferingLayer.swift:325-388). Each block is read on its own.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AccountPreGift {
    /// `Configuration.EnableNextEpisodeAutoPlay`.
    pub next_episode_automatic: Option<bool>,
    /// `Policy.EnableContentDownloading`; `None` if the server says nothing.
    pub downloads_allowed: Option<bool>,
    /// `Policy.EnableVideoPlaybackTranscoding`; `None` if the server says nothing.
    pub convert_allowed: Option<bool>,
    /// `Policy.EnableAudioPlaybackTranscoding`; `None` if the server says nothing.
    pub audio_convert_allowed: Option<bool>,
}

impl AccountPreGift {
    /// `init(nextEpisodeAutomatic:downloadsAllowed:convertAllowed:audioConvertAllowed:)`
    /// (OfferingLayer.swift:338).
    pub fn new(
        next_episode_automatic: Option<bool>,
        downloads_allowed: Option<bool>,
        convert_allowed: Option<bool>,
        audio_convert_allowed: Option<bool>,
    ) -> Self {
        Self {
            next_episode_automatic,
            downloads_allowed,
            convert_allowed,
            audio_convert_allowed,
        }
    }

    /// Whether a smaller quality is offered when downloading (OfferingLayer.swift:347-349).
    pub fn download_quality_selectable(&self) -> bool {
        DownloadQuality::selectable(self.convert_allowed, self.audio_convert_allowed)
    }

    /// The decision lives in `DownloadPermission` (OfferingLayer.swift:353).
    pub fn download_permission(&self) -> DownloadPermission {
        DownloadPermission::from_server(self.downloads_allowed)
    }
}

impl<'de> Deserialize<'de> for AccountPreGift {
    /// OfferingLayer.swift:366-387. A missing block leaves its fields `None`; a wrongly typed
    /// field fails the decode, like `decodeIfPresent(Bool.self)`. (A `null` block is treated as
    /// missing here; Swift would throw. The server never sends that.)
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Configuration {
            #[serde(rename = "EnableNextEpisodeAutoPlay", default)]
            next: Option<bool>,
        }
        #[derive(Deserialize)]
        struct Policy {
            #[serde(rename = "EnableContentDownloading", default)]
            download: Option<bool>,
            #[serde(rename = "EnableVideoPlaybackTranscoding", default)]
            convert: Option<bool>,
            #[serde(rename = "EnableAudioPlaybackTranscoding", default)]
            audio_convert: Option<bool>,
        }
        #[derive(Deserialize)]
        struct Outer {
            #[serde(rename = "Configuration", default)]
            configuration: Option<Configuration>,
            #[serde(rename = "Policy", default)]
            policy: Option<Policy>,
        }
        let outer = Outer::deserialize(deserializer)?;
        Ok(Self {
            next_episode_automatic: outer.configuration.and_then(|c| c.next),
            downloads_allowed: outer.policy.as_ref().and_then(|p| p.download),
            convert_allowed: outer.policy.as_ref().and_then(|p| p.convert),
            audio_convert_allowed: outer.policy.as_ref().and_then(|p| p.audio_convert),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sections::Art;
    use swiftly_rules::episodes_end;

    fn intro() -> ButtonOffering {
        ButtonOffering::Skip {
            to: 90.0,
            art: Art::IntroSegment,
        }
    }

    /// Ticks of half a second each, like `PlaybackTick`. Returns how often it triggered.
    fn running_count(
        e: &mut OfferingLayer,
        seconds: f64,
        offering: ButtonOffering,
        card: bool,
        running: bool,
        countdown: f64,
    ) -> usize {
        let mut triggered = 0;
        for _ in 0..((seconds * 2.0) as usize) {
            if e.tick(offering, card, running, 0.5, countdown, false) {
                triggered += 1;
            }
        }
        triggered
    }

    /// `runningCount` with all defaults (`card: false, running: true, countdown: 7`).
    fn rc(e: &mut OfferingLayer, seconds: f64, offering: ButtonOffering) -> usize {
        running_count(e, seconds, offering, false, true, COUNTDOWN)
    }

    /// `runningCount(..., card: true)`.
    fn rc_card(e: &mut OfferingLayer, seconds: f64) -> usize {
        running_count(
            e,
            seconds,
            ButtonOffering::NextEpisode,
            true,
            true,
            COUNTDOWN,
        )
    }

    fn open(e: &mut OfferingLayer) {
        e.controls(true, Opening::Deliberate);
    }
    fn shut(e: &mut OfferingLayer) {
        e.controls(false, Opening::Deliberate);
    }

    // MARK: OfferingLayerTests (21)

    #[test]
    fn skip_fade_out() {
        let mut e = OfferingLayer::new();
        rc(&mut e, 5.5, intro());
        assert_eq!(e.display(), OfferingPresentation::Button(intro()));
        rc(&mut e, 0.5, intro());
        assert_eq!(
            e.display(),
            OfferingPresentation::Nothing,
            "nach sechs Sekunden ohne Drücken weg"
        );
        rc(&mut e, 60.0, intro());
        assert_eq!(
            e.display(),
            OfferingPresentation::Nothing,
            "und kommt ohne Steuerung nicht wieder"
        );
        assert!(!e.close(), "Zurück gehört dann dem Player");
    }

    #[test]
    fn skip_with_controls() {
        let mut e = OfferingLayer::new();
        rc(&mut e, 8.0, intro());
        assert_eq!(e.display(), OfferingPresentation::Nothing);
        open(&mut e);
        assert_eq!(
            e.display(),
            OfferingPresentation::Button(intro()),
            "Steuerung auf: Knopf da"
        );
        rc(&mut e, 10.0, intro());
        assert_eq!(
            e.display(),
            OfferingPresentation::Button(intro()),
            "solange sie offen ist"
        );
        shut(&mut e);
        assert_eq!(
            e.display(),
            OfferingPresentation::Nothing,
            "Steuerung zu: Knopf weg"
        );
        e.controls(true, Opening::Beside);
        assert_eq!(
            e.display(),
            OfferingPresentation::Button(intro()),
            "auch mit dem Zeiger geöffnet"
        );
        shut(&mut e);
        assert_eq!(e.display(), OfferingPresentation::Nothing);
        open(&mut e);
        rc(&mut e, 1.0, ButtonOffering::Nobody);
        assert_eq!(
            e.display(),
            OfferingPresentation::Nothing,
            "der Abschnitt ist vorbei"
        );
    }

    #[test]
    fn button_time() {
        let mut e = OfferingLayer::new();
        open(&mut e);
        rc(&mut e, 7.0, intro());
        assert_eq!(e.display(), OfferingPresentation::Button(intro()));
        shut(&mut e);
        assert_eq!(
            e.display(),
            OfferingPresentation::Nothing,
            "Zu nach Ablauf nimmt ihn mit"
        );

        let mut p = OfferingLayer::new();
        rc(&mut p, 3.0, intro());
        running_count(&mut p, 30.0, intro(), false, false, COUNTDOWN);
        assert_eq!(
            p.display(),
            OfferingPresentation::Button(intro()),
            "Pause hält die Zeit an"
        );
        rc(&mut p, 3.0, intro());
        assert_eq!(p.display(), OfferingPresentation::Nothing);
    }

    #[test]
    fn new_section() {
        let mut e = OfferingLayer::new();
        rc(&mut e, 8.0, intro());
        assert_eq!(e.display(), OfferingPresentation::Nothing);
        rc(&mut e, 1.0, ButtonOffering::Nobody);
        let look_back = ButtonOffering::Skip {
            to: 300.0,
            art: Art::LookBack,
        };
        rc(&mut e, 1.0, look_back);
        assert_eq!(e.display(), OfferingPresentation::Button(look_back));
    }

    #[test]
    fn immediate_post_jump() {
        let mut e = OfferingLayer::new();
        rc(&mut e, 2.0, ButtonOffering::Nobody);
        let _ = e.tick(intro(), false, true, 0.0, COUNTDOWN, false);
        assert_eq!(e.display(), OfferingPresentation::Button(intro()));
        let _ = e.tick(ButtonOffering::Nobody, false, true, 0.0, COUNTDOWN, false);
        assert_eq!(e.display(), OfferingPresentation::Nothing);
    }

    #[test]
    fn controls_open_close() {
        let mut e = OfferingLayer::new();
        rc(&mut e, 1.0, intro());
        open(&mut e);
        assert_eq!(e.display(), OfferingPresentation::Button(intro()));
        rc(&mut e, 1.0, intro());
        shut(&mut e);
        rc(&mut e, 1.0, intro());
        assert_eq!(e.display(), OfferingPresentation::Button(intro()));
        open(&mut e);
        shut(&mut e);
        assert_eq!(e.display(), OfferingPresentation::Button(intro()));
        rc(&mut e, 1.0, ButtonOffering::Nobody);
        assert_eq!(
            e.display(),
            OfferingPresentation::Nothing,
            "erst das Ende des Abschnitts nimmt ihn weg"
        );
    }

    #[test]
    fn controls_before_open() {
        let mut e = OfferingLayer::new();
        open(&mut e);
        rc(&mut e, 1.0, intro());
        assert_eq!(e.display(), OfferingPresentation::Button(intro()));
        shut(&mut e);
        assert_eq!(e.display(), OfferingPresentation::Button(intro()));
    }

    #[test]
    fn back() {
        let mut e = OfferingLayer::new();
        rc(&mut e, 1.0, intro());
        let first_one = e.close();
        assert!(first_one);
        assert_eq!(e.display(), OfferingPresentation::Nothing);
        let second = e.close();
        assert!(!second, "zweites Zurück verlässt den Player");
        rc(&mut e, 1.0, ButtonOffering::Nobody);
        rc(&mut e, 1.0, intro());
        assert_eq!(e.display(), OfferingPresentation::Button(intro()));
    }

    #[test]
    fn next_only_with_card() {
        let mut e = OfferingLayer::new();
        assert_eq!(
            running_count(
                &mut e,
                60.0,
                ButtonOffering::NextEpisode,
                false,
                true,
                COUNTDOWN
            ),
            0
        );
        assert_eq!(e.display(), OfferingPresentation::Nothing);
        assert!(!e.next_at_end());
    }

    #[test]
    fn countdown() {
        let mut e = OfferingLayer::new();
        rc_card(&mut e, 6.5);
        assert_eq!(e.display(), OfferingPresentation::Card { share: 6.5 / 7.0 });
        assert_eq!(e.countdown_rest(), 1);
        assert!(e.next_at_end());
        assert_eq!(rc_card(&mut e, 0.5), 0);
        assert_eq!(
            e.display(),
            OfferingPresentation::Card { share: 1.0 },
            "rechnerisch voll …"
        );
        assert_eq!(
            rc_card(&mut e, 0.5),
            0,
            "… sichtbar voll erst nach dem Nachziehen, dann eine kurze Ruhe"
        );
        assert_eq!(rc_card(&mut e, 0.5), 1);
        assert_eq!(rc_card(&mut e, 5.0), 0);
    }

    #[test]
    fn countdown_short() {
        let mut e = OfferingLayer::new();
        assert_eq!(
            running_count(&mut e, 4.5, ButtonOffering::NextEpisode, true, true, 4.0),
            0
        );
        assert_eq!(
            running_count(&mut e, 0.5, ButtonOffering::NextEpisode, true, true, 4.0),
            1
        );
    }

    #[test]
    fn countdown_pause() {
        let mut e = OfferingLayer::new();
        rc_card(&mut e, 5.0);
        assert_eq!(
            running_count(
                &mut e,
                30.0,
                ButtonOffering::NextEpisode,
                true,
                false,
                COUNTDOWN
            ),
            0
        );
        assert_eq!(rc_card(&mut e, 5.0), 1);
    }

    #[test]
    fn countdown_controls() {
        let mut e = OfferingLayer::new();
        rc_card(&mut e, 3.0);
        open(&mut e);
        assert_eq!(
            e.display(),
            OfferingPresentation::Nothing,
            "bei offener Steuerung nur der normale Knopf"
        );
        assert!(e.next_cancelled());
        assert!(!e.next_at_end());
        shut(&mut e);
        assert_eq!(rc_card(&mut e, 30.0), 0);
        assert_eq!(
            e.display(),
            OfferingPresentation::Nothing,
            "nach dem Schließen kommt sie nicht wieder"
        );
    }

    #[test]
    fn pointer_does_not_cancel() {
        let mut e = OfferingLayer::new();
        rc_card(&mut e, 3.0);
        e.controls(true, Opening::Beside);
        assert_eq!(
            e.display(),
            OfferingPresentation::Card {
                share: 3.0 / COUNTDOWN
            }
        );
        assert!(!e.next_cancelled());
        // Further movement and a plain sync change nothing.
        e.controls(true, Opening::Beside);
        shut(&mut e);
        e.controls(true, Opening::Beside);
        assert_eq!(rc_card(&mut e, 8.0), 1);
    }

    #[test]
    fn pointer_then_deliberate() {
        let mut e = OfferingLayer::new();
        rc_card(&mut e, 2.0);
        e.controls(true, Opening::Beside);
        rc_card(&mut e, 1.0);
        e.controls(true, Opening::Deliberate);
        assert_eq!(e.display(), OfferingPresentation::Nothing);
        assert!(e.next_cancelled());
        // A later sync does not turn the controls back into "incidental".
        e.controls(true, Opening::Beside);
        assert_eq!(e.display(), OfferingPresentation::Nothing);
        assert_eq!(rc_card(&mut e, 30.0), 0);
    }

    #[test]
    fn countdown_behind_controls() {
        let mut e = OfferingLayer::new();
        open(&mut e);
        assert_eq!(rc_card(&mut e, 30.0), 0);
        assert!(!e.next_cancelled());
        shut(&mut e);
        assert_eq!(e.display(), OfferingPresentation::Card { share: 0.0 });
        assert_eq!(rc_card(&mut e, 8.0), 1);
    }

    #[test]
    fn countdown_cancel() {
        let mut e = OfferingLayer::new();
        rc_card(&mut e, 3.0);
        let toward = e.close();
        assert!(toward);
        assert!(e.next_cancelled());
        assert_eq!(rc_card(&mut e, 30.0), 0);
        e.new_episode();
        assert!(!e.next_cancelled());
    }

    #[test]
    fn fill_clock() {
        let mut u = FillClock::new();
        let t0 = 1_000.0;
        u.set(Some(0.0), true, 7.0, t0);
        assert_eq!(u.share(t0), 0.0);
        assert!(
            (u.share(t0 + 0.1) - 0.1 / 7.0).abs() < 1e-6,
            "zwischen den Takten weiter"
        );
        // The tick reports a smaller value than the clock: it stays with itself.
        u.set(Some(0.07), true, 7.0, t0 + 0.6);
        assert!((u.share(t0 + 0.7) - 0.1).abs() < 1e-6);
        // Pause at 3.5 s: it stands exactly there.
        u.set(Some(0.43), false, 7.0, t0 + 3.5);
        assert_eq!(u.share(t0 + 30.0), 0.5);
        // Continue: from there, not from the layer's smaller value.
        let t1 = t0 + 40.0;
        u.set(Some(0.43), true, 7.0, t1);
        assert_eq!(u.share(t1), 0.5);
        assert_eq!(u.share(t1 + 3.5), 1.0);
        assert_eq!(u.share(t1 + 10.0), 1.0);
        u.set(None, true, 7.0, t1);
        assert_eq!(u.share(t1 + 1.0), 0.0, "ohne Karte zurück auf null");
    }

    #[test]
    fn pressed() {
        let mut e = OfferingLayer::new();
        rc(&mut e, 1.0, intro());
        e.pressed();
        assert_eq!(e.display(), OfferingPresentation::Nothing);
    }

    #[test]
    fn advance() {
        assert!(Advance::applies(None, None));
        assert!(!Advance::applies(None, Some(false)));
        assert!(Advance::applies(Some(true), Some(false)));
        assert!(!Advance::applies(Some(false), Some(true)));
    }

    #[test]
    fn account_defaults() {
        let json = r#"{"Id":"x","Configuration":{"EnableNextEpisodeAutoPlay":false,"PlayDefaultAudioTrack":true}}"#;
        let v: AccountPreGift = serde_json::from_str(json).expect("decodes");
        assert_eq!(v.next_episode_automatic, Some(false));
        let without: AccountPreGift = serde_json::from_str(r#"{"Id":"x"}"#).expect("decodes");
        assert_eq!(without.next_episode_automatic, None);
    }

    // MARK: EpisodesCardTests (the 5 + 1 that need OfferingLayer; the 2 SectionLogic ones are in sections.rs)

    fn layer() -> OfferingLayer {
        let mut e = OfferingLayer::new();
        e.card_waits_controls = true;
        e
    }

    /// `e.tick(offering: .nextEpisode, cardDue: true, running: ..., elapsed: ...)` with defaults.
    fn tick_next(e: &mut OfferingLayer, running: bool, elapsed: f64) -> bool {
        e.tick(
            ButtonOffering::NextEpisode,
            true,
            running,
            elapsed,
            COUNTDOWN,
            false,
        )
    }

    #[test]
    fn controls_covered_and_holds_an() {
        let mut e = layer();
        let _ = tick_next(&mut e, true, 2.0);
        open(&mut e);
        assert_eq!(e.display(), OfferingPresentation::Nothing);
        // While open nothing advances, not even past the length.
        let jumped = tick_next(&mut e, true, 60.0);
        assert!(!jumped && e.next_at_end());
        shut(&mut e);
        let OfferingPresentation::Card { share } = e.display() else {
            panic!("keine Karte");
        };
        assert!((share - 2.0 / COUNTDOWN).abs() < 0.001);
    }

    #[test]
    fn cancel_says_next_off() {
        let mut e = layer();
        let _ = tick_next(&mut e, true, 1.0);
        let toward = e.close();
        assert!(toward);
        assert!(
            e.display() == OfferingPresentation::Nothing && !e.next_at_end() && !e.card_counts()
        );
    }

    #[test]
    fn without_toggle_how_until_from() {
        let mut e = OfferingLayer::new();
        let _ = tick_next(&mut e, true, 1.0);
        open(&mut e);
        assert!(e.display() == OfferingPresentation::Nothing && !e.next_at_end());
    }

    /// Full version of `EpisodesCardTests.endDoesNotSwitchPastCountdown` (swiftly-rules only
    /// has the `advance` half).
    #[test]
    fn end_does_not_switch_past_countdown() {
        let mut e = OfferingLayer::new();
        e.card_waits_controls = true;
        let _ = tick_next(&mut e, true, 0.0);
        assert!(e.card_counts());
        assert!(!episodes_end::advance(
            1500.0,
            1500.0,
            600.0,
            e.card_counts()
        ));
        // Without a card (cancelled or none) as before.
        assert!(episodes_end::advance(1500.0, 1500.0, 600.0, false));
    }

    #[test]
    fn at_end_counts_countdown_next() {
        let mut e = OfferingLayer::new();
        let _ = tick_next(&mut e, false, 0.0);
        let mut done = false;
        for _ in 0..40 {
            if done {
                break;
            }
            done = e.tick(
                ButtonOffering::NextEpisode,
                true,
                false,
                0.5,
                COUNTDOWN,
                true,
            );
        }
        assert!(done);
    }

    #[test]
    fn jump_sets_countdown_back() {
        let mut e = OfferingLayer::new();
        let _ = tick_next(&mut e, true, 5.0);
        e.jumped();
        let OfferingPresentation::Card { share } = e.display() else {
            panic!("keine Karte");
        };
        assert_eq!(share, 0.0);
    }

    // Extra (not in Swift): the policy block and the derived values.
    #[test]
    fn account_policy_block() {
        let json = r#"{"Policy":{"EnableContentDownloading":false,"EnableVideoPlaybackTranscoding":true,"EnableAudioPlaybackTranscoding":false}}"#;
        let v: AccountPreGift = serde_json::from_str(json).expect("decodes");
        assert_eq!(v.next_episode_automatic, None);
        assert_eq!(v.download_permission(), DownloadPermission::Forbidden);
        assert!(!v.download_quality_selectable());
        assert!(
            serde_json::from_str::<AccountPreGift>(
                r#"{"Policy":{"EnableContentDownloading":"x"}}"#
            )
            .is_err()
        );
        assert_eq!(OfferingLayer::new().countdown_length(), COUNTDOWN);
    }

    // Auto-skip: the offer shows first, acts only after the countdown (fake clock = ticks).

    /// Ticks the skip offer and counts how often the platform would press.
    fn skip_run(e: &mut OfferingLayer, seconds: f64, offer: ButtonOffering) -> usize {
        let mut presses = 0;
        for _ in 0..((seconds * 2.0) as usize) {
            e.tick(offer, false, true, 0.5, COUNTDOWN, false);
            if e.take_auto_skip() {
                presses += 1;
            }
        }
        presses
    }

    #[test]
    fn auto_skip_shows_the_offer_first_and_acts_after_the_countdown() {
        let mut e = OfferingLayer::new();
        e.auto_skip = true;
        // First tick of the section: nothing happened yet, the button is there at 0.
        assert_eq!(skip_run(&mut e, 0.5, intro()), 0);
        assert!(matches!(e.display(), OfferingPresentation::Button(_)));
        assert!(e.skip_share().unwrap() < 0.1);
        // Halfway through: still showing, fill grows, no action.
        assert_eq!(skip_run(&mut e, 2.5, intro()), 0);
        let half = e.skip_share().unwrap();
        assert!(half > 0.4 && half < 0.6, "{half}");
        assert!(e.display().visible());
        // The button's six seconds are up, but the rest of the last tick is still awaited.
        assert_eq!(skip_run(&mut e, 3.0, intro()), 0);
        assert!(e.display().visible());
        // Then it acts exactly once, and the overlay is gone.
        assert_eq!(skip_run(&mut e, 5.0, intro()), 1);
        assert!(!e.display().visible());
        assert_eq!(e.skip_share(), None);
    }

    #[test]
    fn auto_skip_dismiss_cancels_the_action() {
        let mut e = OfferingLayer::new();
        e.auto_skip = true;
        skip_run(&mut e, 2.0, intro());
        assert!(e.close());
        assert!(!e.display().visible());
        assert_eq!(skip_run(&mut e, 30.0, intro()), 0);
    }

    #[test]
    fn auto_skip_off_never_acts_and_has_no_countdown() {
        let mut e = OfferingLayer::new();
        assert_eq!(skip_run(&mut e, 60.0, intro()), 0);
        assert_eq!(e.skip_share(), None);
        // With the controls open the button waits for the press as long as it likes.
        open(&mut e);
        assert_eq!(skip_run(&mut e, 60.0, intro()), 0);
        assert!(e.display().visible());
    }

    #[test]
    fn auto_skip_paused_does_not_count() {
        let mut e = OfferingLayer::new();
        e.auto_skip = true;
        for _ in 0..200 {
            e.tick(intro(), false, false, 0.5, COUNTDOWN, false);
            assert!(!e.take_auto_skip());
        }
        assert!(e.display().visible());
    }

    #[test]
    fn auto_skip_outro_skip_and_a_second_section_start_clean() {
        let outro = ButtonOffering::Skip {
            to: 1500.0,
            art: Art::Credits,
        };
        let mut e = OfferingLayer::new();
        e.auto_skip = true;
        assert_eq!(skip_run(&mut e, 20.0, intro()), 1);
        // Out of the section and into the outro: counts again from zero.
        e.tick(ButtonOffering::Nobody, false, true, 0.5, COUNTDOWN, false);
        assert_eq!(skip_run(&mut e, 5.0, outro), 0);
        assert!(e.display().visible());
        assert_eq!(skip_run(&mut e, 5.0, outro), 1);
    }

    #[test]
    fn auto_skip_next_episode_card_counts_down_then_advances_and_dismiss_cancels() {
        // After the outro: the card (the fill) runs for COUNTDOWN, then it advances once.
        let mut e = OfferingLayer::new();
        e.auto_skip = true;
        assert_eq!(rc_card(&mut e, COUNTDOWN), 0);
        assert!(matches!(e.display(), OfferingPresentation::Card { .. }));
        assert_eq!(rc_card(&mut e, 5.0), 1);
        // Dismissed: no advance, not even at the end of the file.
        let mut e = OfferingLayer::new();
        e.auto_skip = true;
        rc_card(&mut e, 2.0);
        assert!(e.close());
        assert_eq!(rc_card(&mut e, 30.0), 0);
        assert!(!e.next_at_end());
    }
}
