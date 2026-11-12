//! Port of `Takeover.swift` (JellyfinKit): decides whether there is anything to take over,
//! which other device it is, and what the card on the badge shows (`TakeoverModel.swift`,
//! `TakeoverCard`/`TakeoverSelection` in `Sources/Shared/Components.swift`).
//!
//! Sans-I/O: `now` is passed in as seconds since 1970 (UTC); `RemoteSession::last_activity`
//! is the server's ISO 8601 string and is read with [`swiftly_model::parse_timestamp`]. A
//! missing or unreadable time counts as fresh and sorts last.

use swiftly_jellyfin::RemoteSession;
use swiftly_model::{Item, parse_timestamp};

/// After this much silence a session counts as forgotten (seconds).
///
/// Jellyfin cleans up sessions late; an app that crashed stays "playing" there for minutes.
pub const IDLE_TIMEOUT: f64 = 90.0;

/// Head of the takeover hint (`DisplayMessage`) to the session handing over.
pub const HINT_HEADER: &str = swiftly_jellyfin::HINT_HEADER;

/// For this long a hint counts as announcing the next stop (seconds).
pub const HINT_DEADLINE: f64 = 3.0;

/// Ticks per second.
const TICKS: f64 = 10_000_000.0;

/// Does the session understand the takeover hint? Only the Swiftly player ("Swiftly
/// Player", formerly "Swiftly"); other programs show a `DisplayMessage` as text, and
/// Swiftly Music takes over nothing.
pub fn takes_hint(s: &RemoteSession) -> bool {
    let p = s.program.as_deref().unwrap_or("");
    p.starts_with("Swiftly") && p != "Swiftly Music"
}

/// Does a stop belong to a takeover? Only then does the picture go off as a card. The hint
/// comes before the stop; a stop from the dashboard or from another app comes without it.
/// `hint_pre`: seconds since the hint, `None` without a hint.
pub fn is_handoff(hint_pre: Option<f64>) -> bool {
    hint_pre.is_some_and(|h| (0.0..HINT_DEADLINE).contains(&h))
}

/// Seconds of the last activity; `None` if missing or unreadable.
fn activity(s: &RemoteSession) -> Option<f64> {
    s.last_activity.as_deref().and_then(parse_timestamp)
}

/// Everything that can be taken over, most recent activity first.
///
/// A list, not a single session: if something plays on two devices, the UI asks which one
/// is meant. The sort is stable, so ties keep the server's order.
pub fn offerings<'a>(
    sessions: &'a [RemoteSession],
    own_device_id: &str,
    own_user_id: &str,
    now: f64,
) -> Vec<&'a RemoteSession> {
    let mut list: Vec<&RemoteSession> = sessions
        .iter()
        .filter(|s| fits(s, own_device_id, own_user_id, now))
        .collect();
    // Most recent first: whoever did something last is probably sitting in front of it.
    list.sort_by(|a, b| {
        let (a, b) = (
            activity(a).unwrap_or(f64::NEG_INFINITY),
            activity(b).unwrap_or(f64::NEG_INFINITY),
        );
        b.total_cmp(&a)
    });
    list
}

/// The one, if there is only one; otherwise the most recent.
pub fn offering<'a>(
    sessions: &'a [RemoteSession],
    own_device_id: &str,
    own_user_id: &str,
    now: f64,
) -> Option<&'a RemoteSession> {
    offerings(sessions, own_device_id, own_user_id, now)
        .into_iter()
        .next()
}

/// Where watching continues here. The position of the session query lags by up to ten
/// seconds; on ending, the other device reports its exact stop and the server stores it on
/// the item. That one applies if it changed compared to before and is not behind the
/// session position; Jellyfin sets it to null near start and end, then the session
/// position is the better one.
///
/// `session`: seconds from the freshest session query; `saved_before`/`saved_afterwards`:
/// `PlaybackPositionTicks` of the item before and after ending.
pub fn start_point(session: f64, saved_before: Option<i64>, saved_afterwards: Option<i64>) -> f64 {
    let Some(afterwards) = saved_afterwards.filter(|a| Some(*a) != saved_before) else {
        return session;
    };
    let seconds = afterwards as f64 / TICKS;
    if seconds >= session - 1.0 {
        seconds
    } else {
        session
    }
}

