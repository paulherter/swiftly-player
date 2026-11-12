//! The pure player helpers of the old Android facade (`Kern.delay*`, `firstFrame*`, `streamWatch*`, `rating*`,
//! `community*`, `nextAutomaticApplies`, `notch`, the settings lists), answered with the same strings and numbers.
//! Each one is compared with the Swift answer by a Kotlin test (`Android/golden`). Texts follow `locale`.

use std::collections::HashMap;
use std::sync::{Mutex, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::json;
use swiftly_l10n::{Arg, Locale, Translator};
use swiftly_playback::first_frame::{self, Level, Rat};
use swiftly_playback::offering_layer::Advance;
use swiftly_playback::stream_watch::{self, Advice};
use swiftly_rules::delay::{Delay, HoldCounter};

fn loc(locale: &str) -> Locale {
    Locale::parse(locale)
}

// ---- Delay ----------------------------------------------------------------------------------------------------

/// `Kern.delayState`: `{"millisekunden","text","istNull","amAnfang","amEnde"}`; the decimal separator follows `language`
/// (the device language), the unit text follows `locale` (the app language).
#[uniffi::export]
pub fn legacy_delay_state(milliseconds: i64, language: String, locale: String) -> String {
    let d = Delay::from_milliseconds(milliseconds);
    let figure = d.figure(swiftly_vm::decimal_separator(loc(&language).language()));
    let text = Translator::new(loc(&locale)).t_args("%@ s", &[Arg::Str(figure)]);
    json!({"millisekunden": d.milliseconds(), "text": text, "istNull": d.is_null(), "amAnfang": d.at_start(), "amEnde": d.at_end()})
        .to_string()
}

/// `Kern.delayShifted`: earlier (-1) or later (+1) by `steps` steps.
#[uniffi::export]
pub fn legacy_delay_shifted(milliseconds: i64, bearing: i64, steps: i64) -> i64 {
    Delay::from_milliseconds(milliseconds)
        .shifted(bearing, steps)
        .milliseconds()
}

/// `Kern.delayForNewTitle`: the same title or series keeps the delay, anything else starts at zero (empty series = none).
#[uniffi::export]
pub fn legacy_delay_for_new_title(
    milliseconds: i64,
    old_title: String,
    old_series: String,
    new_title: String,
    added_series: String,
) -> i64 {
    fn some(s: &str) -> Option<&str> {
        (!s.is_empty()).then_some(s)
    }
    Delay::for_new_title(
        Delay::from_milliseconds(milliseconds),
        &old_title,
        some(&old_series),
        &new_title,
        some(&added_series),
    )
    .milliseconds()
}

/// `Kern.delayMicroseconds`.
#[uniffi::export]
pub fn legacy_delay_microseconds(milliseconds: i64) -> i64 {
    Delay::from_milliseconds(milliseconds).microseconds()
}

/// `Kern.delaySoftFrom`: does the engine read something other than intended?
#[uniffi::export]
pub fn legacy_delay_soft_from(milliseconds: i64, read_microseconds: i64) -> bool {
    Delay::from_milliseconds(milliseconds).soft_off(read_microseconds)
}

/// The hold counters of `Kern.delayPress` (one per row of the delay sheet): a held button counts faster.
#[derive(uniffi::Object, Default)]
pub struct LegacyHoldCounters {
    rows: Mutex<HashMap<String, HoldCounter>>,
}

#[uniffi::export]
impl LegacyHoldCounters {
    /// A fresh set of counters.
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self::default()
    }

    /// `Kern.delayPress(row)`: how many steps this press counts for.
    pub fn press(&self, row: String) -> i64 {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0.0, |d| d.as_secs_f64());
        self.press_at(&row, now)
    }
}

impl LegacyHoldCounters {
    fn press_at(&self, row: &str, now: f64) -> i64 {
        let mut rows = self.rows.lock().unwrap_or_else(PoisonError::into_inner);
        rows.entry(row.to_owned()).or_default().press(now)
    }
}

// ---- First frame ----------------------------------------------------------------------------------------------

fn level(raw: i64) -> Level {
    match raw {
        1 => Level::OutputNew,
        2 => Level::Software,
        3 => Level::GivenUp,
        _ => Level::No,
    }
}

/// `Kern.firstFrameRat`: `nichts`, `warten`, `ausgabeNeu`, `softwareDekoder` or `aufgeben`.
#[uniffi::export]
pub fn legacy_first_frame_rat(
    has_video_track: bool,
    excluded: bool,
    shown: i64,
    runtime: f64,
    until_from: i64,
) -> String {
    match first_frame::rat(
        has_video_track,
        excluded,
        shown.max(0) as u64,
        runtime,
        level(until_from),
    ) {
        Rat::Nothing => "nichts",
        Rat::Wait => "warten",
        Rat::OutputNew => "ausgabeNeu",
        Rat::SoftwareDecoder => "softwareDekoder",
        Rat::GiveUp => "aufgeben",
    }
    .to_owned()
}