fn fits(s: &RemoteSession, own_device_id: &str, own_user_id: &str, now: f64) -> bool {
    why_not(s, own_device_id, own_user_id, now).is_none()
}

/// Audio, audiobooks and music are not a takeover for the player.
fn is_video(title: &Item) -> bool {
    !matches!(
        title.type_.as_deref().unwrap_or(""),
        "Audio" | "AudioBook" | "MusicAlbum" | "Playlist"
    )
}

/// Why a session failed, in one word (log text), or `None` if it fits. The five conditions:
/// not ourselves; the own account only (the server answers with everything the user *may*
/// control); a playing video with an id; takes commands (otherwise two audio tracks fill
/// the room); fresh enough.
pub fn why_not(
    s: &RemoteSession,
    own_device_id: &str,
    own_user_id: &str,
    now: f64,
) -> Option<String> {
    if s.device_id.as_deref() == Some(own_device_id) {
        return Some("wir selbst".into());
    }
    let Some(whom) = s.user_id.as_deref() else {
        return Some("kein Konto genannt".into());
    };
    if whom != own_user_id {
        return Some("fremdes Konto".into());
    }
    let Some(title) = s.running.as_ref() else {
        return Some("spielt nichts".into());
    };
    if title.id.is_empty() {
        return Some("Titel ohne Kennung".into());
    }
    if !is_video(title) || s.program.as_deref() == Some("Swiftly Music") {
        return Some("kein Video".into());
    }
    if !s.takes_commands {
        return Some("nimmt keine Befehle".into());
    }
    if let Some(stir) = activity(s) {
        let older = now - stir;
        if older > IDLE_TIMEOUT {
            return Some(format!("still seit {} s", older as i64));
        }
    }
    None
}

// MARK: Where a film can be sent (`PlayTargets`, PlayOn.swift)

/// Why a session is not offered as a place to play on, in one word (log text), or `None`.
/// Unlike a takeover, nothing has to play there.
pub fn target_why_not(
    s: &RemoteSession,
    own_device_id: &str,
    own_user_id: &str,
    now: f64,
) -> Option<String> {
    let device = s.device_id.as_deref().filter(|d| !d.is_empty());
    let Some(device) = device else {
        return Some("ohne Geräte-ID".into());
    };
    if device == own_device_id {
        return Some("wir selbst".into());
    }
    let Some(whom) = s.user_id.as_deref() else {
        return Some("kein Konto genannt".into());
    };
    if whom != own_user_id {
        return Some("fremdes Konto".into());
    }
    if !takes_hint(s) {
        return Some("kein Swiftly".into());
    }
    if !s.takes_commands {
        return Some("nimmt keine Befehle".into());
    }
    if !s.playable_media_types.iter().any(|t| t == "Video") {
        return Some("spielt kein Video".into());
    }
    if let Some(stir) = activity(s) {
        let older = now - stir;
        if older > IDLE_TIMEOUT {
            return Some(format!("still seit {} s", older as i64));
        }
    }
    None
}

/// What the picker calls the device: its name, else the program.
pub fn target_name(s: &RemoteSession) -> String {
    match s.device_name.as_deref() {
        Some(n) if !n.is_empty() => n.to_owned(),
        _ => s.program.clone().unwrap_or_default(),
    }
}

/// Every device a film can be sent to: one entry per device (the freshest session), sorted by
/// name (then device id), not by activity, so the open picker does not shuffle.
pub fn play_targets(
    sessions: &[RemoteSession],
    own_device_id: &str,
    own_user_id: &str,
    now: f64,
) -> Vec<RemoteSession> {
    let mut freshest: Vec<RemoteSession> = Vec::new();
    for s in sessions
        .iter()
        .filter(|s| target_why_not(s, own_device_id, own_user_id, now).is_none())
    {
        match freshest.iter().position(|k| k.device_id == s.device_id) {
            Some(i) => {
                let known = activity(&freshest[i]).unwrap_or(f64::NEG_INFINITY);
                if known < activity(s).unwrap_or(f64::NEG_INFINITY) {
                    freshest[i] = s.clone();
                }
            }
            None => freshest.push(s.clone()),
        }
    }
    freshest.sort_by(|a, b| {
        target_name(a)
            .to_lowercase()
            .cmp(&target_name(b).to_lowercase())
            .then_with(|| a.device_id.cmp(&b.device_id))
    });
    freshest
}

/// After a server restart the own session is missing from the list: report the capabilities again.
pub fn must_report(sessions: &[RemoteSession], own_device_id: &str) -> bool {
    !sessions
        .iter()
        .any(|s| s.device_id.as_deref() == Some(own_device_id))
}

/// Which device: guessed from the name, the server gives no more. The glyphs stay with the
/// platform; only the decision is shared (`RemoteSession.DevicesKind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DevicesKind {
    /// Phone.
    Phone,
    /// Tablet.
    Tablet,
    /// Computer.
    Computer,
    /// TV.
    Tv,
    /// Unknown.
    Unknown,
}

/// `RemoteSession` extension of Takeover.swift: [`title_line`](Self::title_line) and
/// [`devices_kind`](Self::devices_kind).
pub trait RemoteSessionExt {
    /// "Adults · S2 F1" (German source text, via `Item::episode_code`): what is playing on
    /// the other side; the device name if nothing plays.
    fn title_line(&self) -> String;
    /// Which device it is, from program and name.
    fn devices_kind(&self) -> DevicesKind;
}

impl RemoteSessionExt for RemoteSession {
    fn title_line(&self) -> String {
        let Some(t) = self.running.as_ref() else {
            return self.device_name.clone().unwrap_or_default();
        };
        let mut parts: Vec<String> = Vec::new();
        match t.series_name.as_deref() {
            Some(series) if !series.is_empty() => parts.push(series.to_owned()),
            _ => parts.push(t.name.clone()),
        }
        if let Some(abbreviation) = t.episode_code() {
            parts.push(abbreviation);
        }
        parts.join(" · ")
    }

    fn devices_kind(&self) -> DevicesKind {
        let name = self.device_name.as_deref().unwrap_or("").to_lowercase();
        // Android first, after the program: an Android phone is called "Pixel 10 Pro".
        let app = self.program.as_deref().unwrap_or("").to_lowercase();
        if app.contains("android tv") {
            return DevicesKind::Tv;
        }
        if app.contains("android") {
            return DevicesKind::Phone;
        }
        if name.contains("ipad") {
            return DevicesKind::Tablet;
        }
        if name.contains("mac") || name.contains("pc") || name.contains("linux") {
            return DevicesKind::Computer;
        }
        if name.contains("iphone") || name.contains("phone") {
            return DevicesKind::Phone;
        }
        if name.contains("tv") || name.contains("appletv") {
            return DevicesKind::Tv;
        }
        DevicesKind::Unknown
    }
}

// MARK: Offer card state (TakeoverModel / TakeoverCard / TakeoverSelection)

/// What the takeover UI shows: nothing, the badge, the choice card, a running handover, or
/// the failure message.
#[derive(Debug, Clone, PartialEq)]
pub enum TakeoverOffer {
    /// Nothing to take over.
    None,
    /// The badge; a tap takes the only session directly or opens the choice with several.
    /// Never empty.
    Offer(Vec<RemoteSession>),
    /// The choice card ("Wo weiterschauen?") over a scrim.
    Choosing(Vec<RemoteSession>),
    /// A handover is running; a second tap must not start two playbacks.
    Taking(Box<RemoteSession>),
    /// The handover failed; the message stays until dismissed.
    Failed(String),
}

/// Events that move [`TakeoverOffer`].
#[derive(Debug, Clone, PartialEq)]
pub enum TakeoverEvent {
    /// The poll answered with these offerings (already filtered and sorted).
    Polled(Vec<RemoteSession>),
    /// The badge was tapped.
    Tapped,
    /// A row of the choice card was picked (session id).
    Selected(String),
    /// Scrim, "Abbrechen" or the failure message dismissed.
    Cancelled,
    /// The handover started playing here.
    Succeeded,
    /// The handover failed, with the message to show.
    Failed(String),
    /// Polling stopped (sign-out, view gone).
    Finished,
}