/// `Kern.firstFrameNext`: the stage after an advice.
#[uniffi::export]
pub fn legacy_first_frame_next(rat: String, until_from: i64) -> i64 {
    let r = match rat.as_str() {
        "ausgabeNeu" => Rat::OutputNew,
        "softwareDekoder" => Rat::SoftwareDecoder,
        "aufgeben" => Rat::GiveUp,
        _ => Rat::Nothing,
    };
    first_frame::next(r, level(until_from)) as i64
}

/// `Kern.firstFrameGrowth`: elapsed film time between two looks; `before` below 0 means no previous value.
#[uniffi::export]
pub fn legacy_first_frame_growth(before: f64, now: f64) -> f64 {
    first_frame::growth((before >= 0.0).then_some(before), now)
}

/// `Kern.firstFrameHint`: the notice for the tech badge, empty while nothing intervened.
#[uniffi::export]
pub fn legacy_first_frame_hint(rung: i64, locale: String) -> String {
    first_frame::hint_key(level(rung))
        .map(|k| Translator::new(loc(&locale)).t(k))
        .unwrap_or_default()
}

/// `Kern.firstFrameSoftwareOption`.
#[uniffi::export]
pub fn legacy_first_frame_software_option() -> String {
    first_frame::SOFTWARE_OPTION.to_owned()
}

// ---- Stream watch ---------------------------------------------------------------------------------------------

/// `Kern.streamWatchRat`: `nochNicht`, `sprungLaeuft`, `pufferWaechst` or `neuVerbinden`; a negative
/// `network_change_ago` means no change.
#[uniffi::export]
pub fn legacy_stream_watch_rat(
    standstill_since: f64,
    network_change_ago: f64,
    jump_open: bool,
    last_jump_ago: f64,
    buffer_grew_ago: f64,
) -> String {
    match stream_watch::advice(
        standstill_since,
        (network_change_ago >= 0.0).then_some(network_change_ago),
        jump_open,
        last_jump_ago,
        buffer_grew_ago,
    ) {
        Advice::NotYet => "nochNicht",
        Advice::JumpRunning => "sprungLaeuft",
        Advice::BufferGrows => "pufferWaechst",
        Advice::NewConnect => "neuVerbinden",
    }
    .to_owned()
}

/// `Kern.streamWatchImagesState`: are the frames standing while the clock runs? `before` below 0: no reference yet.
#[uniffi::export]
pub fn legacy_stream_watch_images_state(before: i64, now: i64) -> bool {
    stream_watch::images_state((before >= 0).then_some(before as u64), now.max(0) as u64)
        == Some(true)
}

/// `Kern.streamWatchNetworkChangeDeadline`.
#[uniffi::export]
pub fn legacy_stream_watch_network_change_deadline() -> f64 {
    stream_watch::NETWORK_SWITCH_DEADLINE
}

// ---- Rating, community, next episode, notch -------------------------------------------------------------------

/// `Kern.ratingCounts`: from 90 %, and only for more than a minute.
#[uniffi::export]
pub fn legacy_rating_counts(position: f64, duration: f64) -> bool {
    swiftly_vm::counts_as_ready(position, duration)
}

/// `Kern.ratingDue`: from the third finished title, once per version.
#[uniffi::export]
pub fn legacy_rating_due(done: i64, last_asked: String, version: String) -> bool {
    done >= swiftly_vm::RATING_THRESHOLD && last_asked != version
}

/// `Kern.communityTrigger`: `bewertung`, `discord` or empty; an empty `last_asked` means never asked.
#[uniffi::export]
pub fn legacy_community_trigger(
    done: i64,
    last_asked: String,
    version: String,
    discord_shown: bool,
    rating_possible: bool,
) -> String {
    let last = (!last_asked.is_empty()).then_some(last_asked.as_str());
    match swiftly_vm::kickoff(done, last, &version, discord_shown, rating_possible) {
        Some(swiftly_vm::Nudge::Rating) => "bewertung",
        Some(swiftly_vm::Nudge::Discord) => "discord",
        None => "",
    }
    .to_owned()
}