/// The pure transition of [`TakeoverOffer`]. While `Taking`, only the outcome (or
/// `Finished`) counts, like `takesOver` in the model; a failure message is not overwritten
/// by polls.
pub fn next(state: TakeoverOffer, event: TakeoverEvent) -> TakeoverOffer {
    use TakeoverEvent as E;
    use TakeoverOffer as S;
    match (state, event) {
        (_, E::Finished) => S::None,
        (S::Taking(_), E::Succeeded) => S::None,
        (S::Taking(_), E::Failed(message)) => S::Failed(message),
        (s @ (S::Taking(_) | S::Failed(_)), E::Polled(_)) => s,
        (S::Choosing(_), E::Polled(list)) if !list.is_empty() => S::Choosing(list),
        (_, E::Polled(list)) if list.is_empty() => S::None,
        (_, E::Polled(list)) => S::Offer(list),
        (S::Offer(mut list), E::Tapped) => {
            if list.len() == 1 {
                S::Taking(Box::new(list.remove(0)))
            } else {
                S::Choosing(list)
            }
        }
        (S::Choosing(list), E::Selected(id)) => match list.iter().position(|s| s.id == id) {
            Some(i) => S::Taking(Box::new(list[i].clone())),
            None => S::Choosing(list),
        },
        (S::Choosing(list), E::Cancelled) => S::Offer(list),
        (S::Failed(_), E::Cancelled) => S::None,
        (s, _) => s,
    }
}

#[cfg(test)]
#[allow(clippy::expect_used)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    const NOW: f64 = 1_700_000_000.0;

    /// ISO timestamp `back` seconds before [`NOW`] (2023-11-14T22:13:20Z; same day for
    /// `back` up to 80000).
    fn stamp(back: f64) -> String {
        let secs = 80_000 - back as i64;
        format!(
            "2023-11-14T{:02}:{:02}:{:02}Z",
            secs / 3600,
            secs % 3600 / 60,
            secs % 60
        )
    }

    fn title(id: &str) -> Value {
        json!({"Id": id, "Name": "Folge", "Type": "Episode"})
    }

    struct Make {
        id: &'static str,
        device: Option<&'static str>,
        user: Option<&'static str>,
        takes_commands: bool,
        running: Option<Value>,
        forward: Option<f64>,
    }

    impl Make {
        fn new() -> Self {
            Make {
                id: "s1",
                device: Some("iphone"),
                user: Some("paul"),
                takes_commands: true,
                running: None,
                forward: Some(5.0),
            }
        }
        fn build(self) -> RemoteSession {
            let v = json!({
                "Id": self.id,
                "DeviceId": self.device,
                "UserId": self.user,
                "DeviceName": "iPhone im Wohnzimmer",
                "Client": "Swiftly",
                "SupportsRemoteControl": self.takes_commands,
                "NowPlayingItem": self.running,
                "PlayState": {"IsPaused": false, "PositionTicks": 8_120_000_000_i64},
                "LastActivityDate": self.forward.map(stamp),
            });
            serde_json::from_value(v).expect("test session")
        }
    }

    fn raw(v: Value) -> RemoteSession {
        serde_json::from_value(v).expect("test session")
    }

    fn pick(list: &[RemoteSession]) -> Option<&RemoteSession> {
        offering(list, "appletv", "paul", NOW)
    }

    fn ids(list: &[&RemoteSession]) -> Vec<String> {
        list.iter().map(|s| s.id.clone()).collect()
    }

    #[test]
    fn stamp_helper_matches_now() {
        assert_eq!(parse_timestamp(&stamp(0.0)), Some(NOW));
    }

    #[test]
    fn normal() {
        let list = [Make {
            running: Some(title("e1")),
            ..Make::new()
        }
        .build()];
        let a = pick(&list);
        assert_eq!(a.map(|s| s.id.as_str()), Some("s1"));
        assert_eq!(
            a.and_then(|s| s.state.as_ref()).map(|p| p.spot()),
            Some(812.0)
        );
    }

    #[test]
    fn ticks() {
        let s = raw(
            json!({"Id":"s1","DeviceId":"x","SupportsRemoteControl":true,
            "PlayState":{"IsPaused":false,"PositionTicks":8_120_000_000_i64}}),
        );
        assert_eq!(s.state.map(|p| p.spot()), Some(812.0));
    }

    #[test]
    fn timestamp_with_seven_fraction_digits() {
        let s = raw(
            json!({"Id":"s1","DeviceId":"x","SupportsRemoteControl":true,
            "LastActivityDate":"2026-09-03T14:10:09.2201736Z"}),
        );
        let read = s.last_activity.as_deref().and_then(parse_timestamp);
        assert!(read.is_some());
        // 2026-09-03T14:10:09Z is 1_788_444_609 s since 1970.
        assert!((read.unwrap_or(0.0) - 1_788_444_609.22).abs() < 1.0);
    }

    #[test]
    fn timestamp_without_fraction() {
        let s = raw(
            json!({"Id":"s1","DeviceId":"x","SupportsRemoteControl":true,
            "LastActivityDate":"2026-09-03T14:10:09Z"}),
        );
        assert!(
            s.last_activity
                .as_deref()
                .and_then(parse_timestamp)
                .is_some()
        );
    }

    #[test]
    fn never_offers_the_own_device() {
        let list = [Make {
            device: Some("appletv"),
            running: Some(title("e1")),
            ..Make::new()
        }
        .build()];
        assert!(pick(&list).is_none());
    }

    #[test]
    fn without_title_not_offered() {
        assert!(pick(&[Make::new().build()]).is_none());
    }

    #[test]
    fn without_remote_control_not_offered() {
        let list = [Make {
            takes_commands: false,
            running: Some(title("e1")),
            ..Make::new()
        }
        .build()];
        assert!(pick(&list).is_none());
    }

    #[test]
    fn too_old_after_90_seconds() {
        let old = [Make {
            running: Some(title("e1")),
            forward: Some(91.0),
            ..Make::new()
        }
        .build()];
        assert!(pick(&old).is_none());
        let fresh = [Make {
            running: Some(title("e1")),
            forward: Some(89.0),
            ..Make::new()
        }
        .build()];
        assert!(pick(&fresh).is_some());
    }

    #[test]
    fn without_time_counts_as_fresh() {
        let list = [Make {
            running: Some(title("e1")),
            forward: None,
            ..Make::new()
        }
        .build()];
        assert!(pick(&list).is_some());
    }

    #[test]
    fn foreign_account_never_offered() {
        let list = [Make {
            user: Some("koney"),
            running: Some(title("e1")),
            ..Make::new()
        }
        .build()];
        assert!(pick(&list).is_none());
    }

    #[test]
    fn without_account_not_offered() {
        let list = [Make {
            user: None,
            running: Some(title("e1")),
            ..Make::new()
        }
        .build()];
        assert!(pick(&list).is_none());
    }

    #[test]
    fn own_account_on_another_device() {
        let list = [Make {
            user: Some("paul"),
            running: Some(title("e1")),
            ..Make::new()
        }
        .build()];
        assert!(pick(&list).is_some());
    }

    #[test]
    fn youngest_activity_wins_regardless_of_order() {
        let old = Make {
            id: "alt",
            device: Some("ipad"),
            running: Some(title("e1")),
            forward: Some(60.0),
            ..Make::new()
        }
        .build();
        let new = Make {
            id: "neu",
            device: Some("iphone"),
            running: Some(title("e1")),
            forward: Some(3.0),
            ..Make::new()
        }
        .build();
        assert_eq!(
            pick(&[old.clone(), new.clone()]).map(|s| s.id.as_str()),
            Some("neu")
        );
        assert_eq!(pick(&[new, old]).map(|s| s.id.as_str()), Some("neu"));
    }

    #[test]
    fn unfit_are_skipped_not_the_whole_run() {
        let itself = Make {
            id: "selbst",
            device: Some("appletv"),
            running: Some(title("e1")),
            forward: Some(1.0),
            ..Make::new()
        }
        .build();
        let good = Make {
            id: "gut",
            device: Some("iphone"),
            running: Some(title("e1")),
            forward: Some(30.0),
            ..Make::new()
        }
        .build();
        assert_eq!(pick(&[itself, good]).map(|s| s.id.as_str()), Some("gut"));
    }

    #[test]
    fn two_devices_youngest_first() {
        let old = Make {
            id: "ipad",
            device: Some("ipad"),
            running: Some(title("e1")),
            forward: Some(40.0),
            ..Make::new()
        }
        .build();
        let new = Make {
            id: "iphone",
            device: Some("iphone"),
            running: Some(title("e1")),
            forward: Some(3.0),
            ..Make::new()
        }
        .build();
        let list = [old, new];
        assert_eq!(
            ids(&offerings(&list, "appletv", "paul", NOW)),
            ["iphone", "ipad"]
        );
    }

    #[test]
    fn ties_keep_server_order() {
        let a = Make {
            id: "a",
            device: Some("d1"),
            running: Some(title("e1")),
            forward: None,
            ..Make::new()
        }
        .build();
        let b = Make {
            id: "b",
            device: Some("d2"),
            running: Some(title("e1")),
            forward: None,
            ..Make::new()
        }
        .build();
        let list = [a, b];
        assert_eq!(ids(&offerings(&list, "appletv", "paul", NOW)), ["a", "b"]);
    }

    #[test]
    fn unfit_are_not_in_the_list() {
        let foreign = Make {
            id: "fremd",
            device: Some("mac"),
            user: Some("koney"),
            running: Some(title("e1")),
            ..Make::new()
        }
        .build();
        let itself = Make {
            id: "selbst",
            device: Some("appletv"),
            running: Some(title("e1")),
            ..Make::new()
        }
        .build();
        let good = Make {
            id: "gut",
            device: Some("iphone"),
            running: Some(title("e1")),
            ..Make::new()
        }
        .build();
        let list = [foreign, itself, good];
        assert_eq!(ids(&offerings(&list, "appletv", "paul", NOW)), ["gut"]);
    }

    #[test]
    fn no_sessions_no_offer() {
        assert!(pick(&[]).is_none());
    }

    #[test]
    fn music_and_audio_are_not_offered() {
        let audio = Make {
            running: Some(json!({"Id":"a1","Name":"Lied","Type":"Audio"})),
            ..Make::new()
        }
        .build();
        assert!(pick(&[audio]).is_none());
        let music = raw(
            json!({"Id":"m","DeviceId":"x","UserId":"paul","Client":"Swiftly Music",
            "SupportsRemoteControl":true,"NowPlayingItem":title("e1")}),
        );
        assert!(pick(&[music]).is_none());
    }

    #[test]
    fn why_not_names_the_first_failing_condition() {
        let why = |s: &RemoteSession| why_not(s, "appletv", "paul", NOW);
        assert_eq!(
            why(&Make {
                device: Some("appletv"),
                ..Make::new()
            }
            .build())
            .as_deref(),
            Some("wir selbst")
        );
        assert_eq!(
            why(&Make {
                user: None,
                ..Make::new()
            }
            .build())
            .as_deref(),
            Some("kein Konto genannt")
        );
        assert_eq!(
            why(&Make {
                user: Some("x"),
                ..Make::new()
            }
            .build())
            .as_deref(),
            Some("fremdes Konto")
        );
        assert_eq!(why(&Make::new().build()).as_deref(), Some("spielt nichts"));
        let old = Make {
            running: Some(title("e1")),
            forward: Some(120.0),
            ..Make::new()
        }
        .build();
        assert_eq!(why(&old).as_deref(), Some("still seit 120 s"));
        let ok = Make {
            running: Some(title("e1")),
            ..Make::new()
        }
        .build();
        assert_eq!(why(&ok), None);
    }

    fn kind(name: Option<&str>, program: Option<&str>) -> DevicesKind {
        raw(json!({"Id":"g","DeviceId":"x","DeviceName":name,"Client":program,"SupportsRemoteControl":true}))
            .devices_kind()
    }

    #[test]
    fn android_phone_is_a_phone() {
        assert_eq!(
            kind(Some("Pixel 10 Pro"), Some("Swiftly Player Android")),
            DevicesKind::Phone
        );
    }

    #[test]
    fn android_tv_is_a_tv() {
        assert_eq!(
            kind(Some("TCL 55C805"), Some("Swiftly Player Android TV")),
            DevicesKind::Tv
        );
    }

    #[test]
    fn without_android_the_name_decides() {
        assert_eq!(
            kind(Some("iPhone im Wohnzimmer"), Some("Swiftly Player")),
            DevicesKind::Phone
        );
        assert_eq!(kind(Some("iPad"), None), DevicesKind::Tablet);
        assert_eq!(kind(Some("Paul-PC"), None), DevicesKind::Computer);
        assert_eq!(kind(None, None), DevicesKind::Unknown);
    }

    #[test]
    fn title_line_composes_series_and_code() {
        let s = raw(
            json!({"Id":"g","SupportsRemoteControl":true,"DeviceName":"TV",
            "NowPlayingItem":{"Id":"e","Name":"Pilot","Type":"Episode","SeriesName":"Adults",
                "ParentIndexNumber":2,"IndexNumber":1}}),
        );
        assert_eq!(s.title_line(), "Adults · S2 · F1");
        let movie = raw(json!({"Id":"g","SupportsRemoteControl":true,
            "NowPlayingItem":{"Id":"m","Name":"Film","Type":"Movie"}}));
        assert_eq!(movie.title_line(), "Film");
        let idle = raw(json!({"Id":"g","SupportsRemoteControl":true,"DeviceName":"Wohnzimmer"}));
        assert_eq!(idle.title_line(), "Wohnzimmer");
    }

    #[test]
    fn start_point_after_stop() {
        // Session reported 600 s, the stop 608 s.
        assert_eq!(
            start_point(600.0, Some(1_000_000_000), Some(6_080_000_000)),
            608.0
        );
    }

    #[test]
    fn start_point_without_new_stop_or_reset() {
        assert_eq!(start_point(600.0, Some(50), Some(50)), 600.0);
        assert_eq!(start_point(600.0, Some(50), None), 600.0);
        assert_eq!(start_point(600.0, Some(50), Some(0)), 600.0);
    }

    #[test]
    fn hint_only_for_swiftly_player_and_fresh() {
        let s = |p: Option<&str>| {
            raw(
                json!({"Id":"s","DeviceId":"g","DeviceName":"Wohnzimmer","Client":p,"SupportsRemoteControl":true}),
            )
        };
        assert!(takes_hint(&s(Some("Swiftly Player"))));
        assert!(takes_hint(&s(Some("Swiftly"))));
        assert!(!takes_hint(&s(Some("Swiftly Music"))));
        assert!(!takes_hint(&s(Some("Jellyfin Web"))));
        assert!(!takes_hint(&s(None)));
        assert!(is_handoff(Some(0.2)));
        assert!(!is_handoff(None));
        assert!(!is_handoff(Some(5.0)));
        assert!(!is_handoff(Some(-1.0)));
        assert_eq!(HINT_HEADER, "Swiftly-Uebernahme");
    }

    // MARK: offer card state

    fn playing(id: &'static str, device: &'static str) -> RemoteSession {
        Make {
            id,
            device: Some(device),
            running: Some(title("e1")),
            ..Make::new()
        }
        .build()
    }

    #[test]
    fn poll_shows_and_clears_the_badge() {
        let a = playing("a", "d1");
        let s = next(TakeoverOffer::None, TakeoverEvent::Polled(vec![a.clone()]));
        assert_eq!(s, TakeoverOffer::Offer(vec![a]));
        assert_eq!(next(s, TakeoverEvent::Polled(vec![])), TakeoverOffer::None);
    }

    #[test]
    fn single_session_is_taken_directly() {
        let a = playing("a", "d1");
        let s = next(TakeoverOffer::Offer(vec![a.clone()]), TakeoverEvent::Tapped);
        assert_eq!(s, TakeoverOffer::Taking(Box::new(a)));
    }

    #[test]
    fn several_sessions_open_the_choice_then_take_the_picked_one() {
        let (a, b) = (playing("a", "d1"), playing("b", "d2"));
        let s = next(
            TakeoverOffer::Offer(vec![a.clone(), b.clone()]),
            TakeoverEvent::Tapped,
        );
        assert_eq!(s, TakeoverOffer::Choosing(vec![a.clone(), b.clone()]));
        // Unknown id changes nothing.
        let same = next(s.clone(), TakeoverEvent::Selected("zzz".into()));
        assert_eq!(same, s);
        assert_eq!(
            next(s.clone(), TakeoverEvent::Selected("b".into())),
            TakeoverOffer::Taking(Box::new(b.clone()))
        );
        // Cancel goes back to the badge; a poll keeps the card open.
        assert_eq!(
            next(s.clone(), TakeoverEvent::Cancelled),
            TakeoverOffer::Offer(vec![a.clone(), b.clone()])
        );
        assert_eq!(
            next(s.clone(), TakeoverEvent::Polled(vec![b.clone()])),
            TakeoverOffer::Choosing(vec![b])
        );
        assert_eq!(next(s, TakeoverEvent::Polled(vec![])), TakeoverOffer::None);
    }

    #[test]
    fn taking_ignores_taps_and_polls_until_the_outcome() {
        let a = playing("a", "d1");
        let t = TakeoverOffer::Taking(Box::new(a));
        assert_eq!(next(t.clone(), TakeoverEvent::Tapped), t);
        assert_eq!(next(t.clone(), TakeoverEvent::Polled(vec![])), t);
        assert_eq!(next(t.clone(), TakeoverEvent::Cancelled), t);
        assert_eq!(
            next(t.clone(), TakeoverEvent::Succeeded),
            TakeoverOffer::None
        );
        assert_eq!(
            next(t, TakeoverEvent::Failed("nein".into())),
            TakeoverOffer::Failed("nein".into())
        );
    }

    #[test]
    fn failure_stays_until_dismissed_and_finish_clears_everything() {
        let f = TakeoverOffer::Failed("nein".into());
        assert_eq!(
            next(f.clone(), TakeoverEvent::Polled(vec![playing("a", "d1")])),
            f
        );
        assert_eq!(
            next(f.clone(), TakeoverEvent::Cancelled),
            TakeoverOffer::None
        );
        assert_eq!(next(f, TakeoverEvent::Finished), TakeoverOffer::None);
        let t = TakeoverOffer::Taking(Box::new(playing("a", "d1")));
        assert_eq!(next(t, TakeoverEvent::Finished), TakeoverOffer::None);
    }

    fn target(
        id: &str,
        device: &str,
        name: &str,
        user: &str,
        program: &str,
        back: f64,
        video: bool,
    ) -> RemoteSession {
        serde_json::from_value(json!({
            "Id": id, "DeviceId": device, "DeviceName": name, "UserId": user, "Client": program,
            "SupportsRemoteControl": true, "LastActivityDate": stamp(back),
            "PlayableMediaTypes": if video { json!(["Audio", "Video"]) } else { json!(["Audio"]) },
        }))
        .expect("session")
    }

    #[test]
    fn play_targets_table() {
        let list = vec![
            target("a", "tv1", "Wohnzimmer", "u", "Swiftly Player", 30.0, true),
            target("b", "tv1", "Wohnzimmer", "u", "Swiftly Player", 5.0, true), // fresher duplicate of tv1
            target("c", "own", "Phone", "u", "Swiftly Player", 5.0, true),      // ourselves
            target("d", "tv2", "Arbeit", "other", "Swiftly Player", 5.0, true), // foreign account
            target("e", "tv3", "Bad", "u", "Swiftly Music", 5.0, true),         // not Swiftly
            target("f", "tv4", "Küche", "u", "Swiftly Player", 5.0, false),     // no video
            target("g", "tv5", "Garten", "u", "Swiftly Player", 600.0, true),   // silent too long
            target(
                "h",
                "tv6",
                "Arbeitszimmer",
                "u",
                "Swiftly Player",
                5.0,
                true,
            ),
        ];
        let got = play_targets(&list, "own", "u", NOW);
        let ids: Vec<&str> = got.iter().map(|s| s.id.as_str()).collect();
        assert_eq!(
            ids,
            ["h", "b"],
            "sorted by name, one per device, the freshest session"
        );
        assert_eq!(
            target_why_not(&list[2], "own", "u", NOW).as_deref(),
            Some("wir selbst")
        );
        assert_eq!(
            target_why_not(&list[3], "own", "u", NOW).as_deref(),
            Some("fremdes Konto")
        );
        assert_eq!(
            target_why_not(&list[4], "own", "u", NOW).as_deref(),
            Some("kein Swiftly")
        );
        assert_eq!(
            target_why_not(&list[5], "own", "u", NOW).as_deref(),
            Some("spielt kein Video")
        );
        assert!(
            target_why_not(&list[6], "own", "u", NOW)
                .unwrap_or_default()
                .starts_with("still seit")
        );
        assert!(must_report(&list[..1], "own") && !must_report(&list, "own"));
        assert_eq!(target_name(&list[0]), "Wohnzimmer");
    }
}