const DISCORD: &str = "https://discord.gg/MeGwfv3UwN";
const DISCORD_SHORT: &str = "discord.gg/MeGwfv3UwN";
const PLAY_STORE: &str = "https://play.google.com/store/apps/details?id=de.paulherter.swiftly";
const ERROR_SHORT: &str = "github.com/paulherter/swiftly-player/issues";
const ERROR_REPORT: &str = "https://github.com/paulherter/swiftly-player/issues/new";

/// Percent-encoding of one query item value as `URLComponents` writes it (the query-allowed set without `&`, `=`, `#`).
fn query_value(text: &str) -> String {
    let mut out = String::new();
    for b in text.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~!$'()*,;:@/?+".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// `Kern.communityAddress`: `discord`, `discordKurz`, `play`, `fehlerKurz`, otherwise a new GitHub issue with version and platform.
#[uniffi::export]
pub fn legacy_community_address(art: String, version: String, platform: String) -> String {
    match art.as_str() {
        "discord" => DISCORD.to_owned(),
        "discordKurz" => DISCORD_SHORT.to_owned(),
        "play" => PLAY_STORE.to_owned(),
        "fehlerKurz" => ERROR_SHORT.to_owned(),
        _ => format!(
            "{ERROR_REPORT}?body={}",
            query_value(&format!("\n\n---\nSwiftly {version} \u{b7} {platform}"))
        ),
    }
}

/// `Kern.nextAutomaticApplies`: the own choice before the account's before "on"; both `1`, `0` or empty.
#[uniffi::export]
pub fn legacy_next_automatic_applies(choice: String, account: String) -> bool {
    let read = |t: &str| (!t.is_empty()).then_some(t == "1");
    Advance::applies(read(&choice), read(&account))
}

/// `Kern.notch`: the notch in seconds the slider snaps to, -1 if none is near enough.
#[uniffi::export]
pub fn legacy_notch(value: f64, until: f64, marks: Vec<f64>, width: f64) -> f64 {
    swiftly_rules::notches_snap::notch(value, until, &marks, width).unwrap_or(-1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delay_text_and_limits() {
        let d: serde_json::Value =
            serde_json::from_str(&legacy_delay_state(-1500, "de-DE".into(), "de".into())).unwrap();
        assert_eq!(d["text"], "\u{2212}1,50 s");
        assert_eq!(d["amAnfang"], false);
        assert_eq!(legacy_delay_shifted(9950, 1, 5), 10_000);
        assert_eq!(
            legacy_delay_for_new_title(200, "a".into(), "s".into(), "b".into(), "s".into()),
            200
        );
        assert_eq!(
            legacy_delay_for_new_title(200, "a".into(), "".into(), "b".into(), "".into()),
            0
        );
    }

    #[test]
    fn held_button_counts_faster_and_rows_are_apart() {
        let c = LegacyHoldCounters::new();
        let first = c.press_at("audio", 10.0);
        let held: Vec<i64> = (1..8)
            .map(|i| c.press_at("audio", 10.0 + 0.1 * i as f64))
            .collect();
        assert!(held.last().unwrap() >= &first);
        assert_eq!(c.press_at("subtitle", 10.7), first);
    }

    #[test]
    fn first_frame_and_stream_watch_strings() {
        assert_eq!(legacy_first_frame_rat(true, false, 0, 5.0, 0), "ausgabeNeu");
        assert_eq!(legacy_first_frame_next("ausgabeNeu".into(), 0), 1);
        assert_eq!(legacy_first_frame_hint(0, "en".into()), "");
        assert_eq!(
            legacy_stream_watch_rat(7.0, -1.0, false, 100.0, 100.0),
            "neuVerbinden"
        );
        assert!(!legacy_stream_watch_images_state(-1, 5));
    }

    #[test]
    fn community_and_rating() {
        assert!(!legacy_rating_counts(30.0, 40.0));
        assert!(legacy_rating_counts(2400.0, 2500.0));
        assert_eq!(
            legacy_community_trigger(3, "".into(), "1.0".into(), false, true),
            "bewertung"
        );
        assert_eq!(
            legacy_community_trigger(5, "1.0".into(), "1.0".into(), false, true),
            "discord"
        );
        assert!(
            legacy_community_address("fehler".into(), "1.0".into(), "Android".into())
                .contains("issues/new?body=%0A%0A---%0ASwiftly%201.0%20%C2%B7%20Android")
        );
        assert!(legacy_next_automatic_applies("".into(), "".into()));
        assert!(!legacy_next_automatic_applies("0".into(), "1".into()));
        assert_eq!(legacy_notch(150.0, 2700.0, vec![90.0, 2500.0], 270.0), 90.0);
        assert_eq!(legacy_notch(1000.0, 2700.0, vec![90.0], 270.0), -1.0);
    }
}
